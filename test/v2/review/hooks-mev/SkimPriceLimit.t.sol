// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HMArt, HMEthSink, HMReferralPayout, HooksMevBase} from "./HooksMevBase.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// H4 / H5: the quote-specified branch skims |amountSpecified| in beforeSwap,
/// before the pool knows how much a sqrtPriceLimit will let through.
contract SkimPriceLimitTest is HooksMevBase {
    HMArt internal art;
    HMEthSink internal bounty;
    PoolKey internal key;

    function setUp() public override {
        super.setUp();
        art = _newArt();
        bounty = new HMEthSink();
        key = _skimPool(
            address(art),
            _skimFeeData(5000, 5000, 0, address(bounty), address(new HMReferralPayout())),
            address(0x10C),
            address(0)
        );
        _addLiquidity(key, -6000, 6000, 1000 ether);
    }

    function _skimCollected() internal view returns (uint256) {
        return address(bounty).balance + escrow.feesToClaim(protocolR, address(0));
    }

    /// exact input buy, 10 eth specified, price limit lets ~0.5 eth through.
    /// skim is 5% of 10 eth = 0.5 eth, charged in full. effective skim on
    /// what actually traded is ~50%.
    function test_bug_H4_exactInBuyPartialFillSkimsUnfilledAmount() public {
        uint256 ethBefore = address(this).balance;
        _swap(key, true, -10 ether, TickMath.getSqrtPriceAtTick(-10), "", 10 ether);
        uint256 spent = ethBefore - address(this).balance;
        uint256 skim = _skimCollected();
        assertEq(skim, 0.5 ether, "skim computed on amountSpecified, not on the fill");
        uint256 swapped = spent - skim;
        assertLt(swapped, 1 ether, "price limit stopped the swap early");
        // effective skim rate on the eth that left the trader, in 1e5 units
        uint256 effBps = skim * 100_000 / spent;
        assertGt(effBps, 30_000, "effective skim > 30% vs nominal 5%");
        emit log_named_uint("eth spent", spent);
        emit log_named_uint("eth swapped", swapped);
        emit log_named_uint("effective skim (1e5)", effBps);
    }

    /// exact output sell (ask for 10 eth out), price limit lets ~0.25 eth out.
    /// skim grossed up on 10 eth (0.526 eth) exceeds what the pool paid out,
    /// so the SELLER ends up paying eth on top of the tokens it sold.
    function test_bug_H5_exactOutSellPartialFillMakesSellerPayEth() public {
        uint256 ethBefore = address(this).balance;
        uint256 artBefore = art.balanceOf(address(this));
        _swap(key, false, 10 ether, TickMath.getSqrtPriceAtTick(5), "", 1 ether);
        uint256 artSold = artBefore - art.balanceOf(address(this));
        assertGt(artSold, 0, "tokens went into the pool");
        assertLt(address(this).balance, ethBefore, "seller's eth balance went DOWN on a sell");
        emit log_named_uint("art sold", artSold);
        emit log_named_uint("eth paid by seller", ethBefore - address(this).balance);
        assertEq(_skimCollected(), uint256(10 ether) * 5000 / 95_000);
    }

    /// control: the quote-UNspecified branch (exact-in sell) uses the realized
    /// delta in afterSwap, so a partial fill is skimmed on the fill only.
    function test_control_H4_exactInSellUsesRealizedDelta() public {
        uint256 ethBefore = address(this).balance;
        _swap(key, false, -10 ether, TickMath.getSqrtPriceAtTick(10), "", 0);
        uint256 got = address(this).balance - ethBefore;
        uint256 skim = _skimCollected();
        // skim = 5% of the gross eth the pool released
        assertApproxEqAbs(skim * 100_000 / (got + skim), 5000, 1);
    }
}
