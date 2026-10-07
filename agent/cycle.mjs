// One treasurer cycle: observe → forecast → decide (Claude) → [buy information, decide again] →
// check each decision against the contract → revise once if the contract refuses → act → record.
//
//   TAMIAS_NETWORK=fork node cycle.mjs            run a cycle now
//   TAMIAS_NETWORK=fork node cycle.mjs --if-due   run only if the agent's chosen time has come or something changed
//   TAMIAS_NETWORK=fork node cycle.mjs --dry      decide and simulate, send nothing (no purchases either)
import crypto from "crypto";
import fs from "fs";
import { parseEventLogs, toHex, zeroAddress, BaseError, ContractFunctionRevertedError } from "viem";
import {
  loadConfig, clients, TAMIAS_ABI, USDC, EURC, toUnits, fees, log, readJson, writeJson, appendJsonl, readJsonl, statePath,
} from "./lib.mjs";
import { observe } from "./observe.mjs";
import { forecast, balancesOf } from "./forecast.mjs";
import { briefing, think } from "./brain.mjs";
import { collect } from "./collect.mjs";
import { recallIntent, digestOf, savePending, settlePending } from "./gateway.mjs";
import { buyInfo } from "./x402.mjs";

const argv = new Set(process.argv.slice(2));
const DRY = argv.has("--dry");
const IF_DUE = argv.has("--if-due");
const OP = { pay: 1, act: 2, pay_to: 8 };
const RECALL = (1n << 256n) - 1n;

const cfg = loadConfig();
const { pub, wallet } = clients(cfg);
const agent = wallet(cfg.keys.agent);
const T = { address: cfg.tamias, abi: TAMIAS_ABI };

// ── a lock, so a timer firing during a long cycle does not start a second one ──
const lockFile = statePath("cycle.lock");
try {
  const fd = fs.openSync(lockFile, "wx");
  fs.writeSync(fd, String(process.pid));
  fs.closeSync(fd);
} catch {
  const pid = Number(fs.readFileSync(lockFile, "utf8"));
  let alive = false;
  try { process.kill(pid, 0); alive = true; } catch {}
  if (alive) { log(`cycle already running (pid ${pid})`); process.exit(0); }
  fs.writeFileSync(lockFile, String(process.pid));
}
process.on("exit", () => { try { fs.unlinkSync(lockFile); } catch {} });

const schedule = readJson("schedule.json", { cycle: 0, nextAt: 0, flags: [], cash: null, proposals: null });

// Fixed housekeeping before observing: sweep revenue into the treasury, and finish any Gateway
// transfer the agent authorized earlier (Gateway may need a few minutes to see the authorization).
const swept = DRY ? [] : await collect(cfg, pub, wallet).catch((e) => { log("collect failed:", e.message); return []; });
if (!DRY && cfg.gateway?.wallet) await settlePending(cfg, pub, agent, { waitMs: 0 }).catch((e) => log("gateway settle failed:", e.message));

let snap = await observe(cfg, pub);
let fc = forecast(snap, cfg);

if (IF_DUE) {
  const reasons = [];
  if (Date.now() >= schedule.nextAt) reasons.push("scheduled check");
  const key = (f) => f.split(" ").slice(0, 3).join(" ") + (f.includes("BELOW") ? " BELOW" : "");
  const newFlags = fc.flags.filter((f) => !schedule.flags.some((g) => key(g) === key(f)));
  if (newFlags.length) reasons.push(`new flags: ${newFlags.join("; ")}`);
  const propState = snap.treasury.proposals.map((p) => p.status).join(",");
  if (schedule.proposals != null && propState !== schedule.proposals) reasons.push("a proposal was decided");
  if (schedule.cash != null && Math.abs(snap.treasury.cash - schedule.cash) > 0.25) reasons.push(`treasury cash moved ${schedule.cash} → ${snap.treasury.cash}`);
  if (snap.treasury.frozen !== (schedule.frozen ?? false)) reasons.push("frozen state changed");
  if (!reasons.length) {
    appendJsonl("snapshots.jsonl", { at: snap.at, block: snap.block, balances: balancesOf(snap), paidIn: sweptAsIn(swept) });
    process.exit(0);
  }
  log(`waking: ${reasons.join(" | ")}`);
  snap.wakeReasons = reasons;
}

