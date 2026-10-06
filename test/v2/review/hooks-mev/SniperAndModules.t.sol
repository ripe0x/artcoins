// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HMArt, HooksMevBase} from "./HooksMevBase.sol";
import {ArtCoinsMevLinearFees} from "../../../../src/mev-modules/ArtCoinsMevLinearFees.sol";
import {ArtCoinsMevLinearSkim} from "../../../../src/mev-modules/ArtCoinsMevLinearSkim.sol";
import {ArtCoinsMevSniperSteppedFees} from
    "../../../../src/mev-modules/ArtCoinsMevSniperSteppedFees.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// static-fee hook + fee-dialing / sniper modules.
contract SniperAndModulesTest is HooksMevBase {
    using PoolIdLibrary for PoolKey;

    HMArt internal art;
    address internal sniperR = address(0x5A1);

    function setUp() public override {
        super.setUp();
        art = _newArt();
    }

    function _sniperPool() internal returns (PoolKey memory key) {
        ArtCoinsMevSniperSteppedFees mod = new ArtCoinsMevSniperSteppedFees();
        key = _staticPool(address(art), 10_000, 10_000, address(mod));
        staticHook.factorySetSniperFeeRecipient(key, sniperR, false);
        _addLiquidity(key, -6000, 6000, 1000 ether);
        ArtCoinsMevSniperSteppedFees.Step[] memory steps = new ArtCoinsMevSniperSteppedFees.Step[](1);
        steps[0] = ArtCoinsMevSniperSteppedFees.Step({durationSec: 900, feePpm: 500_000});
        staticHook.initializeMevModule(key, abi.encode(steps, uint24(10_000)));
        vm.warp(block.timestamp + 1);
    }

    /// H6: exact-input pays extraPpm of the GROSS input; exact-output pays
    /// extraPpm of the NET input (no gross-up). at a 49% extra the same tokens
    /// cost ~24% less via exact output. snipers just use exactOutput.
    function test_bug_H6_sniperExtraExactOutputDiscount() public {
        PoolKey memory key = _sniperPool();
        uint256 snap = vm.snapshotState();

        uint256 e0 = address(this).balance;
        uint256 a0 = art.balanceOf(address(this));
        _swap(key, true, -1 ether, 0, "", 1 ether);
        uint256 costIn = e0 - address(this).balance;
        uint256 tokensOut = art.balanceOf(address(this)) - a0;

        vm.revertToState(snap);
        e0 = address(this).balance;
        a0 = art.balanceOf(address(this));
        _swap(key, true, int256(tokensOut), 0, "", 2 ether);
        uint256 costOut = e0 - address(this).balance;
        assertEq(art.balanceOf(address(this)) - a0, tokensOut, "same tokens bought");

        emit log_named_uint("eth cost exact-in ", costIn);
        emit log_named_uint("eth cost exact-out", costOut);
        assertLt(costOut, costIn * 80 / 100, "exact-output is >20% cheaper during the sniper window");
    }

    /// H7: exact-input sniper extra is charged on |amountSpecified| in
    /// beforeSwap, so a price-limited partial fill pays the full extra.
    function test_bug_H7_sniperExtraChargedOnUnfilledInput() public {
        PoolKey memory key = _sniperPool();
        uint256 e0 = address(this).balance;
        _swap(key, true, -10 ether, TickMath.getSqrtPriceAtTick(-10), "", 10 ether);
        uint256 spent = e0 - address(this).balance;
        uint256 extra = staticHook.sniperExtraAccruedToken0(key.toId());
        assertEq(extra, 4.9 ether, "49% of 10 eth regardless of fill");
        assertLt(spent - extra, 1 ether, "under 1 eth actually traded");
    }

    /// H8: LinearFees allows up to 180 min decay, the hook kills any
    /// fee-dialing module at poolCreation + 15 min. default 69%->1% over 69
    /// min therefore cliffs from ~54% to the base fee in one second.
    function test_bug_H8_linearFeesCliffAtHookCap() public {
        ArtCoinsMevLinearFees mod = new ArtCoinsMevLinearFees();
        PoolKey memory key = _staticPool(address(art), 10_000, 10_000, address(mod));
        _addLiquidity(key, -6000, 6000, 1000 ether);
        uint256 t0 = block.timestamp;
        staticHook.initializeMevModule(key, "");

        vm.warp(t0 + 15 minutes - 1);
        _swap(key, true, -0.01 ether, 0, "", 0.01 ether);
        uint24 feeBefore = _lpFee(key);
        assertGt(feeBefore, 500_000, "~54% one second before the cap");

        vm.warp(t0 + 15 minutes);
        _swap(key, true, -0.01 ether, 0, "", 0.01 ether);
        assertEq(_lpFee(key), 10_000, "base fee one second later");
        assertGt(mod.getCurrentFee(key), 500_000, "module still reports ~54%");
    }

    /// H9: the factory gates modules on the BASE interface only, so a skim
    /// module can be bound to the static hook. _runMevModule then calls
    /// beforeSwap() on a contract that has none: every swap reverts until
    /// the 15 min cap expires.
    function test_bug_H9_skimModuleOnStaticHookRevertsSwapsForWindow() public {
        ArtCoinsMevLinearSkim mod = new ArtCoinsMevLinearSkim();
        PoolKey memory key = _staticPool(address(art), 10_000, 10_000, address(mod));
        _addLiquidity(key, -6000, 6000, 1000 ether);
        uint256 t0 = block.timestamp;
        staticHook.initializeMevModule(key, "");
        vm.warp(t0 + 1);
        vm.expectRevert();
        _swap(key, true, -0.01 ether, 0, "", 0.01 ether);
        vm.warp(t0 + 15 minutes);
        _swap(key, true, -0.01 ether, 0, "", 0.01 ether);
    }

    /// H10: IArtCoinsHookStaticFee documents artCoinFee as "fee for buying
    /// ArtCoins" and pairedFee as "fee for selling". _setFee does the
    /// opposite (pairedFee when the paired token is the input, i.e. a buy).
    function test_bug_H10_staticFeeDirectionInvertedVsDocs() public {
        PoolKey memory key = _staticPool(address(art), 10_000, 50_000, address(0));
        _addLiquidity(key, -6000, 6000, 1000 ether);
        _swap(key, true, -0.1 ether, 0, "", 0.1 ether); // eth in, art out: a BUY
        assertEq(_lpFee(key), 50_000, "buy charged pairedFee, docs say artCoinFee");
        _swap(key, false, -0.1 ether, 0, "", 0); // art in: a SELL
        assertEq(_lpFee(key), 10_000, "sell charged artCoinFee, docs say pairedFee");
    }
}
