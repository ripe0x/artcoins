// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CollectFlushKeeperV1} from "../../src/legacy/keepers/CollectFlushKeeperV1.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @notice Deploys `CollectFlushKeeperV1` pinned to the live coin 111 stack. Dry run unless the operator
///         passes `--broadcast` (and a signer: `--account`, `--ledger` or `--private-key`).
///         forge script script/v2/RunKeeper111.s.sol:DeployKeeper111 --rpc-url $MAINNET_RPC_URL
contract DeployKeeper111 is Script {
    // deployments/mainnet.json (current stack: locker, escrow); coin 111 and its fee swapper (locker reward recipient)
    address internal constant LOCKER = 0x866ea3Dc2bf7A3e77374619cf50EB697FA766aab;
    address internal constant COIN = 0x61C9d89fe1212F6b55fF888816A151463287B8ae;
    address internal constant SWAPPER = 0xeBD9B74A4c26C6E54e83C84CB247c069eC42A961;
    address internal constant ESCROW = 0x7559689765aE86cBB38e68CD1294830CccB125F2;

    function run() external returns (CollectFlushKeeperV1 keeper) {
        require(block.chainid == 1, "mainnet only");
        vm.startBroadcast();
        keeper = new CollectFlushKeeperV1(LOCKER, COIN, SWAPPER, ESCROW);
        vm.stopBroadcast();
        console2.log("CollectFlushKeeperV1", address(keeper));
    }
}

/// @notice Runs a deployed keeper: prints `preview()`, quotes `minOut` from pool spot minus slippage, calls
///         `run(true, minOut)`. Env: `KEEPER_111` (required), `KEEPER_SLIPPAGE_BPS` (default 100).
///         forge script script/v2/RunKeeper111.s.sol:RunKeeper111 --rpc-url $MAINNET_RPC_URL            (dry run)
///         ... --broadcast --account <keystore>                                                          (live)
///         Nothing is sent unless `--broadcast` is passed. Give the tx at least 1.2M gas (the keeper reverts
///         on a gas shortfall rather than skipping a step).
contract RunKeeper111 is Script {
    receive() external payable {}

    function run() external {
        CollectFlushKeeperV1 keeper = CollectFlushKeeperV1(payable(vm.envAddress("KEEPER_111")));
        uint256 slippageBps = vm.envOr("KEEPER_SLIPPAGE_BPS", uint256(100));
        require(slippageBps <= 1000, "slippage > 10%");
        _logPreview(keeper);
        uint256 minOut = quoteMinOut(keeper, slippageBps);
        console2.log("minOut (wei)", minOut);

        vm.startBroadcast();
        (uint256 collected, uint256 flushed, uint256 converted) = keeper.run(true, minOut);
        vm.stopBroadcast();
        console2.log("collected", collected);
        console2.log("flushed", flushed);
        console2.log("converted", converted);
        if (converted == 0) {
            console2.log("convert skipped (min blocks, nothing to convert or minOut not met)");
        }
    }

    /// @notice minOut for `convert`: simulate the whole run at the current state (state reverted after) with
    ///         minOut 0, take the eth the swap would return, subtract `slippageBps`. A spot quote is not used:
    ///         the live pool's dynamic fee and skim put realized output several percent under spot.
    ///         Returns 0 when the simulation converts nothing (min blocks not elapsed, no coin).
    function quoteMinOut(CollectFlushKeeperV1 keeper, uint256 slippageBps)
        public
        returns (uint256)
    {
        uint256 snap = vm.snapshotState();
        (,, uint256 simulated) = keeper.run(true, 0);
        vm.revertToState(snap);
        return simulated * (10_000 - slippageBps) / 10_000;
    }

    function _logPreview(CollectFlushKeeperV1 keeper) internal view {
        (uint256 ue, uint256 uc, uint256 esc, uint256 se, uint256 sc) = keeper.preview();
        console2.log("uncollected eth", ue);
        console2.log("uncollected coin", uc);
        console2.log("escrowed eth (flushable)", esc);
        console2.log("swapper eth (stranded if > 0)", se);
        console2.log("swapper coin (convertible)", sc);
    }
}
