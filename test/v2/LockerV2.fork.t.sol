// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {Constants} from "../../src/Constants.sol";
import {ArtCoinsTokenV2} from "../../src/v2/ArtCoinsTokenV2.sol";
import {IArtCoinsFactoryV2} from "../../src/v2/interfaces/IArtCoinsFactoryV2.sol";
import {IArtCoinsLpLockerV2} from "../../src/v2/interfaces/IArtCoinsLpLockerV2.sol";
import {IConstantsBound} from "../../src/v2/interfaces/IConstantsBound.sol";
import {ArtCoinsLpLockerV2} from "../../src/v2/lp-lockers/ArtCoinsLpLockerV2.sol";
import {MockToken} from "./FeeDelivery.t.sol";
import {ForkBase} from "./harness/ForkBase.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

/// @dev Minimal hook: only `afterInitialize` is flagged (a static fee pool
///      needs at least one flag). Exposes `constantsHash()` like every v2 hook.
contract ConstHook {
    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external
        pure
        returns (bytes4)
    {
        return ConstHook.afterInitialize.selector;
    }

    function constantsHash() external pure returns (bytes32) {
        return Constants.hash();
    }
}

contract WrongHashHook {
    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external
        pure
        returns (bytes4)
    {
        return WrongHashHook.afterInitialize.selector;
    }

    function constantsHash() external pure returns (bytes32) {
        return keccak256("other");
    }
}

/// @dev Stand in PositionManager for the no fork unit tests (validation only).
contract StubPosm {
    address public poolManager = address(0x4444);
}

