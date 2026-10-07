// Observe: read everything the treasurer needs to know, straight from the chain.
// Returns plain JSON (numbers in USDC, not wei) so it can go into a prompt and a record.
import { getAbiItem } from "viem";
import { parseAbi } from "viem";
import { fromNative, fromUnits, TAMIAS_ABI, TOCK_ABI, STANDING_ABI, ERC20_ABI, EURC, USDC, readJson } from "./lib.mjs";
import { gatewayBalances } from "./gateway.mjs";

const VAULT_ABI = parseAbi(["function balanceOf(address) view returns (uint256)", "function convertToAssets(uint256) view returns (uint256)"]);

/** Average fee actually paid per run, from the last ~3 h of JobRan events (public RPCs cap a
 *  log query at a few thousand blocks, so walk back in chunks). */
async function recentJobFees(pub, tock, head) {
  const event = getAbiItem({ abi: TOCK_ABI, name: "JobRan" });
  const fees = {};
  for (let i = 0n; i < 4n; i++) {
    const toBlock = head - i * 5000n;
    try {
      const logs = await pub.getLogs({ address: tock, event, fromBlock: toBlock - 4999n, toBlock });
      for (const l of logs) {
        if (!l.args.success) continue;
        const id = Number(l.args.jobId);
        (fees[id] ??= []).push(fromNative(l.args.fee));
      }
    } catch { break; }
  }
  return Object.fromEntries(Object.entries(fees).map(([id, f]) => [id, { avg: f.reduce((a, b) => a + b, 0) / f.length, n: f.length }]));
}

const KINDS = ["transfer", "tock-gas", "cctp"];
const STATUS = ["pending", "approved", "rejected"];

