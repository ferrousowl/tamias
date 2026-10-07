// Prepare a local Arc mainnet fork for a rehearsal: impersonate the live wallets (so their real
// keys are never used off-chain), give the fresh owner and agent keys gas, and optionally start a
// Tock keeper loop against the fork so scheduled jobs keep running there.
//
//   arc-anvil --network arc --fork-url https://rpc.mainnet.arc.io --port 8547 &
//   TAMIAS_NETWORK=fork node fork-setup.mjs
import { parseEther, toHex } from "viem";
import { loadConfig, clients, addressOfKey, log } from "./lib.mjs";

const cfg = loadConfig();
if (!/127\.0\.0\.1|localhost/.test(cfg.rpc)) throw new Error("fork-setup is for a local fork only");
const { pub } = clients(cfg);
const rpc = (method, params) => pub.request({ method, params });

for (const [name, addr] of Object.entries(cfg.impersonate ?? {})) {
  await rpc("anvil_impersonateAccount", [addr]);
  log(`impersonating ${name} ${addr}`);
}
for (const k of [cfg.keys.owner, cfg.keys.agent]) {
  const a = addressOfKey(k);
  const bal = await pub.getBalance({ address: a });
  if (bal < parseEther("1")) await rpc("anvil_setBalance", [a, toHex(parseEther("2"))]);
  log(`${k} ${a} funded on the fork`);
}
