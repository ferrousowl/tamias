// Shared plumbing for the Tamias agent: config, clients, keys, ABIs, units.
// Keys live outside the repo (default ~/.config/standing/<name>.key, mode 600) and are never printed.
import { createPublicClient, createWalletClient, fallback, http, parseAbi, formatUnits, parseUnits } from "viem";
import { privateKeyToAccount, generatePrivateKey } from "viem/accounts";
import fs from "fs";
import os from "os";
import path from "path";

export const ROOT = path.dirname(new URL(import.meta.url).pathname);
export const NETWORK = process.env.TAMIAS_NETWORK ?? "fork";
export const CONFIG_FILE = process.env.TAMIAS_CONFIG ?? path.join(ROOT, "config", `${NETWORK}.json`);
export const STATE_DIR = process.env.TAMIAS_STATE ?? path.join(ROOT, "..", "state", NETWORK);
export const KEYS = process.env.TAMIAS_KEYS ?? path.join(os.homedir(), ".config/standing");

export const USDC = "0x3600000000000000000000000000000000000000";
export const EURC = "0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1";

export function loadConfig() {
  const c = JSON.parse(fs.readFileSync(CONFIG_FILE, "utf8"));
  c.network = NETWORK;
  return c;
}

export function saveConfig(c) {
  const { network, ...rest } = c;
  fs.writeFileSync(CONFIG_FILE, JSON.stringify(rest, null, 2) + "\n");
}

export function clients(cfg) {
  const urls = [cfg.rpc, ...(cfg.rpcFallbacks ?? [])];
  const transport = urls.length > 1 ? fallback(urls.map((u) => http(u, { retryCount: 1 }))) : http(urls[0], { retryCount: 2 });
  const chain = {
    id: cfg.chainId,
    name: cfg.chainName ?? "Arc",
    nativeCurrency: { name: "USDC", symbol: "USDC", decimals: 18 },
    rpcUrls: { default: { http: urls } },
  };
  const pub = createPublicClient({ chain, transport });
  const wallet = (name, { create = false } = {}) => {
    // On a local fork, live wallets are impersonated (anvil signs) instead of using their real keys.
    const imp = cfg.impersonate?.[name];
    if (imp) return createWalletClient({ account: imp, chain, transport });
    const file = path.join(KEYS, `${name}.key`);
    if (!fs.existsSync(file)) {
      if (!create) throw new Error(`missing key ${file}`);
      fs.mkdirSync(KEYS, { recursive: true, mode: 0o700 });
      fs.writeFileSync(file, generatePrivateKey(), { mode: 0o600 });
    }
    const account = privateKeyToAccount(fs.readFileSync(file, "utf8").trim());
    return createWalletClient({ account, chain, transport });
  };
  return { pub, wallet, chain };
}

export const addressOfKey = (name) =>
  privateKeyToAccount(fs.readFileSync(path.join(KEYS, `${name}.key`), "utf8").trim()).address;

// ─── units ───
// The agent and the contract name amounts in 6-decimal token units; native balances have 18.
export const fromNative = (wei) => Number(formatUnits(wei, 18));
export const fromUnits = (u) => Number(formatUnits(u, 6));
export const toUnits = (x) => parseUnits(typeof x === "number" ? x.toFixed(6) : String(x), 6);
export const fmt = (x, d = 4) => (Math.round(x * 10 ** d) / 10 ** d).toFixed(d);

// ─── ABIs ───
export const TAMIAS_ABI = JSON.parse(fs.readFileSync(path.join(ROOT, "abi", "Tamias.json"), "utf8"));

export const TOCK_ABI = parseAbi([
  "struct Job { address owner; address target; uint40 nextRun; uint32 interval; uint32 gasLimit; uint32 runs; uint32 maxRuns; uint8 failures; bool active; uint128 value; uint128 maxFee; uint128 tip; bytes data; string name; }",
  "function balanceOf(address) view returns (uint256)",
  "function agentOf(address) view returns (address)",
  "function jobsOf(address) view returns (uint256[])",
  "function getJob(uint256) view returns (Job)",
  "function deposit() payable",
  "function depositFor(address owner) payable",
  "event JobRan(uint256 indexed jobId, address indexed executor, bool success, uint256 fee, uint40 nextRun, uint32 runs)",
]);

export const AGENT_ABI = parseAbi(["function exec(address target, uint256 value, bytes data) returns (bool)"]);

export const STANDING_ABI = parseAbi([
  "struct Plan { address merchant; address token; uint96 amount; uint32 period; uint96 keeperTip; uint96 maxExecFee; bool active; string name; }",
  "struct Order { uint64 planId; address payer; uint40 nextDue; uint40 startedAt; uint32 payments; bool active; }",
  "function getPlan(uint256) view returns (Plan)",
  "function getOrder(uint256) view returns (Order)",
  "function feeBps() view returns (uint16)",
  "function execute(uint256 orderId)",
  "function executeBatch(uint256[] orderIds) returns (uint256)",
  "event Paid(uint256 indexed orderId, uint256 indexed planId, address indexed executor, uint256 amount, uint256 merchantNet, uint256 protocolFee, uint256 execFee, uint40 nextDue)",
]);

export const ERC20_ABI = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function transfer(address to, uint256 amount) returns (bool)",
  "function approve(address spender, uint256 amount) returns (bool)",
]);

// ─── state files ───
export function statePath(name) {
  fs.mkdirSync(STATE_DIR, { recursive: true });
  return path.join(STATE_DIR, name);
}

export function readJson(name, dflt) {
  const p = statePath(name);
  return fs.existsSync(p) ? JSON.parse(fs.readFileSync(p, "utf8")) : dflt;
}

export function writeJson(name, v) {
  const p = statePath(name);
  fs.writeFileSync(p + ".tmp", JSON.stringify(v, null, 2));
  fs.renameSync(p + ".tmp", p);
}

export function appendJsonl(name, v) {
  fs.appendFileSync(statePath(name), JSON.stringify(v) + "\n");
}

export function readJsonl(name, last = Infinity) {
  const p = statePath(name);
  if (!fs.existsSync(p)) return [];
  const lines = fs.readFileSync(p, "utf8").split("\n").filter(Boolean);
  return lines.slice(Math.max(0, lines.length - last)).map((l) => JSON.parse(l));
}

export const log = (...a) => console.log(new Date().toISOString(), ...a);

/** Fee settings for a write: Arc drops txs priced under the base fee, so pay 2x headroom. */
export async function fees(pub) {
  const { baseFeePerGas } = await pub.getBlock();
  return { maxFeePerGas: baseFeePerGas * 2n, maxPriorityFeePerGas: 0n };
}

export async function sendAndWait(pub, label, hashPromise) {
  const hash = await hashPromise;
  const receipt = await pub.waitForTransactionReceipt({ hash, timeout: 120_000 });
  if (receipt.status !== "success") throw new Error(`${label} reverted: ${hash}`);
  log(`  ${label}: ${hash} (gas ${receipt.gasUsed})`);
  return receipt;
}
