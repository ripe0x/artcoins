// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// package t1 fork tests: the token against live mainnet state. proves the
// derived venue math against the real uniswap v2 and v3 factories, a real v3
// side buy taxed in VENUE and walled off in HARD, and the canonical flow grant
// against the live PoolManager. skips cleanly without an rpc.

import {Constants} from "../../src/Constants.sol";
import {ArtCoinsTokenV2} from "../../src/v2/ArtCoinsTokenV2.sol";
import {IArtCoinsFactoryV2} from "../../src/v2/interfaces/IArtCoinsFactoryV2.sol";
import {IArtCoinsTokenV2} from "../../src/v2/interfaces/IArtCoinsTokenV2.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {TokenV2Base} from "./TokenV2.t.sol";

interface ITV2Erc20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface ITV2V3Factory {
    function createPool(address a, address b, uint24 fee) external returns (address);
}

interface ITV2V2Factory {
    function createPair(address a, address b) external returns (address);
}

interface ITV2V3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function initialize(uint160 sqrtPriceX96) external;
    function mint(address recipient, int24 lo, int24 hi, uint128 amount, bytes calldata data)
        external
        returns (uint256, uint256);
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256, int256);
}

/// @dev Minimal v3 lp and trader: pays mint and swap callbacks from its balance.
contract TV2V3Actor {
    function mint(address pool, uint128 liq) external {
        ITV2V3Pool(pool).mint(address(this), -887_220, 887_220, liq, "");
    }

    function swap(address pool, address to, bool zeroForOne, int256 amt, uint160 lim)
        external
        returns (int256, int256)
    {
        return ITV2V3Pool(pool).swap(to, zeroForOne, amt, lim, "");
    }

    function uniswapV3MintCallback(uint256 a0, uint256 a1, bytes calldata) external {
        _pay(a0, a1);
    }

    function uniswapV3SwapCallback(int256 d0, int256 d1, bytes calldata) external {
        _pay(d0 > 0 ? uint256(d0) : 0, d1 > 0 ? uint256(d1) : 0);
    }

    function _pay(uint256 a0, uint256 a1) internal {
        ITV2V3Pool p = ITV2V3Pool(msg.sender);
        if (a0 > 0) ITV2Erc20(p.token0()).transfer(msg.sender, a0);
        if (a1 > 0) ITV2Erc20(p.token1()).transfer(msg.sender, a1);
    }
}