const cycle = schedule.cycle + 1;
const recent = recentDecisions(snap);
let prompt = briefing({ cfg, snap, fc, recent, cycle }) + (snap.wakeReasons ? `\n\nWhy you were woken: ${snap.wakeReasons.join("; ")}` : "");
const runDir = statePath(`claude-run`);
log(`cycle ${cycle}: thinking (${prompt.length} chars)`);
let brain = await think(prompt, { model: cfg.model, effort: cfg.effort, runDir });
log(`cycle ${cycle}: ${brain.data.decisions.length} decision(s) in ${brain.seconds}s — ${brain.data.assessment}`);

// ── information the agent decided to buy (x402), then decide again with it ──
const bought = [];
const wants = brain.data.decisions.filter((d) => d.type === "buy_info").slice(0, cfg.x402?.maxPerCycle ?? 2);
if (wants.length) {
  const sections = [];
  for (const d of wants) {
    if (DRY) { sections.push(`- ${d.service}: (dry run, not bought)`); continue; }
    try {
      const b = await buyInfo(cfg, agent.account, d.service);
      bought.push({ service: b.id, price: b.price, payTo: b.payTo, tx: b.settlement, why: d.why });
      sections.push(`### ${b.id} (paid ${b.price} USDC)\n${b.text}`);
    } catch (e) {
      bought.push({ service: d.service, error: e.message.slice(0, 200), why: d.why });
      sections.push(`### ${d.service}: purchase failed — ${e.message.slice(0, 200)}`);
    }
  }
  prompt += `\n\n## You chose to buy information\n${wants.map((d) => `- ${d.service}: ${d.why}`).join("\n")}\n\n## What you got\n${sections.join("\n\n")}\n\nNow make your decisions with this. Do not buy anything else this cycle.`;
  brain = await think(prompt, { model: cfg.model, effort: cfg.effort, runDir });
  brain.data.decisions = brain.data.decisions.filter((d) => d.type !== "buy_info");
  log(`cycle ${cycle}: with the information: ${brain.data.decisions.length} decision(s) — ${brain.data.assessment}`);
}
brain.data.decisions = brain.data.decisions.filter((d) => d.type !== "buy_info");
if (!brain.data.decisions.length) brain.data.decisions.push(noteOf("Nothing to do after reviewing the information.", "expect the next cycle to look the same"));

// ── check every decision against the contract; let the agent revise once if refused ──
let checked = await check(brain.data.decisions);
const refusedFirst = checked.filter((c) => c.error);
if (refusedFirst.length) {
  log(`contract refused ${refusedFirst.length}: ${refusedFirst.map((c) => `${c.d.type} → ${c.error}`).join("; ")}`);
  const revise = prompt + `\n\n## You answered:\n${JSON.stringify(brain.data.decisions.map(strip), null, 1)}\n\n## The contract refused these (simulated, nothing was sent):\n` +
    refusedFirst.map((c) => `- ${c.d.type} payee=${c.d.payee} action=${c.d.action} vault=${c.d.vault} amount=${c.d.amount}: ${c.error}`).join("\n") +
    `\n\nReturn your complete, revised list of decisions. Stay inside policy; propose what needs the owner. Do not buy information now.`;
  brain = await think(revise, { model: cfg.model, effort: cfg.effort, runDir });
  brain.data.decisions = brain.data.decisions.filter((d) => d.type !== "buy_info");
  if (!brain.data.decisions.length) brain.data.decisions.push(noteOf("Holding after the contract's refusal.", "the owner reviews the refusal"));
  log(`cycle ${cycle}: revised to ${brain.data.decisions.length} decision(s)`);
  checked = await check(brain.data.decisions);
}

