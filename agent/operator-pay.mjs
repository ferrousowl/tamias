// An operator-initiated payment through the contract with the agent key, recorded as an operator
// action (not an agent decision). Same limits as the agent: listed payee, budgets, floor.
//   TAMIAS_NETWORK=mainnet node operator-pay.mjs <payeeId> <amount> "<why>"
import fs from "fs";
import { toHex } from "viem";
import { loadConfig, clients, TAMIAS_ABI, USDC, toUnits, fees, log, statePath } from "./lib.mjs";

const [payee, amount, why] = process.argv.slice(2);
const cfg = loadConfig();
const { pub, wallet } = clients(cfg);
const agent = wallet(cfg.keys.agent);
const lock = statePath("cycle.lock");
if (fs.existsSync(lock)) throw new Error("a cycle is running; try again in a minute");
fs.writeFileSync(lock, String(process.pid));
process.on("exit", () => { try { fs.unlinkSync(lock); } catch {} });
const record = toHex(new TextEncoder().encode(JSON.stringify({ v: 1, app: "tamias", operator: why, do: { type: "pay", payee: Number(payee), amount: Number(amount), token: "USDC" } })));
const call = { address: cfg.tamias, abi: TAMIAS_ABI, functionName: "pay", args: [BigInt(payee), USDC, toUnits(amount), record] };
await pub.simulateContract({ ...call, account: agent.account });
const hash = await agent.writeContract({ ...call, ...(await fees(pub)) });
const rc = await pub.waitForTransactionReceipt({ hash });
log(`operator pay ${amount} to payee ${payee}: ${hash} (${rc.status})`);