contract TokenV2ForkTest is TokenV2Base {
    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    bytes32 internal constant V3_INIT =
        0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;
    address internal constant V2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    bytes32 internal constant V2_INIT =
        0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;
    /// @dev same pin as test/v2/harness/ForkBase.sol.
    uint256 internal constant FORK_BLOCK = 26_130_269;
    uint160 internal constant MIN_SQRT_RATIO_P1 = 4_295_128_740;
    uint160 internal constant MAX_SQRT_RATIO_M1 =
        1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;

    bool internal onFork;

    function _poolManager() internal override returns (IPoolManager) {
        if (!vm.envOr("SKIP_FORK_TESTS", false)) {
            string memory rpc =
                vm.envOr("MAINNET_RPC_URL", string("https://mainnet.gateway.tenderly.co"));
            if (bytes(rpc).length == 0) rpc = "https://mainnet.gateway.tenderly.co";
            try vm.createSelectFork(rpc, FORK_BLOCK) {
                onFork = POOL_MANAGER.code.length != 0;
            } catch {}
        }
        if (onFork) return IPoolManager(POOL_MANAGER);
        return IPoolManager(address(new PoolManager(address(this))));
    }

    modifier onlyFork() {
        if (!onFork) {
            vm.skip(true);
            return;
        }
        _;
    }

    function _v3Venue() internal view returns (IArtCoinsFactoryV2.TaxVenue memory) {
        return IArtCoinsFactoryV2.TaxVenue({
            kind: 2, factory: V3_FACTORY, initCodeHash: V3_INIT, counterToken: WETH, v3Fee: 3000
        });
    }

    /// @dev Lists the derived v3 pool, then creates it on the real factory.
    function _listAndCreateV3() internal returns (address pool) {
        vm.prank(admin);
        pool = token.addDerivedTaxVenue(_v3Venue());
        address created = ITV2V3Factory(V3_FACTORY).createPool(address(token), WETH, 3000);
        assertEq(created, pool, "derived v3 address");
        ITV2V3Pool(pool).initialize(2 ** 96);
    }

    function test_fork_venue_sideV3Buy_taxed() public onlyFork {
        _deployMode(Constants.TAX_MODE_VENUE);
        address pool = _listAndCreateV3();
        TV2V3Actor actor = new TV2V3Actor();
        token.transfer(address(actor), 1000e18);
        deal(WETH, address(actor), 200 ether);
        actor.mint(pool, 100e18); // coin into a venue is untaxed
        assertGt(token.balanceOf(pool), 0, "lp placed");

        bool wethIs0 = WETH < address(token);
        uint256 deadBefore = token.balanceOf(Constants.DEAD);
        (int256 a0, int256 a1) = actor.swap(
            pool, alice, wethIs0, 1 ether, wethIs0 ? MIN_SQRT_RATIO_P1 : MAX_SQRT_RATIO_M1
        );
        uint256 gross = uint256(-(wethIs0 ? a1 : a0));
        uint256 tax = gross * BPS / 10_000;
        assertGt(gross, 0);
        assertEq(token.balanceOf(alice), gross - tax, "buyer net");
        assertEq(token.balanceOf(Constants.DEAD) - deadBefore, tax, "sink");
    }

    function test_fork_tax_budgetNotSpendableOnV3Venue() public onlyFork {
        _deployMode(Constants.TAX_MODE_VENUE);
        address pool = _listAndCreateV3();
        TV2V3Actor actor = new TV2V3Actor();
        token.transfer(address(actor), 1000e18);
        deal(WETH, address(actor), 200 ether);
        actor.mint(pool, 100e18);

        vm.prank(address(hook));
        token.attestCanonicalBudget(_pid(), 1_000_000e18);
        bool wethIs0 = WETH < address(token);
        (int256 a0, int256 a1) = actor.swap(
            pool, alice, wethIs0, 1 ether, wethIs0 ? MIN_SQRT_RATIO_P1 : MAX_SQRT_RATIO_M1
        );
        uint256 gross = uint256(-(wethIs0 ? a1 : a0));
        assertEq(token.balanceOf(alice), gross - gross * BPS / 10_000, "still taxed");
        (uint256 b,,) = token.pendingCanonical();
        assertEq(b, 1_000_000e18, "budget untouched");
    }

    function test_fork_hard_v3VenueMint_reverts() public onlyFork {
        _deployMode(Constants.TAX_MODE_HARD);
        address pool = _listAndCreateV3();
        TV2V3Actor actor = new TV2V3Actor();
        token.transfer(address(actor), 1000e18);
        deal(WETH, address(actor), 200 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IArtCoinsTokenV2.VenueTransferBlocked.selector, pool)
        );
        actor.mint(pool, 100e18);
    }

    function test_fork_hard_v2PairDerived_blocked() public onlyFork {
        _deployMode(Constants.TAX_MODE_HARD);
        IArtCoinsFactoryV2.TaxVenue memory v = IArtCoinsFactoryV2.TaxVenue({
            kind: 1, factory: V2_FACTORY, initCodeHash: V2_INIT, counterToken: WETH, v3Fee: 0
        });
        vm.prank(admin);
        address pair = token.addDerivedTaxVenue(v);
        assertEq(ITV2V2Factory(V2_FACTORY).createPair(address(token), WETH), pair, "derived v2");
        vm.expectRevert(
            abi.encodeWithSelector(IArtCoinsTokenV2.VenueTransferBlocked.selector, pair)
        );
        token.transfer(pair, 1e18);
    }

    function test_fork_hard_canonicalBuyAndSell_livePoolManager() public onlyFork {
        _deployMode(Constants.TAX_MODE_HARD);
        _initCanonWithLiquidity(100e18);
        uint256 before = token.balanceOf(address(this));
        BalanceDelta d = _buy(_canonKey(), 1 ether);
        assertEq(token.balanceOf(address(this)) - before, uint128(d.amount1()));
        _sell(_canonKey(), 500e18);
        _assertNoPending();
        // a side pool on the live PoolManager cannot be funded with erc20
        IPoolManager livePm = IPoolManager(POOL_MANAGER);
        livePm.initialize(_sideKey(), SQRT_1_1);
        vm.expectPartialRevert(IArtCoinsTokenV2.CanonicalFlowRequired.selector);
        liqRouter.modifyLiquidity{value: 11 ether}(_sideKey(), _liq(10e18), "");
    }
}