// ── act ──
const inputs = { cycle, snap, fc, prompt, output: brain.data, model: brain.model, bought, refusedFirst: refusedFirst.map((c) => ({ d: strip(c.d), error: c.error })) };
const inputsJson = JSON.stringify(inputs, (_, v) => (typeof v === "bigint" ? v.toString() : v));
const inputsSha = crypto.createHash("sha256").update(inputsJson).digest("hex");
fs.mkdirSync(statePath("cycles"), { recursive: true });
if (!DRY) fs.writeFileSync(statePath(`cycles/${cycle}.json`), inputsJson);

const results = [];
const paidIn = sweptAsIn(swept);
const ok = checked.filter((c) => !c.error);
const refusedFinal = checked.filter((c) => c.error);
if (!ok.length) {
  // Something must be written down every cycle; if nothing passed, record the refusal itself.
  ok.push({ d: noteOf(`All decisions were refused by the contract: ${refusedFinal.map((c) => `${c.d.type} → ${c.error}`).join("; ")}. Holding.`, "the owner reviews the refused items") });
}
let recalled = false;
for (let i = 0; i < ok.length; i++) {
  const { d } = ok[i];
  const record = buildRecord({ d, i, of: ok.length, cycle, snap, fc, brain, inputsSha, refused: refusedFirst, bought });
  const entry = { cycle, at: snap.at, i, type: d.type, payee: d.payee, action: d.action, vault: d.vault, to: d.to, token: d.token, amount: d.amount, why: d.why, expect: d.expect, bytes: record.length };
  if (DRY) {
    log(`[dry] ${d.type} ${d.amount ?? ""} payee=${d.payee} action=${d.action} vault=${d.vault}: ${d.why}`);
    continue;
  }
  try {
    const call = await prepare(d, toHex(new TextEncoder().encode(record)));
    await pub.simulateContract({ ...T, ...call, account: agent.account });
    const hash = await agent.writeContract({ ...T, ...call, ...(await fees(pub)) });
    const rc = await pub.waitForTransactionReceipt({ hash, timeout: 120_000 });
    if (rc.status !== "success") throw new Error(`reverted on chain: ${hash}`);
    log(`  ${d.type}${d.amount != null ? ` ${d.amount}` : ""} → ${hash} (gas ${rc.gasUsed}, record ${record.length} B)`);
    const ev = parseEventLogs({ abi: TAMIAS_ABI, logs: rc.logs, eventName: "Recorded" }).find((l) => l.address.toLowerCase() === cfg.tamias.toLowerCase());
    const extra = d.type.startsWith("propose") && ev ? { proposal: Number(ev.args.ref) } : {};
    results.push({ ...entry, ...extra, seq: ev ? Number(ev.args.seq) : null, tx: hash, block: Number(rc.blockNumber), gasUsed: Number(rc.gasUsed), outcome: `done (tx ${hash.slice(0, 10)}…)` });
    if (d.type === "pay") {
      const key = accountKeyOf(snap.treasury.payees[d.payee], cfg);
      if (key) paidIn[key] = (paidIn[key] ?? 0) + d.amount;
    }
    if (d.type === "recall_gateway") {
      savePending({ kind: "recall", digest: d._digest, bi: jsonable(d._intent), at: new Date().toISOString(), authTx: hash });
      recalled = true;
    }
  } catch (e) {
    const reason = revertReason(e);
    log(`  ${d.type} failed: ${reason}`);
    results.push({ ...entry, outcome: `failed: ${reason}` });
  }
}
for (const c of refusedFinal) results.push({ cycle, at: snap.at, type: c.d.type, payee: c.d.payee, action: c.d.action, vault: c.d.vault, amount: c.d.amount, why: c.d.why, expect: c.d.expect, outcome: `refused by contract: ${c.error}` });
if (!DRY) for (const r of results) appendJsonl("decisions.jsonl", r);
if (!DRY) for (const b of bought) appendJsonl("purchases.jsonl", { cycle, at: snap.at, ...b });

// A recall authorized just now: wait for Gateway to see it and mint it back into the treasury.
if (recalled) await settlePending(cfg, pub, agent).catch((e) => log("gateway settle failed:", e.message));

