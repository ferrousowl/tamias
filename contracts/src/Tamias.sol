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
        Cctp // USDC burned through CCTP `via` and minted to `account` on domain `domain`
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
        uint128 maxFee; // CCTP: most the agent may let the bridge charge, token units
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

    uint256 public constant MAX_RECORD = 8192;
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

    // ─────────────────────────── modifiers ───────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyAgent() {
        if (msg.sender != agent) revert NotAgent();
        if (frozen) revert Frozen();
        _;
    }

    /// @dev Agent records are bounded so a log entry always stays cheap to store and to read.
    modifier bounded(bytes calldata record) {
        if (record.length > MAX_RECORD) revert RecordTooLong();
        _;
    }

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
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
        _send(p, token, amount);
        _checkFloor();
        _record(OP_PAY, payeeId, token, amount, usd, record);
    }

    /// @notice Make one of the owner's pre-written calls.
    function act(uint256 actionId, bytes calldata record) external onlyAgent bounded(record) nonReentrant {
        Action storage a = _action(actionId);
        if (!a.active) revert Inactive();
        if (a.charge > autoLimit) revert OverAutoLimit(a.charge, autoLimit);
        if (a.charge > 0) _charge(a.category, a.charge, true);
        _call(a.target, 0, a.data);
        _checkFloor();
        _record(OP_ACT, actionId, address(0), 0, a.charge, record);
    }

    /// @notice Record a decision that moves nothing: holding, deferring, waiting for revenue.
    ///         Allowed while frozen, so the agent can still explain itself.
    function note(bytes calldata record) external bounded(record) {
        if (msg.sender != agent) revert NotAgent();
        _record(OP_NOTE, 0, address(0), 0, 0, record);
    }

    /// @notice Ask the owner for something the agent may not do alone.
    /// @param op OP_PAY (listed payee `ref`), OP_PAY_TO (unlisted `account`) or OP_ACT (action `ref`)
    function propose(uint8 op, uint256 ref, address account, address token, uint256 amount, bytes calldata record)
        external
        onlyAgent
        bounded(record)
        returns (uint256 id)
    {
        uint256 usd;
        if (op == OP_PAY) {
            _payee(ref);
            if (amount == 0) revert BadParams();
            usd = usdValue(token, amount);
        } else if (op == OP_PAY_TO) {
            if (account == address(0) || account == address(this) || amount == 0) revert BadParams();
            usd = usdValue(token, amount);
        } else if (op == OP_ACT) {
            usd = _action(ref).charge;
            token = address(0);
            amount = 0;
        } else {
            revert BadParams();
        }
        if (amount > type(uint128).max) revert BadParams();
        id = _proposals.length;
        _proposals.push(
            Proposal({
                op: op,
                status: Status.Pending,
                createdAt: uint40(block.timestamp),
                ref: uint64(ref),
                account: op == OP_PAY_TO ? account : address(0),
                token: token,
                amount: uint128(amount),
                recordHash: keccak256(record)
            })
        );
        _record(OP_PROPOSE, id, token, amount, usd, record);
    }

    /// @notice The agent stops itself, e.g. when what it sees no longer makes sense to it.
    ///         Only the owner can unfreeze.
    function freeze(bytes calldata record) external bounded(record) {
        if (msg.sender != agent) revert NotAgent();
        frozen = true;
        _record(OP_FREEZE, 1, address(0), 0, 0, record);
    }

    // ───────────────────────── owner: review ─────────────────────────

    /// @notice Carry out a proposal. The owner's approval replaces the agent's limits, but the
    ///         spend still counts against its category so the agent sees the budget used.
    function approveProposal(uint256 id, bytes calldata note_) external onlyOwner nonReentrant {
        Proposal storage pr = _proposal(id);
        if (pr.status != Status.Pending) revert NotPending();
        if (block.timestamp > uint256(pr.createdAt) + proposalTtl) revert Expired();
        pr.status = Status.Approved;
        uint256 usd;
        if (pr.op == OP_PAY) {
            Payee storage p = _payee(pr.ref);
            usd = usdValue(pr.token, pr.amount);
            _charge(p.category, usd, false);
            _send(p, pr.token, pr.amount);
        } else if (pr.op == OP_PAY_TO) {
            usd = usdValue(pr.token, pr.amount);
            _transfer(pr.token, pr.account, pr.amount);
        } else {
            Action storage a = _action(pr.ref);
            usd = a.charge;
            if (usd > 0) _charge(a.category, usd, false);
            _call(a.target, 0, a.data);
        }
        _record(OP_APPROVE, id, pr.token, pr.amount, usd, note_);
    }

    function rejectProposal(uint256 id, bytes calldata note_) external onlyOwner {
        Proposal storage pr = _proposal(id);
        if (pr.status != Status.Pending) revert NotPending();
        pr.status = Status.Rejected;
        _record(OP_REJECT, id, pr.token, pr.amount, 0, note_);
    }

    // ───────────────────────── owner: policy ─────────────────────────
    // Every change is written into the record chain with its exact calldata, so the rules the
    // agent worked under at any moment can be rebuilt from the log.

    function setAgent(address agent_) external onlyOwner {
        agent = agent_;
        _policy();
    }

    function setFrozen(bool frozen_) external onlyOwner {
        frozen = frozen_;
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
                c.period = period;
                c.windowStart = uint40(block.timestamp);
                c.spent = 0;
            }
        }
        _policy();
    }

    /// @param id an existing payee to change, or `payeeCount()` to add one
    function setPayee(uint256 id, Payee calldata p) external onlyOwner {
        if (p.account == address(0) || p.account == address(this)) revert BadParams();
        _category(p.category);
        if (p.kind != Kind.Transfer && (p.via == address(0) || p.via.code.length == 0)) revert BadParams();
        if (id == _payees.length) _payees.push(p);
        else {
            _payee(id);
            _payees[id] = p;
        }
        _policy();
    }

    /// @param id an existing action to change, or `actionCount()` to add one
    function setAction(uint256 id, Action calldata a) external onlyOwner {
        if (a.target == address(this) || a.target.code.length == 0) revert BadParams();
        _category(a.category);
        if (id == _actions.length) _actions.push(a);
        else {
            _action(id);
            _actions[id] = a;
        }
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
        returns (string memory name, uint256 budget, uint256 spent, uint256 remaining, uint256 windowEnd)
    {
        Category storage c = _category(id);
        (uint256 start, uint256 used) = _window(c);
        remaining = used >= c.budget ? 0 : c.budget - used;
        return (c.name, c.budget, used, remaining, start + c.period);
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

    function getCategory(uint256 id) external view returns (Category memory) {
        return _category(id);
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
        } else {
            if (token != USDC) revert TokenNotAccepted();
            if (!IERC20(USDC).approve(p.via, amount)) revert CallFailed("");
            ITokenMessengerV2(p.via).depositForBurn(
                amount, p.domain, bytes32(uint256(uint160(p.account))), USDC, bytes32(0), p.maxFee, 2000
            );
            IERC20(USDC).approve(p.via, 0);
        }
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

    function _checkFloor() internal view {
        uint256 c = cash();
        if (c < floor) revert BelowFloor(c, floor);
    }

    function _policy() internal {
        _record(OP_POLICY, 0, address(0), 0, 0, msg.data);
    }

    function _record(uint8 op, uint256 ref, address token, uint256 amount, uint256 usd, bytes calldata record)
        internal
    {
        uint64 s = seq++;
        bytes32 h = keccak256(abi.encode(head, s, op, msg.sender, ref, token, amount, usd, keccak256(record)));
        head = h;
        uint64 prev = lastBlock;
        lastBlock = uint64(block.number);
        emit Recorded(s, op, ref, msg.sender, token, amount, usd, h, prev, record);
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

    function _proposal(uint256 id) internal view returns (Proposal storage) {
        if (id >= _proposals.length) revert UnknownId();
        return _proposals[id];
    }
}
