// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsHook} from "../interfaces/IArtCoinsHook.sol";
import {IArtCoinsMevModule} from "../interfaces/IArtCoinsMevModule.sol";
import {IArtCoinsMevModuleBase} from "../interfaces/IArtCoinsMevModuleBase.sol";
import {IArtCoinsMevDescendingFees} from "./interfaces/IArtCoinsMevDescendingFees.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/*
 .--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--.
/ .. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \
\ \/\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ \/ /
 \/ /`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'\/ /
 / /\  ````````````````````````````````````````````````````````````````````````````````````  / /\
/ /\ \ ```````````````````````````````````````````````````````````````````````````````````` / /\ \
\ \/ / ```````::::::::``:::````````````:::`````::::````:::`:::````:::`::::::::::`:::::::::` \ \/ /
 \/ /  `````:+:````:+:`:+:``````````:+:`:+:```:+:+:```:+:`:+:```:+:``:+:````````:+:````:+:`  \/ /
 / /\  ````+:+````````+:+`````````+:+```+:+``:+:+:+``+:+`+:+``+:+```+:+````````+:+````+:+``  / /\
/ /\ \ ```+#+````````+#+````````+#++:++#++:`+#+`+:+`+#+`+#++:++````+#++:++#```+#++:++#:```` / /\ \
\ \/ / ``+#+````````+#+````````+#+`````+#+`+#+``+#+#+#`+#+``+#+```+#+````````+#+````+#+```` \ \/ /
 \/ /  `#+#````#+#`#+#````````#+#`````#+#`#+#```#+#+#`#+#```#+#``#+#````````#+#````#+#`````  \/ /
 / /\  `########``##########`###`````###`###````####`###````###`##########`###````###``````  / /\
/ /\ \ ```````````````````````````````````````````````````````````````````````````````````` / /\ \
\ \/ / ```````````````````````````````````````````````````````````````````````````````````` \ \/ /
 \/ /  ````````````````````````````````````````````````````````````````````````````````````  \/ /
 / /\.--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--./ /\
/ /\ \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \/\ \
\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `' /
 `--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'
*/

