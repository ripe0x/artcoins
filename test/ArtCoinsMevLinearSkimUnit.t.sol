// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IArtCoinsMevModule} from "../src/interfaces/IArtCoinsMevModule.sol";
import {IArtCoinsMevModuleBase} from "../src/interfaces/IArtCoinsMevModuleBase.sol";
import {ArtCoinsMevLinearSkim} from "../src/mev-modules/ArtCoinsMevLinearSkim.sol";
import {IArtCoinsMevSkim} from "../src/mev-modules/interfaces/IArtCoinsMevSkim.sol";

import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract ArtCoinsMevLinearSkimUnitTest is Test {
    using PoolIdLibrary for PoolKey;

    ArtCoinsMevLinearSkim internal module;

    // Pretend this contract is the hook for `onlyHook` access.
    PoolKey internal pk;

    function setUp() public {
        module = new ArtCoinsMevLinearSkim();
        pk = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(makeAddr("token")),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(this))
        });
    }

    function _initDefaults() internal {
        module.initialize(pk, "");
    }

    function _initCustom(uint24 starting, uint24 ending, uint32 dur) internal {
        module.initialize(pk, abi.encode(starting, ending, dur));
    }

    function test_initialize_storesDefaults() public {
        _initDefaults();
        PoolId id = pk.toId();
        (uint24 s, uint24 e, uint32 d, uint256 t) = module.skimConfigs(id);
        assertEq(s, 68_690);
        assertEq(e, 5000);
        assertEq(d, 69 minutes);
        assertEq(t, block.timestamp);
    }

    function test_initialize_storesCustom() public {
        _initCustom(50_000, 1000, 30 minutes);
        PoolId id = pk.toId();
        (uint24 s, uint24 e, uint32 d,) = module.skimConfigs(id);
        assertEq(s, 50_000);
        assertEq(e, 1000);
        assertEq(d, 30 minutes);
    }

    function test_initialize_revertsAboveMaxSkim() public {
        vm.expectRevert(ArtCoinsMevLinearSkim.InvalidConfig.selector);
        module.initialize(pk, abi.encode(uint24(90_001), uint24(5000), uint32(69 minutes)));
    }

    function test_initialize_revertsWhenEndingGteStarting() public {
        vm.expectRevert(ArtCoinsMevLinearSkim.InvalidConfig.selector);
        module.initialize(pk, abi.encode(uint24(5000), uint24(5000), uint32(69 minutes)));
    }

    function test_initialize_revertsBelowMinDuration() public {
        vm.expectRevert(ArtCoinsMevLinearSkim.InvalidConfig.selector);
        module.initialize(pk, abi.encode(uint24(50_000), uint24(5000), uint32(30)));
    }

    function test_initialize_revertsAboveMaxDuration() public {
        vm.expectRevert(ArtCoinsMevLinearSkim.InvalidConfig.selector);
        module.initialize(pk, abi.encode(uint24(50_000), uint24(5000), uint32(181 minutes)));
    }

    function test_initialize_revertsOnReinit() public {
        _initDefaults();
        vm.expectRevert(ArtCoinsMevLinearSkim.InvalidConfig.selector);
        module.initialize(pk, "");
    }

    function test_initialize_revertsForNonHookCaller() public {
        // pk.hooks is address(this); a different sender must be rejected.
        PoolKey memory other = PoolKey({
            currency0: pk.currency0,
            currency1: pk.currency1,
            fee: pk.fee,
            tickSpacing: pk.tickSpacing,
            hooks: IHooks(makeAddr("notHook"))
        });
        vm.expectRevert();
        module.initialize(other, "");
    }

    // ─── currentSkimBps & operational ────────────────────────────────────

    function test_currentSkimBps_atTimeZero() public {
        _initDefaults();
        PoolId id = pk.toId();
        assertEq(module.currentSkimBps(id), 68_690);
        assertTrue(module.operational(id));
    }

    function test_currentSkimBps_atMidpoint() public {
        _initDefaults();
        PoolId id = pk.toId();
        // Midpoint: bps = (68_690 + 5_000) / 2 = 36_845
        vm.warp(block.timestamp + (69 minutes) / 2);
        assertEq(module.currentSkimBps(id), uint24(68_690 - (68_690 - 5000) / 2));
    }

    function test_currentSkimBps_atEnd() public {
        _initDefaults();
        PoolId id = pk.toId();
        vm.warp(block.timestamp + 69 minutes);
        assertEq(module.currentSkimBps(id), 5000);
        assertFalse(module.operational(id));
    }

    function test_currentSkimBps_afterEnd() public {
        _initDefaults();
        PoolId id = pk.toId();
        vm.warp(block.timestamp + 200 minutes);
        assertEq(module.currentSkimBps(id), 5000);
        assertFalse(module.operational(id));
    }

    function test_currentSkimBps_beforeInit() public {
        PoolId fresh = PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(makeAddr("fresh")),
                fee: 0,
                tickSpacing: 60,
                hooks: IHooks(address(this))
            }).toId();
        assertEq(module.currentSkimBps(fresh), 0);
        assertFalse(module.operational(fresh));
    }

    function test_getTimeRemaining() public {
        _initDefaults();
        assertEq(module.getTimeRemaining(pk), 69 minutes);
        vm.warp(block.timestamp + 10 minutes);
        assertEq(module.getTimeRemaining(pk), 59 minutes);
        vm.warp(block.timestamp + 60 minutes);
        assertEq(module.getTimeRemaining(pk), 0);
    }

    function test_supportsInterface() public view {
        assertTrue(module.supportsInterface(type(IArtCoinsMevModuleBase).interfaceId));
        assertTrue(module.supportsInterface(type(IArtCoinsMevSkim).interfaceId));
        assertTrue(module.supportsInterface(type(IERC165).interfaceId));
        // A skim module is NOT an IArtCoinsMevModule — it has no `beforeSwap`.
        assertFalse(module.supportsInterface(type(IArtCoinsMevModule).interfaceId));
        assertFalse(module.supportsInterface(0xdeadbeef));
    }
}
