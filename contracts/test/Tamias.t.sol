// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {Tamias, IERC20} from "../src/Tamias.sol";

interface ITockView {
    function balanceOf(address) external view returns (uint256);
}

contract Counter {
    uint256 public count;
    address public lastCaller;

    function bump() external {
        ++count;
        lastCaller = msg.sender;
    }

    function fail() external pure {
        revert("nope");
    }
}

/// @dev An agent that is also a contract and tries to get back in while one of its actions runs.
contract SneakyAgent {
    Tamias public t;
    bool public reentered;

    function setTreasury(Tamias t_) external {
        t = t_;
    }

    function doAct(uint256 id) external {
        t.act(id, "act");
    }

    /// @dev The action's target: called by the treasury in the middle of `act`.
    function hook() external {
        t.pay(0, t.USDC(), 1, "inner");
        reentered = true;
    }
}

/// @dev Runs against a fork of Arc mainnet (foundry.toml sets `network = "arc"`), where the
///      native balance is USDC with 18 decimals and the ERC-20 view of it has 6.
contract TamiasTest is Test {
    address constant USDC = 0x3600000000000000000000000000000000000000;
    address constant EURC = 0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1;
    address constant TOCK = 0x3d5414F772Ce5667b13DfB9339a03072fd904F35; // live Tock on Arc mainnet

    Tamias t;
    Counter counter;
    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address bob = makeAddr("bob"); // a contractor
    address gasOwner = makeAddr("gasOwner"); // whose Tock gas balance the treasury tops up
    address stranger = makeAddr("stranger");

    uint8 constant OP_PAY = 1;
    uint8 constant OP_ACT = 2;
    uint8 constant OP_PAY_TO = 8;
    uint16 constant INFRA = 0;
    uint16 constant CONTRACTORS = 1;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ARC_RPC", string("https://rpc.mainnet.arc.io")));
        vm.fee(20 gwei);
        t = new Tamias(owner, agent, 1e6, 0.5e6); // $1 auto-limit, $0.50 floor
        counter = new Counter();
        vm.deal(address(t), 10 ether); // 10 USDC
        vm.deal(agent, 1 ether);

        vm.startPrank(owner);
        t.setCategory(0, "infra", 2e6, 1 days);
        t.setCategory(1, "contractors", 5e6, 7 days);
        t.setPayee(0, _payee(bob, address(0), Tamias.Kind.Transfer, CONTRACTORS, 3e6, "bob"));
        t.setPayee(1, _payee(gasOwner, TOCK, Tamias.Kind.TockGas, INFRA, 1e6, "tock gas"));
        t.setAction(0, _action(address(counter), abi.encodeCall(Counter.bump, ()), INFRA, 0.1e6, "bump"));
        vm.stopPrank();
    }

    function _payee(address account, address via, Tamias.Kind kind, uint16 cat, uint128 max, string memory label)
        internal
        pure
        returns (Tamias.Payee memory p)
    {
        p.account = account;
        p.via = via;
        p.kind = kind;
        p.category = cat;
        p.active = true;
        p.maxPayment = max;
        p.label = label;
    }

    function _action(address target, bytes memory data, uint16 cat, uint128 charge, string memory label)
        internal
        pure
        returns (Tamias.Action memory a)
    {
        a.target = target;
        a.data = data;
        a.category = cat;
        a.active = true;
        a.charge = charge;
        a.label = label;
    }

    function _remaining(uint256 cat) internal view returns (uint256 r) {
        (,,, r,,) = t.budgetOf(cat);
    }

    // ── paying ──

    function test_pay_transfersUsdcAndRecords() public {
        uint256 before = t.cash();
        vm.prank(agent);
        t.pay(0, USDC, 0.5e6, "pay bob for the first milestone");
        assertEq(IERC20(USDC).balanceOf(bob), 0.5e6);
        assertEq(bob.balance, 0.5 ether, "the ERC-20 view and the native balance are one");
        assertEq(t.cash(), before - 0.5e6);
        assertEq(_remaining(CONTRACTORS), 4.5e6);
    }

    function test_pay_eurcCountsAtTheOwnersRate() public {
        deal(EURC, address(t), 10e6);
        vm.prank(agent);
        vm.expectRevert(Tamias.TokenNotAccepted.selector);
        t.pay(0, EURC, 0.5e6, "");

        vm.prank(owner);
        t.setUsdRate(EURC, 1.17e6);
        vm.prank(agent);
        t.pay(0, EURC, 0.5e6, "invoice in euros");
        assertEq(IERC20(EURC).balanceOf(bob), 0.5e6);
        assertEq(_remaining(CONTRACTORS), 5e6 - 0.585e6);

        // 0.9 EURC is $1.053: over the $1 auto-limit although under 1 token
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Tamias.OverAutoLimit.selector, 1.053e6, 1e6));
        t.pay(0, EURC, 0.9e6, "");
    }

    function test_pay_tockGasDepositsForTheBeneficiary() public {
        uint256 before = ITockView(TOCK).balanceOf(gasOwner);
        vm.prank(agent);
        t.pay(1, USDC, 0.75e6, "gas runway down to 2 days");
        assertEq(ITockView(TOCK).balanceOf(gasOwner) - before, 0.75 ether);
        assertEq(t.cash(), 10e6 - 0.75e6);

        deal(EURC, address(t), 1e6);
        vm.prank(owner);
        t.setUsdRate(EURC, 1.17e6);
        vm.prank(agent);
        vm.expectRevert(Tamias.TokenNotAccepted.selector);
        t.pay(1, EURC, 0.1e6, "");
    }

    function test_pay_onlyTheAgent() public {
        vm.prank(stranger);
        vm.expectRevert(Tamias.NotAgent.selector);
        t.pay(0, USDC, 1, "");
        vm.prank(owner);
        vm.expectRevert(Tamias.NotAgent.selector);
        t.pay(0, USDC, 1, "");
    }

    function test_pay_limits() public {
        vm.startPrank(agent);
        vm.expectRevert(Tamias.UnknownId.selector);
        t.pay(9, USDC, 1, "");
        vm.expectRevert(Tamias.BadParams.selector);
        t.pay(0, USDC, 0, "");
        vm.expectRevert(abi.encodeWithSelector(Tamias.OverAutoLimit.selector, 1.5e6, 1e6));
        t.pay(0, USDC, 1.5e6, "");
        vm.expectRevert(abi.encodeWithSelector(Tamias.OverPayeeLimit.selector, 1.5e6, 1e6));
        t.pay(1, USDC, 1.5e6, "");
        vm.expectRevert(Tamias.RecordTooLong.selector);
        t.pay(0, USDC, 1, new bytes(8193));
        vm.stopPrank();

        vm.prank(owner);
        t.setPayee(0, _payee(bob, address(0), Tamias.Kind.Transfer, CONTRACTORS, 3e6, "bob (paused)"));
        Tamias.Payee memory p = t.getPayee(0);
        p.active = false;
        vm.prank(owner);
        t.setPayee(0, p);
        vm.prank(agent);
        vm.expectRevert(Tamias.Inactive.selector);
        t.pay(0, USDC, 1, "");
    }

    function test_pay_budgetPerWindow() public {
        vm.startPrank(agent);
        t.pay(1, USDC, 1e6, "a");
        t.pay(1, USDC, 0.9e6, "b");
        vm.expectRevert(abi.encodeWithSelector(Tamias.OverBudget.selector, INFRA, 0.2e6, 0.1e6));
        t.pay(1, USDC, 0.2e6, "c");
        vm.stopPrank();

        // the window is aligned to its start: 1.5 days later we are 12 h into the second window
        uint256 start = block.timestamp;
        vm.warp(start + 1.5 days);
        (,, uint256 spent, uint256 remaining, uint256 windowEnd,) = t.budgetOf(INFRA);
        assertEq(spent, 0);
        assertEq(remaining, 2e6);
        assertEq(windowEnd, start + 2 days);
        vm.prank(agent);
        t.pay(1, USDC, 0.2e6, "c");
        (,,,, uint256 end, uint256 per) = t.budgetOf(INFRA);
        assertEq(end - per, start + 1 days);
    }

    function test_pay_neverBelowTheFloor() public {
        vm.deal(address(t), 1.2 ether);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Tamias.BelowFloor.selector, 0.4e6, 0.5e6));
        t.pay(0, USDC, 0.8e6, "");
        vm.prank(agent);
        t.pay(0, USDC, 0.7e6, "");
        assertEq(t.cash(), 0.5e6);
    }

    // ── actions ──

    function test_act_runsTheOwnersExactCall() public {
        vm.prank(agent);
        t.act(0, "settle now");
        assertEq(counter.count(), 1);
        assertEq(counter.lastCaller(), address(t));
        assertEq(_remaining(INFRA), 2e6 - 0.1e6);
    }

    function test_act_failuresRevert() public {
        vm.startPrank(owner);
        t.setAction(1, _action(address(counter), abi.encodeCall(Counter.fail, ()), INFRA, 0, "fail"));
        t.setAction(2, _action(address(counter), abi.encodeCall(Counter.bump, ()), INFRA, 1.5e6, "dear"));
        vm.stopPrank();
        vm.startPrank(agent);
        vm.expectRevert(abi.encodeWithSelector(Tamias.CallFailed.selector, abi.encodeWithSignature("Error(string)", "nope")));
        t.act(1, "");
        vm.expectRevert(abi.encodeWithSelector(Tamias.OverAutoLimit.selector, 1.5e6, 1e6));
        t.act(2, "");
        vm.expectRevert(Tamias.UnknownId.selector);
        t.act(3, "");
        vm.stopPrank();
    }

    function test_act_cannotBeReentered() public {
        SneakyAgent s = new SneakyAgent();
        s.setTreasury(t);
        vm.startPrank(owner);
        t.setAgent(address(s));
        t.setAction(1, _action(address(s), abi.encodeCall(SneakyAgent.hook, ()), INFRA, 0, "hook"));
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(Tamias.CallFailed.selector, abi.encodeWithSelector(Tamias.Reentrancy.selector)));
        s.doAct(1);
        assertFalse(s.reentered());
    }

    // ── freezing ──

    function test_freeze_stopsSpendingButNotExplaining() public {
        vm.prank(agent);
        t.freeze("balances do not reconcile; stopping until a human looks");
        assertTrue(t.frozen());
        vm.startPrank(agent);
        vm.expectRevert(Tamias.Frozen.selector);
        t.pay(0, USDC, 1, "");
        vm.expectRevert(Tamias.Frozen.selector);
        t.act(0, "");
        vm.expectRevert(Tamias.Frozen.selector);
        t.propose(1, 0, address(0), USDC, 1, "");
        t.note("still frozen, waiting");
        vm.stopPrank();

        vm.prank(stranger);
        vm.expectRevert(Tamias.NotOwner.selector);
        t.setFrozen(false);
        vm.prank(owner);
        t.setFrozen(false);
        vm.prank(agent);
        t.pay(0, USDC, 1, "");
    }

    function test_note_onlyAgent() public {
        vm.prank(stranger);
        vm.expectRevert(Tamias.NotAgent.selector);
        t.note("x");
        vm.prank(stranger);
        vm.expectRevert(Tamias.NotAgent.selector);
        t.freeze("x");
    }

    // ── proposals ──

    function test_propose_overLimitThenOwnerApproves() public {
        vm.prank(agent);
        uint256 id = t.propose(OP_PAY, 0, address(0), USDC, 2.5e6, "invoice above my limit");
        Tamias.Proposal memory pr = t.getProposal(id);
        assertEq(uint8(pr.status), uint8(Tamias.Status.Pending));
        assertEq(pr.recordHash, keccak256("invoice above my limit"));
        assertEq(IERC20(USDC).balanceOf(bob), 0, "nothing moves on a proposal");

        vm.prank(agent);
        vm.expectRevert(Tamias.NotOwner.selector);
        t.approveProposal(id, "");

        vm.prank(owner);
        t.approveProposal(id, "ok, invoice checked");
        assertEq(IERC20(USDC).balanceOf(bob), 2.5e6);
        assertEq(uint8(t.getProposal(id).status), uint8(Tamias.Status.Approved));
        assertEq(_remaining(CONTRACTORS), 2.5e6, "approved spend still counts against the budget");

        vm.prank(owner);
        vm.expectRevert(Tamias.NotPending.selector);
        t.approveProposal(id, "");
    }

    function test_propose_approvalMayExceedBudgetAndFloor() public {
        vm.prank(agent);
        uint256 id = t.propose(OP_PAY, 0, address(0), USDC, 9.8e6, "big");
        vm.prank(owner);
        t.approveProposal(id, "yes");
        assertEq(t.cash(), 0.2e6);
        assertEq(_remaining(CONTRACTORS), 0);
        (,, uint256 spent,,,) = t.budgetOf(CONTRACTORS);
        assertEq(spent, 9.8e6);
    }

    function test_propose_payToUnlistedAddress() public {
        vm.startPrank(agent);
        vm.expectRevert(Tamias.BadParams.selector);
        t.propose(OP_PAY_TO, 0, address(0), USDC, 1e6, "");
        vm.expectRevert(Tamias.BadParams.selector);
        t.propose(OP_PAY_TO, 0, address(t), USDC, 1e6, "");
        uint256 id = t.propose(OP_PAY_TO, 0, stranger, USDC, 0.3e6, "new vendor, not on the list");
        vm.stopPrank();
        vm.prank(owner);
        t.approveProposal(id, "vendor verified");
        assertEq(IERC20(USDC).balanceOf(stranger), 0.3e6);
    }

    function test_propose_actAndReject() public {
        vm.prank(agent);
        uint256 id = t.propose(OP_ACT, 0, address(0), address(0), 0, "please run this");
        vm.prank(owner);
        t.rejectProposal(id, "not now");
        assertEq(uint8(t.getProposal(id).status), uint8(Tamias.Status.Rejected));
        vm.prank(owner);
        vm.expectRevert(Tamias.NotPending.selector);
        t.approveProposal(id, "");

        vm.prank(agent);
        id = t.propose(OP_ACT, 0, address(0), address(0), 0, "please run this");
        vm.prank(owner);
        t.approveProposal(id, "fine");
        assertEq(counter.count(), 1);
    }

    function test_propose_expires() public {
        vm.prank(agent);
        uint256 id = t.propose(OP_PAY, 0, address(0), USDC, 2e6, "");
        vm.warp(block.timestamp + 3 days + 1);
        vm.prank(owner);
        vm.expectRevert(Tamias.Expired.selector);
        t.approveProposal(id, "");
        vm.prank(owner);
        t.rejectProposal(id, "stale");
    }

    function test_propose_validates() public {
        vm.startPrank(agent);
        vm.expectRevert(Tamias.BadParams.selector);
        t.propose(7, 0, address(0), USDC, 1, "");
        vm.expectRevert(Tamias.UnknownId.selector);
        t.propose(1, 5, address(0), USDC, 1, "");
        vm.expectRevert(Tamias.TokenNotAccepted.selector);
        t.propose(1, 0, address(0), EURC, 1, "");
        vm.expectRevert(Tamias.BadParams.selector);
        t.propose(1, 0, address(0), USDC, 0, "");
        vm.stopPrank();
    }

    // ── the record chain ──

    function test_chain_replaysFromEvents() public {
        vm.recordLogs();
        vm.prank(agent);
        t.note("hold: revenue lands in 2 h");
        vm.roll(block.number + 5);
        vm.prank(agent);
        t.pay(0, USDC, 0.25e6, "pay");
        vm.prank(owner);
        t.setLimits(2e6, 0.5e6, 2 days);
        vm.roll(block.number + 3);
        vm.prank(agent);
        uint256 id = t.propose(1, 0, address(0), USDC, 3e6, "big");
        vm.prank(owner);
        t.approveProposal(id, "approved");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 h;
        uint64 firstSeq = type(uint64).max;
        uint256 n;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(t) || logs[i].topics[0] != RECORDED) continue;
            Rec memory r = _decode(logs[i]);
            if (firstSeq == type(uint64).max) {
                // the head before this test's first record is not in these logs; start from it
                firstSeq = r.seq;
                h = r.head;
            } else {
                h = keccak256(abi.encode(h, r.seq, r.op, r.by, r.ref, r.token, r.amount, r.usd, r.detail, keccak256(r.record)));
                assertEq(h, r.head, "replayed head matches");
            }
            n++;
        }
        assertEq(n, 5);
        assertEq(h, t.head());
        assertEq(t.seq(), firstSeq + 5);
        assertEq(t.lastBlock(), block.number);
    }

    function test_chain_policyRecordsCarryCalldata() public {
        vm.recordLogs();
        vm.prank(owner);
        t.setLimits(3e6, 1e6, 1 days);
        Rec memory r = _decode(vm.getRecordedLogs()[0]);
        assertEq(r.record, abi.encodeCall(Tamias.setLimits, (3e6, 1e6, 1 days)));
        assertEq(r.op, 7);
        assertEq(r.by, owner);
    }

    function test_chain_linksBlocksBackwards() public {
        vm.roll(block.number + 10);
        uint64 b1 = uint64(block.number);
        vm.prank(agent);
        t.note("one");
        vm.roll(block.number + 7);
        vm.recordLogs();
        vm.prank(agent);
        t.note("two");
        Rec memory r = _decode(vm.getRecordedLogs()[0]);
        assertEq(r.prevBlock, b1);
        assertEq(t.lastBlock(), b1 + 7);
    }

    bytes32 constant RECORDED =
        keccak256("Recorded(uint64,uint8,uint256,address,address,uint256,uint256,bytes32,bytes32,uint64,bytes)");

    struct Rec {
        uint64 seq;
        uint8 op;
        uint256 ref;
        address by;
        address token;
        uint256 amount;
        uint256 usd;
        bytes32 detail;
        bytes32 head;
        uint64 prevBlock;
        bytes record;
    }

    function _decode(Vm.Log memory l) internal pure returns (Rec memory r) {
        r.seq = uint64(uint256(l.topics[1]));
        r.op = uint8(uint256(l.topics[2]));
        r.ref = uint256(l.topics[3]);
        (r.by, r.token, r.amount, r.usd, r.detail, r.head, r.prevBlock, r.record) =
            abi.decode(l.data, (address, address, uint256, uint256, bytes32, bytes32, uint64, bytes));
    }

    // ── owner ──

    function test_owner_setters_validate() public {
        vm.startPrank(owner);
        vm.expectRevert(Tamias.UnknownId.selector);
        t.setCategory(5, "x", 1, 1 days);
        vm.expectRevert(Tamias.BadParams.selector);
        t.setCategory(2, "x", 1, 59 minutes);
        vm.expectRevert(Tamias.BadParams.selector);
        t.setPayee(2, _payee(address(0), address(0), Tamias.Kind.Transfer, 0, 1, ""));
        vm.expectRevert(Tamias.BadParams.selector);
        t.setPayee(2, _payee(address(t), address(0), Tamias.Kind.Transfer, 0, 1, ""));
        vm.expectRevert(Tamias.UnknownId.selector);
        t.setPayee(2, _payee(bob, address(0), Tamias.Kind.Transfer, 9, 1, ""));
        vm.expectRevert(Tamias.BadParams.selector);
        t.setPayee(2, _payee(bob, stranger, Tamias.Kind.TockGas, 0, 1, "")); // `via` must be a contract
        vm.expectRevert(Tamias.UnknownId.selector);
        t.setPayee(5, _payee(bob, address(0), Tamias.Kind.Transfer, 0, 1, ""));
        vm.expectRevert(Tamias.BadParams.selector);
        t.setAction(1, _action(address(t), "", 0, 0, ""));
        vm.expectRevert(Tamias.BadParams.selector);
        t.setAction(1, _action(stranger, "", 0, 0, ""));
        vm.expectRevert(Tamias.BadParams.selector);
        t.setUsdRate(USDC, 2e6);
        vm.expectRevert(Tamias.BadParams.selector);
        t.setLimits(1, 1, 59 minutes);
        vm.expectRevert(Tamias.BadParams.selector);
        t.ownerCall(address(t), 0, "");
        vm.stopPrank();

        vm.startPrank(stranger);
        vm.expectRevert(Tamias.NotOwner.selector);
        t.setCategory(2, "x", 1, 1 days);
        vm.expectRevert(Tamias.NotOwner.selector);
        t.setLimits(1, 1, 1 days);
        vm.expectRevert(Tamias.NotOwner.selector);
        t.ownerCall(stranger, 1, "");
        vm.stopPrank();
    }

    function test_owner_changingAPeriodKeepsWhatWasSpent() public {
        vm.prank(agent);
        t.pay(1, USDC, 1e6, "");
        vm.prank(owner);
        t.setCategory(INFRA, "infra", 3e6, 1 days); // same period: spending kept
        assertEq(_remaining(INFRA), 2e6);
        vm.prank(owner);
        t.setCategory(INFRA, "infra", 3e6, 2 days); // new period starts now, spending carried
        assertEq(_remaining(INFRA), 2e6);
        (,,,, uint256 end, uint256 per) = t.budgetOf(INFRA);
        assertEq(end - per, block.timestamp);
    }

    function test_owner_canWithdrawAnything() public {
        vm.prank(owner);
        t.ownerCall(stranger, 9.9 ether, "");
        assertEq(stranger.balance, 9.9 ether);
        assertEq(t.cash(), 0.1e6);
    }

    function test_owner_twoStepTransfer() public {
        vm.prank(owner);
        t.transferOwnership(stranger);
        assertEq(t.owner(), owner);
        vm.prank(bob);
        vm.expectRevert(Tamias.NotOwner.selector);
        t.acceptOwnership();
        vm.prank(stranger);
        t.acceptOwnership();
        assertEq(t.owner(), stranger);
        assertEq(t.pendingOwner(), address(0));
    }

    function test_receive_emits() public {
        vm.deal(stranger, 1 ether);
        vm.expectEmit(address(t));
        emit Tamias.Received(stranger, 0.3 ether);
        vm.prank(stranger);
        (bool ok,) = address(t).call{value: 0.3 ether}("");
        assertTrue(ok);
        // an ERC-20 transfer of USDC also lands in the native balance
        vm.prank(stranger);
        IERC20(USDC).transfer(address(t), 0.2e6);
        assertEq(t.cash(), 10.5e6);
    }

    function test_usdValue_roundsUp() public {
        vm.prank(owner);
        t.setUsdRate(EURC, 1.170001e6);
        assertEq(t.usdValue(EURC, 1), 2);
        assertEq(t.usdValue(USDC, 7), 7);
    }
}
