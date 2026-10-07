// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {Tamias, IERC20} from "../src/Tamias.sol";

/// @dev Regression tests for the independent review of Tamias.sol (2026-10-07). Each finding was
///      first shown by a proof-of-concept test that passed against the reviewed code; after the
///      fixes, each test here asserts the corrected behaviour.
interface IGatewayWalletView {
    function withdrawalDelay() external view returns (uint256);
}

interface IUsdcAuth {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external;
}

contract ReviewTest is Test {
    address constant USDC = 0x3600000000000000000000000000000000000000;
    address constant EURC = 0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1;
    address constant TOCK = 0x3d5414F772Ce5667b13DfB9339a03072fd904F35;
    address constant GATEWAY_WALLET = 0x77777777Dcc4d5A8B6E418Fd04D8997ef11000eE;
    address constant GATEWAY_MINTER = 0x2222222d7164433c4C09B0b0D809a9b52C04C205;
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    uint32 constant ARC = 26;
    uint32 constant BASE = 6;
    uint256 constant RECALL = type(uint256).max;
    bytes4 constant OK = 0x1626ba7e;
    bytes32 constant RECORDED =
        keccak256("Recorded(uint64,uint8,uint256,address,address,uint256,uint256,bytes32,bytes32,uint64,bytes)");

    // categories
    uint16 constant VENDORS = 0; // Gateway vendor + bob
    uint16 constant INFRA = 1; // Tock gas
    uint16 constant FEES = 2; // Gateway fees

    // payees
    uint256 constant P_VENDOR = 0; // Gateway payee on Base
    uint256 constant P_BOB = 1; // ERC-20 transfer
    uint256 constant P_TOCK = 2; // Tock gas

    Tamias t;
    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address vendor = makeAddr("vendor");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address gasOwner = makeAddr("gasOwner");
    address stranger = makeAddr("stranger");

    function setUp() public {
        vm.createSelectFork(vm.envOr("ARC_RPC", string("https://rpc.mainnet.arc.io")));
        vm.fee(20 gwei);
        t = new Tamias(owner, agent, 2e6, 0.5e6); // $2 auto-limit, $0.50 floor
        vm.deal(address(t), 10 ether); // 10 USDC
        vm.startPrank(owner);
        t.setCategory(VENDORS, "vendors", 5e6, 1 days);
        t.setCategory(INFRA, "infra", 2e6, 1 days);
        t.setCategory(FEES, "gateway fees", 0.05e6, 1 days);
        t.setPayee(P_VENDOR, _p(vendor, GATEWAY_MINTER, BASE, Tamias.Kind.Gateway, VENDORS, 1.5e6, 0.02e6, BASE_USDC, "vendor on Base"));
        t.setPayee(P_BOB, _p(bob, address(0), 0, Tamias.Kind.Transfer, VENDORS, 3e6, 0, address(0), "bob"));
        t.setPayee(P_TOCK, _p(gasOwner, TOCK, 0, Tamias.Kind.TockGas, INFRA, 1e6, 0, address(0), "tock gas"));
        t.setGateway(Tamias.GatewayConfig(GATEWAY_WALLET, GATEWAY_MINTER, ARC, 0.01e6, 200_000, 5e6, FEES));
        vm.stopPrank();
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function _p(
        address account,
        address via,
        uint32 domain,
        Tamias.Kind kind,
        uint16 cat,
        uint128 max,
        uint128 maxFee,
        address remoteToken,
        string memory label
    ) internal pure returns (Tamias.Payee memory p) {
        p.account = account;
        p.via = via;
        p.domain = domain;
        p.kind = kind;
        p.category = cat;
        p.active = true;
        p.maxPayment = max;
        p.maxFee = maxFee;
        p.remoteToken = remoteToken;
        p.label = label;
    }

    function _b(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _recall(uint256 value, uint256 ttlBlocks) internal view returns (Tamias.BurnIntent memory bi) {
        bi.maxBlockHeight = block.number + ttlBlocks;
        bi.maxFee = 0.01e6;
        bi.spec = Tamias.TransferSpec({
            version: 1,
            sourceDomain: ARC,
            destinationDomain: ARC,
            sourceContract: _b(GATEWAY_WALLET),
            destinationContract: _b(GATEWAY_MINTER),
            sourceToken: _b(USDC),
            destinationToken: _b(USDC),
            sourceDepositor: _b(address(t)),
            destinationRecipient: _b(address(t)),
            sourceSigner: _b(address(t)),
            destinationCaller: bytes32(0),
            value: value,
            salt: keccak256(abi.encode(value, ttlBlocks, gasleft())),
            hookData: ""
        });
    }

    function _toVendor(uint256 value, uint256 ttlBlocks) internal view returns (Tamias.BurnIntent memory bi) {
        bi = _recall(value, ttlBlocks);
        bi.maxFee = 0.01e6;
        bi.spec.destinationDomain = BASE;
        bi.spec.destinationToken = _b(BASE_USDC);
        bi.spec.destinationRecipient = _b(vendor);
    }

    function _spent(uint256 cat) internal view returns (uint256 s) {
        (,, s,,,) = t.budgetOf(cat);
    }

    /// @dev The shortest expiry Gateway accepts is its withdrawal delay; ask for a day more,
    ///      as Gateway's own estimate does.
    function _ttl() internal view returns (uint256) {
        return IGatewayWalletView(GATEWAY_WALLET).withdrawalDelay() + 172_800;
    }


    // ── F1: Gateway expiry is bounded below by the withdrawal delay; the Gateway reserve is capped ──

    function test_F1_expiryFollowsGatewaysWithdrawalDelay() public {
        uint256 wd = IGatewayWalletView(GATEWAY_WALLET).withdrawalDelay();
        vm.prank(agent);
        t.toGateway(2e6, "");
        // too short for Gateway, too long for policy: both refused
        Tamias.BurnIntent memory bi = _recall(1e6, wd - 1);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Tamias.BadIntent.selector, uint8(7)));
        t.authorizeIntent(bi, RECALL, "");
        bi = _recall(1e6, wd + 200_001);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Tamias.BadIntent.selector, uint8(7)));
        t.authorizeIntent(bi, RECALL, "");
        // what Gateway's estimate asks for is accepted
        bi = _recall(1e6, _ttl());
        vm.prank(agent);
        bytes32 d = t.authorizeIntent(bi, RECALL, "");
        assertEq(t.isValidSignature(d, ""), OK);
    }

    function test_F1_gatewayReserveIsCapped() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Tamias.OverGatewayCap.selector, 5.5e6, 5e6));
        t.toGateway(5.5e6, "park everything");
        vm.prank(agent);
        t.toGateway(5e6, "");
        assertEq(t.cash(), 5e6);
    }

    // ── F2: an authorization is short-lived and dies with every brake; its digest is on the record ──

    function test_F2_authorizationLapsesWithTime() public {
        Tamias.BurnIntent memory bi = _toVendor(1e6, _ttl());
        vm.prank(agent);
        bytes32 d = t.authorizeIntent(bi, P_VENDOR, "x");
        assertEq(t.isValidSignature(d, ""), OK);
        vm.roll(block.number + t.INTENT_SUBMIT_BLOCKS());
        assertEq(t.isValidSignature(d, ""), OK);
        vm.roll(block.number + 1);
        assertEq(t.isValidSignature(d, ""), bytes4(0xffffffff));
    }

    function test_F2_everyBrakeRevokesAuthorizations() public {
        bytes32 d;
        // freeze by the owner (and it stays dead after unfreezing)
        d = _authVendor(1);
        vm.prank(owner);
        t.setFrozen(true);
        assertEq(t.isValidSignature(d, ""), bytes4(0xffffffff));
        vm.prank(owner);
        t.setFrozen(false);
        assertEq(t.isValidSignature(d, ""), bytes4(0xffffffff));
        // freeze by the agent itself
        d = _authVendor(2);
        vm.prank(agent);
        t.freeze("stop");
        assertEq(t.isValidSignature(d, ""), bytes4(0xffffffff));
        vm.prank(owner);
        t.setFrozen(false);
        // a new agent key
        d = _authVendor(3);
        vm.prank(owner);
        t.setAgent(agent);
        assertEq(t.isValidSignature(d, ""), bytes4(0xffffffff));
        // the payee changed
        d = _authVendor(4);
        Tamias.Payee memory p = t.getPayee(P_VENDOR);
        p.account = carol;
        vm.prank(owner);
        t.setPayee(P_VENDOR, p);
        assertEq(t.isValidSignature(d, ""), bytes4(0xffffffff));
        // Gateway reconfigured or switched off
        vm.prank(owner);
        t.setPayee(P_VENDOR, _p(vendor, GATEWAY_MINTER, BASE, Tamias.Kind.Gateway, VENDORS, 1.5e6, 0.02e6, BASE_USDC, "vendor on Base"));
        d = _authVendor(5);
        vm.prank(owner);
        t.setGateway(Tamias.GatewayConfig(address(0), address(0), 0, 0, 0, 0, 0));
        assertEq(t.isValidSignature(d, ""), bytes4(0xffffffff));
        // and the owner can revoke one directly
        vm.prank(owner);
        t.setGateway(Tamias.GatewayConfig(GATEWAY_WALLET, GATEWAY_MINTER, ARC, 0.01e6, 200_000, 5e6, FEES));
        d = _authVendor(6);
        vm.prank(owner);
        t.revokeIntent(d);
        assertEq(t.isValidSignature(d, ""), bytes4(0xffffffff));
    }

    function _authVendor(uint256 salt) internal returns (bytes32 d) {
        Tamias.BurnIntent memory bi = _toVendor(0.1e6, _ttl());
        bi.spec.salt = bytes32(salt);
        vm.prank(agent);
        d = t.authorizeIntent(bi, P_VENDOR, "x");
        assertEq(t.isValidSignature(d, ""), OK);
    }

    function test_F2_digestIsInTheRecordChain() public {
        Tamias.BurnIntent memory bi = _toVendor(1e6, _ttl());
        vm.recordLogs();
        vm.prank(agent);
        bytes32 d = t.authorizeIntent(bi, P_VENDOR, "x");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (,,,, bytes32 detail,,,) = abi.decode(logs[logs.length - 1].data, (address, address, uint256, uint256, bytes32, bytes32, uint64, bytes));
        assertEq(detail, d);
    }

    // ── F3: the owner can only authorize real burn intents of this treasury, never a raw digest ──

    function test_F3_ownerCannotBlessAnArbitraryDigest() public {
        uint256 value = 10e6;
        bytes32 nonce = keccak256("poc");
        bytes32 typehash = keccak256(
            "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
        );
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                IUsdcAuth(USDC).DOMAIN_SEPARATOR(),
                keccak256(abi.encode(typehash, address(t), stranger, value, 0, type(uint256).max, nonce))
            )
        );
        // there is no way to authorize a bare hash any more
        (bool ok,) = address(t).call(abi.encodeWithSignature("setIntent(bytes32,bool)", digest, true));
        assertFalse(ok);
        assertEq(t.isValidSignature(digest, ""), bytes4(0xffffffff));
        vm.prank(stranger);
        vm.expectRevert();
        IUsdcAuth(USDC).transferWithAuthorization(address(t), stranger, value, 0, type(uint256).max, nonce, "");

        // a hand-authorized intent must spend this treasury's own Gateway balance
        Tamias.BurnIntent memory bi = _recall(1e6, _ttl());
        bi.spec.sourceDepositor = _b(stranger);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Tamias.BadIntent.selector, uint8(4)));
        t.ownerAuthorizeIntent(bi);
        bi = _toVendor(1e6, _ttl()); // the owner may send anywhere, though
        bi.spec.destinationRecipient = _b(carol);
        vm.prank(owner);
        bytes32 d = t.ownerAuthorizeIntent(bi);
        assertEq(t.isValidSignature(d, ""), OK);
    }

    // ── F4: a proposal is bound to what it pays, to its proposer and to its own expiry ──

    function test_F4_approvalRefusesADeactivatedPayee() public {
        vm.prank(agent);
        uint256 id = t.propose(1, P_BOB, address(0), USDC, 2.5e6, "bob invoice 7");
        Tamias.Payee memory p = t.getPayee(P_BOB);
        p.active = false;
        vm.startPrank(owner);
        t.setPayee(P_BOB, p);
        vm.expectRevert(Tamias.ProposalChanged.selector);
        t.approveProposal(id, "approving the backlog");
        vm.stopPrank();
        assertEq(IERC20(USDC).balanceOf(bob), 0);
    }

    function test_F4_approvalRefusesARotatedOutProposer() public {
        vm.prank(agent);
        uint256 id = t.propose(1, P_BOB, address(0), USDC, 2.5e6, "bob invoice 7");
        vm.startPrank(owner);
        t.setAgent(makeAddr("fresh agent key"));
        vm.expectRevert(Tamias.ProposalChanged.selector);
        t.approveProposal(id, "");
        t.rejectProposal(id, "stale"); // it can still be closed
        vm.stopPrank();
    }

    function test_F4_approvalRefusesARepointedPayeeSlot() public {
        vm.prank(agent);
        uint256 id = t.propose(1, P_BOB, address(0), USDC, 2.5e6, "bob invoice 7");
        Tamias.Payee memory p = t.getPayee(P_BOB);
        p.account = carol;
        p.label = "carol";
        vm.startPrank(owner);
        t.setPayee(P_BOB, p);
        vm.expectRevert(Tamias.ProposalChanged.selector);
        t.approveProposal(id, "bob's invoice, ok");
        // a label or limit change alone does not void it
        p.account = bob;
        p.label = "bob (renamed)";
        p.maxPayment = 1e6;
        t.setPayee(P_BOB, p);
        t.approveProposal(id, "ok");
        vm.stopPrank();
        assertEq(IERC20(USDC).balanceOf(bob), 2.5e6);
        assertEq(IERC20(USDC).balanceOf(carol), 0);
    }

    function test_F4_raisingTheTtlDoesNotReviveStaleProposals() public {
        vm.prank(agent);
        uint256 id = t.propose(1, P_BOB, address(0), USDC, 2.5e6, "old");
        vm.warp(block.timestamp + 30 days);
        vm.startPrank(owner);
        t.setLimits(2e6, 0.5e6, 60 days);
        vm.expectRevert(Tamias.Expired.selector);
        t.approveProposal(id, "");
        vm.stopPrank();
    }

    function test_F4_gatewayPayeesCannotBeProposedForPay() public {
        vm.prank(agent);
        vm.expectRevert(Tamias.BadParams.selector);
        t.propose(1, P_VENDOR, address(0), USDC, 1e6, "");
    }

    function test_F4_payToProposalStoresNoStrayRef() public {
        vm.prank(agent);
        uint256 id = t.propose(8, 12345, carol, USDC, 1e6, "");
        assertEq(t.getProposal(id).ref, 0);
    }

    // ── F5: changing a period never hands out a fresh budget ──

    function test_F5_periodChangeKeepsWhatWasSpent() public {
        vm.startPrank(agent);
        t.pay(P_TOCK, USDC, 1e6, "");
        t.pay(P_TOCK, USDC, 1e6, "");
        vm.stopPrank();
        vm.prank(owner);
        t.setCategory(INFRA, "infra", 2e6, 2 days);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Tamias.OverBudget.selector, INFRA, 1e6, 0));
        t.pay(P_TOCK, USDC, 1e6, "");
        vm.warp(block.timestamp + 2 days);
        vm.prank(agent);
        t.pay(P_TOCK, USDC, 1e6, "");
    }

    // ── F6: recall fees are charged to the Gateway fee budget ──

    function test_F6_recallFeesAreBudgeted() public {
        vm.prank(agent);
        t.toGateway(5e6, "");
        for (uint256 i; i < 5; i++) {
            Tamias.BurnIntent memory bi = _recall(0.3e6, _ttl());
            bi.spec.salt = bytes32(i);
            vm.prank(agent);
            t.authorizeIntent(bi, RECALL, "");
        }
        assertEq(_spent(FEES), 0.05e6);
        Tamias.BurnIntent memory bi2 = _recall(0.3e6, _ttl());
        bi2.spec.salt = bytes32(uint256(99));
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Tamias.OverBudget.selector, FEES, 0.01e6, 0));
        t.authorizeIntent(bi2, RECALL, "");
    }

    // ── F7: the record chain names the recipient of proposals and approvals ──

    function test_F7_recipientIsInTheRecordChain() public {
        vm.recordLogs();
        vm.prank(agent);
        t.propose(8, 0, stranger, USDC, 2.5e6, '{"why":"bob invoice 7 (payee 1)"}');
        vm.prank(owner);
        t.approveProposal(0, "ok");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32[2] memory details;
        uint256 n;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(t) || logs[i].topics[0] != RECORDED) continue;
            (,,,, bytes32 detail,,,) = abi.decode(logs[i].data, (address, address, uint256, uint256, bytes32, bytes32, uint64, bytes));
            details[n++] = detail;
        }
        assertEq(n, 2);
        assertEq(details[0], keccak256(abi.encode(uint8(8), uint256(0), _b(stranger))), "proposal commits to the recipient");
        assertEq(details[1], _b(stranger), "approval names the recipient");
    }

    // ── F8: the USDC floor does not block payments that take no USDC ──

    function test_F8_floorIgnoresEurcPayments() public {
        deal(EURC, address(t), 10e6);
        vm.startPrank(owner);
        t.setUsdRate(EURC, 1.17e6);
        t.ownerCall(stranger, 9.6 ether, ""); // USDC on hand now 0.4 < floor 0.5
        vm.stopPrank();
        vm.prank(agent);
        t.pay(P_BOB, EURC, 0.1e6, "paid in euros; USDC untouched");
        assertEq(IERC20(EURC).balanceOf(bob), 0.1e6);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Tamias.BelowFloor.selector, 0.3e6, 0.5e6));
        t.pay(P_BOB, USDC, 0.1e6, "");
    }

    // ── F9: actions on priced tokens are refused; an action is charged what it actually took ──

    function test_F9_tokenActionsAreRefused() public {
        Tamias.Action memory a;
        a.target = USDC;
        a.category = INFRA;
        a.active = true;
        a.charge = 0.1e6;
        a.data = abi.encodeCall(IERC20.approve, (stranger, 2e6));
        a.label = "authorize the vendor's monthly pull";
        vm.prank(owner);
        t.setAction(0, a);
        vm.prank(agent);
        vm.expectRevert(Tamias.BadParams.selector);
        t.act(0, "");
    }

    function test_F9_actIsChargedWhatLeaves() public {
        Sink sink = new Sink();
        Tamias.Action memory a;
        a.target = address(new Puller(t));
        a.category = INFRA;
        a.active = true;
        a.charge = 0.1e6; // declared
        a.data = abi.encodeCall(Puller.pull, (address(sink), 0.7e6));
        a.label = "an integration that takes more than declared";
        vm.startPrank(owner);
        t.setAction(0, a);
        // let the puller take USDC from the treasury through the owner's own allowance
        t.ownerCall(USDC, 0, abi.encodeCall(IERC20.approve, (a.target, 10e6)));
        vm.stopPrank();
        vm.prank(agent);
        t.act(0, "");
        assertEq(_spent(INFRA), 0.7e6, "charged the real outflow, not the declared 0.1");
        vm.prank(agent);
        t.act(0, "");
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Tamias.OverBudget.selector, INFRA, 0.7e6, 0.6e6));
        t.act(0, "");
    }

    // ── informational: transferOwnership is on the record ──

    function test_transferOwnershipIsRecorded() public {
        uint64 before = t.seq();
        vm.prank(owner);
        t.transferOwnership(carol);
        assertEq(t.seq(), before + 1);
    }
}

contract Sink {}

/// @dev Pulls USDC from the treasury with an allowance the owner granted, when the treasury calls it.
contract Puller {
    Tamias immutable T;

    constructor(Tamias t_) {
        T = t_;
    }

    function pull(address to, uint256 amount) external {
        (bool ok,) = 0x3600000000000000000000000000000000000000.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", address(T), to, amount)
        );
        require(ok, "pull failed");
    }
}
