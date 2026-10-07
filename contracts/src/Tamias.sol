// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @dev Tock (github.com/ferrousowl/tock): prepaid gas balances for scheduled jobs.
interface ITock {
    function depositFor(address owner) external payable;
}

/// @dev Circle CCTP v2 TokenMessenger.
interface ITokenMessengerV2 {
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external;
}

/// @dev Circle Gateway wallet (unified USDC balance).
interface IGatewayWallet {
    function deposit(address token, uint256 value) external;
    function depositFor(address token, address depositor, uint256 value) external;
    function totalBalance(address token, address depositor) external view returns (uint256);
    function withdrawalDelay() external view returns (uint256);
}

/// @dev ERC-4626 vault, e.g. a Morpho USDC vault offered through Circle App Kit Earn.
interface IERC4626 {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function balanceOf(address) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// @title Tamias — a treasury an AI agent runs and cannot overspend
/// @notice Tamias (ταμίας) was the Athenian treasurer. This contract holds a business's USDC and
///         lets a hot key — the agent — move it, but only along paths the owner has opened:
///
///         * money goes only to payees the owner listed, never to an address the agent names;
///         * every payee belongs to a budget category with a spending cap per period;
///         * no single payment above `autoLimit`, and never below the `floor` of USDC on hand;
///         * anything outside those limits can only be *proposed*; a human approves or rejects it;
///         * every action carries the agent's written record of why, and every record is chained
///           into an append-only hash (`head`), so the log of decisions cannot be edited later.
///
///         The agent decides when and how much. The contract decides whether it is allowed.
///
///         Amounts the agent names are in token units: USDC and EURC both have 6 decimals here.
///         On Arc the native balance *is* USDC (18 decimals); the ERC-20 view at
///         `0x3600…0000` moves the same balance with 6. Budgets are kept in micro-USD.
contract Tamias {
    // ───────────────────────────── types ─────────────────────────────

    /// @notice How a payment reaches a payee.
    enum Kind {
        Transfer, // ERC-20 transfer of USDC or EURC to `account`
        TockGas, // native USDC into the Tock gas balance of `account`, through the Tock contract `via`
        Cctp, // USDC burned through CCTP `via` and minted to `account` on domain `domain`
        GatewayDeposit, // USDC into the Circle Gateway balance of `account` (e.g. the agent's x402 budget), wallet `via`
        Gateway // from the treasury's own Gateway balance, by a burn intent minted to `account` on `domain`
            // through minter `via` as token `remoteToken` (see `authorizeIntent`)
    }

    struct Category {
        uint128 budget; // micro-USD the agent may spend per period
        uint128 spent; // micro-USD spent in the current window
        uint32 period; // seconds
        uint40 windowStart;
        string name;
    }

    struct Payee {
        address account;
        address via; // Tock or CCTP TokenMessenger contract, for those kinds
        uint32 domain; // CCTP destination domain
        Kind kind;
        uint16 category;
        bool active;
        uint128 maxPayment; // micro-USD per payment
        uint128 maxFee; // CCTP / Gateway: most the agent may let the bridge charge, token units
        address remoteToken; // Gateway: USDC on the destination chain
        string label;
    }

    /// @notice A call the owner has written out in full. The agent may only choose *when* to
    ///         make it; it cannot change the target, the calldata or anything else.
    struct Action {
        address target;
        uint16 category;
        bool active;
        uint128 charge; // micro-USD counted against the category each time it runs
        bytes data;
        string label;
    }

    enum Status {
        Pending,
        Approved,
        Rejected
    }

    /// @notice Something the agent wanted to do but may not do alone.
    struct Proposal {
        uint8 op; // OP_PAY (to a listed payee), OP_PAY_TO (to any address) or OP_ACT
        Status status;
        uint40 createdAt;
        uint64 ref; // payee or action id
        address account; // OP_PAY_TO recipient
        address token;
        uint128 amount;
        bytes32 recordHash; // the agent's reasoning, as recorded when it proposed
        bytes32 target; // what the proposal pays or calls, fixed when proposed (see `_targetHash`)
        address proposer; // the agent key that proposed it; a rotated-out key's proposals lapse
        uint40 expiresAt;
    }

    /// @notice A place idle cash can wait and earn: an ERC-4626 vault holding USDC.
    struct Vault {
        address vault;
        bool active;
        uint128 cap; // most USDC (token units) the agent may keep in it
        string label;
    }

    /// @notice Circle Gateway on this chain. The treasury can hold part of its cash there as a
    ///         unified balance; spending it takes a burn intent that this contract signs (ERC-1271)
    ///         only after checking it against policy.
    struct GatewayConfig {
        address wallet;
        address minter;
        uint32 domain; // this chain's Gateway/CCTP domain (Arc: 26)
        uint128 recallMaxFee; // most a recall to the treasury may pay in fees, token units
        uint32 maxIntentBlocks; // how far beyond Gateway's withdrawal delay an intent may stay burnable
        uint128 cap; // most USDC (token units) the agent may keep in the treasury's Gateway balance
        uint16 feeCategory; // budget that pays Gateway fees on recalls
    }

    /// @dev An authorized burn intent. Gateway checks the signature only when the intent is
    ///      submitted, so the authorization needs to live only minutes, and it lapses whenever the
    ///      owner applies a brake (freeze, new agent key, payee or Gateway change).
    struct IntentAuth {
        uint64 epoch; // `intentEpoch` for the agent's intents, `ownerIntentEpoch` for the owner's
        uint64 submitBy; // last block at which `isValidSignature` accepts it
        bool byOwner; // owner intents survive the agent's brakes (they are how the owner recovers)
    }

    /// @dev Circle Gateway burn intent (EIP-712, domain {name: "GatewayWallet", version: "1"}).
    struct TransferSpec {
        uint32 version;
        uint32 sourceDomain;
        uint32 destinationDomain;
        bytes32 sourceContract;
        bytes32 destinationContract;
        bytes32 sourceToken;
        bytes32 destinationToken;
        bytes32 sourceDepositor;
        bytes32 destinationRecipient;
        bytes32 sourceSigner;
        bytes32 destinationCaller;
        uint256 value;
        bytes32 salt;
        bytes hookData;
    }

    struct BurnIntent {
        uint256 maxBlockHeight;
        uint256 maxFee;
        TransferSpec spec;
    }

    // ─────────────────────────── constants ───────────────────────────

    address public constant USDC = 0x3600000000000000000000000000000000000000;
    uint256 internal constant NATIVE_PER_UNIT = 1e12; // native wei per USDC token unit

    uint8 public constant OP_NOTE = 0; // a decision that moved nothing (hold, defer, wait)
    uint8 public constant OP_PAY = 1;
    uint8 public constant OP_ACT = 2;
    uint8 public constant OP_PROPOSE = 3;
    uint8 public constant OP_APPROVE = 4;
    uint8 public constant OP_REJECT = 5;
    uint8 public constant OP_FREEZE = 6;
    uint8 public constant OP_POLICY = 7; // an owner change; the record is its exact calldata
    uint8 public constant OP_PAY_TO = 8; // proposal kind only: pay an address that is not listed
    uint8 public constant OP_GATEWAY_IN = 9; // cash moved into the treasury's Gateway balance
    uint8 public constant OP_VAULT_IN = 10; // cash parked in a vault
    uint8 public constant OP_VAULT_OUT = 11; // cash taken back from a vault
    uint8 public constant OP_INTENT = 12; // a Gateway burn intent authorized (ref = payee, or RECALL)

    /// @notice `authorizeIntent` payee id meaning "back to this treasury on this chain".
    uint256 public constant RECALL = type(uint256).max;

    bytes4 internal constant ERC1271_OK = 0x1626ba7e;
    bytes32 internal constant TRANSFER_SPEC_TYPEHASH = keccak256(
        "TransferSpec(uint32 version,uint32 sourceDomain,uint32 destinationDomain,bytes32 sourceContract,bytes32 destinationContract,bytes32 sourceToken,bytes32 destinationToken,bytes32 sourceDepositor,bytes32 destinationRecipient,bytes32 sourceSigner,bytes32 destinationCaller,uint256 value,bytes32 salt,bytes hookData)"
    );
    bytes32 internal constant BURN_INTENT_TYPEHASH = keccak256(
        "BurnIntent(uint256 maxBlockHeight,uint256 maxFee,TransferSpec spec)TransferSpec(uint32 version,uint32 sourceDomain,uint32 destinationDomain,bytes32 sourceContract,bytes32 destinationContract,bytes32 sourceToken,bytes32 destinationToken,bytes32 sourceDepositor,bytes32 destinationRecipient,bytes32 sourceSigner,bytes32 destinationCaller,uint256 value,bytes32 salt,bytes hookData)"
    );
    bytes32 internal constant GATEWAY_DOMAIN_SEPARATOR = keccak256(
        abi.encode(keccak256("EIP712Domain(string name,string version)"), keccak256("GatewayWallet"), keccak256("1"))
    );

    uint256 public constant MAX_RECORD = 8192;
    /// @notice Blocks (~0.5 s each) an authorized intent stays submittable to Gateway: ~30 min,
    ///         enough for Gateway's validator, which reads state up to 5 minutes old.
    uint64 public constant INTENT_SUBMIT_BLOCKS = 3600;
    uint32 public constant MIN_PERIOD = 1 hours;

    // ──────────────────────────── storage ────────────────────────────

    address public owner;
    address public pendingOwner;
    address public agent;
    bool public frozen; // when set, the agent can do nothing but write notes

    uint128 public autoLimit; // largest payment the agent may make alone, micro-USD
    uint128 public floor; // USDC (token units) the agent may never spend below
    uint32 public proposalTtl = 3 days;

    /// @notice micro-USD per whole token (1e6 units). USDC is fixed at 1e6; others are set by
    ///         the owner and used only to count them against budgets. 0 means not accepted.
    mapping(address token => uint256) public usdRate;

    Category[] internal _categories;
    Payee[] internal _payees;
    Action[] internal _actions;
    Proposal[] internal _proposals;

    /// @notice Hash chain over every record: head = keccak(head, seq, op, by, ref, token, amount,
    ///         usd, keccak(record)). Anyone can replay the events and arrive at the same value.
    bytes32 public head;
    uint64 public seq;
    /// @notice Block of the latest record; each record names the block of the one before it, so a
    ///         reader can walk the log backwards without scanning block ranges.
    uint64 public lastBlock;

    Vault[] internal _vaults;
    GatewayConfig public gateway;
    /// @notice Burn-intent digests this treasury has authorized; `isValidSignature` accepts only these,
    ///         and only while their epoch is current and their submission window open.
    mapping(bytes32 digest => IntentAuth) public intentAuth;
    uint64 public intentEpoch;
    uint64 public ownerIntentEpoch;

    bool private transient _locked;

    // ──────────────────────────── events ─────────────────────────────

    event Recorded(
        uint64 indexed seq,
        uint8 indexed op,
        uint256 indexed ref,
        address by,
        address token,
        uint256 amount,
        uint256 usd,
        bytes32 detail,
        bytes32 head,
        uint64 prevBlock,
        bytes record
    );
    event Received(address indexed from, uint256 amount);
    event OwnershipTransferStarted(address indexed from, address indexed to);

    // ──────────────────────────── errors ─────────────────────────────

    error NotOwner();
    error NotAgent();
    error Frozen();
    error BadParams();
    error UnknownId();
    error Inactive();
    error TokenNotAccepted();
    error OverPayeeLimit(uint256 usd, uint256 limit);
    error OverAutoLimit(uint256 usd, uint256 limit);
    error OverBudget(uint16 category, uint256 usd, uint256 remaining);
    error BelowFloor(uint256 balanceAfter, uint256 floor);
    error RecordTooLong();
    error NotPending();
    error Expired();
    error CallFailed(bytes reason);
    error Reentrancy();
    /// @notice A burn intent failed a check. field: 0 version, 1 sourceDomain, 2 sourceContract,
    ///         3 sourceToken, 4 depositor/signer, 5 hookData, 6 value, 7 maxBlockHeight,
    ///         8 recall destination, 9 maxFee, 10 payee kind, 11 payee destination.
    error BadIntent(uint8 field);
    error OverVaultCap(uint256 assets, uint256 cap);
    error OverGatewayCap(uint256 balance, uint256 cap);
    error ProposalChanged();

    // ─────────────────────────── modifiers ───────────────────────────

    // Each modifier calls one internal function, so its checks are not copied into every function.

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    modifier onlyAgent() {
        _onlyAgent();
        _;
    }

    /// @dev Agent records are bounded so a log entry always stays cheap to store and to read.
    modifier bounded(bytes calldata record) {
        _bounded(record.length);
        _;
    }

    modifier nonReentrant() {
        _enter();
        _;
        _locked = false;
    }

    function _onlyOwner() internal view {
        if (msg.sender != owner) revert NotOwner();
    }

    function _onlyAgent() internal view {
        if (msg.sender != agent) revert NotAgent();
        if (frozen) revert Frozen();
    }

    function _bounded(uint256 length) internal pure {
        if (length > MAX_RECORD) revert RecordTooLong();
    }

    function _enter() internal {
        if (_locked) revert Reentrancy();
        _locked = true;
    }

    constructor(address owner_, address agent_, uint128 autoLimit_, uint128 floor_) {
        if (owner_ == address(0)) revert BadParams();
        owner = owner_;
        agent = agent_;
        autoLimit = autoLimit_;
        floor = floor_;
        usdRate[USDC] = 1e6;
    }

    /// @notice Revenue and top-ups arrive as plain native USDC transfers.
    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    // ───────────────────────── agent actions ─────────────────────────

    /// @notice Pay a listed payee. Reverts unless the payment fits the payee's limit, the
    ///         auto-approval limit, the category budget and the USDC floor.
    function pay(uint256 payeeId, address token, uint256 amount, bytes calldata record)
        external
        onlyAgent
        bounded(record)
        nonReentrant
    {
        Payee storage p = _payee(payeeId);
        if (!p.active) revert Inactive();
        if (amount == 0) revert BadParams();
        uint256 usd = usdValue(token, amount);
        if (usd > p.maxPayment) revert OverPayeeLimit(usd, p.maxPayment);
        if (usd > autoLimit) revert OverAutoLimit(usd, autoLimit);
        _charge(p.category, usd, true);
        uint256 before = cash();
        _send(p, token, amount);
        _checkFloor(before);
        _record(OP_PAY, payeeId, token, amount, usd, _b32(p.account), record);
    }

    /// @notice Make one of the owner's pre-written calls. It is charged its declared cost or the
    ///         USDC it actually took out of the treasury, whichever is more. Calls to a priced
    ///         token are refused: an allowance would let value leave later, unseen by the budget.
    function act(uint256 actionId, bytes calldata record) external onlyAgent bounded(record) nonReentrant {
        Action storage a = _action(actionId);
        if (!a.active) revert Inactive();
        _checkAction(a);
        uint256 before = cash();
        _call(a.target, 0, a.data);
        uint256 afterCash = cash();
        uint256 usd = before > afterCash ? before - afterCash : 0;
        if (usd < a.charge) usd = a.charge;
        if (usd > autoLimit) revert OverAutoLimit(usd, autoLimit);
        if (usd > 0) _charge(a.category, usd, true);
        _checkFloor(before);
        _record(OP_ACT, actionId, address(0), 0, usd, _actionHash(a), record);
    }

    /// @notice Record a decision that moves nothing: holding, deferring, waiting for revenue.
    ///         Allowed while frozen, so the agent can still explain itself.
    function note(bytes calldata record) external bounded(record) {
        if (msg.sender != agent) revert NotAgent();
        _record(OP_NOTE, 0, address(0), 0, 0, bytes32(0), record);
    }

    /// @notice Ask the owner for something the agent may not do alone. What it pays or calls is
    ///         fixed now: if the owner later changes that payee or action, the proposal lapses.
    /// @param op OP_PAY (listed payee `ref`), OP_PAY_TO (unlisted `account`) or OP_ACT (action `ref`)
    function propose(uint8 op, uint256 ref, address account, address token, uint256 amount, bytes calldata record)
        external
        onlyAgent
        bounded(record)
        returns (uint256 id)
    {
        (Proposal memory pr, uint256 usd) = _draft(op, ref, account, token, amount);
        pr.recordHash = keccak256(record);
        id = _proposals.length;
        _proposals.push(pr);
        _logProposal(id, pr, usd, record);
    }

    function _logProposal(uint256 id, Proposal memory pr, uint256 usd, bytes calldata record) internal {
        _record(OP_PROPOSE, id, pr.token, pr.amount, usd, keccak256(abi.encode(pr.op, uint256(pr.ref), pr.target)), record);
    }

    /// @dev Validate a proposal and fix what it is bound to.
    function _draft(uint8 op, uint256 ref, address account, address token, uint256 amount)
        internal
        view
        returns (Proposal memory pr, uint256 usd)
    {
        if (op == OP_PAY) {
            Payee storage p = _payee(ref);
            if (p.kind == Kind.Gateway || amount == 0) revert BadParams(); // Gateway payees: authorizeIntent
            usd = usdValue(token, amount);
            pr.target = _payeeHash(p);
            pr.ref = uint64(ref);
        } else if (op == OP_PAY_TO) {
            if (account == address(0) || account == address(this) || amount == 0) revert BadParams();
            usd = usdValue(token, amount);
            pr.target = _b32(account);
            pr.account = account;
        } else if (op == OP_ACT) {
            Action storage a = _action(ref);
            usd = a.charge;
            pr.target = _actionHash(a);
            pr.ref = uint64(ref);
            token = address(0);
            amount = 0;
        } else {
            revert BadParams();
        }
        if (amount > type(uint128).max) revert BadParams();
        pr.op = op;
        pr.status = Status.Pending;
        pr.createdAt = uint40(block.timestamp);
        pr.expiresAt = uint40(block.timestamp + proposalTtl);
        pr.token = token;
        pr.amount = uint128(amount);
        pr.proposer = msg.sender;
    }

    /// @notice The agent stops itself, e.g. when what it sees no longer makes sense to it.
    ///         Only the owner can unfreeze. Any Gateway intent it authorized lapses too.
    function freeze(bytes calldata record) external bounded(record) {
        if (msg.sender != agent) revert NotAgent();
        frozen = true;
        ++intentEpoch;
        _record(OP_FREEZE, 1, address(0), 0, 0, bytes32(0), record);
    }

    // ─────────────────────── agent: reserves ───────────────────────
    // Moving cash between the treasury and its own reserves spends nothing, so it is not charged to
    // a budget (Gateway fees are); the floor still applies to what stays on hand.

    /// @notice Move cash into the treasury's Circle Gateway balance (a unified USDC balance that
    ///         can later be spent on any Gateway chain, but only through `authorizeIntent`).
    function toGateway(uint256 amount, bytes calldata record) external onlyAgent bounded(record) nonReentrant {
        address w = gateway.wallet;
        if (w == address(0) || amount == 0) revert BadParams();
        uint256 before = cash();
        _approve(w, amount);
        IGatewayWallet(w).deposit(USDC, amount);
        _approve(w, 0);
        uint256 held = IGatewayWallet(w).totalBalance(USDC, address(this)); // includes any withdrawal in progress
        if (held > gateway.cap) revert OverGatewayCap(held, gateway.cap);
        _checkFloor(before);
        _record(OP_GATEWAY_IN, 0, USDC, amount, 0, _b32(w), record);
    }

    /// @notice Park cash in a listed vault so it earns while it waits.
    function toVault(uint256 vaultId, uint256 assets, bytes calldata record)
        external
        onlyAgent
        bounded(record)
        nonReentrant
    {
        Vault storage v = _vault(vaultId);
        if (!v.active) revert Inactive();
        if (assets == 0) revert BadParams();
        uint256 before = cash();
        _approve(v.vault, assets);
        IERC4626(v.vault).deposit(assets, address(this));
        _approve(v.vault, 0);
        uint256 held = IERC4626(v.vault).convertToAssets(IERC4626(v.vault).balanceOf(address(this)));
        if (held > v.cap) revert OverVaultCap(held, v.cap);
        _checkFloor(before);
        _record(OP_VAULT_IN, vaultId, USDC, assets, 0, _b32(v.vault), record);
    }

    /// @notice Take cash back from a vault. Allowed for inactive vaults, so money is never stuck.
    function fromVault(uint256 vaultId, uint256 assets, bytes calldata record)
        external
        onlyAgent
        bounded(record)
        nonReentrant
    {
        Vault storage v = _vault(vaultId);
        if (assets == 0) revert BadParams();
        IERC4626(v.vault).withdraw(assets, address(this), address(this));
        _record(OP_VAULT_OUT, vaultId, USDC, assets, 0, _b32(v.vault), record);
    }

    /// @notice Authorize one Circle Gateway burn intent against the treasury's Gateway balance.
    ///         The intent is checked field by field: it must spend this treasury's balance on this
    ///         chain, and either come back to this treasury (`payeeId == RECALL`, its fee charged
    ///         to the Gateway fee budget) or go to a listed Gateway payee, within that payee's
    ///         limits and budget like any other payment. `isValidSignature` then accepts its
    ///         digest for `INTENT_SUBMIT_BLOCKS`, and only until the owner applies any brake.
    /// @return digest the EIP-712 digest to submit to Gateway with `contractSigner: true`
    function authorizeIntent(BurnIntent calldata bi, uint256 payeeId, bytes calldata record)
        external
        onlyAgent
        bounded(record)
        nonReentrant
        returns (bytes32 digest)
    {
        GatewayConfig memory g = gateway;
        TransferSpec calldata t = bi.spec;
        _checkSource(bi, g);
        if (t.hookData.length != 0) revert BadIntent(5);
        if (t.value == 0) revert BadIntent(6);
        // Gateway refuses intents that could still be burned after a trustless withdrawal could
        // complete; anything much longer only keeps an authorization alive for no reason.
        uint256 delay = IGatewayWallet(g.wallet).withdrawalDelay();
        if (
            bi.maxBlockHeight < block.number + delay + INTENT_SUBMIT_BLOCKS
                || bi.maxBlockHeight > block.number + delay + g.maxIntentBlocks
        ) {
            revert BadIntent(7);
        }

        uint256 usd;
        if (payeeId == RECALL) {
            if (
                t.destinationDomain != g.domain || t.destinationContract != _b32(g.minter)
                    || t.destinationToken != _b32(USDC) || t.destinationRecipient != _b32(address(this))
            ) revert BadIntent(8);
            if (bi.maxFee > g.recallMaxFee) revert BadIntent(9);
            usd = bi.maxFee;
            if (usd > 0) _charge(g.feeCategory, usd, true);
        } else {
            Payee storage p = _payee(payeeId);
            if (!p.active) revert Inactive();
            if (p.kind != Kind.Gateway) revert BadIntent(10);
            if (
                t.destinationDomain != p.domain || t.destinationContract != _b32(p.via)
                    || t.destinationToken != _b32(p.remoteToken) || t.destinationRecipient != _b32(p.account)
            ) revert BadIntent(11);
            if (bi.maxFee > p.maxFee) revert BadIntent(9);
            usd = t.value + bi.maxFee; // USDC token units = micro-USD; charge the worst case
            if (usd > p.maxPayment) revert OverPayeeLimit(usd, p.maxPayment);
            if (usd > autoLimit) revert OverAutoLimit(usd, autoLimit);
            _charge(p.category, usd, true);
        }
        digest = _authorize(bi, false);
        _record(OP_INTENT, payeeId, USDC, t.value, usd, digest, record);
    }

    // ───────────────────────── owner: review ─────────────────────────

    /// @notice Carry out a proposal. The owner's approval replaces the agent's limits, but the
    ///         spend still counts against its category so the agent sees the budget used. A
    ///         proposal lapses if it expired, if its payee or action changed since, or if the
    ///         agent key that proposed it has been replaced.
    function approveProposal(uint256 id, bytes calldata note_) external onlyOwner nonReentrant {
        Proposal storage pr = _proposal(id);
        if (pr.status != Status.Pending) revert NotPending();
        if (block.timestamp > pr.expiresAt) revert Expired();
        if (pr.proposer != agent) revert ProposalChanged();
        pr.status = Status.Approved;
        uint256 usd;
        bytes32 detail;
        if (pr.op == OP_PAY) {
            Payee storage p = _payee(pr.ref);
            if (!p.active || _payeeHash(p) != pr.target) revert ProposalChanged();
            usd = usdValue(pr.token, pr.amount);
            _charge(p.category, usd, false);
            _send(p, pr.token, pr.amount);
            detail = _b32(p.account);
        } else if (pr.op == OP_PAY_TO) {
            usd = usdValue(pr.token, pr.amount);
            _transfer(pr.token, pr.account, pr.amount);
            detail = _b32(pr.account);
        } else {
            Action storage a = _action(pr.ref);
            if (!a.active || _actionHash(a) != pr.target) revert ProposalChanged();
            _checkAction(a);
            usd = a.charge;
            if (usd > 0) _charge(a.category, usd, false);
            _call(a.target, 0, a.data);
            detail = pr.target;
        }
        _record(OP_APPROVE, id, pr.token, pr.amount, usd, detail, note_);
    }

    function rejectProposal(uint256 id, bytes calldata note_) external onlyOwner {
        Proposal storage pr = _proposal(id);
        if (pr.status != Status.Pending) revert NotPending();
        pr.status = Status.Rejected;
        _record(OP_REJECT, id, pr.token, pr.amount, 0, pr.target, note_);
    }

    // ───────────────────────── owner: policy ─────────────────────────
    // Every change is written into the record chain with its exact calldata, so the rules the
    // agent worked under at any moment can be rebuilt from the log.

    function setAgent(address agent_) external onlyOwner {
        agent = agent_;
        ++intentEpoch;
        _policy();
    }

    function setFrozen(bool frozen_) external onlyOwner {
        frozen = frozen_;
        if (frozen_) ++intentEpoch;
        _policy();
    }

    function setLimits(uint128 autoLimit_, uint128 floor_, uint32 proposalTtl_) external onlyOwner {
        if (proposalTtl_ < 1 hours) revert BadParams();
        autoLimit = autoLimit_;
        floor = floor_;
        proposalTtl = proposalTtl_;
        _policy();
    }

    function setUsdRate(address token, uint256 rate) external onlyOwner {
        if (token == USDC || token == address(0)) revert BadParams();
        usdRate[token] = rate;
        _policy();
    }

    /// @param id an existing category to change, or `categoryCount()` to add one
    function setCategory(uint256 id, string calldata name, uint128 budget, uint32 period) external onlyOwner {
        if (period < MIN_PERIOD) revert BadParams();
        if (id == _categories.length) {
            _categories.push(Category(budget, 0, period, uint40(block.timestamp), name));
        } else {
            Category storage c = _category(id);
            c.name = name;
            c.budget = budget;
            if (c.period != period) {
                // a new period starts a new window, but what was spent in the current one carries
                // over: changing the period must never hand the agent a fresh budget
                (, uint256 used) = _window(c);
                c.period = period;
                c.windowStart = uint40(block.timestamp);
                c.spent = uint128(used);
            }
        }
        _policy();
    }

    /// @param id an existing payee to change, or `payeeCount()` to add one
    function setPayee(uint256 id, Payee calldata p) external onlyOwner {
        if (p.account == address(0) || p.account == address(this)) revert BadParams();
        _category(p.category);
        if (p.kind == Kind.Gateway) {
            // the minter and token live on the destination chain, so they cannot be checked here
            if (p.via == address(0) || p.remoteToken == address(0)) revert BadParams();
        } else if (p.kind != Kind.Transfer && (p.via == address(0) || p.via.code.length == 0)) {
            revert BadParams();
        }
        if (id == _payees.length) {
            _payees.push(p);
        } else {
            _payee(id);
            _payees[id] = p;
        }
        ++intentEpoch; // an intent authorized for the old payee must not outlive the change
        _policy();
    }

    /// @param id an existing action to change, or `actionCount()` to add one
    function setAction(uint256 id, Action calldata a) external onlyOwner {
        if (a.target == address(this) || a.target.code.length == 0) revert BadParams();
        _category(a.category);
        if (id == _actions.length) {
            _actions.push(a);
        } else {
            _action(id);
            _actions[id] = a;
        }
        _policy();
    }

    function setGateway(GatewayConfig calldata g) external onlyOwner {
        if (g.wallet != address(0)) {
            if (g.wallet.code.length == 0 || g.minter.code.length == 0) revert BadParams();
            _category(g.feeCategory);
        }
        gateway = g;
        ++intentEpoch;
        ++ownerIntentEpoch;
        _policy();
    }

    /// @param id an existing vault to change, or `vaultCount()` to add one
    function setVault(uint256 id, Vault calldata v) external onlyOwner {
        if (v.vault.code.length == 0 || IERC4626(v.vault).asset() != USDC) revert BadParams();
        if (id == _vaults.length) {
            _vaults.push(v);
        } else {
            _vault(id);
            _vaults[id] = v;
        }
        _policy();
    }

    /// @notice The owner may authorize a Gateway intent by hand, e.g. to recover the Gateway
    ///         balance while the agent is frozen or gone. It must still be a burn intent spending
    ///         this treasury's own Gateway balance: the contract computes the digest itself, so an
    ///         owner can never be talked into blessing an arbitrary hash (which other protocols
    ///         would accept as this treasury's signature). It lapses only by time, `revokeIntent`
    ///         or `setGateway`, never by the agent's brakes.
    function ownerAuthorizeIntent(BurnIntent calldata bi) external onlyOwner returns (bytes32 digest) {
        _checkSource(bi, gateway);
        digest = _authorize(bi, true);
        _policy();
    }

    function revokeIntent(bytes32 digest) external onlyOwner {
        delete intentAuth[digest];
        _policy();
    }

    /// @notice The owner can always move funds or make any call; the limits bind only the agent.
    function ownerCall(address target, uint256 value, bytes calldata data)
        external
        onlyOwner
        nonReentrant
        returns (bytes memory ret)
    {
        if (target == address(this)) revert BadParams();
        ret = _call(target, value, data);
        _policy();
    }

    function transferOwnership(address to) external onlyOwner {
        pendingOwner = to;
        emit OwnershipTransferStarted(owner, to);
        _policy();
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        owner = msg.sender;
        pendingOwner = address(0);
        _policy();
    }

    // ───────────────────────────── views ─────────────────────────────

    /// @notice micro-USD value of `amount` units of `token`, rounded up. Reverts for tokens the
    ///         owner has not priced.
    function usdValue(address token, uint256 amount) public view returns (uint256) {
        uint256 rate = usdRate[token];
        if (rate == 0) revert TokenNotAccepted();
        return (amount * rate + 1e6 - 1) / 1e6;
    }

    /// @notice A category as the agent sees it right now, with an elapsed window already rolled.
    function budgetOf(uint256 id)
        external
        view
        returns (string memory name, uint256 budget, uint256 spent, uint256 remaining, uint256 windowEnd, uint256 period)
    {
        Category storage c = _category(id);
        (uint256 start, uint256 used) = _window(c);
        remaining = used >= c.budget ? 0 : c.budget - used;
        return (c.name, c.budget, used, remaining, start + c.period, c.period);
    }

    function categoryCount() external view returns (uint256) {
        return _categories.length;
    }

    function payeeCount() external view returns (uint256) {
        return _payees.length;
    }

    function actionCount() external view returns (uint256) {
        return _actions.length;
    }

    function proposalCount() external view returns (uint256) {
        return _proposals.length;
    }

    function vaultCount() external view returns (uint256) {
        return _vaults.length;
    }

    function getPayee(uint256 id) external view returns (Payee memory) {
        return _payee(id);
    }

    function getAction(uint256 id) external view returns (Action memory) {
        return _action(id);
    }

    function getProposal(uint256 id) external view returns (Proposal memory) {
        return _proposal(id);
    }

    function getVault(uint256 id) external view returns (Vault memory) {
        return _vault(id);
    }

    /// @notice ERC-1271: the treasury "signs" exactly the Gateway intents it has authorized, while
    ///         their window is open and no brake has been applied since.
    function isValidSignature(bytes32 hash, bytes calldata) external view returns (bytes4) {
        IntentAuth memory a = intentAuth[hash];
        bool live = a.byOwner ? a.epoch == ownerIntentEpoch : (!frozen && a.epoch == intentEpoch);
        return live && a.submitBy != 0 && block.number <= a.submitBy ? ERC1271_OK : bytes4(0xffffffff);
    }

    /// @notice EIP-712 digest of a Gateway burn intent, as Gateway computes it.
    function intentDigest(BurnIntent calldata bi) public pure returns (bytes32) {
        TransferSpec calldata t = bi.spec;
        bytes32 specHash = keccak256(
            bytes.concat(
                abi.encode(
                    TRANSFER_SPEC_TYPEHASH,
                    t.version,
                    t.sourceDomain,
                    t.destinationDomain,
                    t.sourceContract,
                    t.destinationContract,
                    t.sourceToken
                ),
                abi.encode(
                    t.destinationToken,
                    t.sourceDepositor,
                    t.destinationRecipient,
                    t.sourceSigner,
                    t.destinationCaller,
                    t.value,
                    t.salt,
                    keccak256(t.hookData)
                )
            )
        );
        bytes32 structHash = keccak256(abi.encode(BURN_INTENT_TYPEHASH, bi.maxBlockHeight, bi.maxFee, specHash));
        return keccak256(abi.encodePacked("\x19\x01", GATEWAY_DOMAIN_SEPARATOR, structHash));
    }

    /// @notice USDC on hand in token units (6 decimals).
    function cash() public view returns (uint256) {
        return address(this).balance / NATIVE_PER_UNIT;
    }

    // ─────────────────────────── internals ───────────────────────────

    function _window(Category storage c) internal view returns (uint256 start, uint256 used) {
        start = c.windowStart;
        used = c.spent;
        if (block.timestamp >= start + c.period) {
            start = block.timestamp - (block.timestamp - start) % c.period;
            used = 0;
        }
    }

    function _charge(uint16 id, uint256 usd, bool enforce) internal {
        Category storage c = _category(id);
        (uint256 start, uint256 used) = _window(c);
        if (enforce && used + usd > c.budget) revert OverBudget(id, usd, used >= c.budget ? 0 : c.budget - used);
        c.windowStart = uint40(start);
        uint256 total = used + usd;
        c.spent = total > type(uint128).max ? type(uint128).max : uint128(total);
    }

    function _send(Payee storage p, address token, uint256 amount) internal {
        if (p.kind == Kind.Transfer) {
            _transfer(token, p.account, amount);
        } else if (p.kind == Kind.TockGas) {
            if (token != USDC) revert TokenNotAccepted();
            ITock(p.via).depositFor{value: amount * NATIVE_PER_UNIT}(p.account);
        } else if (p.kind == Kind.Cctp) {
            if (token != USDC) revert TokenNotAccepted();
            _approve(p.via, amount);
            ITokenMessengerV2(p.via).depositForBurn(amount, p.domain, _b32(p.account), USDC, bytes32(0), p.maxFee, 2000);
            _approve(p.via, 0);
        } else if (p.kind == Kind.GatewayDeposit) {
            if (token != USDC) revert TokenNotAccepted();
            _approve(p.via, amount);
            IGatewayWallet(p.via).depositFor(USDC, p.account, amount);
            _approve(p.via, 0);
        } else {
            revert BadParams(); // Gateway payees are paid through `authorizeIntent`
        }
    }

    /// @dev The source side of a burn intent must be this treasury's balance in this chain's
    ///      GatewayWallet, in USDC.
    function _checkSource(BurnIntent calldata bi, GatewayConfig memory g) internal view {
        TransferSpec calldata t = bi.spec;
        if (g.wallet == address(0)) revert BadParams();
        if (t.version != 1) revert BadIntent(0);
        if (t.sourceDomain != g.domain) revert BadIntent(1);
        if (t.sourceContract != _b32(g.wallet)) revert BadIntent(2);
        if (t.sourceToken != _b32(USDC)) revert BadIntent(3);
        if (t.sourceDepositor != _b32(address(this)) || t.sourceSigner != _b32(address(this))) {
            revert BadIntent(4);
        }
    }

    function _authorize(BurnIntent calldata bi, bool byOwner) internal returns (bytes32 digest) {
        digest = intentDigest(bi);
        intentAuth[digest] =
            IntentAuth(byOwner ? ownerIntentEpoch : intentEpoch, uint64(block.number) + INTENT_SUBMIT_BLOCKS, byOwner);
    }

    /// @dev What a proposal to pay this payee is bound to: where and how the money would go.
    function _payeeHash(Payee storage p) internal view returns (bytes32) {
        return keccak256(abi.encode(p.account, p.via, p.domain, p.kind, p.category, p.remoteToken, p.maxFee));
    }

    /// @dev An action's value must be visible to the budget, which measures only USDC on hand.
    ///      So no action may call a priced token, a reserve (vault or Gateway), or any function that
    ///      grants an allowance or moves tokens, on any target: value moved that way would leave
    ///      unseen, now or later. Such things are the owner's to do with `ownerCall`.
    function _checkAction(Action storage a) internal view {
        address t = a.target;
        if (usdRate[t] != 0 || t == gateway.wallet) revert BadParams();
        for (uint256 i; i < _vaults.length; ++i) {
            if (_vaults[i].vault == t) revert BadParams();
        }
        if (a.data.length >= 4) {
            bytes4 sel = bytes4(a.data);
            if (
                sel == IERC20.approve.selector || sel == IERC20.transfer.selector || sel == 0x23b872dd // transferFrom
                    || sel == 0x39509351 // increaseAllowance
                    || sel == 0xd505accf // permit (EIP-2612)
                    || sel == 0xa22cb465 // setApprovalForAll
            ) revert BadParams();
        }
    }

    function _actionHash(Action storage a) internal view returns (bytes32) {
        return keccak256(abi.encode(a.target, a.category, a.data));
    }

    function _approve(address spender, uint256 amount) internal {
        if (!IERC20(USDC).approve(spender, amount)) revert CallFailed("");
    }

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _transfer(address token, address to, uint256 amount) internal {
        if (usdRate[token] == 0) revert TokenNotAccepted();
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok || (ret.length > 0 && !abi.decode(ret, (bool)))) revert CallFailed(ret);
    }

