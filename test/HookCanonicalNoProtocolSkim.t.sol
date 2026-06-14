// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {ArtCoinsHookStaticFee} from "../src/hooks/ArtCoinsHookStaticFee.sol";
import {IArtCoinsHook} from "../src/interfaces/IArtCoinsHook.sol";

/// @notice Structural guarantee for the canonical hook: the dormant hook-level
///         protocol-fee path is GONE. There is no `protocolFeeNumerator` /
///         `protocolFee` / `MAX_PROTOCOL_FEE_NUMERATOR` to read and no
///         `setProtocolFeeNumerator` to turn on, so a trader on any pool using
///         this hook pays exactly the configured pool fee — enforced by
///         construction, not by a runtime `== 0` assertion. With those public
///         members removed, their auto-generated getter selectors no longer
///         exist on the contract, which this test verifies directly.
///
///         Division of coverage:
///           - This file: the protocol-fee SURFACE is gone (by construction).
///           - Swap-level fee behavior of this canonical hook is exercised by
///             the canonical fork tests (`ArtCoinsV3StackForkTest`,
///             `SpikePerSwapConvertForkTest`, `AutoBurnOpenTabForkTest`,
///             `ArtCoinsLpLockerFeeConversionForkTest`).
///           - The frozen legacy `ArtCoinsHookV2` keeps the dormant path at
///             numerator 0; the deployed-hook regression for that lives in
///             `HookProtocolFeeNumeratorZeroTest` + `FeeMathReconciliationForkTest`.
///
///         Fork-free: `BaseHook`'s constructor only validates the mined address
///         bits (it never calls the pool manager), so the hook can be deployed
///         with placeholder wiring and introspected directly.
contract HookCanonicalNoProtocolSkimTest is Test {
    ArtCoinsHookStaticFee internal hook;

    function setUp() public {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        // Placeholder wiring — the constructor only stores these (and validates
        // the mined hook address), so no live pool manager / factory is needed.
        address pm = makeAddr("poolManager");
        address factory = makeAddr("factory");
        address ext = makeAddr("poolExtensionAllowlist");
        address weth = makeAddr("weth");
        address escrow = makeAddr("feeEscrow");

        bytes memory ctorArgs = abi.encode(pm, factory, ext, weth, escrow);
        (address minedHook, bytes32 salt) =
            HookMiner.find(address(this), flags, type(ArtCoinsHookStaticFee).creationCode, ctorArgs);

        hook = new ArtCoinsHookStaticFee{salt: salt}(pm, factory, ext, weth, escrow);
        require(address(hook) == minedHook, "hook address mismatch");
    }

    /// @dev The removed public members have no getter selectors anymore. A
    ///      `staticcall` to a non-existent view selector hits no function and,
    ///      with no fallback defined, reverts — so success == false proves the
    ///      member is gone. (A present public getter would return data.)
    function test_protocolFeeSurfaceRemoved() public view {
        assertFalse(
            _viewSelectorExists(abi.encodeWithSignature("protocolFeeNumerator()")),
            "protocolFeeNumerator() must not exist on the canonical hook"
        );
        assertFalse(
            _viewSelectorExists(abi.encodeWithSignature("protocolFee()")),
            "protocolFee() must not exist on the canonical hook"
        );
        assertFalse(
            _viewSelectorExists(abi.encodeWithSignature("MAX_PROTOCOL_FEE_NUMERATOR()")),
            "MAX_PROTOCOL_FEE_NUMERATOR() must not exist on the canonical hook"
        );
    }

    /// @dev Sanity floor: still-present constant getters succeed, proving the
    ///      staticcall probe distinguishes present from absent selectors (so the
    ///      assertions above are meaningful, not vacuously false).
    function test_coreSurfaceIntact() public view {
        assertTrue(
            _viewSelectorExists(abi.encodeWithSignature("MAX_LP_FEE()")), "MAX_LP_FEE() missing"
        );
        assertTrue(
            _viewSelectorExists(abi.encodeWithSignature("MAX_MEV_LP_FEE()")),
            "MAX_MEV_LP_FEE() missing"
        );
        assertTrue(
            _viewSelectorExists(abi.encodeWithSignature("FEE_DENOMINATOR()")),
            "FEE_DENOMINATOR() missing (sniper-extra math depends on it)"
        );
    }

    /// @dev Removing the protocol-fee path does not change the hook's identity.
    function test_stillImplementsHookInterface() public view {
        assertTrue(
            hook.supportsInterface(type(IArtCoinsHook).interfaceId),
            "canonical hook must still implement IArtCoinsHook"
        );
    }

    function _viewSelectorExists(bytes memory callData) internal view returns (bool ok) {
        (ok,) = address(hook).staticcall(callData);
    }
}
