// Circle Gateway, keyless: the treasury's reserve lives in GatewayWallet as a unified USDC balance.
// Spending it takes a burn intent that the Tamias contract itself authorizes (ERC-1271) after
// checking it against policy; this module builds the intent, gets Gateway's fee estimate, submits
// the authorized intent to the Gateway API, and mints the attestation on Arc.
import crypto from "crypto";
import { hashTypedData, pad, parseAbi } from "viem";
import { fees, log, readJson, writeJson, TAMIAS_ABI, USDC } from "./lib.mjs";

const UA = { "content-type": "application/json", "user-agent": "tamias-agent/1.0" };
const MINTER_ABI = parseAbi(["function gatewayMint(bytes attestationPayload, bytes signature)"]);
export const GATEWAY_WALLET_ABI = parseAbi([
  "function availableBalance(address token, address depositor) view returns (uint256)",
  "function withdrawingBalance(address token, address depositor) view returns (uint256)",
]);

const b32 = (a) => pad(a.toLowerCase(), { size: 32 });

const TYPES = {
  TransferSpec: [
    { name: "version", type: "uint32" }, { name: "sourceDomain", type: "uint32" }, { name: "destinationDomain", type: "uint32" },
    { name: "sourceContract", type: "bytes32" }, { name: "destinationContract", type: "bytes32" }, { name: "sourceToken", type: "bytes32" },
    { name: "destinationToken", type: "bytes32" }, { name: "sourceDepositor", type: "bytes32" }, { name: "destinationRecipient", type: "bytes32" },
    { name: "sourceSigner", type: "bytes32" }, { name: "destinationCaller", type: "bytes32" }, { name: "value", type: "uint256" },
    { name: "salt", type: "bytes32" }, { name: "hookData", type: "bytes" },
  ],
  BurnIntent: [{ name: "maxBlockHeight", type: "uint256" }, { name: "maxFee", type: "uint256" }, { name: "spec", type: "TransferSpec" }],
};

const jsonBig = (o) => JSON.stringify(o, (_, v) => (typeof v === "bigint" ? v.toString() : v));

async function api(cfg, path, body) {
  const r = await fetch(cfg.gateway.api + path, { method: body ? "POST" : "GET", headers: UA, body: body ? jsonBig(body) : undefined });
  const text = await r.text();
  if (!r.ok) throw new Error(`Gateway ${path} ${r.status}: ${text.slice(0, 300)}`);
  return JSON.parse(text);
}

/** A recall intent: the treasury's Gateway balance back to the treasury on this chain. */
export async function recallIntent(cfg, valueUnits) {
  const g = cfg.gateway;
  const spec = {
    version: 1, sourceDomain: g.domain, destinationDomain: g.domain,
    sourceContract: b32(g.wallet), destinationContract: b32(g.minter),
    sourceToken: b32(USDC), destinationToken: b32(USDC),
    sourceDepositor: b32(cfg.tamias), destinationRecipient: b32(cfg.tamias), sourceSigner: b32(cfg.tamias),
    destinationCaller: b32("0x0000000000000000000000000000000000000000"),
    value: valueUnits, salt: "0x" + crypto.randomBytes(32).toString("hex"), hookData: "0x",
  };
  // Gateway decides how long an intent must stay valid and what it costs; ask it.
  const [est] = await api(cfg, "/v1/estimate", [{ spec }]);
  const maxFee = BigInt(est.burnIntent.maxFee);
  const maxBlockHeight = BigInt(est.burnIntent.maxBlockHeight);
  return { maxBlockHeight, maxFee, spec };
}

export const digestOf = (bi) => hashTypedData({ domain: { name: "GatewayWallet", version: "1" }, types: TYPES, primaryType: "BurnIntent", message: bi });

/** Remember an authorized intent until it is minted. */
export function savePending(entry) {
  const p = readJson("gateway-pending.json", []);
  p.push(entry);
  writeJson("gateway-pending.json", p);
}

/**
 * Submit authorized intents to Gateway and mint them. Gateway checks the contract's signature
 * against blocks up to 5 minutes old, so a fresh authorization can be refused for a few minutes:
 * keep retrying until `waitMs` runs out, then leave it for the next cycle.
 */
export async function settlePending(cfg, pub, agentWallet, { waitMs = 7 * 60e3 } = {}) {
  const pending = readJson("gateway-pending.json", []);
  const done = [];
  for (const p of pending) {
    if (p.minted || p.dead) continue;
    const bi = { maxBlockHeight: BigInt(p.bi.maxBlockHeight), maxFee: BigInt(p.bi.maxFee), spec: { ...p.bi.spec, value: BigInt(p.bi.spec.value) } };
    const ok = await pub.readContract({ address: cfg.tamias, abi: TAMIAS_ABI, functionName: "isValidSignature", args: [p.digest, "0x00"] });
    if (ok !== "0x1626ba7e") { p.dead = true; p.error = "authorization lapsed (window passed or a brake was applied)"; continue; }
    const until = Date.now() + waitMs;
    let res = null, lastErr = "";
    while (!res && Date.now() < until) {
      try {
        res = await api(cfg, "/v1/transfer", [{ burnIntent: bi, signature: "0x00", contractSigner: true }]);
      } catch (e) {
        lastErr = e.message;
        await new Promise((r) => setTimeout(r, 45_000));
      }
    }
    if (!res) { p.error = lastErr; p.tries = (p.tries ?? 0) + 1; log(`gateway intent ${p.digest.slice(0, 10)} not attested yet: ${lastErr}`); continue; }
    const hash = await agentWallet.writeContract({ address: cfg.gateway.minter, abi: MINTER_ABI, functionName: "gatewayMint", args: [res.attestation, res.signature], ...(await fees(pub)) });
    const rc = await pub.waitForTransactionReceipt({ hash, timeout: 120_000 });
    if (rc.status !== "success") { p.error = `mint reverted ${hash}`; continue; }
    p.minted = { tx: hash, transferId: res.transferId, at: new Date().toISOString() };
    delete p.error;
    log(`gateway ${p.kind} of ${Number(p.bi.spec.value) / 1e6} USDC minted: ${hash}`);
    done.push(p);
  }
  writeJson("gateway-pending.json", pending);
  return done;
}

export async function gatewayBalances(cfg, pub, addresses) {
  const out = {};
  for (const [k, a] of Object.entries(addresses)) {
    const [avail, withdrawing] = await Promise.all([
      pub.readContract({ address: cfg.gateway.wallet, abi: GATEWAY_WALLET_ABI, functionName: "availableBalance", args: [USDC, a] }),
      pub.readContract({ address: cfg.gateway.wallet, abi: GATEWAY_WALLET_ABI, functionName: "withdrawingBalance", args: [USDC, a] }),
    ]);
    out[k] = { available: Number(avail) / 1e6, withdrawing: Number(withdrawing) / 1e6 };
  }
  return out;
}
