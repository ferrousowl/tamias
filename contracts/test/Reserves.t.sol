// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Tamias, IERC20} from "../src/Tamias.sol";

interface IGatewayView {
    function availableBalance(address token, address depositor) external view returns (uint256);
    function withdrawalDelay() external view returns (uint256);
}

interface IVaultView {
    function balanceOf(address) external view returns (uint256);
    function convertToAssets(uint256) external view returns (uint256);
}

/// @dev Circle integrations against the live contracts on an Arc mainnet fork: Gateway (deposits,
///      deposits for another account, and burn intents the treasury signs via ERC-1271), CCTP, and
///      an ERC-4626 vault from App Kit Earn.
contract ReservesTest is Test {
    address constant USDC = 0x3600000000000000000000000000000000000000;
    address constant GATEWAY_WALLET = 0x77777777Dcc4d5A8B6E418Fd04D8997ef11000eE;
    address constant GATEWAY_MINTER = 0x2222222d7164433c4C09B0b0D809a9b52C04C205;
    address constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address constant STEAKHOUSE_USDC = 0xbeef0016cb2Fd5C352ea7CA08a9f54739DFa7298; // Morpho vault
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    uint32 constant ARC = 26;
    uint32 constant BASE = 6;
    uint256 constant RECALL = type(uint256).max;

    Tamias t;
    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address vendor = makeAddr("vendor"); // paid on Base
    address stranger = makeAddr("stranger");

    function setUp() public {
        vm.createSelectFork(vm.envOr("ARC_RPC", string("https://rpc.mainnet.arc.io")));
        vm.fee(20 gwei);
        t = new Tamias(owner, agent, 2e6, 0.5e6);
        vm.deal(address(t), 10 ether);
        vm.startPrank(owner);
        t.setCategory(0, "vendors", 5e6, 1 days);
        t.setCategory(1, "agent data", 1e6, 1 days);
        t.setCategory(2, "gateway fees", 0.1e6, 1 days);
        t.setPayee(0, _p(vendor, GATEWAY_MINTER, BASE, Tamias.Kind.Gateway, 0, 1.5e6, 0.02e6, BASE_USDC, "vendor on Base via Gateway"));
        t.setPayee(1, _p(agent, GATEWAY_WALLET, 0, Tamias.Kind.GatewayDeposit, 1, 0.5e6, 0, address(0), "agent x402 budget"));
        t.setPayee(2, _p(vendor, TOKEN_MESSENGER, BASE, Tamias.Kind.Cctp, 0, 1.5e6, 0, address(0), "vendor on Base via CCTP"));
        t.setGateway(Tamias.GatewayConfig(GATEWAY_WALLET, GATEWAY_MINTER, ARC, 0.01e6, 200_000, 5e6, 2));
        t.setVault(0, Tamias.Vault(STEAKHOUSE_USDC, true, 3e6, "Steakhouse Prime USDC (Morpho)"));
        vm.stopPrank();
    }

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

    function _recall(uint256 value) internal view returns (Tamias.BurnIntent memory bi) {
        bi.maxBlockHeight = block.number + IGatewayView(GATEWAY_WALLET).withdrawalDelay() + 172_800;
        bi.maxFee = 0.005e6;
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
            salt: keccak256(abi.encode(value, block.number)),
            hookData: ""
        });
    }

    function _toVendor(uint256 value) internal view returns (Tamias.BurnIntent memory bi) {
        bi = _recall(value);
        bi.maxFee = 0.01e6;
        bi.spec.destinationDomain = BASE;
        bi.spec.destinationToken = _b(BASE_USDC);
        bi.spec.destinationRecipient = _b(vendor);
    }

    // ── EIP-712 digest matches Gateway's (reference values computed with viem.hashTypedData) ──

    function test_intentDigest_matchesViem() public view {
        Tamias.BurnIntent memory bi;
        bi.maxBlockHeight = 123456789;
        bi.maxFee = 10000;
        bi.spec = Tamias.TransferSpec({
            version: 1,
            sourceDomain: 26,
            destinationDomain: 6,
            sourceContract: _b(GATEWAY_WALLET),
            destinationContract: _b(GATEWAY_MINTER),
            sourceToken: _b(USDC),
            destinationToken: _b(BASE_USDC),
            sourceDepositor: _b(0x1111111111111111111111111111111111111111),
            destinationRecipient: _b(0x2222222222222222222222222222222222222222),
            sourceSigner: _b(0x1111111111111111111111111111111111111111),
            destinationCaller: bytes32(0),
            value: 1000000,
            salt: 0xabababababababababababababababababababababababababababababababab,
            hookData: ""
        });
        assertEq(t.intentDigest(bi), 0xed4b8bf97be94ca8393fe23cb85f439734c2c7608c361113c099ee5439e4399f);
        bi.spec.hookData = hex"deadbeef";
        assertEq(t.intentDigest(bi), 0xfd489c417a7fdf501ec3ed3f75600d6ff232092b0879be86a946062feba14d69);
    }

    // ── Gateway reserve ──

    function test_toGateway_depositsIntoTheTreasurysBalance() public {
        vm.prank(agent);
        t.toGateway(3e6, "park surplus in Gateway");
        assertEq(IGatewayView(GATEWAY_WALLET).availableBalance(USDC, address(t)), 3e6);
        assertEq(t.cash(), 7e6);
        assertEq(IERC20(USDC).balanceOf(address(t)), 7e6);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Tamias.OverGatewayCap.selector, 5.5e6, 5e6));
        t.toGateway(2.5e6, "");

        vm.deal(address(t), 1 ether);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Tamias.BelowFloor.selector, 0.4e6, 0.5e6));
        t.toGateway(0.6e6, "");
        vm.prank(stranger);
        vm.expectRevert(Tamias.NotAgent.selector);
        t.toGateway(1, "");
    }

    function test_authorizeIntent_recallIsSignedOnlyAfterChecks() public {
        Tamias.BurnIntent memory bi = _recall(1e6);
        bytes32 d = t.intentDigest(bi);
        assertEq(t.isValidSignature(d, ""), bytes4(0xffffffff));
        vm.prank(agent);
        bytes32 got = t.authorizeIntent(bi, RECALL, "recall 1 USDC: payroll tomorrow");
        assertEq(got, d);
        assertEq(t.isValidSignature(d, hex"00"), bytes4(0x1626ba7e));
        assertEq(t.isValidSignature(keccak256("other"), ""), bytes4(0xffffffff));
        (,, uint256 spent,,,) = t.budgetOf(0);
        assertEq(spent, 0, "a recall spends no vendor budget");
        (,, spent,,,) = t.budgetOf(2);
        assertEq(spent, 0.005e6, "but its fee is charged to the Gateway fee budget");

        vm.prank(owner);
        t.revokeIntent(d);
        assertEq(t.isValidSignature(d, ""), bytes4(0xffffffff));
    }

    function test_authorizeIntent_rejectsAnythingElse() public {
        Tamias.BurnIntent memory bi;

        bi = _recall(1e6);
        bi.spec.destinationRecipient = _b(stranger);
        _expectBad(bi, RECALL, 8);

        bi = _recall(1e6);
        bi.spec.sourceDepositor = _b(stranger);
        _expectBad(bi, RECALL, 4);

        bi = _recall(1e6);
        bi.spec.sourceSigner = _b(agent);
        _expectBad(bi, RECALL, 4);

        bi = _recall(1e6);
        bi.spec.sourceContract = _b(stranger);
        _expectBad(bi, RECALL, 2);

        bi = _recall(1e6);
        bi.spec.sourceDomain = 0;
        _expectBad(bi, RECALL, 1);

        bi = _recall(1e6);
        bi.spec.sourceToken = _b(stranger);
        _expectBad(bi, RECALL, 3);

        bi = _recall(1e6);
        bi.spec.version = 2;
        _expectBad(bi, RECALL, 0);

        bi = _recall(1e6);
        bi.spec.hookData = hex"01";
        _expectBad(bi, RECALL, 5);

        bi = _recall(0);
        _expectBad(bi, RECALL, 6);

        bi = _recall(1e6);
        bi.maxFee = 0.02e6;
        _expectBad(bi, RECALL, 9);

        bi = _recall(1e6);
        bi.maxBlockHeight = block.number + IGatewayView(GATEWAY_WALLET).withdrawalDelay() + 200_001;
        _expectBad(bi, RECALL, 7);

        bi = _recall(1e6);
        bi.maxBlockHeight = block.number + IGatewayView(GATEWAY_WALLET).withdrawalDelay() - 1;
        _expectBad(bi, RECALL, 7);

        // a vendor intent may not be sent to a different payee's destination
        bi = _toVendor(1e6);
        bi.spec.destinationRecipient = _b(stranger);
        _expectBad(bi, 0, 11);
        bi = _toVendor(1e6);
        bi.spec.destinationDomain = ARC;
        _expectBad(bi, 0, 11);
        bi = _toVendor(1e6);
        _expectBad(bi, 1, 10);
        bi = _toVendor(1e6);
        bi.maxFee = 0.03e6;
        _expectBad(bi, 0, 9);
    }

    function _expectBad(Tamias.BurnIntent memory bi, uint256 payee, uint8 field) internal {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Tamias.BadIntent.selector, field));
        t.authorizeIntent(bi, payee, "");
    }

    function test_authorizeIntent_toPayeeIsBudgeted() public {
        Tamias.BurnIntent memory bi = _toVendor(1e6);
        vm.prank(agent);
        bytes32 d = t.authorizeIntent(bi, 0, "pay the Base vendor from the Gateway reserve");
        assertEq(t.isValidSignature(d, ""), bytes4(0x1626ba7e));
        (,, uint256 spent,,,) = t.budgetOf(0);
        assertEq(spent, 1.01e6, "value plus the most the fee can be");

        bi = _toVendor(1.5e6);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Tamias.OverPayeeLimit.selector, 1.51e6, 1.5e6));
        t.authorizeIntent(bi, 0, "");

        // a Gateway payee cannot be paid with `pay`
        vm.prank(agent);
        vm.expectRevert(Tamias.BadParams.selector);
        t.pay(0, USDC, 1e6, "");
    }

    function test_authorizeIntent_respectsFreezeAndRoles() public {
        Tamias.BurnIntent memory bi = _recall(1e6);
        vm.prank(stranger);
        vm.expectRevert(Tamias.NotAgent.selector);
        t.authorizeIntent(bi, RECALL, "");
        vm.prank(owner);
        t.setFrozen(true);
        vm.prank(agent);
        vm.expectRevert(Tamias.Frozen.selector);
        t.authorizeIntent(bi, RECALL, "");
    }

    function test_authorizeIntent_needsGatewayConfigured() public {
        vm.prank(owner);
        t.setGateway(Tamias.GatewayConfig(address(0), address(0), 0, 0, 0, 0, 0));
        Tamias.BurnIntent memory bi = _recall(1e6);
        vm.prank(agent);
        vm.expectRevert(Tamias.BadParams.selector);
        t.authorizeIntent(bi, RECALL, "");
        vm.prank(agent);
        vm.expectRevert(Tamias.BadParams.selector);
        t.toGateway(1e6, "");
    }

    // ── Gateway deposit for another account (the agent's x402 / nanopayment budget) ──

    function test_gatewayDepositPayee_fundsTheAgentsBuyerBalance() public {
        vm.prank(agent);
        t.pay(1, USDC, 0.3e6, "top up my x402 data budget");
        assertEq(IGatewayView(GATEWAY_WALLET).availableBalance(USDC, agent), 0.3e6);
        assertEq(IGatewayView(GATEWAY_WALLET).availableBalance(USDC, address(t)), 0);
        (,, uint256 spent,,,) = t.budgetOf(1);
        assertEq(spent, 0.3e6);
        assertEq(IERC20(USDC).balanceOf(address(t)), 9.7e6);
    }

    // ── CCTP ──

    function test_cctpPayee_burnsForTheVendorOnBase() public {
        uint256 before = IERC20(USDC).balanceOf(address(t));
        vm.recordLogs();
        vm.prank(agent);
        t.pay(2, USDC, 1e6, "vendor invoices on Base");
        assertEq(before - IERC20(USDC).balanceOf(address(t)), 1e6);
        // the messenger is left with no allowance
        (bool ok, bytes memory ret) =
            USDC.staticcall(abi.encodeWithSignature("allowance(address,address)", address(t), TOKEN_MESSENGER));
        assertTrue(ok);
        assertEq(abi.decode(ret, (uint256)), 0);
        assertGt(vm.getRecordedLogs().length, 2, "burn and message events emitted");
    }

    // ── ERC-4626 vault (Morpho via App Kit Earn) ──

    function test_vault_parkAndRedeem() public {
        vm.prank(agent);
        t.toVault(0, 2e6, "idle for a week: earn on it");
        uint256 held = IVaultView(STEAKHOUSE_USDC).convertToAssets(IVaultView(STEAKHOUSE_USDC).balanceOf(address(t)));
        assertApproxEqAbs(held, 2e6, 2);
        assertEq(t.cash(), 8e6);

        vm.prank(agent);
        vm.expectRevert();
        t.toVault(0, 1.5e6, ""); // cap 3

        vm.prank(agent);
        t.fromVault(0, 1e6, "forecast needs it back");
        assertEq(t.cash(), 9e6);

        // an inactive vault takes no more money but still gives it back
        Tamias.Vault memory v = t.getVault(0);
        v.active = false;
        vm.prank(owner);
        t.setVault(0, v);
        vm.prank(agent);
        vm.expectRevert(Tamias.Inactive.selector);
        t.toVault(0, 0.1e6, "");
        vm.prank(agent);
        t.fromVault(0, 0.9e6, "closing the position");
        assertEq(t.cash(), 9.9e6);
    }

    function test_setVault_requiresAUsdcVault() public {
        vm.startPrank(owner);
        vm.expectRevert(Tamias.BadParams.selector);
        t.setVault(1, Tamias.Vault(stranger, true, 1, "eoa"));
        vm.expectRevert(); // EURC has no asset()
        t.setVault(1, Tamias.Vault(0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1, true, 1, "not a vault"));
        vm.stopPrank();
    }

    function test_setGateway_andPayee_validate() public {
        vm.startPrank(owner);
        vm.expectRevert(Tamias.BadParams.selector);
        t.setGateway(Tamias.GatewayConfig(stranger, GATEWAY_MINTER, ARC, 0, 0, 0, 0));
        vm.expectRevert(Tamias.UnknownId.selector); // the fee category must exist
        t.setGateway(Tamias.GatewayConfig(GATEWAY_WALLET, GATEWAY_MINTER, ARC, 0, 0, 0, 9));
        vm.expectRevert(Tamias.BadParams.selector);
        t.setPayee(3, _p(vendor, GATEWAY_MINTER, BASE, Tamias.Kind.Gateway, 0, 1e6, 0, address(0), "no token"));
        // a Gateway payee's minter lives on another chain, so it need not have code here
        t.setPayee(3, _p(vendor, address(0xBEEF), BASE, Tamias.Kind.Gateway, 0, 1e6, 0, BASE_USDC, "ok"));
        vm.stopPrank();
    }
}
