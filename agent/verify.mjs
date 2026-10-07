// Replay the treasurer's on-chain record and check it: every record is read back from the chain
// (walking lastBlock → prevBlock, so no block-range scans), the hash chain is recomputed from zero
// and compared with the contract's `head`, and the decisions are summed up.
//
//   TAMIAS_NETWORK=mainnet node verify.mjs [--json out.json]
import fs from "fs";
import { getAbiItem, keccak256, encodeAbiParameters, hexToString } from "viem";
import { loadConfig, clients, TAMIAS_ABI, fromUnits } from "./lib.mjs";

const OPS = ["note", "pay", "act", "propose", "approve", "reject", "freeze", "policy"];

export async function readRecords(cfg, pub) {
  const event = getAbiItem({ abi: TAMIAS_ABI, name: "Recorded" });
  const T = { address: cfg.tamias, abi: TAMIAS_ABI };
  const [head, seq, lastBlock] = await Promise.all(["head", "seq", "lastBlock"].map((f) => pub.readContract({ ...T, functionName: f })));
  const out = [];
  let block = lastBlock;
  const seen = new Set();
  while (block > 0n && !seen.has(block)) {
    seen.add(block);
    const logs = await pub.getLogs({ address: cfg.tamias, event, fromBlock: block, toBlock: block });
    if (!logs.length) throw new Error(`no records found in block ${block}`);
    for (const l of logs) out.push({ ...l.args, block: l.blockNumber, tx: l.transactionHash, logIndex: l.logIndex });
    // The first record in a block names the previous block that has records; later ones in the
    // same block name this block. So the smallest prevBlock is the next block to read (0 = start).
    block = logs.reduce((m, l) => (l.args.prevBlock < m ? l.args.prevBlock : m), block);
    if (block === logs[0].blockNumber) break;
  }
  out.sort((a, b) => Number(a.seq - b.seq));
  return { head, seq, records: out };
}

export function replay(records) {
  let h = "0x" + "00".repeat(32);
  const types = [
    { type: "bytes32" }, { type: "uint64" }, { type: "uint8" }, { type: "address" }, { type: "uint256" },
    { type: "address" }, { type: "uint256" }, { type: "uint256" }, { type: "bytes32" },
  ];
  for (const r of records) {
    h = keccak256(encodeAbiParameters(types, [h, r.seq, r.op, r.by, r.ref, r.token, r.amount, r.usd, keccak256(r.record)]));
    if (h !== r.head) return { ok: false, at: Number(r.seq), computed: h, logged: r.head };
  }
  return { ok: true, head: h };
}

export function summarize(records) {
  const s = { records: records.length, byOp: {}, paidUsd: 0, paidByPayee: {}, proposals: 0, approved: 0, rejected: 0, cycles: new Set() };
  for (const r of records) {
    const op = OPS[r.op] ?? `op${r.op}`;
    s.byOp[op] = (s.byOp[op] ?? 0) + 1;
    let j = null;
    try { j = JSON.parse(hexToString(r.record)); } catch {}
    if (j?.cycle != null && Number(r.op) <= 3) s.cycles.add(j.cycle);
    if (r.op === 1 || r.op === 4) {
      s.paidUsd += fromUnits(r.usd);
      if (r.op === 1) s.paidByPayee[r.ref] = (s.paidByPayee[r.ref] ?? 0) + fromUnits(r.usd);
    }
    if (r.op === 3) s.proposals++;
    if (r.op === 4) s.approved++;
    if (r.op === 5) s.rejected++;
  }
  s.cycles = s.cycles.size;
  s.paidUsd = +s.paidUsd.toFixed(6);
  return s;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const cfg = loadConfig();
  const { pub } = clients(cfg);
  const { head, seq, records } = await readRecords(cfg, pub);
  const r = replay(records);
  console.log(`records read: ${records.length} (contract seq ${seq})`);
  console.log(r.ok && r.head === head ? `chain OK: replayed head ${r.head} equals the contract's head` : `CHAIN MISMATCH: ${JSON.stringify(r)} contract head ${head}`);
  console.log(JSON.stringify(summarize(records), null, 1));
  const i = process.argv.indexOf("--json");
  if (i > 0) {
    const rows = records.map((x) => ({ seq: Number(x.seq), op: OPS[x.op], ref: Number(x.ref), by: x.by, token: x.token, amount: x.amount.toString(), usd: fromUnits(x.usd), block: Number(x.block), tx: x.tx, record: hexToString(x.record) }));
    fs.writeFileSync(process.argv[i + 1], JSON.stringify({ tamias: cfg.tamias, head, rows }, null, 1));
  }
  if (!(r.ok && r.head === head) || records.length !== Number(seq)) process.exit(1);
}
