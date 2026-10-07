// Forecast: a deterministic cash projection the agent reasons over. It does not decide anything.
//
// Two estimates per balance, both reported so the agent can see when they disagree:
//   structural — from what is scheduled (Tock job intervals and fee caps, Standing plan amounts);
//   observed   — from this agent's own balance snapshots over the last 36 h, with the payments the
//                treasury itself made taken out, so a top-up does not look like income.
import { readJsonl } from "./lib.mjs";

const DAY = 24;

function structural(snap, cfg) {
  const rates = {}; // per day, USDC
  const add = (k, v, why) => {
    rates[k] ??= { perDay: 0, basis: [] };
    rates[k].perDay += v;
    rates[k].basis.push(why);
  };
  const typicalFee = cfg.business.tock.typicalFeeShare ?? 0.6;
  const walletByAddr = Object.fromEntries(Object.entries(snap.wallets).map(([id, w]) => [w.address.toLowerCase(), id]));
  const ownerAgent = Object.fromEntries((cfg.business.tock.owners ?? []).map((o) => [o.id, o.agentWallet]));

  for (const j of snap.tock.jobs) {
    if (!j.active) continue;
    const runs = DAY / j.intervalHours;
    const fee = j.recentFeePerRun ?? j.maxFeePerRun * typicalFee;
    const src = j.recentFeePerRun != null ? `avg of last ${j.recentRuns} run(s)` : `${typicalFee * 100}% of the fee cap, no recent runs seen`;
    add(`tockGas:${j.owner}`, -runs * fee, `job ${j.id} "${j.name}": ${runs.toFixed(2)} runs/day × ${fee.toFixed(4)} gas (${src})`);
    if (j.valuePerRun > 0 && ownerAgent[j.owner]) {
      add(`wallet:${ownerAgent[j.owner]}`, -runs * j.valuePerRun, `job ${j.id} pays ${j.valuePerRun} per run`);
    }
  }
  for (const o of snap.standing.orders) {
    if (!o.active) continue;
    const runs = DAY / o.periodHours;
    const payer = walletByAddr[o.payer.toLowerCase()];
    const merchant = walletByAddr[o.merchant.toLowerCase()];
    if (payer) add(`wallet:${payer}`, -runs * o.amount, `order ${o.id} "${o.plan}": pays ${o.amount} every ${o.periodHours} h`);
    if (merchant) add(`wallet:${merchant}`, runs * (o.amount * 0.997 - o.maxExecFee / 2), `order ${o.id}: receives ~${(o.amount * 0.997 - o.maxExecFee / 2).toFixed(4)} net per payment`);
  }
  for (const p of cfg.business.scheduledInflows ?? []) add(p.key, p.perDay, p.why);
  return rates;
}

function observed(history, keys) {
  const out = {};
  const recent = history.filter((h) => Date.now() - Date.parse(h.at) < 36 * 3600e3);
  for (const k of keys) {
    let delta = 0, hours = 0;
    for (let i = 1; i < recent.length; i++) {
      const a = recent[i - 1], b = recent[i];
      if (a.balances[k] == null || b.balances[k] == null) continue;
      const dt = (Date.parse(b.at) - Date.parse(a.at)) / 3600e3;
      if (dt <= 0 || dt > 6) continue; // a gap in the data says nothing about the rate
      delta += b.balances[k] - a.balances[k] - (b.paidIn?.[k] ?? 0) + (b.paidOut?.[k] ?? 0);
      hours += dt;
    }
    if (hours >= 3) out[k] = { perDay: (delta / hours) * DAY, hours: +hours.toFixed(1) };
  }
  return out;
}

/** Flatten a snapshot into the balances we track, keyed like "wallet:subscriber". */
export function balancesOf(snap) {
  const b = { treasury: snap.treasury.cash };
  for (const [id, w] of Object.entries(snap.wallets)) b[`wallet:${id}`] = w.usdc;
  for (const [id, g] of Object.entries(snap.tock.gasBalances)) b[`tockGas:${id}`] = g.usdc;
  return b;
}

