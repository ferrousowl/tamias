#!/usr/bin/env bash
# Tamias mainnet go-live. RUN ONLY WITH THE USER'S EXPLICIT OK (it deploys and moves mainnet funds,
# and replaces the live ops timer). Each step prints what it did; stop at the first error.
#
#   bash ops/go-live.sh <treasury-funding-USDC>     e.g. bash ops/go-live.sh 1.0
set -euo pipefail
cd "$(dirname "$0")/../agent"
export TAMIAS_NETWORK=mainnet
FUND=${1:?usage: go-live.sh <treasury funding in USDC>}

# 0. Preconditions: tests green, config has no deployment yet.
( cd ../contracts && nice arc-forge test >/dev/null ) && echo "tests: ok"
python3 -c "import json,sys; c=json.load(open('config/mainnet.json')); sys.exit('already deployed' if c.get('tamias') else 0)"

# 1. Gas for the owner key (deploy + policy ≈ 0.16 USDC) and the agent key, from the deployer.
node --input-type=module -e "
const { loadConfig, clients, addressOfKey, fees, sendAndWait } = await import('./lib.mjs');
const { parseEther } = await import('viem');
const cfg = loadConfig(); const { pub, wallet } = clients(cfg); const d = wallet('deployer');
for (const [k, v] of [[cfg.keys.owner, '0.25'], [cfg.keys.agent, '0.15']]) {
  await sendAndWait(pub, 'gas for ' + k, d.sendTransaction({ to: addressOfKey(k), value: parseEther(v), ...(await fees(pub)) }));
}"

# 2. Deploy and apply the policy in config/mainnet.json (writes the address into the config).
node owner.mjs deploy

# 3. Fund the treasury from the deployer (the merchant account keeps its 0.6 working float).
node owner.mjs fund "$FUND" deployer

# 4. Verify the source on Sourcify (the explorer's own API is behind Cloudflare).
ADDR=$(python3 -c "import json; print(json.load(open('config/mainnet.json'))['tamias'])")
ARGS=$(node --input-type=module -e "
const { loadConfig, addressOfKey, toUnits } = await import('./lib.mjs');
const { encodeAbiParameters } = await import('viem');
const c = loadConfig();
console.log(encodeAbiParameters([{type:'address'},{type:'address'},{type:'uint128'},{type:'uint128'}],
  [addressOfKey(c.keys.owner), addressOfKey(c.keys.agent), toUnits(c.policy.autoLimit), toUnits(c.policy.floor)]));")
( cd ../contracts && arc-forge verify-contract "$ADDR" src/Tamias.sol:Tamias --verifier sourcify --chain-id 5042 \
    --constructor-args "$ARGS" ) || echo "verify: failed, retry by hand (see NOTES)"

# 5. The page reads mainnet.
python3 - <<EOF
import json; c=json.load(open('config/mainnet.json'))
json.dump({"tamias": c["tamias"], "rpcs": ["https://rpc.mainnet.arc.io", "https://5042.rpc.thirdweb.com"], "explorer": "https://explorer.arc.io"}, open('../web/config.json','w'))
EOF

# 6. Tamias takes over from the hourly ops script; tock-keeper.service stays as it is.
systemctl --user disable --now standing-topup.timer
cp ../ops/tamias-agent.service ../ops/tamias-agent.timer ~/.config/systemd/user/
systemctl --user daemon-reload

# 7. First cycle by hand, then the timer.
node cycle.mjs
node verify.mjs | head -3
systemctl --user enable --now tamias-agent.timer
echo "live: $ADDR"
