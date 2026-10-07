// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TaxModesV2Helpers, TaxModesHardSideV2ForkTest} from "../integration/TaxModesV2.fork.t.sol";
import {I1EmptyTreasury} from "../integration/mocks/I1Mocks.sol";
import {V2AActor} from "../review-v2/a/V2A_TaxBypass.t.sol";
import {Constants} from "../../../src/Constants.sol";
import {IArtCoinsFactoryV2} from "../../../src/v2/interfaces/IArtCoinsFactoryV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Independent audit ACV2-01 proof: a canonical buy grants an outflow, a side pool take
///         consumes it, and a canonical sell in the same unlock cancels only the unused remainder.
abstract contract ACV2_01Ops {
    function _swap(PoolKey memory k, bool zeroForOne, int256 amount) internal pure returns (V2AActor.Op memory o) {
        o.kind = 1;
        o.key = k;
        o.zeroForOne = zeroForOne;
        o.amount = amount;
    }

    function _one(V2AActor.Op memory a) internal pure returns (V2AActor.Op[] memory ops) {
        ops = new V2AActor.Op[](1);
        ops[0] = a;
    }

    function _sequence(PoolKey memory canonical, PoolKey memory side, uint256 coinOut)
        internal
        pure
        returns (V2AActor.Op[] memory ops)
    {
        ops = new V2AActor.Op[](4);
        ops[0] = _swap(canonical, true, int256(coinOut));
        ops[1] = _swap(side, true, int256(coinOut));
        ops[2].kind = 3;
        ops[3] = _swap(canonical, false, -int256(coinOut));
    }
}

contract ACV2_01VenueForkProof is TaxModesV2Helpers, ACV2_01Ops {
    function test_ACV2_01_venueSpentBudgetBypassesSideTax() public onlyFork {
        I1EmptyTreasury treasury = new I1EmptyTreasury();
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _creditsConfig(address(treasury));
        c.fee.baselineSkimBps = 0;
        c.fee.maxReferralBpsOfVolume = 0;
        c.mev.module = address(0);
        c.mev.startingSkimBps = 0;
        c.mev.windowSeconds = 0;
        c.tax.taxBps = 2000;
        c.tax.taxBpsMax = 2000;
        c.tax.taxSink = Constants.DEAD;
        address coin = _ownerLaunch(c);
        PoolKey memory canonical = _key(coin);
        PoolKey memory side = _initSide(canonical, coin);
        uint256 seed = _buy(canonical, 1 ether);
        IERC20(coin).approve(address(liqRouter), type(uint256).max);
        liqRouter.modifyLiquidity(side, _coinOnly(side, seed / 2), "");
        liqRouter.modifyLiquidity{value: 1 ether}(side, _ethOnly(side, 0.5 ether), "");
        uint256 x = seed / 1000;
        assertGt(x, 0);

        V2AActor ordinary = new V2AActor(pm, coin);
        vm.deal(address(ordinary), 100 ether);
        uint256 sinkBefore = IERC20(coin).balanceOf(Constants.DEAD);
        ordinary.run(_one(_swap(side, true, int256(x))));
        assertGt(IERC20(coin).balanceOf(Constants.DEAD), sinkBefore, "plain side buy is taxed");

        V2AActor attacker = new V2AActor(pm, coin);
        vm.deal(address(attacker), 100 ether);
        sinkBefore = IERC20(coin).balanceOf(Constants.DEAD);
        attacker.run(_sequence(canonical, side, x));
        assertEq(IERC20(coin).balanceOf(address(attacker)), x, "side buy exits gross");
        assertEq(IERC20(coin).balanceOf(Constants.DEAD), sinkBefore, "no tax paid");
    }
}

contract ACV2_01HardForkProof is TaxModesHardSideV2ForkTest, ACV2_01Ops {
    function test_ACV2_01_hardSpentGrantLetsSideCoinExitAsErc20() public onlyFork {
        uint256 x = pm.balanceOf(address(this), uint256(uint160(coin))) / 1000;
        assertGt(x, 0);
        V2AActor attacker = new V2AActor(pm, coin);
        vm.deal(address(attacker), 100 ether);
        attacker.run(_sequence(key, side, x));
        assertEq(IERC20(coin).balanceOf(address(attacker)), x, "side coin exits as ERC20");
    }
}
