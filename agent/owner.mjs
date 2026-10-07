// The owner's side: deploy, set policy, fund, review proposals. A human runs these; the agent
// loop never loads the owner key.
//
//   node owner.mjs deploy                 deploy Tamias and apply config.policy (saves the address)
//   node owner.mjs status                 policy, budgets and proposals
//   node owner.mjs approve <id> "<note>"  carry out a proposal
//   node owner.mjs reject <id> "<note>"
//   node owner.mjs fund <amount> [key]    send USDC into the treasury (default: the owner key)
//   node owner.mjs unfreeze | freeze
import fs from "fs";
import path from "path";
import { encodeFunctionData, parseAbiItem, toHex, toFunctionSelector, encodeAbiParameters, parseEther } from "viem";
import { loadConfig, saveConfig, clients, addressOfKey, TAMIAS_ABI, EURC, USDC, ROOT, toUnits, fees, log, sendAndWait } from "./lib.mjs";
import { observe } from "./observe.mjs";

const cfg = loadConfig();
const { pub, wallet } = clients(cfg);
const owner = wallet(cfg.keys.owner);
const T = () => ({ address: cfg.tamias, abi: TAMIAS_ABI });
const KIND = { transfer: 0, "tock-gas": 1, cctp: 2 };
const [cmd, ...rest] = process.argv.slice(2);
const note = (s) => toHex(new TextEncoder().encode(s ?? ""));

async function write(label, functionName, args, extra = {}) {
  return sendAndWait(pub, label, owner.writeContract({ ...T(), functionName, args, ...extra, ...(await fees(pub)) }));
}

const resolve = (x) => (x === "tock" ? cfg.business.tock.address : x === "standing" ? cfg.business.standing.address : x === "cctp" ? cfg.cctp?.tokenMessenger : x);

function actionCalldata(a) {
  const item = parseAbiItem(`function ${a.call}`);
  return encodeFunctionData({ abi: [item], functionName: item.name, args: a.args.map((v, i) => (item.inputs[i].type.startsWith("uint") ? BigInt(v) : v)) });
}

async function applyPolicy(p) {
  await write("setLimits", "setLimits", [toUnits(p.autoLimit), toUnits(p.floor), p.proposalTtlHours * 3600]);
  if (p.eurcRate) await write("setUsdRate EURC", "setUsdRate", [EURC, toUnits(p.eurcRate)]);
  const nCat = Number(await pub.readContract({ ...T(), functionName: "categoryCount" }));
  for (const [i, c] of p.categories.entries()) {
    if (i < nCat) continue; // only add new ones here; edit existing ones deliberately
    await write(`category ${i} ${c.name}`, "setCategory", [BigInt(i), c.name, toUnits(c.budget), c.periodHours * 3600]);
  }
  const nPay = Number(await pub.readContract({ ...T(), functionName: "payeeCount" }));
  for (const [i, x] of p.payees.entries()) {
    if (i < nPay) continue;
    const payee = {
      account: resolve(x.account), via: x.via ? resolve(x.via) : "0x0000000000000000000000000000000000000000", domain: x.domain ?? 0,
      kind: KIND[x.kind], category: x.category, active: true, maxPayment: toUnits(x.maxPayment), maxFee: toUnits(x.maxFee ?? 0), label: x.label,
    };
    await write(`payee ${i} ${x.label}`, "setPayee", [BigInt(i), payee]);
  }
  const nAct = Number(await pub.readContract({ ...T(), functionName: "actionCount" }));
  for (const [i, a] of (p.actions ?? []).entries()) {
    if (i < nAct) continue;
    const action = { target: resolve(a.target), category: a.category, active: true, charge: toUnits(a.charge ?? 0), data: actionCalldata(a), label: a.label };
    await write(`action ${i} ${a.label}`, "setAction", [BigInt(i), action]);
  }
}

if (cmd === "deploy") {
  if (cfg.tamias) throw new Error(`already deployed at ${cfg.tamias}; remove it from the config to deploy again`);
  const art = JSON.parse(fs.readFileSync(path.join(ROOT, "..", "contracts", "out", "Tamias.sol", "Tamias.json"), "utf8"));
  const agentAddr = addressOfKey(cfg.keys.agent);
  const p = cfg.policy;
  const hash = await owner.deployContract({
    abi: TAMIAS_ABI, bytecode: art.bytecode.object, args: [owner.account.address, agentAddr, toUnits(p.autoLimit), toUnits(p.floor)], ...(await fees(pub)),
  });
  const rc = await pub.waitForTransactionReceipt({ hash });
  if (rc.status !== "success") throw new Error(`deploy reverted ${hash}`);
  cfg.tamias = rc.contractAddress;
  cfg.deployBlock = Number(rc.blockNumber);
  cfg.deployTx = hash;
  saveConfig(cfg);
  log(`Tamias deployed at ${cfg.tamias} (tx ${hash}); owner ${owner.account.address}, agent ${agentAddr}`);
  await applyPolicy(p);
  log("policy applied");
} else if (cmd === "apply-policy") {
  await applyPolicy(cfg.policy);
} else if (cmd === "status") {
  const s = await observe(cfg, pub);
  console.log(JSON.stringify(s.treasury, null, 1));
} else if (cmd === "approve" || cmd === "reject") {
  const [id, text] = rest;
  await write(`${cmd} #${id}`, cmd === "approve" ? "approveProposal" : "rejectProposal", [BigInt(id), note(JSON.stringify({ v: 1, app: "tamias", by: "owner", decision: cmd, proposal: Number(id), note: text ?? "" }))]);
} else if (cmd === "fund") {
  const [amount, key] = rest;
  const from = key ? wallet(key) : owner;
  await sendAndWait(pub, `fund ${amount}`, from.sendTransaction({ to: cfg.tamias, value: parseEther(String(amount)), ...(await fees(pub)) }));
} else if (cmd === "freeze" || cmd === "unfreeze") {
  await write(cmd, "setFrozen", [cmd === "freeze"]);
} else {
  console.log("usage: node owner.mjs deploy | apply-policy | status | approve <id> <note> | reject <id> <note> | fund <amount> [key] | freeze | unfreeze");
}
