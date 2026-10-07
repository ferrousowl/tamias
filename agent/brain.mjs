// Brain: one headless Claude call that turns what the treasurer sees into decisions.
// Claude gets no tools at all: it reads a briefing and answers in a fixed JSON shape. Everything it
// proposes is then checked against the contract before anything is sent.
import { spawn } from "child_process";
import os from "os";
import fs from "fs";
import path from "path";
import crypto from "crypto";

const CLAUDE = process.env.CLAUDE_BIN || path.join(os.homedir(), ".local/bin/claude");

export const DECISION_TYPES = ["pay", "act", "propose_pay", "propose_pay_to", "propose_act", "note", "freeze"];

export const SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["review_of_last_cycle", "assessment", "decisions", "next_check_minutes"],
  properties: {
    review_of_last_cycle: { type: "string", description: "Did the expectations you wrote last cycle hold? Name any that failed and what that tells you." },
    assessment: { type: "string", description: "The situation in 1–3 sentences with the numbers that matter." },
    decisions: {
      type: "array",
      minItems: 1,
      maxItems: 6,
      items: {
        type: "object",
        additionalProperties: false,
        required: ["type", "payee", "action", "to", "token", "amount", "why", "rule", "alternatives", "confidence", "expect"],
        properties: {
          type: { type: "string", enum: DECISION_TYPES },
          payee: { type: ["integer", "null"], description: "payee id for pay / propose_pay" },
          action: { type: ["integer", "null"], description: "action id for act / propose_act" },
          to: { type: ["string", "null"], description: "0x address for propose_pay_to only" },
          token: { type: ["string", "null"], enum: ["USDC", "EURC", null] },
          amount: { type: ["number", "null"], description: "token amount, e.g. 0.25" },
          why: { type: "string", description: "The reasoning, with the numbers that drove it. Max ~500 characters." },
          rule: { type: "string", description: "The policy limit or forecast fact this rests on." },
          alternatives: { type: "string", description: "What else you considered and why not." },
          confidence: { type: "number", minimum: 0, maximum: 1 },
          expect: { type: "string", description: "A checkable expectation for the next cycle if this was right." },
        },
      },
    },
    next_check_minutes: { type: "integer", minimum: 10, maximum: 360, description: "When you want to look again." },
  },
};

export const SYSTEM = `You are Tamias, the treasurer of a small business that runs on the Arc blockchain, where USDC is the money and also pays for gas.

You run the business's money continuously: you watch cash against what is coming due, decide what to pay, when and how much, and write down why. You act only through the Tamias contract, which holds the treasury and enforces the owner's policy on-chain:
- money can go only to listed payees, each with a per-payment cap and a budget category with a cap per period;
- no single payment may exceed the auto-approval limit, and the treasury's USDC may never drop below its floor;
- actions are calls the owner wrote out in full; you choose only when to make them;
- anything outside those limits you may only propose; the human owner approves or rejects it;
- every decision you make is recorded on-chain with your reasoning, permanently. Write as if an auditor will read each one.
The contract will refuse anything outside policy, so do not try to work around it. If the right move is outside your authority, propose it and say why.

How to decide:
- Keep every account the business depends on above its minimum for the time until you next look, with a sensible buffer. A balance that runs dry stops a live service.
- Do not over-fund. Cash parked in a sub-account cannot be used elsewhere, and every transaction costs gas (~0.001–0.003 USDC). Prefer fewer, well-sized payments over many small ones, but never let a service lapse to save a cent.
- Use the forecast, but check it against what you see: when the observed and scheduled rates disagree, say which one you trust and why.
- Choose when to look next (next_check_minutes): sooner when something is close to its minimum, overdue, or just changed; later when everything has days of runway.
- Escalate (propose) when a payment exceeds your limits, when a payee is not on the list, or when the owner should weigh in (e.g. distributing surplus to the owner). Freeze yourself if what you see is inconsistent in a way that suggests a fault or compromise.
- If nothing needs doing, return exactly one "note" decision that says why holding is right.
- Each decision needs a checkable "expect" for the next cycle. Next cycle you will see your previous expectations next to what actually happened: learn from misses.
Amounts are token units (USDC has 6 decimals; write 0.25, not 250000). Be concrete and brief.`;

