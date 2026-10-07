// Revenue collection: fixed policy, not an agent decision. Wallets the business operates (the
// Standing merchant account, the Tock Agent that earns executor fees, the keepers) keep a working
// float; anything above `keep + minSweep` is swept into the treasury, where the agent allocates it.
import { parseEther } from "viem";
import { AGENT_ABI, fees, fromNative, log } from "./lib.mjs";

export async function collect(cfg, pub, wallet) {
  const done = [];
  for (const s of cfg.collector?.sweeps ?? []) {
    const w = cfg.business.wallets.find((x) => x.id === s.from);
    if (!w) continue;
    const bal = await pub.getBalance({ address: w.address });
    const keep = parseEther(String(s.keep));
    if (bal < keep + parseEther(String(s.minSweep))) continue;
    // leave a little for gas when the swept wallet pays for its own transfer
    const amount = bal - keep;
    const label = `sweep ${fromNative(amount).toFixed(4)} USDC from ${s.from}`;
    let hash;
    if (s.agentOwnerKey) {
      // a Tock Agent: its owner moves funds out with Agent.exec(treasury, amount, "")
      const owner = wallet(s.agentOwnerKey);
      hash = await owner.writeContract({ address: w.address, abi: AGENT_ABI, functionName: "exec", args: [cfg.tamias, amount, "0x"], ...(await fees(pub)) });
    } else {
      const from = wallet(s.key);
      hash = await from.sendTransaction({ to: cfg.tamias, value: amount, ...(await fees(pub)) });
    }
    const rc = await pub.waitForTransactionReceipt({ hash, timeout: 120_000 });
    if (rc.status !== "success") { log(`${label} reverted: ${hash}`); continue; }
    log(`${label} → ${hash}`);
    done.push({ from: s.from, amount: fromNative(amount), tx: hash });
  }
  return done;
}
