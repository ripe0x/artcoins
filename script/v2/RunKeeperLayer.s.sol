// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// targets the SUPERSEDED legacy stack (LAYER: locker 0x75BE, fee locker 0x1143, controller 0x5fDc, routers).
// mainnet runs are refused unless ALLOW_SUPERSEDED=1. addresses come from script/Addresses.sol (registry).

import {CollectFlushKeeperLayer} from "../../src/v2/keepers/CollectFlushKeeperLayer.sol";
import {Addresses} from "../Addresses.sol";
import {Script, console2} from "forge-std/Script.sol";

abstract contract SupersededGuard is Script {
    function _guard() internal view {
        require(block.chainid == Addresses.CHAIN_ID, "mainnet only");
        require(
            vm.envOr("ALLOW_SUPERSEDED", uint256(0)) == 1,
            "targets the superseded legacy stack; set ALLOW_SUPERSEDED=1"
        );
    }
}

/// @notice Deploys `CollectFlushKeeperLayer` pinned to the live LAYER fee path. Dry run unless the operator
///         passes `--broadcast` and a signer.
///         ALLOW_SUPERSEDED=1 forge script script/v2/RunKeeperLayer.s.sol:DeployKeeperLayer --rpc-url $MAINNET_RPC_URL
contract DeployKeeperLayer is SupersededGuard {
    function run() external returns (CollectFlushKeeperLayer keeper) {
        _guard();
        vm.startBroadcast();
        keeper = new CollectFlushKeeperLayer(
            Addresses.LEGACY_LOCKER,
            Addresses.COIN_LAYER,
            Addresses.WETH,
            Addresses.LEGACY_FEE_LOCKER,
            Addresses.LEGACY_PROTOCOL_FEE_CONTROLLER,
            [Addresses.LEGACY_BURN_ROUTER, Addresses.OPEN_BURN_ROUTER, Addresses.CURRENT_BURN_ROUTER]
        );
        vm.stopBroadcast();
        console2.log("CollectFlushKeeperLayer", address(keeper));
    }
}

/// @notice Runs a deployed keeper: prints `preview()`, quotes the LAYER per weth rate from a simulated run,
///         calls `run(doBurn, rate, unwrap)`. Env: `KEEPER_LAYER` (required), `KEEPER_SLIPPAGE_BPS` (default
///         200), `KEEPER_DO_BURN` (default true), `KEEPER_UNWRAP` (default true).
///         ALLOW_SUPERSEDED=1 forge script script/v2/RunKeeperLayer.s.sol:RunKeeperLayer --rpc-url $MAINNET_RPC_URL
///         ... --broadcast --account <keystore> --gas-limit 3000000                       (live)
contract RunKeeperLayer is SupersededGuard {
    receive() external payable {}

    function run() external {
        _guard();
        CollectFlushKeeperLayer keeper =
            CollectFlushKeeperLayer(payable(vm.envAddress("KEEPER_LAYER")));
        uint256 slippageBps = vm.envOr("KEEPER_SLIPPAGE_BPS", uint256(200));
        require(slippageBps <= 1000, "slippage > 10%");
        bool doBurn = vm.envOr("KEEPER_DO_BURN", true);
        _logPreview(keeper);
        uint256 rate = doBurn ? quoteRate(keeper, slippageBps) : 0;
        console2.log("rate (LAYER per 1e18 weth, 0 = router floors)", rate);

        vm.startBroadcast();
        (uint256 lc, uint256 wc, uint256 lbd, uint256 wb, uint256 lb) =
            keeper.run(doBurn, rate, vm.envOr("KEEPER_UNWRAP", true));
        vm.stopBroadcast();
        console2.log("collected LAYER, weth", lc, wc);
        console2.log("LAYER burned direct", lbd);
        console2.log("weth burned, LAYER bought and burned", wb, lb);
    }

    /// @notice Rate for `run`: simulate the whole run at current state (reverted after) with rate 0, so each
    ///         router applies its own floor, take the realized LAYER per weth of the weth burns, subtract
    ///         `slippageBps`. 0 when the simulation burns no weth (all routers under threshold or blocked);
    ///         the router floors still apply then.
    function quoteRate(CollectFlushKeeperLayer keeper, uint256 slippageBps)
        public
        returns (uint256)
    {
        uint256 snap = vm.snapshotState();
        (,,, uint256 wb, uint256 lb) = keeper.run(true, 0, false);
        vm.revertToState(snap);
        if (wb == 0) return 0;
        return lb * 1e18 / wb * (10_000 - slippageBps) / 10_000;
    }

    function _logPreview(CollectFlushKeeperLayer keeper) internal view {
        (uint256 ul, uint256 uw, uint256[4] memory c, uint256[3] memory rw, uint256[3] memory rt) =
            keeper.preview();
        console2.log("uncollected LAYER, weth", ul, uw);
        console2.log("fee locker controller slot LAYER, weth", c[0], c[1]);
        console2.log("fee locker router slot LAYER, weth", c[2], c[3]);
        console2.log("router 0x2eDB weth+eth / threshold", rw[0], rt[0]);
        console2.log("router 0xE600 weth+eth / threshold", rw[1], rt[1]);
        console2.log("router 0x0EB2 weth+eth / threshold", rw[2], rt[2]);
    }
}
