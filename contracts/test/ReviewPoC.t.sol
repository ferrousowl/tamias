// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {Tamias, IERC20} from "../src/Tamias.sol";

/// @dev Proof-of-concept tests for the independent review of Tamias.sol (2026-10-07).
///      Each test PASSES when the reported weakness is present.
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

contract ReviewPoCTest is Test {
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
        keccak256("Recorded(uint64,uint8,uint256,address,address,uint256,uint256,bytes32,uint64,bytes)");

    // categories
    uint16 constant VENDORS = 0; // Gateway vendor + bob
    uint16 constant INFRA = 1; // Tock gas

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
        t.setPayee(P_VENDOR, _p(vendor, GATEWAY_MINTER, BASE, Tamias.Kind.Gateway, VENDORS, 1.5e6, 0.02e6, BASE_USDC, "vendor on Base"));
        t.setPayee(P_BOB, _p(bob, address(0), 0, Tamias.Kind.Transfer, VENDORS, 3e6, 0, address(0), "bob"));
        t.setPayee(P_TOCK, _p(gasOwner, TOCK, 0, Tamias.Kind.TockGas, INFRA, 1e6, 0, address(0), "tock gas"));
        // the configuration the repository's tests use
        t.setGateway(Tamias.GatewayConfig(GATEWAY_WALLET, GATEWAY_MINTER, ARC, 0.01e6, 100_000));
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
        (,, s,,) = t.budgetOf(cat);
    }

    function _workingGateway() internal {
        // what an owner must configure for Gateway to ever accept an intent (see test_F1)
        vm.prank(owner);
        t.setGateway(Tamias.GatewayConfig(GATEWAY_WALLET, GATEWAY_MINTER, ARC, 0.01e6, 2_000_000));
    }

    // ─────────────────────────────── F1 ───────────────────────────────
    // Gateway refuses to attest an intent whose maxBlockHeight is less than `withdrawalDelay`
    // blocks ahead (docs: technical guide, "Burn intent"); on Arc that is 1,209,600 blocks (~7
    // days) and /v1/estimate currently asks for ~1,382,400. With the tested `maxIntentBlocks`
    // (100,000) the contract refuses every intent Gateway would accept, so nothing parked with
    // `toGateway` can come back through the agent, and `toGateway` itself is unbudgeted.

    function test_F1_testedGatewayConfigCanNeverProduceAnAttestableIntent() public {
        uint256 wd = IGatewayWalletView(GATEWAY_WALLET).withdrawalDelay();
        assertEq(wd, 1_209_600, "Arc mainnet GatewayWallet withdrawal delay (blocks)");

        Tamias.BurnIntent memory bi = _recall(1e6, wd); // the shortest expiry Gateway accepts
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Tamias.BadIntent.selector, "maxBlockHeight"));
        t.authorizeIntent(bi, RECALL, "");

        // meanwhile the agent can move all cash above the floor into Gateway, charged nowhere
        vm.prank(agent);
        t.toGateway(9.5e6, "park everything");
        assertEq(t.cash(), 0.5e6);
        assertEq(_spent(VENDORS) + _spent(INFRA), 0);
        // ...and every payment is now blocked by the floor until the owner recovers the reserve
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Tamias.BelowFloor.selector, 0.4e6, 0.5e6));
        t.pay(P_BOB, USDC, 0.1e6, "");
    }

    // ─────────────────────────────── F2 ───────────────────────────────
    // With a working config, an authorized digest stays a valid treasury signature through every
    // brake the owner has: freeze, agent rotation, payee deactivation / re-pointing, and even
    // switching Gateway off. The digest is never emitted, so the owner cannot easily find it.

    function test_F2_authorizedIntentSurvivesFreezeRotationAndPayeeRemoval() public {
        _workingGateway();
        Tamias.BurnIntent memory bi = _toVendor(1e6, 1_400_000);

        vm.recordLogs();
        vm.prank(agent);
        bytes32 d = t.authorizeIntent(bi, P_VENDOR, "x");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            for (uint256 k; k < logs[i].topics.length; k++) {
                assertTrue(logs[i].topics[k] != d, "digest in a topic");
            }
            bytes memory data = logs[i].data;
            for (uint256 off; off + 32 <= data.length; off += 32) {
                bytes32 w;
                assembly {
                    w := mload(add(add(data, 32), off))
                }
                assertTrue(w != d, "digest in event data");
            }
        }

        // the owner pulls every brake
        vm.startPrank(owner);
        t.setFrozen(true);
        t.setAgent(makeAddr("fresh agent key"));
        Tamias.Payee memory p = t.getPayee(P_VENDOR);
        p.active = false;
        t.setPayee(P_VENDOR, p);
        p.account = carol; // vendor replaced
        t.setPayee(P_VENDOR, p);
        t.setGateway(Tamias.GatewayConfig(address(0), address(0), 0, 0, 0)); // Gateway "off"
        vm.stopPrank();

        // ~21 hours later the intent is still inside Gateway's attestable window
        // (1,400,000 - 1,209,600 = 190,400 blocks) and the treasury still "signs" it
        vm.roll(block.number + 150_000);
        assertEq(t.isValidSignature(d, ""), OK);
    }

    // ─────────────────────────────── F3 ───────────────────────────────
    // `isValidSignature` accepts any digest in `intentAuthorized`, not only Gateway burn intents,
    // and `setIntent` takes a raw bytes32. A digest the owner is talked into authorising (e.g. the
    // agent: "Gateway rejects my recall, please authorise digest 0x… by hand") can be a USDC
    // EIP-3009 authorization: anyone then moves the whole balance, past budgets and the floor.

    function test_F3_ownerAuthorizedDigestIsAUniversalSignature() public {
        uint256 value = 10e6; // everything, floor included
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
        vm.prank(owner);
        t.setIntent(digest, true); // looks like any other Gateway digest to a human

        vm.prank(stranger);
        IUsdcAuth(USDC).transferWithAuthorization(address(t), stranger, value, 0, type(uint256).max, nonce, "");
        assertEq(IERC20(USDC).balanceOf(stranger), value);
        assertEq(t.cash(), 0);
    }

    // ─────────────────────────────── F4 ───────────────────────────────
    // Proposals point at mutable ids. Approval ignores `active` and pays whatever the payee slot
    // holds at approval time; proposals by a rotated-out agent remain approvable.

    function test_F4_approvalPaysADeactivatedPayee() public {
        vm.prank(agent);
        uint256 id = t.propose(1, P_BOB, address(0), USDC, 2.5e6, "bob invoice 7");
        Tamias.Payee memory p = t.getPayee(P_BOB);
        p.active = false; // e.g. bob's key leaked
        vm.startPrank(owner);
        t.setPayee(P_BOB, p);
        t.setAgent(makeAddr("fresh agent key")); // the proposing agent is rotated out too
        t.approveProposal(id, "approving the backlog");
        vm.stopPrank();
        assertEq(IERC20(USDC).balanceOf(bob), 2.5e6, "paid to an inactive payee");
    }

    function test_F4_approvalFollowsAPayeeSlotThatWasRepointed() public {
        vm.prank(agent);
        uint256 id = t.propose(1, P_BOB, address(0), USDC, 2.5e6, "bob invoice 7");
        Tamias.Payee memory p = t.getPayee(P_BOB);
        p.account = carol;
        p.label = "carol";
        vm.startPrank(owner);
        t.setPayee(P_BOB, p); // slot 1 reused for a new vendor
        t.approveProposal(id, "bob's invoice, ok");
        vm.stopPrank();
        assertEq(IERC20(USDC).balanceOf(carol), 2.5e6, "bob's proposal paid carol");
        assertEq(IERC20(USDC).balanceOf(bob), 0);
    }

    function test_F4_shrinkingThenRaisingTtlRevivesStaleProposals() public {
        vm.prank(agent);
        uint256 id = t.propose(1, P_BOB, address(0), USDC, 2.5e6, "old");
        vm.warp(block.timestamp + 30 days);
        vm.prank(owner);
        vm.expectRevert(Tamias.Expired.selector);
        t.approveProposal(id, "");
        vm.prank(owner);
        t.setLimits(2e6, 0.5e6, 60 days); // a later, unrelated TTL change
        vm.prank(owner);
        t.approveProposal(id, "approving what the queue shows"); // a month-old proposal executes
        assertEq(IERC20(USDC).balanceOf(bob), 2.5e6);
    }

    // ─────────────────────────────── F5 ───────────────────────────────
    // Changing a category's period zeroes `spent`. An owner who "tightens" a category from
    // 2 USDC/day to 2 USDC/2 days hands the agent a fresh 2 USDC immediately.

    function test_F5_periodChangeResetsSpentGivingAFreshBudget() public {
        vm.startPrank(agent);
        t.pay(P_TOCK, USDC, 1e6, "");
        t.pay(P_TOCK, USDC, 1e6, "");
        vm.expectRevert();
        t.pay(P_TOCK, USDC, 1, "");
        vm.stopPrank();

        vm.prank(owner);
        t.setCategory(INFRA, "infra", 2e6, 2 days); // meant: halve the rate

        vm.startPrank(agent);
        t.pay(P_TOCK, USDC, 1e6, "");
        t.pay(P_TOCK, USDC, 1e6, "");
        vm.stopPrank();
        assertEq(t.cash(), 6e6, "4 USDC out of a 2 USDC category in one block");
    }

    // Aligned fixed windows: a full budget at the last second of one window and another at the
    // first second of the next (2x the budget within 2 seconds). Inherent to the design.
    function test_F5b_windowBoundaryAllowsTwiceTheBudget() public {
        uint256 start = t.getCategory(INFRA).windowStart;
        vm.warp(start + 1 days - 1);
        vm.startPrank(agent);
        t.pay(P_TOCK, USDC, 1e6, "");
        t.pay(P_TOCK, USDC, 1e6, "");
        vm.warp(start + 1 days + 1);
        t.pay(P_TOCK, USDC, 1e6, "");
        t.pay(P_TOCK, USDC, 1e6, "");
        vm.stopPrank();
        assertEq(t.cash(), 6e6);
    }

    // ─────────────────────────────── F6 ───────────────────────────────
    // Recall fees are not charged to any budget: each toGateway + recall cycle may cost up to
    // `recallMaxFee` (Gateway currently quotes 0.00385 USDC for an Arc->Arc recall) without limit.

    function test_F6_recallFeesAreChargedNowhere() public {
        _workingGateway();
        vm.prank(agent);
        t.toGateway(9e6, "");
        for (uint256 i; i < 25; i++) {
            Tamias.BurnIntent memory bi = _recall(0.3e6, 1_400_000);
            bi.spec.salt = bytes32(i);
            vm.prank(agent);
            t.authorizeIntent(bi, RECALL, "");
        }
        assertEq(_spent(VENDORS) + _spent(INFRA), 0, "25 x 0.01 USDC of possible fees, no budget used");
    }

    // ─────────────────────────────── F7 ───────────────────────────────
    // The record chain does not commit to where a proposal (or its approval) sends money:
    // OP_PROPOSE carries the proposal id, token, amount and the agent's own text only.

    function test_F7_proposalRecordOmitsTheRecipient() public {
        vm.recordLogs();
        vm.prank(agent);
        t.propose(8, 0, stranger, USDC, 2.5e6, '{"why":"bob invoice 7 (payee 1)"}');
        vm.prank(owner);
        t.approveProposal(0, "ok");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 n;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(t) || logs[i].topics[0] != RECORDED) continue;
            (address by, address token,,,,, bytes memory record) =
                abi.decode(logs[i].data, (address, address, uint256, uint256, bytes32, uint64, bytes));
            assertTrue(by != stranger && token != stranger);
            assertEq(uint256(logs[i].topics[3]), 0, "ref is the proposal id, not the recipient");
            assertTrue(keccak256(record) != keccak256(abi.encodePacked(stranger)));
            n++;
        }
        assertEq(n, 2);
        assertEq(IERC20(USDC).balanceOf(stranger), 2.5e6, "money went somewhere the log never names");
    }

    // ─────────────────────────────── F8 ───────────────────────────────
    // The USDC floor is checked on EURC payments too: once USDC on hand is below the floor (after
    // an approved payout, or cash parked in reserves), EURC payments the policy allows revert.

    function test_F8_floorBlocksEurcPayments() public {
        deal(EURC, address(t), 10e6);
        vm.startPrank(owner);
        t.setUsdRate(EURC, 1.17e6);
        t.ownerCall(stranger, 9.6 ether, ""); // USDC on hand now 0.4 < floor 0.5
        vm.stopPrank();
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Tamias.BelowFloor.selector, 0.4e6, 0.5e6));
        t.pay(P_BOB, EURC, 0.1e6, "paid in euros; USDC untouched");
    }
}
