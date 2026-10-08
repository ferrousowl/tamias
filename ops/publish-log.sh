#!/usr/bin/env bash
# Publish the decision record as a snapshot (log.json) to the orphan `log` branch of the public repo,
# replacing the previous snapshot (one commit, force-pushed). The page reads it from
# raw.githubusercontent.com, then reads anything newer straight from the chain and re-verifies all.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOGREPO="${TAMIAS_LOG_REPO:-$HOME/work/tamias-log}"
if [ ! -d "$LOGREPO/.git" ]; then
  mkdir -p "$LOGREPO" && git -C "$LOGREPO" init -q -b log
  git -C "$LOGREPO" remote add origin git@github.com:ferrousowl/tamias.git
fi
( cd "$ROOT/agent" && TAMIAS_NETWORK=mainnet node verify.mjs --json "$LOGREPO/log.json" >/dev/null )
cd "$LOGREPO"
git add log.json
if git rev-parse -q --verify HEAD >/dev/null; then
  TZ=UTC git commit -q --amend -m "Tamias decision record snapshot"
else
  TZ=UTC git commit -q -m "Tamias decision record snapshot"
fi
git push -q -f origin HEAD:log