export async function observe(cfg, pub) {
  const block = await pub.getBlock();
  const now = Number(block.timestamp);
  const t = { address: cfg.tamias, abi: TAMIAS_ABI };
  const read = (c, functionName, args = []) => pub.readContract({ ...c, functionName, args });

  // ── the treasury itself ──
  const [cash, eurc, frozen, autoLimit, floor, ttl, head, seq, nCat, nPay, nAct, nProp, agent, owner] = await Promise.all([
    read(t, "cash"),
    pub.readContract({ address: EURC, abi: ERC20_ABI, functionName: "balanceOf", args: [cfg.tamias] }).catch(() => 0n),
    read(t, "frozen"),
    read(t, "autoLimit"),
    read(t, "floor"),
    read(t, "proposalTtl"),
    read(t, "head"),
    read(t, "seq"),
    read(t, "categoryCount"),
    read(t, "payeeCount"),
    read(t, "actionCount"),
    read(t, "proposalCount"),
    read(t, "agent"),
    read(t, "owner"),
  ]);
  const categories = [];
  for (let i = 0n; i < nCat; i++) {
    const [name, budget, spent, remaining, windowEnd, period] = await read(t, "budgetOf", [i]);
    categories.push({
      id: Number(i), name, budget: fromUnits(budget), spent: fromUnits(spent), remaining: fromUnits(remaining),
      periodHours: Number(period) / 3600, windowEndsInHours: +((Number(windowEnd) - now) / 3600).toFixed(2),
    });
  }
  const payees = [];
  for (let i = 0n; i < nPay; i++) {
    const p = await read(t, "getPayee", [i]);
    payees.push({
      id: Number(i), label: p.label, kind: KINDS[p.kind], account: p.account, category: p.category,
      active: p.active, maxPayment: fromUnits(p.maxPayment), ...(p.kind === 2 ? { domain: p.domain } : {}),
    });
  }
  const actions = [];
  for (let i = 0n; i < nAct; i++) {
    const a = await read(t, "getAction", [i]);
    actions.push({ id: Number(i), label: a.label, target: a.target, category: a.category, active: a.active, charge: fromUnits(a.charge) });
  }
  const proposals = [];
  for (let i = nProp > 20n ? nProp - 20n : 0n; i < nProp; i++) {
    const p = await read(t, "getProposal", [i]);
    proposals.push({
      id: Number(i), op: p.op, status: STATUS[p.status], ageHours: +((now - p.createdAt) / 3600).toFixed(2),
      expired: p.status === 0 && now > p.expiresAt, ref: Number(p.ref), account: p.account,
      token: p.token === EURC ? "EURC" : p.token === USDC ? "USDC" : null, amount: fromUnits(p.amount),
    });
  }

  // ── reserves: Circle Gateway balance and ERC-4626 vaults ──
  const reserves = { gateway: null, agentGateway: null, vaults: [], pendingIntents: [] };
  if (cfg.gateway?.wallet) {
    const gb = await gatewayBalances(cfg, pub, { treasury: cfg.tamias, agent });
    reserves.gateway = gb.treasury;
    reserves.agentGateway = gb.agent;
    reserves.pendingIntents = readJson("gateway-pending.json", []).filter((p) => !p.minted && !p.dead).map((p) => ({ kind: p.kind, value: Number(p.bi.spec.value) / 1e6, at: p.at, error: p.error ?? null }));
  }
  const nVault = await read(t, "vaultCount");
  for (let i = 0n; i < nVault; i++) {
    const v = await read(t, "getVault", [i]);
    const shares = await pub.readContract({ address: v.vault, abi: VAULT_ABI, functionName: "balanceOf", args: [cfg.tamias] });
    const held = shares > 0n ? await pub.readContract({ address: v.vault, abi: VAULT_ABI, functionName: "convertToAssets", args: [shares] }) : 0n;
    reserves.vaults.push({ id: Number(i), label: v.label, address: v.vault, active: v.active, cap: fromUnits(v.cap), held: fromUnits(held) });
  }

  // ── the business: wallets, scheduled jobs, subscriptions ──
  const wallets = {};
  for (const w of cfg.business.wallets) {
    wallets[w.id] = { label: w.label, address: w.address, usdc: fromNative(await pub.getBalance({ address: w.address })) };
    if (w.minimum != null) wallets[w.id].minimum = w.minimum;
  }

  const tock = { address: cfg.business.tock.address, abi: TOCK_ABI };
  const paid = await recentJobFees(pub, cfg.business.tock.address, block.number);
  const gasBalances = {};
  const jobs = [];
  for (const o of cfg.business.tock.owners) {
    gasBalances[o.id] = { label: o.label, owner: o.address, usdc: fromNative(await read(tock, "balanceOf", [o.address])) };
    if (o.minimum != null) gasBalances[o.id].minimum = o.minimum;
    for (const id of await read(tock, "jobsOf", [o.address])) {
      const j = await read(tock, "getJob", [id]);
      jobs.push({
        id: Number(id), name: j.name, owner: o.id, active: j.active, intervalHours: j.interval / 3600,
        nextRunInMinutes: +((j.nextRun - now) / 60).toFixed(1), runs: j.runs, failures: j.failures,
        valuePerRun: fromNative(j.value), maxFeePerRun: fromNative(j.maxFee),
        ...(paid[Number(id)] ? { recentFeePerRun: +paid[Number(id)].avg.toFixed(6), recentRuns: paid[Number(id)].n } : {}),
      });
    }
  }

  const so = { address: cfg.business.standing.address, abi: STANDING_ABI };
  const orders = [];
  for (const id of cfg.business.standing.orders) {
    const o = await read(so, "getOrder", [BigInt(id)]);
    const p = await read(so, "getPlan", [o.planId]);
    orders.push({
      id, plan: p.name, active: o.active && p.active, payer: o.payer, merchant: p.merchant,
      amount: fromUnits(p.amount), periodHours: p.period / 3600, payments: o.payments,
      dueInMinutes: +((o.nextDue - now) / 60).toFixed(1), maxExecFee: fromUnits(p.maxExecFee),
    });
  }

  return {
    at: new Date(now * 1000).toISOString(),
    block: Number(block.number),
    baseFeeGwei: Number(block.baseFeePerGas) / 1e9,
    treasury: {
      address: cfg.tamias, owner, agent, frozen, cash: fromUnits(cash), eurc: fromUnits(eurc),
      autoLimit: fromUnits(autoLimit), floor: fromUnits(floor), proposalTtlHours: Number(ttl) / 3600,
      records: Number(seq), head, categories, payees, actions, proposals,
    },
    reserves,
    wallets,
    tock: { gasBalances, jobs },
    standing: { orders },
  };
}
