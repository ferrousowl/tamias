// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Tamias, IERC20} from "../src/Tamias.sol";

/// @dev Second-round review PoCs (fixes in 357dd76). Each test PASSES when the behaviour it
///      describes is present.
interface IGatewayWallet2 {
    function withdrawalDelay() external view returns (uint256);
    function availableBalance(address token, address depositor) external view returns (uint256);
    function withdrawingBalance(address token, address depositor) external view returns (uint256);
    function initiateWithdrawal(address token, uint256 value) external;
}

contract ReviewPoC2Test is Test {
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

    function test_N1_ownerRecoveryIntentDoesNotValidateWhileFrozen() public {
        vm.prank(agent);
        t.toGateway(4e6, "");
        vm.startPrank(owner);
        t.setFrozen(true); // incident: stop the agent, then get the reserve back
        bytes32 d = t.ownerAuthorizeIntent(_recall(4e6, block.number + _delay() + 172_800));
        vm.stopPrank();
        assertEq(t.isValidSignature(d, ""), bytes4(0xffffffff), "owner's recall refused while frozen");
    }

    function test_N1_agentFreezeOrAnyPayeeEditLapsesTheOwnersIntent() public {
        vm.prank(agent);
        t.toGateway(4e6, "");
        Tamias.BurnIntent memory bi = _recall(4e6, block.number + _delay() + 172_800);
        vm.prank(owner);
        bytes32 d = t.ownerAuthorizeIntent(bi);
        assertEq(t.isValidSignature(d, ""), OK);

        vm.prank(agent);
        t.freeze("I stop myself"); // also callable repeatedly while frozen
        vm.prank(owner);
        t.setFrozen(false);
        assertEq(t.isValidSignature(d, ""), bytes4(0xffffffff), "owner's intent lapsed by the agent");

        bi = _recall(4e6, block.number + _delay() + 172_801);
        vm.prank(owner);
        d = t.ownerAuthorizeIntent(bi);
        assertEq(t.isValidSignature(d, ""), OK);
        vm.prank(owner);
        t.setPayee(2, _p(stranger, address(0), 0, Tamias.Kind.Transfer, INFRA, 1, 0, address(0))); // unrelated new payee
        assertEq(t.isValidSignature(d, ""), bytes4(0xffffffff), "lapsed by an unrelated payee addition");
    }

    // ── N2: the lower bound does not cover the submit window. Gateway requires maxBlockHeight to
    //        be >= (current block + withdrawalDelay) when the intent is submitted, so an intent at
    //        the contract's lower bound is unattestable one block later, while still "signed" and
    //        already charged to the budget ──

    function test_N2_intentAtTheLowerBoundGoesStaleNextBlock() public {
        Tamias.BurnIntent memory bi = _recall(1e6, block.number + _delay());
        bi.spec.destinationDomain = BASE;
        bi.spec.destinationToken = _b(BASE_USDC);
        bi.spec.destinationRecipient = _b(vendor);
        vm.prank(agent);
        bytes32 d = t.authorizeIntent(bi, P_VENDOR, "");
        (,, uint256 spent,,,) = t.budgetOf(VENDORS);
        assertEq(spent, 1.01e6);
        vm.roll(block.number + 1);
        assertLt(bi.maxBlockHeight, block.number + _delay(), "below Gateway's minimum at submission");
        assertEq(t.isValidSignature(d, ""), OK, "still signed for 3,599 more blocks");
    }

    // ── N3: the `act` guard keys on `usdRate`, not on value. An unpriced token the treasury holds
    //        (EURC before/after the owner prices it, vault shares) can still be approved by an
    //        owner action, and the outflow measurement sees only native USDC ──

    function test_N3_unpricedTokenAllowanceActionStillBypassesBudget() public {
        deal(EURC, address(t), 10e6); // EURC held, but not priced (rate 0)
        Tamias.Action memory a;
        a.target = EURC;
        a.category = INFRA;
        a.active = true;
        a.charge = 0.1e6;
        a.data = abi.encodeCall(IERC20.approve, (stranger, 2e6));
        vm.prank(owner);
        t.setAction(0, a);
        for (uint256 i; i < 5; i++) {
            vm.prank(agent);
            t.act(0, "");
            vm.prank(stranger);
            (bool ok,) = EURC.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", address(t), stranger, 2e6));
            assertTrue(ok);
        }
        (,, uint256 spent,,,) = t.budgetOf(INFRA);
        assertEq(spent, 0.5e6);
        assertEq(IERC20(EURC).balanceOf(stranger), 10e6);
    }

    // ── N4: the Gateway cap counts only `availableBalance`. After the owner starts a trustless
    //        withdrawal, the agent can park up to the cap again on top of it ──

    function test_N4_gatewayCapIgnoresWithdrawingBalance() public {
        vm.prank(agent);
        t.toGateway(5e6, ""); // at the 5 USDC cap
        vm.prank(owner);
        t.ownerCall(GATEWAY_WALLET, 0, abi.encodeCall(IGatewayWallet2.initiateWithdrawal, (USDC, 5e6)));
        vm.prank(agent);
        t.toGateway(4.5e6, "");
        uint256 total = IGatewayWallet2(GATEWAY_WALLET).availableBalance(USDC, address(t))
            + IGatewayWallet2(GATEWAY_WALLET).withdrawingBalance(USDC, address(t));
        assertEq(total, 9.5e6, "9.5 USDC in Gateway under a 5 USDC cap");
    }
}
