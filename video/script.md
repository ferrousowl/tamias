# Tamias demo video: script (target 2:40, hard limit 3:00)

Rules: no face, no voice. Captions only (burned into the frames), with optional quiet music-free
silence. Everything shown is real: mainnet transactions, the live decision-record page, the actual
agent logs. Recorded with Playwright screen capture of a scene page (`video/scenes.html`, built
from real data) at 1280×720, exported as WebM (Playwright's bundled ffmpeg), uploaded to the
host the user picks.

| # | Time | On screen | Caption (burned in) |
|---|------|-----------|---------------------|
| 1 | 0:00–0:10 | Title card: "Tamias", seal motif, Arc · USDC · Circle Gateway · x402 | Tamias: an AI treasurer that cannot overspend. Running a real business's money on Arc. |
| 2 | 0:10–0:28 | Split: left `ops-hourly.mjs` thresholds (the old cron job); right Standing + Tock live stats | This business runs two live protocols on Arc mainnet. Until this week, a cron script ran its money on fixed thresholds. |
| 3 | 0:28–0:40 | Diagram: owner → Tamias contract (budgets, payees, floor, auto-limit) → payees; agent hot key on the side | The agent's limits live in a contract, not a prompt: listed payees, budgets per period, a per-payment limit, a cash floor. |
| 4 | 0:40–1:15 | Terminal replay of a real cycle: observe → forecast lines → Claude's assessment → "contract refused: OverAutoLimit(0.9, 0.3)" → revised: pay 0.3 + propose 0.9 → tx hashes | Every cycle it reads the chain, forecasts runway, and decides. When it asks for too much, the contract says no. It pays what it may and asks the owner for the rest. |
| 5 | 1:15–1:30 | Owner approval (owner CLI line + the approve record on the page) | A human signs above the limit. Approvals are on the record too. |
| 6 | 1:30–1:55 | Gateway: `toGateway` record → `authorizeIntent` record (digest) → Gateway API attestation → `gatewayMint` tx | Its reserve sits in Circle Gateway. The contract checks each transfer on-chain and signs it itself, via ERC-1271. |
| 7 | 1:55–2:10 | x402: "bought yields for 0.006 USDC" record, then the decision that used it | When data would change a decision, it buys it over x402, per request, from a budget the contract caps. |
| 8 | 2:10–2:35 | Decision-record page: green "verified" badge, metrics row, scroll through decisions, open one record's details (rule, alternatives, expectation, self-review) | Every decision, with its reasoning, is on-chain in a hash chain anyone can replay. This page re-checks it in your browser. |
| 9 | 2:35–2:45 | End card: repo URL, page URL, contract address | github.com/ferrousowl/tamias. Built during Tameion, on Arc. |

Notes
- Scenes 4–7 must use mainnet records from the live window. Fall back to fork footage only if a
  path never fired on mainnet, and label it "local fork rehearsal" in the caption.
- Use numbers from the live record for the metrics (decisions, USDC paid, escalations, agreement rate).
- Keep each caption on screen at least 4 s (~12 words per 4 s).