export function forecast(snap, cfg) {
  const balances = balancesOf(snap);
  const history = readJsonl("snapshots.jsonl", 400);
  const st = structural(snap, cfg);
  const ob = observed(history, Object.keys(balances));
  const minimum = {};
  for (const [id, w] of Object.entries(snap.wallets)) if (w.minimum != null) minimum[`wallet:${id}`] = w.minimum;
  for (const [id, g] of Object.entries(snap.tock.gasBalances)) if (g.minimum != null) minimum[`tockGas:${id}`] = g.minimum;
  minimum.treasury = snap.treasury.floor;

  const accounts = {};
  for (const [k, now] of Object.entries(balances)) {
    const s = st[k]?.perDay ?? 0;
    const o = ob[k]?.perDay;
    const rate = o != null && ob[k].hours >= 6 ? o : s; // trust what we saw once we have seen enough
    const min = minimum[k] ?? 0;
    const runway = rate < 0 ? Math.max(0, (now - min) / -rate) : null;
    accounts[k] = {
      now: +now.toFixed(6),
      minimum: min,
      perDay: +rate.toFixed(4),
      structuralPerDay: +s.toFixed(4),
      observedPerDay: o != null ? +o.toFixed(4) : null,
      observedHours: ob[k]?.hours ?? 0,
      daysToMinimum: runway == null ? null : +runway.toFixed(2),
      in24h: +(now + rate).toFixed(4),
      in72h: +(now + rate * 3).toFixed(4),
      in7d: +(now + rate * 7).toFixed(4),
      basis: st[k]?.basis ?? [],
    };
  }

  const upcoming = [];
  for (const j of snap.tock.jobs) {
    if (j.active && j.nextRunInMinutes < 24 * 60) upcoming.push({ inMinutes: j.nextRunInMinutes, what: `Tock job ${j.id} "${j.name}" runs (gas from ${j.owner}'s Tock balance, cap ${j.maxFeePerRun})` });
  }
  for (const o of snap.standing.orders) {
    if (o.active && o.dueInMinutes < 24 * 60) upcoming.push({ inMinutes: o.dueInMinutes, what: `Standing order ${o.id} "${o.plan}" due: ${o.amount} USDC payer→merchant` });
  }
  upcoming.sort((a, b) => a.inMinutes - b.inMinutes);

  const flags = [];
  for (const [k, a] of Object.entries(accounts)) {
    if (a.now < a.minimum) flags.push(`${k} is BELOW its minimum (${a.now} < ${a.minimum})`);
    else if (a.daysToMinimum != null && a.daysToMinimum < 1) flags.push(`${k} reaches its minimum in ${(a.daysToMinimum * 24).toFixed(1)} h`);
    if (a.observedPerDay != null && Math.abs(a.observedPerDay - a.structuralPerDay) > Math.max(0.05, Math.abs(a.structuralPerDay) * 0.5))
      flags.push(`${k}: observed rate ${a.observedPerDay}/day differs from scheduled ${a.structuralPerDay}/day`);
  }
  for (const j of snap.tock.jobs) {
    if (j.active && j.nextRunInMinutes < -15) flags.push(`Tock job ${j.id} is ${-j.nextRunInMinutes} min overdue (keeper down or underfunded?)`);
    if (j.failures > 0) flags.push(`Tock job ${j.id} has ${j.failures} consecutive failure(s)`);
    if (!j.active) flags.push(`Tock job ${j.id} "${j.name}" is paused or cancelled`);
  }
  for (const o of snap.standing.orders) if (o.active && o.dueInMinutes < -10) flags.push(`Standing order ${o.id} is ${-o.dueInMinutes} min overdue`);

  const totalNow = Object.values(accounts).reduce((s, a) => s + a.now, 0);
  const totalPerDay = Object.values(accounts).reduce((s, a) => s + a.perDay, 0);
  return { accounts, upcoming, flags, operation: { totalNow: +totalNow.toFixed(4), netPerDay: +totalPerDay.toFixed(4) } };
}