// The treasury's own cash change from its payments is not income or burn: note it for the forecast.
const paidOut = { treasury: Object.values(paidIn).reduce((s, v) => s + v, 0) - sweptTotal(swept) };
const after = DRY ? snap : await observe(cfg, pub);
if (!DRY) appendJsonl("snapshots.jsonl", { at: after.at, block: after.block, balances: balancesOf(after), paidIn, paidOut });
const minutes = Math.min(360, Math.max(10, brain.data.next_check_minutes | 0));
if (!DRY) {
  writeJson("schedule.json", {
    cycle, nextAt: Date.now() + minutes * 60e3, flags: forecast(after, cfg).flags, cash: after.treasury.cash,
    proposals: after.treasury.proposals.map((p) => p.status).join(","), frozen: after.treasury.frozen,
  });
}
log(`cycle ${cycle} done; next check in ${minutes} min`);

// ───────────────────────────── helpers ─────────────────────────────

function noteOf(why, expect) {
  return { type: "note", payee: null, action: null, vault: null, service: null, to: null, token: null, amount: null, why, rule: "contract policy", alternatives: "", confidence: 1, expect };
}
function strip(d) {
  const { _intent, _digest, ...rest } = d;
  return rest;
}
function jsonable(o) {
  return JSON.parse(JSON.stringify(o, (_, v) => (typeof v === "bigint" ? v.toString() : v)));
}

function sweptAsIn(sw) {
  const m = {};
  for (const s of sw) m.treasury = (m.treasury ?? 0) + s.amount;
  return m;
}
function sweptTotal(sw) {
  return sw.reduce((a, s) => a + s.amount, 0);
}

function accountKeyOf(p, cfg) {
  if (!p) return null;
  const a = p.account.toLowerCase();
  if (p.kind === "tock-gas") {
    const o = cfg.business.tock.owners.find((o) => o.address.toLowerCase() === a);
    return o ? `tockGas:${o.id}` : null;
  }
  const w = cfg.business.wallets.find((w) => w.address.toLowerCase() === a);
  return w ? `wallet:${w.id}` : null;
}

/** The contract call for a decision. A Gateway recall builds its burn intent once and keeps it. */
async function prepare(d, record) {
  const token = d.token === "EURC" ? EURC : USDC;
  const amt = d.amount != null ? toUnits(d.amount) : 0n;
  switch (d.type) {
    case "pay": return { functionName: "pay", args: [BigInt(d.payee), token, amt, record] };
    case "act": return { functionName: "act", args: [BigInt(d.action), record] };
    case "propose_pay": return { functionName: "propose", args: [OP.pay, BigInt(d.payee), zeroAddress, token, amt, record] };
    case "propose_pay_to": return { functionName: "propose", args: [OP.pay_to, 0n, d.to, token, amt, record] };
    case "propose_act": return { functionName: "propose", args: [OP.act, BigInt(d.action), zeroAddress, zeroAddress, 0n, record] };
    case "freeze": return { functionName: "freeze", args: [record] };
    case "to_gateway": return { functionName: "toGateway", args: [amt, record] };
    case "to_vault": return { functionName: "toVault", args: [BigInt(d.vault), amt, record] };
    case "from_vault": return { functionName: "fromVault", args: [BigInt(d.vault), amt, record] };
    case "recall_gateway": {
      if (!d._intent) {
        d._intent = await recallIntent(cfg, amt);
        d._digest = digestOf(d._intent);
        // the contract must compute the same digest Gateway will check, or nothing is authorized
        const onchain = await pub.readContract({ ...T, functionName: "intentDigest", args: [d._intent] });
        if (onchain !== d._digest) throw new Error(`intent digest mismatch ${onchain} vs ${d._digest}`);
      }
      return { functionName: "authorizeIntent", args: [d._intent, RECALL, record] };
    }
    default: return { functionName: "note", args: [record] };
  }
}

function shapeError(d) {
  const needPayee = ["pay", "propose_pay"].includes(d.type), needAction = ["act", "propose_act"].includes(d.type);
  const needAmount = ["pay", "propose_pay", "propose_pay_to", "to_gateway", "recall_gateway", "to_vault", "from_vault"].includes(d.type);
  if (needAmount && !(d.amount > 0)) return "needs a positive amount";
  if (needPayee && d.payee == null) return "needs a payee";
  if (needAction && d.action == null) return "needs an action id";
  if (["to_vault", "from_vault"].includes(d.type) && d.vault == null) return "needs a vault id";
  if (["to_gateway", "recall_gateway"].includes(d.type) && !cfg.gateway?.wallet) return "Gateway is not configured";
  if (d.type === "propose_pay_to" && !/^0x[0-9a-fA-F]{40}$/.test(d.to ?? "")) return "needs a 0x address";
  return null;
}

