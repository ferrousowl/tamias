# Tamias: an AI treasurer that cannot overspend

**Tamias** (ταμίας) was the Athenian treasurer: the official who held the city's money, and who answered for every coin at the end of his term. This Tamias is an AI agent that runs a small business's money on [Arc](https://arc.network), Circle's stablecoin chain. It decides when to pay, how much, and when to ask a human. It writes down why. It works inside a contract that enforces the owner's budgets on-chain, so whatever the model decides, it cannot spend past them.

- **Live on Arc mainnet since 2026-10-08 03:45 UTC:** [`0xc53fef25d0b143e67ed97961e616867b382cf1e9`](https://explorer.arc.io/address/0xc53fef25d0b143e67ed97961e616867b382cf1e9) (source verified on [Sourcify](https://repo.sourcify.dev/5042/0xc53fef25d0b143e67ed97961e616867b382cf1e9), exact match)
- **Decision record (every decision, read from the chain and verified in your browser):** https://ferrousowl.github.io/tamias/
- **Built for** the [Tameion Agents Hackathon](https://tameion.thecanteenapp.com/) (Canteen × Circle), 2026-10-07 → 2026-10-17

---

## The problem

A small business's money is many small decisions:
- top up this, pay that, hold the rest;
- this vendor is new, that subscription is late;
- the reserve is idle.

A cron job can follow thresholds, but it cannot weigh a late payment against a thin buffer, or notice that a deposit makes no sense. An LLM can do both. It can also be talked into anything, so nobody should hand it the keys to the treasury.

The Tameion brief puts the answer plainly: put the limit "somewhere the agent cannot reach: a contract that enforces the budget rather than a prompt that requests it, a threshold above which a human signs, a complete record it must produce afterwards." Tamias is those three things, plus an agent that is actually worth bounding.

## What it runs today

The business is real and small. Since 2026-10-02 ferrousowl has run two public protocols on Arc mainnet:

- [Standing](https://github.com/ferrousowl/standing): recurring USDC payments with keeper gas refunds.
- [Tock](https://github.com/ferrousowl/tock): a scheduler where owners prepay USDC gas for jobs.

Keeping them alive costs money every hour:
- a Tock gas balance pays whoever runs the scheduled jobs;
- two keeper bots need float to send transactions;
- a demo customer pays an hourly subscription that keeps Standing's public demo honest.

Until now a cron script handled that money with fixed thresholds (top up below X, move Y). Tamias replaces the script.

Every cycle the agent does six things:

1. **Observes** the chain: treasury cash and budgets, every operating wallet, the Tock jobs and what they really cost per run, the Standing orders, its reserves, and its pending proposals.
2. **Forecasts** each balance from what is scheduled and what it actually saw, and computes runway, the operation's net cost, and how many days the treasury covers.
3. **Decides** using Claude, which gets no tools, a briefing and a fixed JSON shape. It answers: pay, top up, settle a late payment itself, park cash, recall it, buy a piece of data, propose to the owner, hold, or freeze itself. Every decision states its reasoning, the rule it rests on, the alternatives it rejected, its confidence and a checkable expectation. The agent also picks when to look next: sooner when something is close to its minimum or late, later when everything has days of runway.
4. **Checks** each decision against the contract by simulation. If the contract refuses (over budget, over the per-payment limit, below the floor), the refusal goes back to the agent once. It usually revises into a smaller payment plus a proposal for the rest. The refusal itself goes on the record.
5. **Acts** by sending each decision as a contract call that carries the decision record.
6. **Learns**: next cycle, the agent sees its previous expectations next to what actually happened.

Revenue collection is fixed policy, not an agent decision. Before each cycle a collector sweeps what the operation's own wallets earned (subscription income, executor fees) into the treasury, leaving each wallet a working float. It only ever sends to the treasury.

## The contract: what the agent cannot do

[`contracts/src/Tamias.sol`](contracts/src/Tamias.sol) holds the treasury. The **owner** (a human) has full control. The **agent** (a hot key driven by the model) can only do the following:

| The agent may… | …and the contract enforces |
|---|---|
| `pay` a **listed payee** | per-payee cap; budget category with a cap per period; global auto-approval limit; USDC floor that cash on hand may never go below |
| `act`: make a call the owner wrote out in full | it picks only *when*; charged the larger of its declared cost and the USDC it actually took out; calls to tokens refused |
| `propose` anything else | the owner approves or rejects; the proposal is bound to what it pays and lapses if the payee changes, the key rotates, or it expires |
| park cash in a **vault** or **Circle Gateway**, and take it back | per-venue caps; floor; Gateway fees budgeted |
| `authorizeIntent`: let the treasury "sign" a Gateway transfer | the intent is checked field by field on-chain; it must go back to the treasury or to a listed payee within budget; the authorization lives ~30 minutes and dies with any brake |
| `note` a decision to hold, or `freeze` itself | only the owner unfreezes |

**Every call carries the agent's record:** the situation it saw, the forecast, the reasoning, the rule, the alternatives and what it expects, at most 8 KB of JSON, emitted in a `Recorded` event. Each record is folded into a hash chain:

```
head = keccak(head, seq, op, by, ref, token, amount, usd, detail, keccak(record))
```

`detail` binds what the record is about (the recipient, the Gateway intent digest, a proposal's target), so the agent's own text cannot misstate where money went. Owner policy changes go into the same chain with their exact calldata, so the rules in force at any moment can be rebuilt. Editing, dropping or reordering anything changes `head`. This is the Athenian *euthyna*, the audit an official faced at the end of his term, made continuous.

## Circle stack, used with no API key

| Piece | How Tamias uses it |
|---|---|
| **USDC on Arc** | The treasury's money and the gas. The native 18-decimal balance and the 6-decimal ERC-20 view are one balance. |
| **Circle Gateway** | The treasury's **reserve** as a unified USDC balance, spendable on other chains. The treasury itself is the depositor and signs its own burn intents through **ERC-1271**. The contract recomputes the EIP-712 digest from the intent and checks every field against policy before `isValidSignature` will accept it. The agent then posts it to the keyless Gateway API (`contractSigner: true`) and mints the attestation. A policy contract cosigning its own cross-chain transfers is the part of this project we have not seen elsewhere. |
| **x402** (Arc USDC, EIP-3009) | The agent **buys the data it uses**, per request: DeFi yields before parking cash, EUR/USD before valuing euros. It pays from its own wallet, which the treasury refills only within an on-chain budget. Each purchase must come from the owner's catalog, be on Arc, be in USDC, and cost no more than the catalog price. A **Gateway Nanopayments** buyer balance can be funded the same way (`GatewayDeposit` payees). |
| **CCTP v2** | A payee kind for vendors on other chains: burn on Arc, mint to a fixed recipient on a fixed domain. |
| **App Kit Earn** (Morpho ERC-4626 vaults on Arc) | A yield reserve. Idle cash beyond about two weeks of needs is parked when the yield beats the gas, and redeemed when the forecast needs it. |
| **EURC** | Payable to listed payees and counted against budgets at an owner-set USD rate. |

USYC (institutional KYB) and Circle Paymaster (not deployed on Arc, where gas is already USDC) were out of reach.

## Repository

```
contracts/   Tamias.sol + 58 tests on an Arc mainnet fork (Tamias, Reserves, Review)
agent/       observe → forecast → brain (Claude) → check → act; collector, Gateway, x402,
             owner CLI, chain verifier; config/{fork,mainnet}.json
web/         the decision-record page: reads the chain, replays the hash chain in the browser
ops/         systemd timer: a 5-minute check; the agent decides when a full cycle is due
```

### Run the tests

```sh
cd contracts && arc-forge test          # Arc Foundry; forks Arc mainnet
```

### Rehearse on a local fork

```sh
arc-anvil --network arc --fork-url https://rpc.mainnet.arc.io --port 8547 &
cd agent && npm ci
TAMIAS_NETWORK=fork node fork-setup.mjs        # impersonate the live wallets, fund fresh keys
TAMIAS_NETWORK=fork node owner.mjs deploy      # deploy + apply config.policy
TAMIAS_NETWORK=fork node owner.mjs fund 2 deployer
TAMIAS_NETWORK=fork node cycle.mjs             # one decision cycle (needs the `claude` CLI)
TAMIAS_NETWORK=fork node owner.mjs approve 0 "ok"
TAMIAS_NETWORK=fork node verify.mjs            # replay the record chain
```

### Verify the live record yourself

```sh
cd agent && TAMIAS_NETWORK=mainnet node verify.mjs
```

The command reads every record from the chain by following each record's `prevBlock` link, with no indexer and no block-range scan. It recomputes `head` from zero and compares it with the contract's. The web page does the same in your browser.

## Security

An independent review (2026-10-07) found nothing critical or high. The two medium findings and the low ones were fixed, each with a regression test in [`contracts/test/Review.t.sol`](contracts/test/Review.t.sol). The medium ones:
- a Gateway authorization could outlive the owner's brakes;
- an owner could be talked into blessing a raw digest, which other protocols would accept as the treasury's signature.

The fixes:
- Gateway authorizations are now short-lived and revoked by any brake.
- The owner can authorize only real burn intents of this treasury.
- Proposals are bound to their target.
- Period changes keep what was already spent.
- Gateway fees are budgeted.
- Actions are charged what actually leaves.
- The floor applies only to USDC outflows.

Known limits:
- Budgets use fixed windows, so up to twice a budget can go out across a window boundary.
- The EURC rate is set by the owner.
- Payees that are the agent's own wallet are an exfiltration channel up to their budget, so they are sized for that.
- The owner key is trusted.

## Built during Tameion

All of this repository was written during the event. The root commit is empty on purpose, so [`compare/a8404bd...main`](https://github.com/ferrousowl/tamias/compare/a8404bd...main) shows the whole delta. Standing and Tock themselves were started on 2026-10-02, also inside the event window.

## Deployment

Arc mainnet (chain 5042), deployed 2026-10-08 03:45 UTC:

| | |
|---|---|
| Tamias | [`0xc53fef25d0b143e67ed97961e616867b382cf1e9`](https://explorer.arc.io/address/0xc53fef25d0b143e67ed97961e616867b382cf1e9), deploy tx [`0xed8cc15e…cf3bdc`](https://explorer.arc.io/tx/0xed8cc15e861275027b147baae2d5f3cd2f8f62ebc8535c48c4918b0f55cf3bdc), block 24,838,865 |
| Owner (human) | `0x722440CbAd38E5f5bcb9512EF5F94277F7d1E697` |
| Agent (hot key) | `0xec358c50D7079EB83Ae317D20052e6be80a2EF39` |
| x402 data wallet | `0x9f9936706F5D640775e32b0948dcc3C93d5278e3` |
| Policy | [`agent/config/mainnet.json`](agent/config/mainnet.json): every value is also on the record chain as an owner `policy` entry |

First Gateway round trip (operator smoke test, 2026-10-08):
- moved 0.1 USDC into the treasury's Gateway balance: [`0x0bd93feb…`](https://explorer.arc.io/tx/0x0bd93feb0b07c6a8c1365d4e28f0077f529cc43ce9888b41139eb13570e5566b);
- the contract authorized the recall intent: [`0x94651c25…`](https://explorer.arc.io/tx/0x94651c25f896b6c389369ac9ac98c052603e0587fddebd260396f85dcf8552a5);
- the keyless Gateway API attested it through ERC-1271, and the 0.09615 USDC was minted back: [`0xeb55a311…`](https://explorer.arc.io/tx/0xeb55a311457acf49b0de2f7b3527b6406d97b099de87b1edd14f483b57b8ed64).

## License

MIT
