// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Tamias, IERC20} from "../src/Tamias.sol";

/// @dev Regression tests for the second review round (re-review of the fixes, 2026-10-07): each
///      issue was first shown by a passing proof of concept; these assert the corrected behaviour.
interface IGatewayWallet2 {
    function withdrawalDelay() external view returns (uint256);
    function availableBalance(address token, address depositor) external view returns (uint256);
    function withdrawingBalance(address token, address depositor) external view returns (uint256);
    function initiateWithdrawal(address token, uint256 value) external;
}

contract Review2Test is Test {
    address constant USDC = 0x3600000000000000000000000000000000000000;
    address constant EURC = 0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1;
    address constant GATEWAY_WALLET = 0x77777777Dcc4d5A8B6E418Fd04D8997ef11000eE;
    address constant GATEWAY_MINTER = 0x2222222d7164433c4C09B0b0D809a9b52C04C205;
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    uint32 constant ARC = 26;
    uint32 constant BASE = 6;
    uint256 constant RECALL = type(uint256).max;
    bytes4 constant OK = 0x1626ba7e;
    uint16 constant VENDORS = 0;
    uint16 constant INFRA = 1;
    uint16 constant FEES = 2;
    uint256 constant P_VENDOR = 0;
    uint256 constant P_BOB = 1;

    Tamias t;
    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address vendor = makeAddr("vendor");
    address bob = makeAddr("bob");
    address stranger = makeAddr("stranger");

    function setUp() public {
        vm.createSelectFork(vm.envOr("ARC_RPC", string("https://rpc.mainnet.arc.io")));
        vm.fee(20 gwei);
        t = new Tamias(owner, agent, 2e6, 0.5e6);
        vm.deal(address(t), 10 ether);
        vm.startPrank(owner);
        t.setCategory(VENDORS, "vendors", 5e6, 1 days);
        t.setCategory(INFRA, "infra", 2e6, 1 days);
        t.setCategory(FEES, "gateway fees", 0.05e6, 1 days);
        t.setPayee(P_VENDOR, _p(vendor, GATEWAY_MINTER, BASE, Tamias.Kind.Gateway, VENDORS, 1.5e6, 0.02e6, BASE_USDC));
        t.setPayee(P_BOB, _p(bob, address(0), 0, Tamias.Kind.Transfer, VENDORS, 3e6, 0, address(0)));
        t.setGateway(Tamias.GatewayConfig(GATEWAY_WALLET, GATEWAY_MINTER, ARC, 0.01e6, 200_000, 5e6, FEES));
        vm.stopPrank();
    }

    function _p(address account, address via, uint32 domain, Tamias.Kind kind, uint16 cat, uint128 max, uint128 maxFee, address remoteToken)
        internal
        pure
        returns (Tamias.Payee memory p)
    {
        p.account = account;
        p.via = via;
        p.domain = domain;
        p.kind = kind;
        p.category = cat;
        p.active = true;
        p.maxPayment = max;
        p.maxFee = maxFee;
        p.remoteToken = remoteToken;
        p.label = "x";
    }

    function _b(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _delay() internal view returns (uint256) {
        return IGatewayWallet2(GATEWAY_WALLET).withdrawalDelay();
    }

    function _recall(uint256 value, uint256 maxBlockHeight) internal view returns (Tamias.BurnIntent memory bi) {
        bi.maxBlockHeight = maxBlockHeight;
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
            salt: keccak256(abi.encode(value, maxBlockHeight)),
            hookData: ""
        });
    }

    // ── N1: while frozen nothing validates, not even the owner's own recovery intent; and the
    //        agent's `freeze()` (callable at any time, even when already frozen) or any routine
    //        owner change lapses an owner-authorized intent too ──

    function test_N1_ownerRecoveryIntentValidatesWhileFrozen() public {
        vm.prank(agent);
        t.toGateway(4e6, "");
        vm.startPrank(owner);
        t.setFrozen(true); // incident: stop the agent, then get the reserve back
        bytes32 d = t.ownerAuthorizeIntent(_recall(4e6, block.number + _delay() + 172_800));
        vm.stopPrank();
        assertEq(t.isValidSignature(d, ""), OK, "the owner's recall works while the agent is frozen");
    }

    function test_N1_agentBrakesDoNotLapseTheOwnersIntent() public {
        vm.prank(agent);
        t.toGateway(4e6, "");
        Tamias.BurnIntent memory bi = _recall(4e6, block.number + _delay() + 172_800);
        vm.prank(owner);
        bytes32 d = t.ownerAuthorizeIntent(bi);
        assertEq(t.isValidSignature(d, ""), OK);
        vm.prank(agent);
        t.freeze("I stop myself");
        vm.prank(agent);
        t.freeze("and again");
        vm.prank(owner);
        t.setPayee(2, _p(stranger, address(0), 0, Tamias.Kind.Transfer, INFRA, 1, 0, address(0)));
        assertEq(t.isValidSignature(d, ""), OK, "still valid after agent freezes and payee edits");
        // it lapses by time, by revocation, or when Gateway is reconfigured
        (address w, address m, uint32 dom, uint128 rmf, uint32 mib, uint128 cap, uint16 fc) = t.gateway();
        vm.prank(owner);
        t.setGateway(Tamias.GatewayConfig(w, m, dom, rmf, mib, cap, fc));
        assertEq(t.isValidSignature(d, ""), bytes4(0xffffffff));
        bi = _recall(4e6, block.number + _delay() + 172_801);
        vm.prank(owner);
        d = t.ownerAuthorizeIntent(bi);
        vm.roll(block.number + t.INTENT_SUBMIT_BLOCKS() + 1);
        assertEq(t.isValidSignature(d, ""), bytes4(0xffffffff));
    }

    function test_N2_lowerBoundCoversTheSubmitWindow() public {
        Tamias.BurnIntent memory bi = _recall(1e6, block.number + _delay() + t.INTENT_SUBMIT_BLOCKS() - 1);
        bi.spec.destinationDomain = BASE;
        bi.spec.destinationToken = _b(BASE_USDC);
        bi.spec.destinationRecipient = _b(vendor);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Tamias.BadIntent.selector, uint8(7)));
        t.authorizeIntent(bi, P_VENDOR, "");
        bi.maxBlockHeight += 1;
        vm.prank(agent);
        t.authorizeIntent(bi, P_VENDOR, "");
    }

    function test_N3_allowanceAndTransferActionsAreRefusedOnAnyTarget() public {
        deal(EURC, address(t), 10e6); // EURC held, but not priced (rate 0)
        Tamias.Action memory a;
        a.target = EURC;
        a.category = INFRA;
        a.active = true;
        a.charge = 0.1e6;
        a.data = abi.encodeCall(IERC20.approve, (stranger, 2e6));
        vm.prank(owner);
        t.setAction(0, a);
        vm.prank(agent);
        vm.expectRevert(Tamias.BadParams.selector);
        t.act(0, "");
        // the same through an approved proposal
        vm.prank(agent);
        uint256 id = t.propose(2, 0, address(0), address(0), 0, "");
        vm.prank(owner);
        vm.expectRevert(Tamias.BadParams.selector);
        t.approveProposal(id, "");
        // transfer / transferFrom selectors on an arbitrary contract
        a.target = GATEWAY_MINTER;
        a.data = abi.encodeWithSelector(IERC20.transfer.selector, stranger, 1);
        vm.prank(owner);
        t.setAction(1, a);
        vm.prank(agent);
        vm.expectRevert(Tamias.BadParams.selector);
        t.act(1, "");
        // the Gateway wallet itself
        a.target = GATEWAY_WALLET;
        a.data = abi.encodeWithSignature("initiateWithdrawal(address,uint256)", USDC, 1);
        vm.prank(owner);
        t.setAction(2, a);
        vm.prank(agent);
        vm.expectRevert(Tamias.BadParams.selector);
        t.act(2, "");
    }

    function test_N4_gatewayCapCountsWithdrawingBalance() public {
        vm.prank(agent);
        t.toGateway(5e6, ""); // at the 5 USDC cap
        vm.prank(owner);
        t.ownerCall(GATEWAY_WALLET, 0, abi.encodeCall(IGatewayWallet2.initiateWithdrawal, (USDC, 5e6)));
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Tamias.OverGatewayCap.selector, 9.5e6, 5e6));
        t.toGateway(4.5e6, "");
    }
}
