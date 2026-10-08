// x402: the agent buys information it decides it needs, per request, in USDC on Arc.
// Payments come from the agent's own hot wallet, which the treasury refills only through a payee
// whose budget category caps the agent's spending on-chain. On top of that, every purchase must be
// from the owner's catalog, on Arc, in USDC, and at or under the catalog price.
import { wrapFetchWithPaymentFromConfig, decodePaymentResponseHeader } from "@x402/fetch";
import { ExactEvmScheme } from "@x402/evm";
import { USDC, log, readJsonl } from "./lib.mjs";

const ARC = "eip155:5042";

export function catalogText(cfg) {
  return (cfg.x402?.services ?? []).map((s) => `- "${s.id}": ${s.what} (≈${s.price} USDC per call)`).join("\n");
}

/** Buy one catalog item. Returns { id, price, payTo, settlement, text } or throws. */
export async function buyInfo(cfg, account, id) {
  const s = (cfg.x402?.services ?? []).find((x) => x.id === id);
  if (!s) throw new Error(`"${id}" is not in the catalog`);
  // a local total cap on top of the on-chain budget that refills the purchase wallet
  const spent = readJsonl("purchases.jsonl").reduce((t, p) => t + (p.error ? 0 : p.price ?? 0), 0);
  if (cfg.x402?.totalCap != null && spent + s.price > cfg.x402.totalCap) throw new Error(`total x402 cap reached (${spent.toFixed(4)} of ${cfg.x402.totalCap} USDC spent)`);
  const maxUnits = BigInt(Math.round(s.price * 1e6));
  let chosen = null;
  const pay = wrapFetchWithPaymentFromConfig(fetch, {
    schemes: [{ network: ARC, client: new ExactEvmScheme(account) }],
    // Refuse anything but USDC on Arc at or under the catalog price.
    paymentRequirementsSelector: (_v, accepts) => {
      const ok = accepts.filter((a) => a.network === ARC && a.asset?.toLowerCase() === USDC.toLowerCase() && BigInt(a.amount ?? a.maxAmountRequired ?? "0") <= maxUnits);
      if (!ok.length) throw new Error(`no acceptable payment option for ${id} (want ≤ ${s.price} USDC on Arc)`);
      chosen = ok[0];
      return ok[0];
    },
  });
  const r = await pay(s.url, { method: "GET", headers: { accept: "application/json" } });
  const body = await r.text();
  if (!r.ok) throw new Error(`${id}: HTTP ${r.status} ${body.slice(0, 200)}`);
  let settlement = null;
  const hdr = r.headers.get("payment-response") ?? r.headers.get("x-payment-response");
  if (hdr) {
    try { settlement = decodePaymentResponseHeader(hdr); } catch {}
  }
  const price = chosen ? Number(BigInt(chosen.amount ?? chosen.maxAmountRequired)) / 1e6 : s.price;
  log(`x402: bought "${id}" for ${price} USDC${settlement?.transaction ? ` (tx ${settlement.transaction})` : ""}`);
  return { id, price, payTo: chosen?.payTo ?? null, settlement: settlement?.transaction ?? null, text: digest(s, body) };
}

/** Keep what the agent can use: services return large documents. */
function digest(s, body) {
  let j;
  try { j = JSON.parse(body); } catch { return body.slice(0, 3000); }
  if (s.filter) {
    const re = new RegExp(s.filter, "i");
    const rows = (j.data?.data ?? j.data ?? j.pools ?? j).filter?.((x) => re.test(JSON.stringify(x)));
    if (rows) {
      const slim = rows.slice(0, s.maxRows ?? 15).map((x) => Object.fromEntries(Object.entries(x).filter(([k]) => (s.keep ?? []).length === 0 || s.keep.includes(k))));
      return JSON.stringify({ matched: rows.length, rows: slim }).slice(0, 4000);
    }
  }
  return JSON.stringify(j).slice(0, 4000);
}
