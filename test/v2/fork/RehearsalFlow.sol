// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {DeployV2Lib} from "../../../script/v2/DeployV2Lib.sol";
import {LaunchV2Lib} from "../../../script/v2/LaunchV2Coin.s.sol";
import {Constants} from "../../../src/Constants.sol";
import {IArtCoinsHook} from "../../../src/interfaces/IArtCoinsHook.sol";
import {IArtCoinsFactoryV2} from "../../../src/v2/interfaces/IArtCoinsFactoryV2.sol";
import {IArtCoinsFeeEscrowV2} from "../../../src/v2/interfaces/IArtCoinsFeeEscrowV2.sol";
import {IArtCoinsHookV2} from "../../../src/v2/interfaces/IArtCoinsHookV2.sol";
import {IArtCoinsLpLockerV2} from "../../../src/v2/interfaces/IArtCoinsLpLockerV2.sol";
import {BurnRouterV2} from "../../../src/v2/protocol-fee/BurnRouterV2.sol";
import {ProtocolFeeControllerV2} from "../../../src/v2/protocol-fee/ProtocolFeeControllerV2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

struct FcExactIn {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    bytes hookData;
}

interface IFcUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline)
        external
        payable;
}

interface IFcPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// Treasury stand in: accepts eth within the 2300 gas stipend.
contract FcTreasury {
    receive() external payable virtual {}
}

/// Recipient that reverts on eth, so the hook falls back to the escrow.
contract FcRejecter {
    function claimTo(IArtCoinsFeeEscrowV2 e, address to) external {
        e.claimTo(address(this), address(0), payable(to));
    }
}

