// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsMevModule} from "../interfaces/IArtCoinsMevModule.sol";
import {IArtCoinsMevModuleBase} from "../interfaces/IArtCoinsMevModuleBase.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title ArtCoinsMevTimeDelay
/// @notice Simple MEV module that locks swaps for a fixed number of seconds after pool creation.
contract ArtCoinsMevTimeDelay is IArtCoinsMevModule {
    /// @notice Reverts when constructed with a zero delay.
    error TimeDelayMustBeGreaterThanZero();

    /// @notice Per-pool unlock timestamp.
    mapping(PoolId => uint256) public poolUnlockTime;

    /// @notice Configured time delay (seconds).
    uint256 public timeDelay;

    /// @param _timeDelay Seconds to lock the pool after initialization.
    constructor(uint256 _timeDelay) {
        if (_timeDelay == 0) {
            revert TimeDelayMustBeGreaterThanZero();
        }
        timeDelay = _timeDelay;
    }

    /// @dev Restricts a function to the pool's hook.
    modifier onlyHook(PoolKey calldata poolKey) {
        if (msg.sender != address(poolKey.hooks)) {
            revert OnlyHook();
        }
        _;
    }

    /// @notice Initializes the unlock time for a pool.
    /// @param poolKey The pool key.
    function initialize(PoolKey calldata poolKey, bytes calldata) external onlyHook(poolKey) {
        // set the pool unlock time to the current timestamp + the time delay
        poolUnlockTime[poolKey.toId()] = block.timestamp + timeDelay;
    }

    /// @notice Reverts swaps until the pool's unlock time has passed; otherwise disables the module.
    /// @param poolKey The pool key.
    /// @return disableMevModule Always true once unlocked.
    function beforeSwap(
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata,
        bool,
        bytes calldata
    ) external onlyHook(poolKey) returns (bool disableMevModule) {
        // check if the pool is locked
        if (block.timestamp < poolUnlockTime[poolKey.toId()]) {
            revert PoolLocked();
        }

        // pool should be unlocked now
        return true;
    }

    /// @notice ERC-165 introspection.
    /// @param interfaceId The interface id.
    /// @return True if supported.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IArtCoinsMevModule).interfaceId
            || interfaceId == type(IArtCoinsMevModuleBase).interfaceId;
    }
}