contract LockerV2ForkTest is ForkBase {
    // the coin sorts as token1 against native eth; ticks given as if token0
    int24 constant START = -200_000;
    int24 constant SPACING = 200;
    uint24 constant FEE = 10_000;
    uint256 constant SUPPLY = 1_000_000_000e18;

    ArtCoinsLpLockerV2 locker;
    address owner = makeAddr("owner");
    address launcher = makeAddr("launcher");
    address hook;
    uint160 hookSalt;

    function setUp() public {
        forkMainnet();
        address posm = onFork ? POSITION_MANAGER : address(new StubPosm());
        locker = new ArtCoinsLpLockerV2(owner, posm, PERMIT2);
        vm.prank(owner);
        locker.setLauncher(launcher, true);
        hook = _etchHook(address(new ConstHook()));
    }

    // ── helpers ───────────────────────────────────────────────────────────

    /// @dev Places code at an address whose low 14 bits are exactly AFTER_INITIALIZE (1 << 12).
    function _etchHook(address impl) internal returns (address at) {
        hookSalt++;
        at = address(uint160(0x1000) | (uint160(0xA1C0) + hookSalt) << 20);
        vm.etch(at, impl.code);
    }

    function _key(address token, address h) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: FEE,
            tickSpacing: SPACING,
            hooks: IHooks(h)
        });
    }

    function _poolConfig(address h) internal pure returns (IArtCoinsFactoryV2.PoolConfigV2 memory) {
        return IArtCoinsFactoryV2.PoolConfigV2({
            hook: h,
            tickIfToken0IsCoin: START,
            tickSpacing: SPACING,
            extension: address(0),
            extensionData: ""
        });
    }

    function _lockerConfig(uint256 nPos)
        internal
        view
        returns (IArtCoinsFactoryV2.LockerConfigV2 memory c)
    {
        c.locker = address(locker);
        c.tickLower = new int24[](nPos);
        c.tickUpper = new int24[](nPos);
        c.positionBps = new uint16[](nPos);
        uint256 left = Constants.BPS;
        for (uint256 i; i < nPos; ++i) {
            c.tickLower[i] = START + int24(int256(i)) * SPACING * 10;
            c.tickUpper[i] = -120_000;
            uint16 b = i == nPos - 1 ? uint16(left) : uint16(Constants.BPS / nPos);
            c.positionBps[i] = b;
            left -= b;
        }
    }

    /// @dev Inits the pool and places liquidity from `launcher`.
    function _launch(address coin, uint256 nPos) internal returns (PoolKey memory key) {
        key = _key(coin, hook);
        IPoolManager(POOL_MANAGER).initialize(key, TickMath.getSqrtPriceAtTick(-START));
        IArtCoinsFactoryV2.LockerConfigV2 memory lc = _lockerConfig(nPos);
        vm.startPrank(launcher);
        IERC20(coin).approve(address(locker), SUPPLY);
        locker.placeLiquidity(lc, _poolConfig(hook), key, SUPPLY, coin);
        vm.stopPrank();
    }

    function _newCoin() internal returns (MockToken t) {
        t = new MockToken();
        t.mint(launcher, SUPPLY);
        t.mint(address(this), 1e27);
    }

    // ── no fork unit tests (validation) ───────────────────────────────────

    function _expectPlaceRevert(
        IArtCoinsFactoryV2.LockerConfigV2 memory lc,
        PoolKey memory key,
        bytes memory err
    ) internal {
        vm.prank(launcher);
        vm.expectRevert(err);
        locker.placeLiquidity(
            lc, _poolConfig(address(key.hooks)), key, SUPPLY, Currency.unwrap(key.currency1)
        );
    }

    function test_lockerV2_constantsHash() public view {
        assertEq(locker.constantsHash(), Constants.hash());
    }

    function test_lockerV2_place_notLauncher_reverts() public {
        IArtCoinsFactoryV2.LockerConfigV2 memory lc = _lockerConfig(1);
        PoolKey memory key = _key(address(0xC01), hook);
        vm.expectRevert(IArtCoinsLpLockerV2.NotLauncher.selector);
        locker.placeLiquidity(lc, _poolConfig(hook), key, SUPPLY, address(0xC01));
    }

    function test_lockerV2_place_zeroToken_reverts() public {
        _expectPlaceRevert(
            _lockerConfig(1),
            _key(address(0), hook),
            abi.encodeWithSelector(IArtCoinsLpLockerV2.ZeroAddress.selector)
        );
    }

    function test_lockerV2_constructor_zeroAddress_reverts() public {
        StubPosm posm = new StubPosm();
        vm.expectRevert(IArtCoinsLpLockerV2.ZeroAddress.selector);
        new ArtCoinsLpLockerV2(owner, address(0), PERMIT2);
        vm.expectRevert(IArtCoinsLpLockerV2.ZeroAddress.selector);
        new ArtCoinsLpLockerV2(owner, address(posm), address(0));
    }

    function test_lockerV2_place_tooManyPositions_reverts() public {
        _expectPlaceRevert(
            _lockerConfig(Constants.MAX_LP_POSITIONS + 1),
            _key(address(0xC01), hook),
            abi.encodeWithSelector(IArtCoinsLpLockerV2.TooManyPositions.selector)
        );
    }

    function test_lockerV2_place_badPositions_revert() public {
        IArtCoinsFactoryV2.LockerConfigV2 memory lc = _lockerConfig(2);
        lc.positionBps[1] = 0;
        lc.positionBps[0] = 10_000;
        _expectPlaceRevert(
            lc,
            _key(address(0xC01), hook),
            abi.encodeWithSelector(IArtCoinsLpLockerV2.InvalidPositionBps.selector)
        );
        // sum != 10000
        lc = _lockerConfig(2);
        lc.positionBps[1] -= 1;
        _expectPlaceRevert(
            lc,
            _key(address(0xC01), hook),
            abi.encodeWithSelector(IArtCoinsLpLockerV2.InvalidPositionBps.selector)
        );
        // below the start: needs eth
        lc = _lockerConfig(1);
        lc.tickLower[0] = START - SPACING;
        _expectPlaceRevert(
            lc,
            _key(address(0xC01), hook),
            abi.encodeWithSelector(
                IArtCoinsLpLockerV2.InvalidTickRange.selector, START - SPACING, int24(-120_000)
            )
        );
        // empty range
        lc = _lockerConfig(1);
        lc.tickUpper[0] = lc.tickLower[0];
        _expectPlaceRevert(
            lc,
            _key(address(0xC01), hook),
            abi.encodeWithSelector(
                IArtCoinsLpLockerV2.InvalidTickRange.selector, lc.tickLower[0], lc.tickLower[0]
            )
        );
        // off tick spacing
        lc = _lockerConfig(1);
        lc.tickUpper[0] = -120_001;
        _expectPlaceRevert(
            lc,
            _key(address(0xC01), hook),
            abi.encodeWithSelector(
                IArtCoinsLpLockerV2.InvalidTickRange.selector, lc.tickLower[0], int24(-120_001)
            )
        );
        // mismatched arrays
        lc = _lockerConfig(1);
        lc.tickUpper = new int24[](0);
        _expectPlaceRevert(
            lc,
            _key(address(0xC01), hook),
            abi.encodeWithSelector(IArtCoinsLpLockerV2.MismatchedPositionArrays.selector)
        );
        // no positions
        lc = _lockerConfig(0);
        _expectPlaceRevert(
            lc,
            _key(address(0xC01), hook),
            abi.encodeWithSelector(IArtCoinsLpLockerV2.InvalidPositionBps.selector)
        );
    }

    function test_lockerV2_place_badKey_reverts() public {
        IArtCoinsFactoryV2.LockerConfigV2 memory lc = _lockerConfig(1);
        // not native paired
        PoolKey memory key = _key(address(0xC01), hook);
        key.currency0 = Currency.wrap(WETH);
        _expectPlaceRevert(
            lc, key, abi.encodeWithSelector(IArtCoinsLpLockerV2.UnsupportedPoolKey.selector)
        );
        // hook with a different constants set
        address wrong = _etchHook(address(new WrongHashHook()));
        _expectPlaceRevert(
            lc,
            _key(address(0xC01), wrong),
            abi.encodeWithSelector(IConstantsBound.ConstantsMismatch.selector, wrong)
        );
    }

    function test_lockerV2_setLauncher() public {
        address l2 = makeAddr("l2");
        vm.expectRevert();
        locker.setLauncher(l2, true);
        vm.startPrank(owner);
        vm.expectRevert(IArtCoinsLpLockerV2.ZeroAddress.selector);
        locker.setLauncher(address(0), true);
        vm.expectEmit(true, false, false, true, address(locker));
        emit IArtCoinsLpLockerV2.LauncherSet(l2, true);
        locker.setLauncher(l2, true);
        assertTrue(locker.isLauncher(l2));
        locker.setLauncher(l2, false);
        assertFalse(locker.isLauncher(l2));
        vm.stopPrank();
    }

    function test_lockerV2_rescue_rules() public {
        MockToken t = new MockToken();
        t.mint(address(locker), 5e18);
        vm.prank(address(0xBAD));
        vm.expectRevert();
        locker.rescue(address(t), address(0xBAD), 5e18);
        address posm = address(locker.positionManager());
        vm.startPrank(owner);
        vm.expectRevert(IArtCoinsLpLockerV2.RescueForbidden.selector);
        locker.rescue(posm, owner, 1);
        vm.expectRevert(IArtCoinsLpLockerV2.ZeroAddress.selector);
        locker.rescue(address(t), address(0), 1);
        locker.rescue(address(t), owner, 5e18);
        vm.stopPrank();
        assertEq(t.balanceOf(owner), 5e18);
    }

    function test_lockerV2_rescue_eth() public {
        vm.deal(address(locker), 1 ether);
        address to = makeAddr("ethTo");
        vm.prank(owner);
        locker.rescue(address(0), to, 1 ether);
        assertEq(to.balance, 1 ether);
        assertEq(address(locker).balance, 0);
    }

    // ── fork tests (real PoolManager and PositionManager) ─────────────────

    function test_lockerV2_place_recordsLock() public onlyFork {
        MockToken coin = _newCoin();
        uint256 dead0 = coin.balanceOf(Constants.DEAD);
        uint256 pm0 = coin.balanceOf(POOL_MANAGER);
        uint256 expectedId = IPositionManager(POSITION_MANAGER).nextTokenId();
        PoolKey memory key = _key(address(coin), hook);
        IPoolManager(POOL_MANAGER).initialize(key, TickMath.getSqrtPriceAtTick(-START));
        IArtCoinsFactoryV2.LockerConfigV2 memory lc3 = _lockerConfig(3);
        vm.startPrank(launcher);
        coin.approve(address(locker), SUPPLY);
        vm.expectEmit(true, false, false, false, address(locker));
        emit IArtCoinsLpLockerV2.LiquidityLocked(
            address(coin), key, SUPPLY, expectedId, 3, lc3.tickLower, lc3.tickUpper, lc3.positionBps
        );
        locker.placeLiquidity(lc3, _poolConfig(hook), key, SUPPLY, address(coin));
        vm.stopPrank();

        IArtCoinsLpLockerV2.LockedLiquidity memory info = locker.lockedLiquidity(address(coin));
        assertEq(info.token, address(coin));
        assertEq(info.positionId, expectedId);
        assertEq(info.numPositions, 3);
        assertEq(address(info.poolKey.hooks), hook);
        // locker owns the nfts, holds no coin
        for (uint256 i; i < 3; ++i) {
            assertEq(IERC721Like(POSITION_MANAGER).ownerOf(info.positionId + i), address(locker));
            assertGt(
                IPositionManager(POSITION_MANAGER).getPositionLiquidity(info.positionId + i), 0
            );
        }
        assertEq(coin.balanceOf(address(locker)), 0);
        assertEq(coin.balanceOf(launcher), 0);
        // rounding dust goes to DEAD: pulled supply = pool manager delta + dead delta
        assertEq(
            coin.balanceOf(POOL_MANAGER) - pm0 + coin.balanceOf(Constants.DEAD) - dead0, SUPPLY
        );
        // all positions sit at or below the start price (coin only): none active
        assertEq(readLiquidity(key), 0);

        // second placement for the same coin reverts
        IArtCoinsFactoryV2.LockerConfigV2 memory lc = _lockerConfig(1);
        vm.prank(launcher);
        vm.expectRevert(IArtCoinsLpLockerV2.TokenAlreadyLocked.selector);
        locker.placeLiquidity(lc, _poolConfig(hook), key, SUPPLY, address(coin));
    }

    /// @dev The real v2 token (solady) fixes the Permit2 allowance at
    ///      infinity and reverts any approve to Permit2. Placement skips the
    ///      erc20 approve and its reset.
    function test_lockerV2_place_realTokenV2_permit2Infinite() public onlyFork {
        IArtCoinsFactoryV2.TokenConfigV2 memory t;
        t.tokenAdmin = makeAddr("tokenAdmin");
        t.name = "Locker Test";
        t.symbol = "LKT";
        IArtCoinsFactoryV2.RestrictionConfigV2 memory restr; // not restricted
        ArtCoinsTokenV2.CanonicalPool memory canon = ArtCoinsTokenV2.CanonicalPool({
            hook: hook, poolManager: POOL_MANAGER, tickSpacing: SPACING
        });
        ArtCoinsTokenV2 coin = new ArtCoinsTokenV2(t, 2 * SUPPLY, restr, canon, launcher);
        assertEq(coin.allowance(address(locker), PERMIT2), type(uint256).max);
        // the token rejects approvals to Permit2, which is what broke placement
        vm.prank(address(locker));
        vm.expectRevert(bytes4(0x3f68539a)); // Permit2AllowanceIsFixedAtInfinity()
        coin.approve(PERMIT2, 0);

        _launch(address(coin), 3);
        IArtCoinsLpLockerV2.LockedLiquidity memory info = locker.lockedLiquidity(address(coin));
        assertEq(info.numPositions, 3);
        for (uint256 i; i < 3; ++i) {
            assertGt(
                IPositionManager(POSITION_MANAGER).getPositionLiquidity(info.positionId + i), 0
            );
        }
        assertEq(coin.balanceOf(address(locker)), 0);
        assertEq(coin.allowance(address(locker), PERMIT2), type(uint256).max);
        (uint160 p2amount,,) = IAllowanceTransferLike(PERMIT2)
            .allowance(address(locker), address(coin), POSITION_MANAGER);
        assertEq(p2amount, 0);
    }

    /// @dev A plain erc20 gets the exact approve to Permit2, reset to 0 after
    ///      the mint, and the Permit2 allowance is zeroed too.
    function test_lockerV2_place_plainErc20_approveReset() public onlyFork {
        MockToken coin = _newCoin();
        assertEq(coin.allowance(address(locker), PERMIT2), 0);
        vm.recordLogs();
        _launch(address(coin), 2);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // the exact approve happened (Approval(locker, permit2, SUPPLY)) and was reset
        bool sawExact;
        bytes32 approvalSig = keccak256("Approval(address,address,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(coin) && logs[i].topics[0] == approvalSig
                    && logs[i].topics[1] == bytes32(uint256(uint160(address(locker))))
                    && logs[i].topics[2] == bytes32(uint256(uint160(PERMIT2)))
                    && abi.decode(logs[i].data, (uint256)) == SUPPLY
            ) sawExact = true;
        }
        assertTrue(sawExact);
        assertEq(coin.allowance(address(locker), PERMIT2), 0);
        (uint160 p2amount,,) = IAllowanceTransferLike(PERMIT2)
            .allowance(address(locker), address(coin), POSITION_MANAGER);
        assertEq(p2amount, 0);
        assertEq(locker.lockedLiquidity(address(coin)).numPositions, 2);
    }

    function test_lockerV2_place_maxPositions() public onlyFork {
        MockToken coin = _newCoin();
        _launch(address(coin), Constants.MAX_LP_POSITIONS);
        assertEq(locker.lockedLiquidity(address(coin)).numPositions, Constants.MAX_LP_POSITIONS);
    }
}

interface IERC721Like {
    function ownerOf(uint256 id) external view returns (address);
}

interface IAllowanceTransferLike {
    function allowance(address user, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}