/// @notice RUNBOOK gate 7 sequence, shared by the rehearsal against the deployed stack and the
///         rehearsal against a freshly deployed stack: launch, swaps through the Universal Router,
///         escrow claim, `processFees()`, `processBurn(minOut)`.
abstract contract RehearsalFlow is Test {
    using PoolIdLibrary for PoolKey;

    address internal constant FC_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant FC_UR = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address internal constant FC_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint256 internal constant FC_TX_CAP = 16_700_000;

    /// @dev Addresses of one v2 stack.
    struct Rig {
        IArtCoinsFactoryV2 factory;
        address hook;
        address locker;
        address mev;
        IArtCoinsFeeEscrowV2 escrow;
        ProtocolFeeControllerV2 controller;
        BurnRouterV2 router;
        address layer;
        /// @dev Sender of the launch (factory owner while the factory is deprecated).
        address launcher;
    }

    receive() external payable virtual {}

    function _target(Rig memory r) internal pure returns (LaunchV2Lib.Target memory t) {
        t = LaunchV2Lib.Target(address(r.factory), r.hook, r.locker, r.mev);
    }

    // ── launch ────────────────────────────────────────────────────────────

    /// @dev Launches `l` from `r.launcher`, asserts the launch record, returns the coin and its pool.
    function _launchChecked(Rig memory r, LaunchV2Lib.Launch memory l)
        internal
        returns (address token, PoolKey memory key)
    {
        LaunchV2Lib.Target memory t = _target(r);
        (address predicted, uint256 value) = LaunchV2Lib.preflight(t, l, r.launcher);
        bytes32 cfgHash = r.factory.configHash(l.cfg);
        vm.deal(r.launcher, r.launcher.balance + value);

        vm.recordLogs();
        vm.prank(r.launcher);
        uint256 g = gasleft();
        token = r.factory.deployToken{value: value}(l.cfg);
        g -= gasleft();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        console2.log("launch gas", g);
        console2.log("launch gas headroom to 16.7M cap", FC_TX_CAP > g ? FC_TX_CAP - g : 0);
        assertLt(g, FC_TX_CAP, "launch gas above tx cap");
        assertEq(token, predicted, "token != predicted");
        PoolId pid = LaunchV2Lib.checkLaunched(t, l, token);
        assertTrue(r.factory.isCoin(token), "isCoin");
        assertEq(IArtCoinsHookV2(r.hook).poolInfo(pid).version, 2, "hook version");
        key = IArtCoinsLpLockerV2(r.locker).lockedLiquidity(token).poolKey;
        assertEq(PoolId.unwrap(key.toId()), PoolId.unwrap(pid), "pool id");

        _checkCreatedEvent(r, logs, token, pid, cfgHash);
        _checkExtensions(r, l, logs, token);
    }

    function _checkCreatedEvent(
        Rig memory r,
        Vm.Log[] memory logs,
        address token,
        PoolId pid,
        bytes32 cfgHash
    ) internal view {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(r.factory)) continue;
            if (logs[i].topics[0] != IArtCoinsFactoryV2.TokenCreatedV2.selector) continue;
            ++n;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), r.launcher, "event sender");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), token, "event token");
            assertEq(logs[i].topics[3], PoolId.unwrap(pid), "event poolId");
            (
                uint16 stackVersion,
                bytes32 h,
                address protocolRecipient,
                uint256 poolSupply,
                uint256 extensionsSupply
            ) = abi.decode(logs[i].data, (uint16, bytes32, address, uint256, uint256));
            assertEq(stackVersion, Constants.STACK_VERSION, "event stackVersion");
            assertEq(h, cfgHash, "event configHash");
            assertEq(protocolRecipient, address(r.controller), "event protocolRecipient");
            assertEq(
                poolSupply + extensionsSupply, IERC20(token).totalSupply(), "event supply split"
            );
        }
        assertEq(n, 1, "one TokenCreatedV2");
    }

    /// @dev One ExtensionTriggered per configured extension (airdrop, vault, dev buy) in config
    ///      order, with its supply floor and eth. An empty extension list expects zero events.
    function _checkExtensions(
        Rig memory r,
        LaunchV2Lib.Launch memory l,
        Vm.Log[] memory logs,
        address token
    ) internal view {
        uint256 total = IERC20(token).totalSupply();
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(r.factory)) continue;
            if (logs[i].topics[0] != IArtCoinsFactoryV2.ExtensionTriggered.selector) continue;
            IArtCoinsFactoryV2.ExtensionConfigV2 memory e = l.cfg.extensions[seen];
            assertEq(address(uint160(uint256(logs[i].topics[1]))), token, "ext token");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), e.extension, "ext address");
            (uint256 supply, uint256 msgValue) = abi.decode(logs[i].data, (uint256, uint256));
            assertEq(supply, (total * e.extensionBps) / Constants.BPS, "ext supply share");
            assertEq(msgValue, e.msgValue, "ext msgValue");
            ++seen;
        }
        assertEq(seen, l.cfg.extensions.length, "ExtensionTriggered count");
    }

    // ── swaps through the live universal router ───────────────────────────

    function _urBuy(PoolKey memory key, uint256 ethIn, bytes memory hookData)
        internal
        returns (uint256 got)
    {
        address coin = Currency.unwrap(key.currency1);
        bytes memory actions = abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(FcExactIn(key, true, uint128(ethIn), 0, hookData));
        params[1] = abi.encode(key.currency0, ethIn);
        params[2] = abi.encode(key.currency1, uint256(0));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(actions, params);
        inputs[1] = abi.encode(address(0), address(this), uint256(0));
        vm.deal(address(this), address(this).balance + ethIn);
        uint256 c0 = IERC20(coin).balanceOf(address(this));
        uint256 g = gasleft();
        IFcUniversalRouter(FC_UR).execute{value: ethIn}(
            abi.encodePacked(uint8(0x10), uint8(0x04)), inputs, block.timestamp
        );
        g -= gasleft();
        got = IERC20(coin).balanceOf(address(this)) - c0;
        console2.log("buy gas", g);
        assertGt(got, 0, "buy got nothing");
        assertEq(FC_UR.balance, 0, "universal router holds no eth");
    }

    function _urSell(PoolKey memory key, uint256 coinIn, bytes memory hookData)
        internal
        returns (uint256 got)
    {
        address coin = Currency.unwrap(key.currency1);
        IERC20(coin).approve(FC_PERMIT2, type(uint256).max);
        IFcPermit2(FC_PERMIT2)
            .approve(coin, FC_UR, type(uint160).max, uint48(block.timestamp + 1 days));
        bytes memory actions = abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(FcExactIn(key, false, uint128(coinIn), 0, hookData));
        params[1] = abi.encode(key.currency1, coinIn);
        params[2] = abi.encode(key.currency0, uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        uint256 e0 = address(this).balance;
        uint256 g = gasleft();
        IFcUniversalRouter(FC_UR).execute(abi.encodePacked(uint8(0x10)), inputs, block.timestamp);
        g -= gasleft();
        got = address(this).balance - e0;
        console2.log("sell gas", g);
        assertGt(got, 0, "sell got nothing");
    }

    /// @dev Hook data naming `to` as the refund address.
    function _refundData(address to) internal pure returns (bytes memory) {
        return abi.encode(
            IArtCoinsHook.PoolSwapData({
                mevModuleSwapData: abi.encode(to), poolExtensionSwapData: ""
            })
        );
    }

    /// @dev Buy inside the anti sniper window, buy after it, sell a quarter. Returns coin held.
    function _flow(PoolKey memory key, address token, bytes memory hookData)
        internal
        returns (uint256 coinHeld)
    {
        _urBuy(key, 0.5 ether, hookData);
        vm.warp(block.timestamp + 5000);
        vm.roll(block.number + 400);
        _urBuy(key, 0.5 ether, hookData);
        coinHeld = IERC20(token).balanceOf(address(this));
        _urSell(key, coinHeld / 4, hookData);
    }

    // ── the sequence ──────────────────────────────────────────────────────

    /// @notice RUNBOOK 2b steps 3 to 7 in order. `l.cfg.fee.bountyRecipient` is replaced by a
    ///         contract that rejects eth, so its bounty is credited in the escrow and claimable.
    function _rehearse(Rig memory r, LaunchV2Lib.Launch memory l) internal {
        FcRejecter rej = new FcRejecter();
        l.cfg.fee.bountyRecipient = payable(address(rej));
        address refundTo = makeAddr("rehearsal.refund");

        // launch config hash, TokenCreatedV2 fields, gas, extensions
        (address token, PoolKey memory key) = _launchChecked(r, l);
        assertEq(r.escrow.balances(address(rej), address(0)), 0, "no credit before swaps");
        assertEq(r.escrow.balances(refundTo, address(0)), 0, "refund address credit at launch");

        // Universal Router buy and sell with a refund address in hookData
        uint256 held = _flow(key, token, _refundData(refundTo));
        assertGt(held, 0, "coin held");
        assertEq(r.escrow.balances(refundTo, address(0)), 0, "full fills credit no refund");
        assertEq(refundTo.balance, 0, "full fills pay no refund");

        // escrow claim by the credited recipient
        uint256 credit = r.escrow.balances(address(rej), address(0));
        console2.log("escrow credit of the rejecting bounty recipient", credit);
        assertGt(credit, 0, "bounty credited to escrow");
        address payee = makeAddr("rehearsal.payee");
        rej.claimTo(r.escrow, payee);
        assertEq(payee.balance, credit, "claimTo paid");
        assertEq(r.escrow.balances(address(rej), address(0)), 0, "credit cleared");

        _processFees(r);
        _processBurn(r);
    }

    /// @dev Exact split of everything the controller holds or is owed. The burn leg is the
    ///      remainder after the treasury share, so rounding dust goes to the burn router.
    function _processFees(Rig memory r) internal {
        ProtocolFeeControllerV2 c = r.controller;
        address treasury = c.treasury();
        address router = c.burnRouter();
        assertEq(c.treasuryBps(), DeployV2Lib.TREASURY_BPS, "split at launch value");

        uint256 pending = c.pending();
        console2.log("controller pending", pending);
        assertGt(pending, 0, "protocol fees accrued");
        uint256 treasuryAmount = (pending * c.treasuryBps()) / Constants.BPS;
        uint256 burnAmount = pending - treasuryAmount;

        uint256 t0 = treasury.balance + r.escrow.balances(treasury, address(0));
        uint256 r0 = router.balance;
        vm.prank(makeAddr("rehearsal.keeper"));
        c.processFees();

        assertEq(
            treasury.balance + r.escrow.balances(treasury, address(0)) - t0,
            treasuryAmount,
            "treasury leg (paid or credited)"
        );
        assertEq(router.balance - r0, burnAmount, "burn leg incl. dust");
        assertEq(address(c).balance, 0, "controller drained");
        assertEq(c.pending(), 0, "nothing pending");
    }

    /// @dev `processBurn(minOut)` with the router's own floor for the current budget.
    function _processBurn(Rig memory r) internal {
        BurnRouterV2 router = r.router;
        vm.roll(block.number + 1);
        uint256 budget = router.swapBudget();
        assertGt(budget, 0, "burn budget");
        uint256 minOut = router.floorFor(budget);
        assertGt(minOut, 0, "burn floor");
        uint256 supply0 = IERC20(r.layer).totalSupply();
        uint256 inventory = address(router).balance + IERC20(FC_WETH).balanceOf(address(router));

        vm.prank(makeAddr("rehearsal.keeper"));
        (uint256 wethIn, uint256 burned) = router.processBurn(minOut);

        console2.log("burn wethIn", wethIn);
        console2.log("burn LAYER burned", burned);
        console2.log("router eth after", address(router).balance);
        console2.log("router weth after", IERC20(FC_WETH).balanceOf(address(router)));
        assertGe(burned, minOut, "floor enforced");
        assertLe(wethIn, budget, "spent within budget");
        assertEq(IERC20(r.layer).totalSupply(), supply0 - burned, "LAYER supply reduced by burned");
        assertEq(IERC20(r.layer).balanceOf(address(router)), 0, "no LAYER left in router");
        assertEq(address(router).balance, 0, "router eth wrapped");
        assertLe(IERC20(FC_WETH).balanceOf(address(router)), inventory - wethIn, "weth accounted");
    }
}