    function _call(address target, uint256 value, bytes memory data) internal returns (bytes memory ret) {
        bool ok;
        (ok, ret) = target.call{value: value}(data);
        if (!ok) revert CallFailed(ret);
    }

    /// @dev The floor binds only when the operation took cash out (an EURC payment does not).
    function _checkFloor(uint256 before) internal view {
        uint256 c = cash();
        if (c < before && c < floor) revert BelowFloor(c, floor);
    }

    function _policy() internal {
        _record(OP_POLICY, 0, address(0), 0, 0, bytes32(0), msg.data);
    }

    /// @dev `detail` binds what the record is about (the recipient, the intent digest, the
    ///      proposal's target) into the hash chain, so the agent's own text cannot misstate it.
    function _record(
        uint8 op,
        uint256 ref,
        address token,
        uint256 amount,
        uint256 usd,
        bytes32 detail,
        bytes calldata record
    ) internal {
        uint64 s = seq++;
        bytes32 h = keccak256(abi.encode(head, s, op, msg.sender, ref, token, amount, usd, detail, keccak256(record)));
        head = h;
        uint64 prev = lastBlock;
        lastBlock = uint64(block.number);
        emit Recorded(s, op, ref, msg.sender, token, amount, usd, detail, h, prev, record);
    }

    function _category(uint256 id) internal view returns (Category storage) {
        if (id >= _categories.length) revert UnknownId();
        return _categories[id];
    }

    function _payee(uint256 id) internal view returns (Payee storage) {
        if (id >= _payees.length) revert UnknownId();
        return _payees[id];
    }

    function _action(uint256 id) internal view returns (Action storage) {
        if (id >= _actions.length) revert UnknownId();
        return _actions[id];
    }

    function _vault(uint256 id) internal view returns (Vault storage) {
        if (id >= _vaults.length) revert UnknownId();
        return _vaults[id];
    }

    function _proposal(uint256 id) internal view returns (Proposal storage) {
        if (id >= _proposals.length) revert UnknownId();
        return _proposals[id];
    }
}
