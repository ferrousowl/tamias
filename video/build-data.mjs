// Collect real data for the demo video's scenes into video/data.json: the live record (read from
// the chain and verified), the agent's own cycle logs, and the operator transactions.
//   cd video && node build-data.mjs
import fs from "fs";
import path from "path";
import { execSync } from "child_process";

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const out = path.join(ROOT, "video", "data.json");
const tmp = path.join(ROOT, "state", "video-log.json");
execSync(`node verify.mjs --json ${tmp}`, { cwd: path.join(ROOT, "agent"), env: { ...process.env, TAMIAS_NETWORK: "mainnet" }, stdio: "pipe" });
const log = JSON.parse(fs.readFileSync(tmp, "utf8"));
const hex2str = (h) => Buffer.from(h.slice(2), "hex").toString("utf8");
const rows = log.rows.map((r) => {
  let j = null;
  try { j = r.opId === 7 ? null : JSON.parse(hex2str(r.recordHex)); } catch {}
  return { seq: r.seq, op: r.op, ref: r.ref, usd: r.usd, amount: r.amount, tx: r.tx, block: r.block, j };
});
const agentRows = rows.filter((r) => r.j && !r.j.operator);
const by = (op) => rows.filter((r) => r.op === op);

// real agent logs: the timer's journal (cycles that ran under systemd)
let journal = "";
try {
  journal = execSync("journalctl --user -u tamias-agent.service --no-pager -o cat --since '2026-10-08'", { encoding: "utf8" });
} catch {}
const cycleLines = journal.split("\n").filter((l) => /cycle \d+|→ 0x|contract refused|waking|bought|sweep/.test(l)).slice(-60);

const stateDir = path.join(ROOT, "state", "mainnet");
const readJsonl = (f) => (fs.existsSync(path.join(stateDir, f)) ? fs.readFileSync(path.join(stateDir, f), "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)) : []);

const data = {
  builtAt: new Date().toISOString(),
  tamias: log.tamias,
  head: log.head,
  records: rows.length,
  metrics: {
    cycles: new Set(agentRows.map((r) => r.j.cycle)).size,
    agentRecords: agentRows.length,
    payments: by("pay").filter((r) => !r.j?.operator).length,
    paidUsd: +by("pay").filter((r) => !r.j?.operator).reduce((s, r) => s + r.usd, 0).toFixed(4),
    proposals: by("propose").length,
    approved: by("approve").length,
    rejected: by("reject").length,
    refusals: agentRows.reduce((s, r) => s + (r.j.refused?.length ?? 0), 0),
    purchases: readJsonl("purchases.jsonl").filter((p) => !p.error).length,
  },
  decisions: agentRows.slice(-30).map((r) => ({ seq: r.seq, op: r.op, usd: r.usd, tx: r.tx, ...r.j })),
  escalations: rows.filter((r) => ["propose", "approve", "reject"].includes(r.op)).map((r) => ({ seq: r.seq, op: r.op, ref: r.ref, usd: r.usd, tx: r.tx, ...(r.j ?? {}) })),
  refused: agentRows.filter((r) => r.j.refused?.length).map((r) => ({ seq: r.seq, tx: r.tx, refused: r.j.refused, why: r.j.why, do: r.j.do })),
  purchases: readJsonl("purchases.jsonl"),
  gateway: {
    deposit: "0x0bd93feb0b07c6a8c1365d4e28f0077f529cc43ce9888b41139eb13570e5566b",
    authorize: "0x94651c25f896b6c389369ac9ac98c052603e0587fddebd260396f85dcf8552a5",
    mint: "0xeb55a311457acf49b0de2f7b3527b6406d97b099de87b1edd14f483b57b8ed64",
    recalled: 0.09615,
  },
  // the old cron job's decision rules, verbatim
  cron: fs.readFileSync(path.join(process.env.HOME, "work/standing-ops/ops-hourly.mjs"), "utf8").split("\n")
    .filter((l) => /if \(|parseEther\("1"\)|late > 600/.test(l)).map((l) => l.trim().replace(/, \.\.\.fees.*$/, ")").slice(0, 120)).slice(0, 8),
  journal: cycleLines,
};
fs.writeFileSync(out, JSON.stringify(data, null, 1));
console.log(`wrote ${out}: ${rows.length} records, ${data.decisions.length} decisions, ${data.escalations.length} escalation records, ${cycleLines.length} log lines`);
