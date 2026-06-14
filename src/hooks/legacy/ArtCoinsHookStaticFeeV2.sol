// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsHookStaticFee} from "../interfaces/IArtCoinsHookStaticFee.sol";
import {ArtCoinsHookV2} from "./ArtCoinsHookV2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title ArtCoinsHookStaticFeeV2
/// @notice Hook variant that applies a fixed LP fee per swap direction (ArtCoins-in vs paired-in).
contract ArtCoinsHookStaticFeeV2 is ArtCoinsHookV2, IArtCoinsHookStaticFee {
    /// @notice Fee charged when buying ArtCoins.
    mapping(PoolId => uint24) public artCoinFee;
    /// @notice Fee charged when selling ArtCoins for paired token.
    mapping(PoolId => uint24) public pairedFee;

    /// @param _poolManager Uniswap v4 pool manager.
    /// @param _factory The ArtCoins factory.
    /// @param _poolExtensionAllowlist Pool-extension allowlist contract.
    /// @param _weth WETH address.
    constructor(
        address _poolManager,
        address _factory,
        address _poolExtensionAllowlist,
        address _weth
    ) ArtCoinsHookV2(_poolManager, _factory, _poolExtensionAllowlist, _weth) {}

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

        _setProtocolFee(fee);
        IPoolManager(poolManager).updateDynamicLPFee(poolKey, fee);
    }
}
