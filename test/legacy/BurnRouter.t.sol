// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BurnRouter} from "../../src/protocol-fee/legacy/BurnRouter.sol";
import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract MockBurnableToken is ERC20, ERC20Burnable {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Tests for non-swap paths. The WETH→LAYER swap path requires a live
///      Uniswap v4 pool and is exercised by the LaunchLayer fork test.
contract BurnRouterTest is Test {
    BurnRouter internal router;
    MockBurnableToken internal layer;
    MockBurnableToken internal weth;
    address internal admin = address(0xA1);
    address internal universalRouter = address(0xC0FFEE);
    address internal permit2 = address(0xBEEF);

    PoolKey internal poolKey;

    function setUp() public {
        router = new BurnRouter(admin);
        layer = new MockBurnableToken("Layer", "LAYER");
        weth = new MockBurnableToken("WETH", "WETH");

        // Mock universalRouter and permit2 with code so calls don't blow up.
        vm.etch(universalRouter, hex"60016001");
        vm.etch(permit2, hex"60016001");

        // Build a pool key with LAYER and WETH in canonical sort order.
        (address c0, address c1) = address(layer) < address(weth)
            ? (address(layer), address(weth))
            : (address(weth), address(layer));
        poolKey = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 0x800000, // dynamic
            tickSpacing: 200,
            hooks: IHooks(address(0xBABE))
        });
    }

    // ─── initialization ──────────────────────────────────────────────────

    function test_initialState() public view {
        assertFalse(router.initialized());
        assertEq(router.layerToken(), address(0));
    }

    function test_initialize() public {
        // Permit2 approve will be called; mock its return value.
        vm.mockCall(
            permit2,
            abi.encodeWithSignature("approve(address,address,uint160,uint48)"),
            abi.encode()
        );

        vm.prank(admin);
        router.initialize(address(layer), address(weth), universalRouter, permit2, poolKey);

        assertTrue(router.initialized());
        assertEq(router.layerToken(), address(layer));
        assertEq(router.weth(), address(weth));
        assertEq(address(router.universalRouter()), universalRouter);
        assertEq(address(router.permit2()), permit2);
    }

    function test_initialize_revertsIfTwice() public {
        vm.startPrank(admin);
        router.initialize(address(layer), address(weth), universalRouter, permit2, poolKey);
        vm.expectRevert(BurnRouter.AlreadyInitialized.selector);
        router.initialize(address(layer), address(weth), universalRouter, permit2, poolKey);
        vm.stopPrank();
    }

    function test_initialize_revertsOnZeros() public {
        vm.startPrank(admin);
        vm.expectRevert(BurnRouter.ZeroAddress.selector);
        router.initialize(address(0), address(weth), universalRouter, permit2, poolKey);
        vm.expectRevert(BurnRouter.ZeroAddress.selector);
        router.initialize(address(layer), address(0), universalRouter, permit2, poolKey);
        vm.expectRevert(BurnRouter.ZeroAddress.selector);
        router.initialize(address(layer), address(weth), address(0), permit2, poolKey);
        vm.expectRevert(BurnRouter.ZeroAddress.selector);
        router.initialize(address(layer), address(weth), universalRouter, address(0), poolKey);
        vm.stopPrank();
    }

    function test_initialize_revertsIfPoolKeyMismatched() public {
        // Build a pool key with a wrong currency.
        MockBurnableToken other = new MockBurnableToken("Other", "OTH");
        (address c0, address c1) = address(layer) < address(other)
            ? (address(layer), address(other))
            : (address(other), address(layer));
        PoolKey memory wrongKey = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 0x800000,
            tickSpacing: 200,
            hooks: IHooks(address(0xBABE))
        });

        vm.prank(admin);
        vm.expectRevert(BurnRouter.InvalidPoolKey.selector);
        router.initialize(address(layer), address(weth), universalRouter, permit2, wrongKey);
    }

    function test_initialize_nonOwnerReverts() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        router.initialize(address(layer), address(weth), universalRouter, permit2, poolKey);
    }

    // ─── direct LAYER burn ───────────────────────────────────────────────

    function test_processBurnLayer() public {
        vm.prank(admin);
        router.initialize(address(layer), address(weth), universalRouter, permit2, poolKey);

        layer.mint(address(router), 1_000_000e18);
        uint256 supplyBefore = layer.totalSupply();

        uint256 burned = router.processBurnLayer();
        assertEq(burned, 1_000_000e18);
        assertEq(layer.totalSupply(), supplyBefore - 1_000_000e18);
        assertEq(layer.balanceOf(address(router)), 0);
    }

    function test_processBurnLayer_revertsIfEmpty() public {
        vm.prank(admin);
        router.initialize(address(layer), address(weth), universalRouter, permit2, poolKey);

        vm.expectRevert(BurnRouter.NothingToBurn.selector);
        router.processBurnLayer();
    }

    function test_processBurnLayer_revertsIfNotInitialized() public {
        vm.expectRevert(BurnRouter.NotInitialized.selector);
        router.processBurnLayer();
    }

    // ─── threshold ───────────────────────────────────────────────────────

    function test_setMinThreshold() public {
        vm.prank(admin);
        router.setMinThreshold(0.05 ether);
        assertEq(router.minProcessThreshold(), 0.05 ether);
    }

    function test_setMinThreshold_floor() public {
        vm.prank(admin);
        vm.expectRevert(BurnRouter.MinThresholdTooLow.selector);
        router.setMinThreshold(1); // below MIN_THRESHOLD_FLOOR
    }

    function test_setMinThreshold_nonAdminReverts() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        router.setMinThreshold(0.05 ether);
    }

    function test_setMinLayerOutPerWeth() public {
        vm.prank(admin);
        router.setMinLayerOutPerWeth(2e18);
        assertEq(router.minLayerOutPerWeth(), 2e18);
    }

    function test_setMinLayerOutPerWeth_nonAdminReverts() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        router.setMinLayerOutPerWeth(2e18);
    }

    function test_requiredMinLayerOutViews() public {
        vm.prank(admin);
        router.initialize(address(layer), address(weth), universalRouter, permit2, poolKey);

        assertEq(router.requiredMinLayerOutForWethAmount(1 ether), 0);

        vm.prank(admin);
        router.setMinLayerOutPerWeth(2e18);
        weth.mint(address(router), 0.5 ether);

        assertEq(router.requiredMinLayerOutForWethAmount(1 ether), 2e18);
        assertEq(router.requiredMinLayerOutForCurrentWethBalance(), 1e18);
    }

    function test_processBurnWeth_revertsWhenFloorUnset() public {
        vm.prank(admin);
        router.initialize(address(layer), address(weth), universalRouter, permit2, poolKey);
        weth.mint(address(router), 1 ether);

        vm.expectRevert(BurnRouter.SlippageFloorNotSet.selector);
        router.processBurnWeth(0);
    }

    function test_processBurnWeth_revertsBelowOwnerFloor() public {
        vm.prank(admin);
        router.initialize(address(layer), address(weth), universalRouter, permit2, poolKey);
        vm.prank(admin);
        router.setMinLayerOutPerWeth(2e18);
        weth.mint(address(router), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(BurnRouter.MinLayerOutBelowFloor.selector, 2e18 - 1, 2e18)
        );
        router.processBurnWeth(2e18 - 1);
    }

    function test_processBurnWeth_succeedsAtOwnerFloor() public {
        vm.prank(admin);
        router.initialize(address(layer), address(weth), universalRouter, permit2, poolKey);
        vm.prank(admin);
        router.setMinLayerOutPerWeth(2e18);
        weth.mint(address(router), 1 ether);

        vm.mockCall(
            permit2,
            abi.encodeWithSignature(
                "approve(address,address,uint160,uint48)",
                address(weth),
                universalRouter,
                uint160(1 ether),
                uint48(block.timestamp + 1)
            ),
            abi.encode()
        );
        bytes4 executeSelector = bytes4(keccak256("execute(bytes,bytes[],uint256)"));
        vm.mockCall(universalRouter, abi.encodeWithSelector(executeSelector), abi.encode());

        (uint256 wethIn, uint256 layerBurned) = router.processBurnWeth(2e18);

        assertEq(wethIn, 1 ether);
        assertEq(layerBurned, 0);
    }

    // ─── adminConvertArtcoin ─────────────────────────────────────────────

    function test_adminSweepHeldToken_blocksLayerAndWeth() public {
        vm.prank(admin);
        router.initialize(address(layer), address(weth), universalRouter, permit2, poolKey);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(BurnRouter.BlockedToken.selector, address(layer)));
        router.adminSweepHeldToken(address(layer), address(0xCAFE), 100);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(BurnRouter.BlockedToken.selector, address(weth)));
        router.adminSweepHeldToken(address(weth), address(0xCAFE), 100);
    }

    function test_adminSweepHeldToken_movesOtherTokens() public {
        vm.prank(admin);
        router.initialize(address(layer), address(weth), universalRouter, permit2, poolKey);

        MockBurnableToken other = new MockBurnableToken("X", "X");
        other.mint(address(router), 5000);

        vm.prank(admin);
        router.adminSweepHeldToken(address(other), address(0xCAFE), 5000);
        assertEq(other.balanceOf(address(0xCAFE)), 5000);
    }

    function test_heldBalanceView() public {
        vm.prank(admin);
        router.initialize(address(layer), address(weth), universalRouter, permit2, poolKey);

        MockBurnableToken artcoin = new MockBurnableToken("ART", "ART");
        artcoin.mint(address(router), 12_345);
        assertEq(router.heldBalance(address(artcoin)), 12_345);
    }

    // ─── status view ─────────────────────────────────────────────────────

    function test_statusView() public {
        vm.prank(admin);
        router.initialize(address(layer), address(weth), universalRouter, permit2, poolKey);

        layer.mint(address(router), 100);
        weth.mint(address(router), 0.005 ether);
        (uint256 l, uint256 w, bool ready) = router.status();
        assertEq(l, 100);
        assertEq(w, 0.005 ether);
        assertFalse(ready); // below default 0.01 threshold

        weth.mint(address(router), 0.01 ether);
        (,, ready) = router.status();
        assertTrue(ready);
    }
}