export function briefing({ cfg, snap, fc, recent, cycle }) {
  const lines = [];
  lines.push(`# Cycle ${cycle} — ${snap.at} (block ${snap.block}, base fee ${snap.baseFeeGwei} gwei)`);
  lines.push(`\n## The business\n${cfg.business.description}`);
  lines.push(`\n## Treasury (Tamias contract ${snap.treasury.address})`);
  const t = snap.treasury;
  lines.push(`cash ${t.cash} USDC, ${t.eurc} EURC; floor ${t.floor}; auto-approval limit ${t.autoLimit} per payment; frozen: ${t.frozen}; records so far: ${t.records}`);
  lines.push(`\nBudget categories:\n` + t.categories.map((c) => `- [${c.id}] ${c.name}: ${c.remaining} of ${c.budget} left this ${c.periodHours} h window (resets in ${c.windowEndsInHours} h)`).join("\n"));
  lines.push(`\nPayees (money can go only here):\n` + t.payees.map((p) => `- payee ${p.id} "${p.label}" (${p.kind}${p.kind === "cctp" ? ` domain ${p.domain}` : ""}) → ${p.account}; category ${p.category}; max ${p.maxPayment} per payment${p.active ? "" : "; INACTIVE"}`).join("\n"));
  lines.push(`\nActions (exact calls you may trigger):\n` + (t.actions.length ? t.actions.map((a) => `- action ${a.id} "${a.label}"; category ${a.category}; charge ${a.charge}${a.active ? "" : "; INACTIVE"}`).join("\n") : "- none"));
  const open = t.proposals.filter((p) => p.status === "pending");
  lines.push(`\nProposals: ${open.length} pending` + (t.proposals.length ? "\n" + t.proposals.slice(-6).map((p) => `- #${p.id} op ${p.op} ref ${p.ref} ${p.amount} ${p.token ?? ""} → ${p.status}${p.expired ? " (expired)" : ""}, ${p.ageHours} h old`).join("\n") : ""));

  lines.push(`\n## Accounts and forecast (USDC; perDay negative = outflow)`);
  for (const [k, a] of Object.entries(fc.accounts)) {
    const label = k.startsWith("wallet:") ? snap.wallets[k.slice(7)]?.label : k.startsWith("tockGas:") ? snap.tock.gasBalances[k.slice(8)]?.label : "treasury cash";
    lines.push(`- ${k} (${label}): now ${a.now}; min ${a.minimum}; rate ${a.perDay}/day [scheduled ${a.structuralPerDay}, observed ${a.observedPerDay ?? "n/a"} over ${a.observedHours} h]; ${a.daysToMinimum == null ? "not draining" : `${a.daysToMinimum} days to minimum`}; 24h→${a.in24h}, 7d→${a.in7d}`);
    for (const b of a.basis) lines.push(`    · ${b}`);
  }
  lines.push(`Whole operation: ${fc.operation.totalNow} USDC across all accounts, net ${fc.operation.netPerDay}/day.`);
  lines.push(`\nScheduled in the next 24 h:\n` + (fc.upcoming.length ? fc.upcoming.slice(0, 8).map((u) => `- in ${u.inMinutes} min: ${u.what}`).join("\n") : "- nothing"));
  lines.push(`\nFlags:\n` + (fc.flags.length ? fc.flags.map((f) => `- ${f}`).join("\n") : "- none"));

  lines.push(`\n## Your recent decisions (oldest first) and what happened since`);
  if (!recent.length) lines.push("- none yet: this is your first cycle.");
  for (const r of recent) {
    lines.push(`- cycle ${r.cycle} ${r.at}: ${r.type}${r.amount != null ? ` ${r.amount}` : ""}${r.payee != null ? ` to payee ${r.payee}` : ""}${r.action != null ? ` action ${r.action}` : ""} → ${r.outcome}`);
    lines.push(`    why: ${r.why}`);
    lines.push(`    expected: ${r.expect}`);
  }
  if (cfg.business.notes?.length) lines.push(`\n## Standing notes from the owner\n` + cfg.business.notes.map((n) => `- ${n}`).join("\n"));
  lines.push(`\nDecide now. Return JSON only.`);
  return lines.join("\n");
}

export async function think(prompt, { model = "sonnet", effort = "medium", timeoutMs = 600_000, runDir } = {}) {
  const args = [
    "-p", "--model", model, "--effort", effort,
    "--tools", "", "--strict-mcp-config", "--no-session-persistence", "--disable-slash-commands", "--setting-sources", "",
    "--output-format", "json", "--json-schema", JSON.stringify(SCHEMA), "--system-prompt", SYSTEM,
  ];
  fs.mkdirSync(runDir, { recursive: true });
  const started = Date.now();
  const out = await new Promise((resolve, reject) => {
    const p = spawn(CLAUDE, args, { cwd: runDir, stdio: ["pipe", "pipe", "pipe"] });
    let stdout = "", stderr = "";
    const timer = setTimeout(() => { p.kill("SIGTERM"); reject(new Error(`claude timed out after ${timeoutMs / 1000}s`)); }, timeoutMs);
    p.stdout.on("data", (d) => (stdout += d));
    p.stderr.on("data", (d) => (stderr += d));
    p.on("close", (code) => { clearTimeout(timer); resolve({ code, stdout, stderr }); });
    p.on("error", reject);
    p.stdin.end(prompt);
  });
  let res;
  try {
    res = JSON.parse(out.stdout);
  } catch {
    throw new Error(`unreadable claude output (exit ${out.code}): ${(out.stdout || out.stderr).slice(0, 300)}`);
  }
  if (res.is_error) throw new Error(`claude error: ${String(res.result).slice(0, 300)}`);
  const data = res.structured_output ?? JSON.parse(res.result);
  return {
    data,
    model: Object.keys(res.modelUsage ?? {})[0] ?? model,
    seconds: Math.round((Date.now() - started) / 1000),
    promptSha: crypto.createHash("sha256").update(SYSTEM + "\n" + prompt).digest("hex"),
  };
}
