// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsHook} from "../interfaces/IArtCoinsHook.sol";
import {IArtCoinsMevModule} from "../interfaces/IArtCoinsMevModule.sol";
import {IArtCoinsMevModuleBase} from "../interfaces/IArtCoinsMevModuleBase.sol";

import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title ArtCoinsMevLinearFees
/// @notice Anti-sniper MEV module with linear fee decay.
/// @dev Starts at a high fee (default 69%) and linearly decays to an ending fee
///      over a configurable duration (default 69 minutes). The cap is 99% so
///      deployers can opt into a sharper sniper deterrent if they want.
///
///      fee = startingFee - (startingFee - endingFee) * elapsed / duration
///
///      After the duration expires, the module disables itself and normal
///      pool fees take over.
contract ArtCoinsMevLinearFees is IArtCoinsMevModule {
    using PoolIdLibrary for PoolKey;

    /// @notice Reverts on invalid init data, re-initialization, or out-of-range parameters.
    error InvalidConfig();

    /// @notice Per-pool fee decay configuration.
    /// @param startingFee Fee at launch (max 990_000 = 99%).
    /// @param endingFee Fee at the end of decay.
    /// @param duration Decay duration in seconds.
    /// @param startTime Block timestamp when the pool was initialized with this module.
    struct FeeConfig {
        uint24 startingFee;
        uint24 endingFee;
        uint32 duration;
        uint256 startTime;
    }

    /// @notice Maximum allowed fee (99%).
    uint24 public constant MAX_FEE = 990_000;
    /// @notice Default starting fee (69%) — chosen to give post-launch buyers
    ///         a tradeable price within seconds while still penalising the
    ///         block-zero sniper.
    uint24 public constant DEFAULT_STARTING_FEE = 690_000;
    /// @notice Default ending fee (1%).
    uint24 public constant DEFAULT_ENDING_FEE = 10_000;
    /// @notice Default decay duration (69 minutes).
    uint32 public constant DEFAULT_DURATION = 69 minutes;
    /// @notice Minimum allowed decay duration.
    uint32 public constant MIN_DURATION = 1 minutes;
    /// @notice Maximum allowed decay duration.
    uint32 public constant MAX_DURATION = 180 minutes;

    /// @notice Fee config for each pool id.
    mapping(PoolId => FeeConfig) public feeConfigs;

    /// @dev Restricts a function to the pool's hook.
    modifier onlyHook(PoolKey calldata poolKey) {
        if (msg.sender != address(poolKey.hooks)) {
            revert OnlyHook();
        }
        _;
    }

    /// @notice Called by the hook during pool initialization
    /// @param poolKey The pool being initialized
    /// @param mevModuleInitData ABI-encoded (uint24 startingFee, uint24 endingFee, uint32 duration)
    ///        or empty bytes for defaults (69% -> 1% over 69 minutes)
    function initialize(PoolKey calldata poolKey, bytes calldata mevModuleInitData)
        external
        onlyHook(poolKey)
    {
        // Only initialize once
        if (feeConfigs[poolKey.toId()].startTime != 0) {
            revert InvalidConfig();
        }

        FeeConfig memory config;

        if (mevModuleInitData.length == 0) {
            config = FeeConfig({
                startingFee: DEFAULT_STARTING_FEE,
                endingFee: DEFAULT_ENDING_FEE,
                duration: DEFAULT_DURATION,
                startTime: block.timestamp
            });
        } else {
            (uint24 startingFee, uint24 endingFee, uint32 duration) =
                abi.decode(mevModuleInitData, (uint24, uint24, uint32));

            if (startingFee > MAX_FEE) revert InvalidConfig();
            if (endingFee >= startingFee) revert InvalidConfig();
            if (duration < MIN_DURATION || duration > MAX_DURATION) revert InvalidConfig();

            config = FeeConfig({
                startingFee: startingFee,
                endingFee: endingFee,
                duration: duration,
                startTime: block.timestamp
            });
        }

        feeConfigs[poolKey.toId()] = config;
    }

    /// @notice Called by the hook before each swap to set the anti-sniper fee
    /// @return disableMevModule True when the decay period is over
    function beforeSwap(
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata,
        bool,
        bytes calldata
    ) external onlyHook(poolKey) returns (bool disableMevModule) {
        FeeConfig memory config = feeConfigs[poolKey.toId()];

        uint256 elapsed = block.timestamp - config.startTime;

        // Decay complete — disable this module, normal pool fees take over
        if (elapsed >= config.duration) {
            return true;
        }

        // Linear interpolation: fee = start - (start - end) * elapsed / duration
        uint24 feeRange = config.startingFee - config.endingFee;
        uint24 currentFee =
            config.startingFee - uint24(uint256(feeRange) * elapsed / config.duration);

        // Tell the hook to set this fee for the current swap
        IArtCoinsHook(msg.sender).mevModuleSetFee(poolKey, currentFee);

        return false;
    }

    /// @notice Returns the current fee for a pool (view helper).
    /// @param poolKey The pool key.
    /// @return Current fee in hundredths of a basis point.
    function getCurrentFee(PoolKey calldata poolKey) external view returns (uint24) {
        FeeConfig memory config = feeConfigs[poolKey.toId()];
        if (config.startTime == 0) return 0;

        uint256 elapsed = block.timestamp - config.startTime;
        if (elapsed >= config.duration) return config.endingFee;

        uint24 feeRange = config.startingFee - config.endingFee;
        return config.startingFee - uint24(uint256(feeRange) * elapsed / config.duration);
    }

    /// @notice Returns seconds remaining in the anti-sniper period.
    /// @param poolKey The pool key.
    /// @return Seconds until decay completes (0 if already complete).
    function getTimeRemaining(PoolKey calldata poolKey) external view returns (uint256) {
        FeeConfig memory config = feeConfigs[poolKey.toId()];
        if (config.startTime == 0) return 0;

        uint256 elapsed = block.timestamp - config.startTime;
        if (elapsed >= config.duration) return 0;

        return config.duration - elapsed;
    }

    /// @notice ERC-165 introspection.
    /// @param interfaceId The interface id.
    /// @return True if supported.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IArtCoinsMevModule).interfaceId
            || interfaceId == type(IArtCoinsMevModuleBase).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }
}