/// @title ArtCoinsMevDescendingFees
/// @notice MEV module that quadratically decays a per-pool fee from a starting fee to an
///         ending fee over a configured number of seconds.
/// @dev Same-second-as-deployment swaps are rejected. After decay completes, the module
///      disables itself and the pool reverts to its base fee.
contract ArtCoinsMevDescendingFees is IArtCoinsMevDescendingFees {
    /// @notice Per-pool fee configuration.
    mapping(PoolId poolId => FeeConfig feeConfig) public feeConfig;
    /// @notice Per-pool block timestamp when the module was initialized.
    mapping(PoolId poolId => uint256 poolStartTime) public poolStartTime;

    /// @notice Seconds added to the start time before decay begins (anti-MEV guard).
    uint256 public delayGuard = 1;

    /// @dev Restricts a function to the pool's hook.
    modifier onlyHook(PoolKey calldata poolKey) {
        if (msg.sender != address(poolKey.hooks)) {
            revert OnlyHook();
        }
        _;
    }

    /// @notice Initializes the MEV module — called once per pool by the hook.
    /// @param poolKey The pool key.
    /// @param poolFeeConfig ABI-encoded `FeeConfig`.
    function initialize(PoolKey calldata poolKey, bytes calldata poolFeeConfig)
        external
        onlyHook(poolKey)
    {
        // only initialize once
        if (poolStartTime[poolKey.toId()] != 0) {
            revert PoolAlreadyInitialized();
        }

        // set pool's start time
        poolStartTime[poolKey.toId()] = block.timestamp;

        // decode the fee config
        FeeConfig memory feeConfigData = abi.decode(poolFeeConfig, (FeeConfig));

        // validate the fee config
        if (feeConfigData.secondsToDecay == 0) {
            revert TimeDecayMustBeGreaterThanZero();
        }
        if (feeConfigData.startingFee == 0) {
            revert StartingFeeMustBeGreaterThanZero();
        }
        if (feeConfigData.startingFee < feeConfigData.endingFee) {
            revert StartingFeeMustBeGreaterThanEndingFee();
        }

        // ensure the associated pool's hook implements the IArtCoinsHook interface
        if (!IArtCoinsHook(address(poolKey.hooks))
                .supportsInterface(type(IArtCoinsHook).interfaceId)) {
            revert OnlyArtCoinsHook();
        }

        // ensure the starting fee is not greater than the max mev LP fee
        if (feeConfigData.startingFee > IArtCoinsHook(address(poolKey.hooks)).MAX_MEV_LP_FEE()) {
            revert StartingFeeGreaterThanMaxLpFee();
        }

        // ensure the max time length is not longer than the max auction length
        if (
            feeConfigData.secondsToDecay
                > IArtCoinsHook(address(poolKey.hooks)).MAX_MEV_MODULE_DELAY()
        ) {
            revert TimeDecayLongerThanMaxMevDelay();
        }

        // set the fee config
        feeConfig[poolKey.toId()] = FeeConfig({
            startingFee: feeConfigData.startingFee,
            endingFee: feeConfigData.endingFee,
            secondsToDecay: feeConfigData.secondsToDecay
        });

        emit FeeConfigSet(
            poolKey.toId(),
            feeConfigData.startingFee,
            feeConfigData.endingFee,
            feeConfigData.secondsToDecay
        );
    }

    /// @notice Returns the current fee for a pool.
    /// @param poolId The pool id.
    /// @return Current fee, or 0 if uninitialized or decay is complete.
    function getFee(PoolId poolId) external view returns (uint24) {
        // if the pool is not initialized, return zero
        if (poolStartTime[poolId] == 0) {
            return 0;
        }

        // check if the decay period is over
        if (block.timestamp > poolStartTime[poolId] + feeConfig[poolId].secondsToDecay) {
            // decay period is over, return zero
            return 0;
        }

        // check if this is the same block as deployment, if so, return the starting fee
        if (block.timestamp == poolStartTime[poolId]) {
            return feeConfig[poolId].startingFee;
        }

        // return the fee for the swap
        return _calculateFee(poolId);
    }

    function _calculateFee(PoolId poolId) internal view returns (uint24) {
        // how much time has passed since pool creation
        uint256 timeDecay = feeConfig[poolId].secondsToDecay
            - (block.timestamp - (poolStartTime[poolId] + delayGuard));
        uint256 feeRange = feeConfig[poolId].startingFee - feeConfig[poolId].endingFee;

        // Parabolic decay: fee = endingFee + feeRange * (timeDecay / timeToDecay)²
        uint256 normalizedTime = (timeDecay * 1e18) / feeConfig[poolId].secondsToDecay; // Scale for precision
        uint256 squaredTime = (normalizedTime * normalizedTime) / 1e18;
        uint256 decayAmount = (feeRange * squaredTime) / 1e18;

        return uint24(feeConfig[poolId].endingFee + decayAmount);
    }

    /// @notice Called by the hook before a swap to set the dynamic fee.
    /// @param poolKey The pool key.
    /// @return disableMevModule True when the decay period has ended.
    function beforeSwap(
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata,
        bool,
        bytes calldata
    ) external onlyHook(poolKey) returns (bool disableMevModule) {
        // don't allow trading in the same second as deployment
        if (block.timestamp == poolStartTime[poolKey.toId()]) {
            revert SameSecondAsDeployment();
        }

        // check if tax period is over
        if (
            block.timestamp
                >= poolStartTime[poolKey.toId()] + feeConfig[poolKey.toId()].secondsToDecay
                    + delayGuard
        ) {
            // disable the mev module without setting the fee
            emit DecayPeriodOver(poolKey.toId());
            return true;
        }

        // calculate the fee for the swap
        uint24 swapFee = _calculateFee(poolKey.toId());

        // call back into the hook to update the fee for the swap
        IArtCoinsHook(msg.sender).mevModuleSetFee(poolKey, swapFee);

        // mev module is still active
        return false;
    }

    /// @notice ERC-165 introspection.
    /// @param interfaceId The interface id.
    /// @return True if supported.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IArtCoinsMevModule).interfaceId
            || interfaceId == type(IArtCoinsMevModuleBase).interfaceId;
    }
}