async function check(decisions) {
  const out = [];
  for (const d of decisions) {
    const shape = shapeError(d);
    if (shape) { out.push({ d, error: `malformed decision: ${shape}` }); continue; }
    try {
      await pub.simulateContract({ ...T, ...(await prepare(d, "0x")), account: agent.account });
      out.push({ d });
    } catch (e) {
      out.push({ d, error: revertReason(e) });
    }
  }
  return out;
}

function revertReason(e) {
  if (e instanceof BaseError) {
    const r = e.walk((x) => x instanceof ContractFunctionRevertedError);
    if (r?.data?.errorName) {
      const args = (r.data.args ?? []).map((a) => (typeof a === "bigint" ? (a > 1000n ? (Number(a) / 1e6).toString() : a.toString()) : String(a)));
      return `${r.data.errorName}(${args.join(", ")})`;
    }
    return e.shortMessage;
  }
  return String(e.message ?? e).slice(0, 200);
}

function recentDecisions(snap) {
  const rows = readJsonl("decisions.jsonl", 10);
  return rows.map((r) => {
    if (r.proposal == null) return r;
    const p = snap.treasury.proposals.find((x) => x.id === r.proposal);
    return { ...r, outcome: `${r.outcome}; proposal #${r.proposal} is now ${p ? p.status + (p.expired ? " (expired)" : "") : "unknown"}` };
  });
}

function buildRecord({ d, i, of, cycle, snap, fc, brain, inputsSha, refused, bought }) {
  const p = d.payee != null ? snap.treasury.payees[d.payee] : null;
  const a = d.action != null ? snap.treasury.actions[d.action] : null;
  const v = d.vault != null ? snap.reserves?.vaults?.[d.vault] : null;
  const saw = { cash: snap.treasury.cash, reserves: fc.operation.reserves };
  for (const [k, x] of Object.entries(fc.accounts)) saw[k] = [x.now, x.perDay, x.daysToMinimum];
  const rec = {
    v: 1, app: "tamias", cycle, n: i + 1, of, at: snap.at, block: snap.block,
    do: {
      type: d.type,
      ...(p ? { payee: d.payee, to: p.label } : {}), ...(a ? { action: d.action, label: a.label } : {}), ...(v ? { vault: d.vault, label: v.label } : {}),
      ...(d.to ? { to: d.to } : {}), ...(d.amount != null ? { amount: d.amount, token: d.token ?? "USDC" } : {}), ...(d._digest ? { intent: d._digest } : {}),
    },
    why: d.why, rule: d.rule, alt: d.alternatives, conf: d.confidence, expect: d.expect,
    ...(i === 0 ? { assessment: brain.data.assessment, review: brain.data.review_of_last_cycle, next: brain.data.next_check_minutes } : {}),
    ...(i === 0 && bought.length ? { bought: bought.map((b) => ({ service: b.service, price: b.price, tx: b.tx, why: b.why, error: b.error })) } : {}),
    ...(i === 0 && refused.length ? { refused: refused.map((c) => ({ tried: `${c.d.type} ${c.d.amount ?? ""} payee ${c.d.payee ?? "-"} action ${c.d.action ?? "-"}`.trim(), contract: c.error })) } : {}),
    ...(i === 0 ? { saw: { "[now, perDay, daysToMin]": saw } } : {}),
    model: brain.model, inputs: `sha256:${inputsSha}`,
  };
  let s = JSON.stringify(rec);
  if (s.length > 8000) { delete rec.saw; s = JSON.stringify(rec); }
  if (s.length > 8000) { rec.why = String(rec.why).slice(0, 1500); delete rec.review; s = JSON.stringify(rec); }
  return s;
}
