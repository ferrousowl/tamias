// Operator smoke test of the Circle Gateway path on mainnet: move a small amount into the
// treasury's Gateway balance, then recall it through a burn intent the contract authorizes itself
// (ERC-1271), the keyless Gateway API, and gatewayMint. Both records say it is an operator test.
//
//   cd agent && TAMIAS_NETWORK=mainnet node gateway-smoke.mjs 0.1
import fs from "fs";
import { toHex } from "viem";
import { loadConfig, clients, TAMIAS_ABI, USDC, toUnits, fees, log, statePath } from "./lib.mjs";
import { recallIntent, digestOf, savePending, settlePending, gatewayBalances } from "./gateway.mjs";

const amount = Number(process.argv[2] ?? "0.1");
const cfg = loadConfig();
const { pub, wallet } = clients(cfg);
const agent = wallet(cfg.keys.agent);
const T = { address: cfg.tamias, abi: TAMIAS_ABI };
const rec = (o) => toHex(new TextEncoder().encode(JSON.stringify({ v: 1, app: "tamias", operator: "smoke test of the Gateway path, run by the operator, not an agent decision", ...o })));

// hold the agent's cycle lock so a timer-started cycle cannot race this on the agent's nonce
const lock = statePath("cycle.lock");
if (fs.existsSync(lock)) throw new Error("a cycle is running; try again in a minute");
fs.writeFileSync(lock, String(process.pid));
process.on("exit", () => { try { fs.unlinkSync(lock); } catch {} });

async function send(label, functionName, args) {
  await pub.simulateContract({ ...T, functionName, args, account: agent.account });
  const hash = await agent.writeContract({ ...T, functionName, args, ...(await fees(pub)) });
  const rc = await pub.waitForTransactionReceipt({ hash });
  if (rc.status !== "success") throw new Error(`${label} reverted ${hash}`);
  log(`${label}: ${hash}`);
  return hash;
}

const units = toUnits(amount);
await send(`toGateway ${amount}`, "toGateway", [units, rec({ do: { type: "to_gateway", amount } })]);

// wait until Gateway's API counts the deposit
for (let i = 0; i < 40; i++) {
  const r = await fetch(`${cfg.gateway.api}/v1/balances`, {
    method: "POST", headers: { "content-type": "application/json", "user-agent": "tamias-agent/1.0" },
    body: JSON.stringify({ token: "USDC", sources: [{ domain: cfg.gateway.domain, depositor: cfg.tamias }] }),
  });
  const j = await r.json();
  const bal = Number(j.balances?.[0]?.balance ?? 0);
  log(`Gateway API balance: ${bal}`);
  if (bal >= amount) break;
  await new Promise((r) => setTimeout(r, 15_000));
}

// recall what is there minus the fee
const bi0 = await recallIntent(cfg, 1n);
const value = units - bi0.maxFee;
const bi = await recallIntent(cfg, value);
const digest = digestOf(bi);
const onchain = await pub.readContract({ ...T, functionName: "intentDigest", args: [bi] });
if (onchain !== digest) throw new Error(`digest mismatch ${onchain} vs ${digest}`);
log(`recall ${Number(value) / 1e6} USDC, fee cap ${Number(bi.maxFee) / 1e6}, maxBlockHeight ${bi.maxBlockHeight}, digest ${digest}`);
const authTx = await send("authorizeIntent (recall)", "authorizeIntent", [bi, (1n << 256n) - 1n, rec({ do: { type: "recall_gateway", amount: Number(value) / 1e6, intent: digest } })]);
savePending({ kind: "recall", digest, bi: JSON.parse(JSON.stringify(bi, (_, v) => (typeof v === "bigint" ? v.toString() : v))), at: new Date().toISOString(), authTx, smoke: true });
const done = await settlePending(cfg, pub, agent, { waitMs: 9 * 60e3 });
log(done.length ? `minted back: ${JSON.stringify(done.map((d) => d.minted))}` : "not attested yet; the agent's next cycles will keep trying until the authorization lapses");
console.log(JSON.stringify(await gatewayBalances(cfg, pub, { treasury: cfg.tamias })));
