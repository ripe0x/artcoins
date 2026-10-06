// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CollectFlushKeeperV1} from "../../src/v2/keepers/CollectFlushKeeperV1.sol";
import {IFeeAutoSwapper} from "../../src/interfaces/IFeeAutoSwapper.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Script, console2} from "forge-std/Script.sol";

interface ISwapperLimits {
    function maxStepIn() external view returns (uint256);
}

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
    using PoolIdLibrary for PoolKey;

    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);

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
        if (converted == 0) console2.log("convert skipped (min blocks, nothing to convert or minOut not met)");
    }

    /// @notice minOut for `convert`: simulate collect (state reverted after), take the coin the swapper will
    ///         convert (capped by maxStepIn), value it at pool spot, subtract `slippageBps`. Spot ignores the
    ///         pool fee and coin tax, so a tight slippage makes convert revert (swallowed, converted 0).
    function quoteMinOut(CollectFlushKeeperV1 keeper, uint256 slippageBps) public returns (uint256) {
        IFeeAutoSwapper swapper = keeper.swapper();
        uint256 snap = vm.snapshotState();
        keeper.run(false, 0);
        uint256 coinIn = swapper.accruedArtCoin();
        vm.revertToState(snap);
        uint256 cap = ISwapperLimits(address(swapper)).maxStepIn();
        if (coinIn > cap) coinIn = cap;
        (uint160 sqrtP,,,) = POOL_MANAGER.getSlot0(swapper.poolKey().toId());
        // coin is currency1: price(coin per eth) = sqrtP^2 / 2^192, so eth = coin * 2^192 / sqrtP^2
        uint256 ethAtSpot = FullMath.mulDiv(FullMath.mulDiv(coinIn, 1 << 96, sqrtP), 1 << 96, sqrtP);
        return ethAtSpot * (10_000 - slippageBps) / 10_000;
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
