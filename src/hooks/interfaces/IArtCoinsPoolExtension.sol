// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsFactory} from "../../interfaces/IArtCoinsFactory.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @title IArtCoinsPoolExtension
/// @notice Interface for pool extensions invoked by `ArtCoinsHook` around swaps.
interface IArtCoinsPoolExtension {
    /// @notice Reverts when a hook-only function is called by another address.
    error OnlyHook();

    /// @notice Called once by the hook during pool initialization, before the locker is set up.
    /// @param poolKey The pool key.
    /// @param artCoinIsToken0 True if ArtCoins is token0.
    /// @param poolExtensionInitData Extension-specific init data.
    function initializePreLockerSetup(
        PoolKey calldata poolKey,
        bool artCoinIsToken0,
        bytes calldata poolExtensionInitData
    ) external;

    /// @notice Called once by the hook after the locker is set up (during MEV module init).
    /// @param poolKey The pool key.
    /// @param locker The locker contract address.
    /// @param artCoinIsToken0 True if ArtCoins is token0.
    function initializePostLockerSetup(
        PoolKey calldata poolKey,
        address locker,
        bool artCoinIsToken0
    ) external;

    /// @notice Called by the hook after each swap (in a try/catch) to run extension logic.
    /// @param poolKey The pool key.
    /// @param swapParams The swap params.
    /// @param delta The balance delta produced by the swap.
    /// @param artCoinIsToken0 True if ArtCoins is token0.
    /// @param poolExtensionSwapData Extension-specific swap data.
    function afterSwap(
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta,
        bool artCoinIsToken0,
        bytes calldata poolExtensionSwapData
    ) external;

    /// @notice ERC-165 introspection.
    /// @param interfaceId The interface id.
    /// @return True if supported.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool);
}
