// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ArtCoinsHook} from "./ArtCoinsHook.sol";
import {IArtCoinsHookStaticFee} from "./interfaces/IArtCoinsHookStaticFee.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title  ArtCoinsHookStaticFee
/// @notice Concrete static-fee variant of `ArtCoinsHook`. Inherits from
///         `ArtCoinsHook`, which allows native-ETH-paired pools.
/// @dev    Applies a fixed LP fee per swap direction (ArtCoins-in vs paired-in).
contract ArtCoinsHookStaticFee is ArtCoinsHook, IArtCoinsHookStaticFee {
    /// @notice Fee charged when buying ArtCoins.
    mapping(PoolId => uint24) public artCoinFee;
    /// @notice Fee charged when selling ArtCoins for paired token.
    mapping(PoolId => uint24) public pairedFee;

    /// @param _poolManager Uniswap v4 pool manager.
    /// @param _factory The ArtCoins factory.
    /// @param _poolExtensionAllowlist Pool-extension allowlist contract.
    /// @param _weth WETH address (used by `initializePoolOpen`'s
    ///        `artCoin == weth` guard, unrelated to native-ETH pairing).
    /// @param _feeEscrow Fee escrow that native-ETH sniper-extra fees route
    ///        through. Escrow must allowlist this hook as depositor.
    constructor(
        address _poolManager,
        address _factory,
        address _poolExtensionAllowlist,
        address _weth,
        address _feeEscrow
    ) ArtCoinsHook(_poolManager, _factory, _poolExtensionAllowlist, _weth, _feeEscrow) {}

    function _initializeFeeData(PoolKey memory poolKey, bytes memory feeData) internal override {
        PoolStaticConfigVars memory _poolConfigVars = abi.decode(feeData, (PoolStaticConfigVars));

        if (_poolConfigVars.artCoinFee > MAX_LP_FEE) {
            revert ArtCoinsFeeTooHigh();
        }

        if (_poolConfigVars.pairedFee > MAX_LP_FEE) {
            revert PairedFeeTooHigh();
        }

        artCoinFee[poolKey.toId()] = _poolConfigVars.artCoinFee;
        pairedFee[poolKey.toId()] = _poolConfigVars.pairedFee;

        emit PoolInitialized(poolKey.toId(), _poolConfigVars.artCoinFee, _poolConfigVars.pairedFee);
    }

    /// @dev Sets the dynamic LP fee per swap direction using the configured static fees.
    function _setFee(PoolKey calldata poolKey, IPoolManager.SwapParams calldata swapParams)
        internal
        override
    {
        uint24 fee = swapParams.zeroForOne != artCoinIsToken0[poolKey.toId()]
            ? pairedFee[poolKey.toId()]
            : artCoinFee[poolKey.toId()];

        IPoolManager(poolManager).updateDynamicLPFee(poolKey, fee);
    }
}
