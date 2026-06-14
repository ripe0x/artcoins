// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title  IArtCoinsMevModuleBase
/// @notice The surface common to EVERY anti-sniper MEV-window module the
///         factory can register and a hook can initialize — independent of how
///         the module expresses its protection. It is exactly the part the
///         factory's `setMevModule` gate and the hook's `initializeMevModule`
///         plumbing depend on: a one-time per-pool `initialize` plus ERC-165
///         `supportsInterface`.
/// @dev    Kind-specific surfaces extend this base:
///           - {IArtCoinsMevModule} adds the per-swap `beforeSwap` callback for
///             modules that dial the pool's LP fee.
///           - {IArtCoinsMevSkim} adds the read-only `currentSkimBps` /
///             `operational` views for modules that drive a hook-level skim.
///         The factory gates `setMevModule` on
///         `type(IArtCoinsMevModuleBase).interfaceId`, so both kinds advertise
///         it from `supportsInterface`. Because Solidity excludes inherited
///         functions from `type(I).interfaceId`, this base id equals
///         `initialize.selector ^ supportsInterface.selector` and is disjoint
///         from each kind's own id (e.g. `type(IArtCoinsMevModule).interfaceId`
///         is just `beforeSwap.selector`).
interface IArtCoinsMevModuleBase {
    /// @notice Reverts when a hook-only function is called by a different caller.
    error OnlyHook();

    /// @notice Initializes the MEV module for a given pool.
    /// @param poolKey The pool key being protected.
    /// @param mevModuleInitData Encoded initialization data specific to the module.
    function initialize(PoolKey calldata poolKey, bytes calldata mevModuleInitData) external;

    /// @notice ERC-165 introspection.
    /// @param interfaceId The interface id.
    /// @return True if supported.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool);
}
