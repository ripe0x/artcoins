// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {Constants} from "../../src/Constants.sol";
import {ArtCoinsFeeEscrowV2} from "../../src/v2/ArtCoinsFeeEscrowV2.sol";
import {ArtCoinsTokenV2} from "../../src/v2/ArtCoinsTokenV2.sol";
import {IArtCoinsFactoryV2} from "../../src/v2/interfaces/IArtCoinsFactoryV2.sol";
import {IArtCoinsLpLockerV2} from "../../src/v2/interfaces/IArtCoinsLpLockerV2.sol";
import {IConstantsBound} from "../../src/v2/interfaces/IConstantsBound.sol";
import {ArtCoinsLpLockerV2} from "../../src/v2/lp-lockers/ArtCoinsLpLockerV2.sol";
import {
    BlockingToken,
    GasBurner,
    MockToken,
    PayableRecipient,
    RevertingRecipient
} from "./FeeDelivery.t.sol";
import {ForkBase} from "./harness/ForkBase.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

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

/// @dev LF-01 attack shape: open an unlock, mint a position without paying,
///      then try to collect so the locker's TAKE would net against the debt.
contract UnlockAttacker is IUnlockCallback {
    IPoolManager immutable pm;
    IPositionManager immutable posm;
    ArtCoinsLpLockerV2 immutable locker;

    constructor(IPoolManager pm_, IPositionManager posm_, ArtCoinsLpLockerV2 locker_) {
        pm = pm_;
        posm = posm_;
        locker = locker_;
    }

    function attack(PoolKey calldata key, address token, int24 lo, int24 hi) external {
        pm.unlock(abi.encode(key, token, lo, hi));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, address token, int24 lo, int24 hi) =
            abi.decode(data, (PoolKey, address, int24, int24));
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION));
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(
            key,
            lo,
            hi,
            uint256(1e18),
            type(uint128).max,
            type(uint128).max,
            address(this),
            bytes("")
        );
        // unpaid: leaves a debt on the PositionManager inside this unlock
        posm.modifyLiquiditiesWithoutUnlock(actions, params);
        locker.collectRewards(token);
        return "";
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC721Received.selector;
    }
}

/// @dev Recipient that is also the locker owner and tries to rescue the
///      in flight shares from inside its push.
contract RescuingOwner {
    ArtCoinsLpLockerV2 immutable locker;
    bool public tried;

    constructor(ArtCoinsLpLockerV2 l) {
        locker = l;
    }

    function accept() external {
        locker.acceptOwnership();
    }

    receive() external payable {
        // reverts (reentrancy lock), which fails this push into the escrow
        locker.rescue(address(0), address(this), address(locker).balance);
    }
}

contract LockerV2ForkTest is ForkBase {
    // the coin sorts as token1 against native eth; ticks given as if token0
    int24 constant START = -200_000;
    int24 constant SPACING = 200;
    uint24 constant FEE = 10_000;
    uint256 constant SUPPLY = 1_000_000_000e18;

    ArtCoinsFeeEscrowV2 escrow;
    ArtCoinsLpLockerV2 locker;
    address owner = makeAddr("owner");
    address launcher = makeAddr("launcher");
    address hook;
    uint160 hookSalt;

    function setUp() public {
        forkMainnet();
        escrow = new ArtCoinsFeeEscrowV2(owner);
        address posm = onFork ? POSITION_MANAGER : address(new StubPosm());
        locker = new ArtCoinsLpLockerV2(owner, posm, PERMIT2, address(escrow));
        vm.startPrank(owner);
        escrow.addDepositor(address(locker), true);
        locker.setLauncher(launcher, true);
        vm.stopPrank();
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
            tickIfToken0IsArtCoin: START,
            tickSpacing: SPACING,
            extension: address(0),
            extensionData: ""
        });
    }

    function _lockerConfig(address[] memory recipients, uint16[] memory bps, uint256 nPos)
        internal
        view
        returns (IArtCoinsFactoryV2.LockerConfigV2 memory c)
    {
        c.locker = address(locker);
        c.rewardRecipients = recipients;
        c.rewardBps = bps;
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

    function _one(address r) internal pure returns (address[] memory a, uint16[] memory b) {
        a = new address[](1);
        a[0] = r;
        b = new uint16[](1);
        b[0] = 10_000;
    }

    /// @dev Deploys `coin` supply to the launcher, inits the pool, places liquidity.
    function _launch(address coin, address[] memory recipients, uint16[] memory bps, uint256 nPos)
        internal
        returns (PoolKey memory key)
    {
        key = _key(coin, hook);
        IPoolManager(POOL_MANAGER).initialize(key, TickMath.getSqrtPriceAtTick(-START));
        IArtCoinsFactoryV2.LockerConfigV2 memory lc = _lockerConfig(recipients, bps, nPos);
        vm.startPrank(launcher);
        IERC20(coin).approve(address(locker), SUPPLY);
        locker.placeLiquidity(lc, _poolConfig(hook), key, SUPPLY, coin, type(uint256).max);
        vm.stopPrank();
    }

    function _newCoin() internal returns (MockToken t) {
        t = new MockToken();
        t.mint(launcher, SUPPLY);
        t.mint(address(this), 1e27);
    }

    /// @dev Buy then sell so both currencies accrue lp fees.
    function _trade(PoolKey memory key) internal {
        swapExactIn(key, true, 2 ether, address(this), "");
        swapExactIn(
            key,
            false,
            IERC20(Currency.unwrap(key.currency1)).balanceOf(address(this)) / 4,
            address(this),
            ""
        );
    }

    function _three()
        internal
        returns (
            address[] memory r,
            uint16[] memory b,
            PayableRecipient p,
            RevertingRecipient rv,
            GasBurner g
        )
    {
        p = new PayableRecipient();
        rv = new RevertingRecipient();
        g = new GasBurner();
        r = new address[](3);
        r[0] = address(p);
        r[1] = address(rv);
        r[2] = address(g);
        b = new uint16[](3);
        b[0] = 5000;
        b[1] = 3000;
        b[2] = 2000;
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
            lc,
            _poolConfig(address(key.hooks)),
            key,
            SUPPLY,
            Currency.unwrap(key.currency1),
            type(uint256).max
        );
    }

    function test_lockerV2_constantsHash() public view {
        assertEq(locker.constantsHash(), Constants.hash());
    }

    function test_lockerV2_place_notLauncher_reverts() public {
        (address[] memory r, uint16[] memory b) = _one(address(1));
        IArtCoinsFactoryV2.LockerConfigV2 memory lc = _lockerConfig(r, b, 1);
        PoolKey memory key = _key(address(0xC01), hook);
        vm.expectRevert(IArtCoinsLpLockerV2.NotLauncher.selector);
        locker.placeLiquidity(lc, _poolConfig(hook), key, SUPPLY, address(0xC01), type(uint256).max);
    }

    /// @dev FT-10: array length mismatch reverts instead of truncating.
    function test_lockerV2_place_bpsMismatch_reverts() public {
        address[] memory r = new address[](2);
        r[0] = address(1);
        r[1] = address(2);
        uint16[] memory b = new uint16[](1);
        b[0] = 10_000;
        _expectPlaceRevert(
            _lockerConfig(r, b, 1),
            _key(address(0xC01), hook),
            abi.encodeWithSelector(IArtCoinsLpLockerV2.MismatchedRewardArrays.selector)
        );
    }

    function test_lockerV2_place_bpsSum_reverts() public {
        address[] memory r = new address[](2);
        r[0] = address(1);
        r[1] = address(2);
        uint16[] memory b = new uint16[](2);
        b[0] = 5000;
        b[1] = 4999;
        _expectPlaceRevert(
            _lockerConfig(r, b, 1),
            _key(address(0xC01), hook),
            abi.encodeWithSelector(IArtCoinsLpLockerV2.InvalidRewardBps.selector)
        );
        b[1] = 0;
        b[0] = 10_000;
        _expectPlaceRevert(
            _lockerConfig(r, b, 1),
            _key(address(0xC01), hook),
            abi.encodeWithSelector(IArtCoinsLpLockerV2.ZeroRewardAmount.selector)
        );
    }

    function test_lockerV2_place_tooManyRecipients_reverts() public {
        uint256 n = Constants.MAX_REWARD_PARTICIPANTS + 1;
        address[] memory r = new address[](n);
        uint16[] memory b = new uint16[](n);
        for (uint256 i; i < n; ++i) {
            r[i] = address(uint160(i + 1));
            b[i] = 1000;
        }
        b[0] = uint16(10_000 - 1000 * (n - 1));
        _expectPlaceRevert(
            _lockerConfig(r, b, 1),
            _key(address(0xC01), hook),
            abi.encodeWithSelector(IArtCoinsLpLockerV2.TooManyRewardParticipants.selector)
        );
    }

    /// @dev LF-05: zero (or self) recipient strands fees; rejected at placement.
    function test_lockerV2_place_zeroRecipient_reverts() public {
        (address[] memory r, uint16[] memory b) = _one(address(0));
        _expectPlaceRevert(
            _lockerConfig(r, b, 1),
            _key(address(0xC01), hook),
            abi.encodeWithSelector(IArtCoinsLpLockerV2.ZeroAddress.selector)
        );
        r[0] = address(locker);
        _expectPlaceRevert(
            _lockerConfig(r, b, 1),
            _key(address(0xC01), hook),
            abi.encodeWithSelector(IArtCoinsLpLockerV2.ZeroAddress.selector)
        );
    }

    function test_lockerV2_place_tooManyPositions_reverts() public {
        (address[] memory r, uint16[] memory b) = _one(address(1));
        _expectPlaceRevert(
            _lockerConfig(r, b, Constants.MAX_LP_POSITIONS + 1),
            _key(address(0xC01), hook),
            abi.encodeWithSelector(IArtCoinsLpLockerV2.TooManyPositions.selector)
        );
    }

    function test_lockerV2_place_badPositions_revert() public {
        (address[] memory r, uint16[] memory b) = _one(address(1));
        IArtCoinsFactoryV2.LockerConfigV2 memory lc = _lockerConfig(r, b, 2);
        lc.positionBps[1] = 0;
        lc.positionBps[0] = 10_000;
        _expectPlaceRevert(
            lc,
            _key(address(0xC01), hook),
            abi.encodeWithSelector(IArtCoinsLpLockerV2.InvalidPositionBps.selector)
        );
        lc = _lockerConfig(r, b, 1);
        lc.tickLower[0] = START - SPACING; // below the start: needs eth
        _expectPlaceRevert(
            lc,
            _key(address(0xC01), hook),
            abi.encodeWithSelector(
                IArtCoinsLpLockerV2.InvalidTickRange.selector, START - SPACING, int24(-120_000)
            )
        );
        lc = _lockerConfig(r, b, 1);
        lc.tickUpper = new int24[](0);
        _expectPlaceRevert(
            lc,
            _key(address(0xC01), hook),
            abi.encodeWithSelector(IArtCoinsLpLockerV2.MismatchedPositionArrays.selector)
        );
        lc = _lockerConfig(r, b, 0);
        _expectPlaceRevert(
            lc,
            _key(address(0xC01), hook),
            abi.encodeWithSelector(IArtCoinsLpLockerV2.InvalidPositionBps.selector)
        );
    }

    function test_lockerV2_place_badKey_reverts() public {
        (address[] memory r, uint16[] memory b) = _one(address(1));
        IArtCoinsFactoryV2.LockerConfigV2 memory lc = _lockerConfig(r, b, 1);
        // not native paired (D17)
        PoolKey memory key = _key(address(0xC01), hook);
        key.currency0 = Currency.wrap(WETH);
        _expectPlaceRevert(
            lc, key, abi.encodeWithSelector(ArtCoinsLpLockerV2.UnsupportedPoolKey.selector)
        );
        // hook with a different constants set
        address wrong = _etchHook(address(new WrongHashHook()));
        _expectPlaceRevert(
            lc,
            _key(address(0xC01), wrong),
            abi.encodeWithSelector(IConstantsBound.ConstantsMismatch.selector, wrong)
        );
    }

    function test_lockerV2_keeperRewardBps_defaultsToZero() public {
        assertEq(locker.keeperRewardBps(), 0);
    }

    function test_lockerV2_ownerSetters_bounded() public {
        vm.startPrank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtCoinsLpLockerV2.KeeperRewardBpsOutOfBounds.selector, 201, 200
            )
        );
        locker.setKeeperRewardBps(201);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtCoinsLpLockerV2.KeeperRewardCapOutOfBounds.selector,
                0.05 ether + 1,
                0.001 ether,
                0.05 ether
            )
        );
        locker.setKeeperRewardCap(0.05 ether + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtCoinsLpLockerV2.KeeperRewardCapOutOfBounds.selector,
                0.001 ether - 1,
                0.001 ether,
                0.05 ether
            )
        );
        locker.setKeeperRewardCap(0.001 ether - 1);
        locker.setKeeperRewardBps(200);
        locker.setKeeperRewardCap(0.05 ether);
        // escrow must share the constants set
        vm.expectRevert(
            abi.encodeWithSelector(IConstantsBound.ConstantsMismatch.selector, address(0xBEEF))
        );
        locker.setFeeEscrow(address(0xBEEF));
        ArtCoinsFeeEscrowV2 e2 = new ArtCoinsFeeEscrowV2(owner);
        locker.setFeeEscrow(address(e2));
        vm.stopPrank();
        assertEq(locker.feeEscrow(), address(e2));
        assertEq(locker.keeperRewardBps(), 200);

        vm.expectRevert();
        locker.setLauncher(address(this), true);
    }

    function test_lockerV2_rescue_rules() public {
        MockToken t = new MockToken();
        t.mint(address(locker), 5e18);
        vm.prank(address(0xBAD));
        vm.expectRevert();
        locker.rescue(address(t), address(0xBAD), 5e18);
        address posm = address(locker.positionManager());
        vm.startPrank(owner);
        vm.expectRevert(ArtCoinsLpLockerV2.RescueForbidden.selector);
        locker.rescue(posm, owner, 1);
        vm.expectRevert(IArtCoinsLpLockerV2.ZeroAddress.selector);
        locker.rescue(address(t), address(0), 1);
        locker.rescue(address(t), owner, 5e18);
        vm.stopPrank();
        assertEq(t.balanceOf(owner), 5e18);
    }

    function test_lockerV2_collect_unknownToken_reverts() public {
        vm.expectRevert(IArtCoinsLpLockerV2.TokenNotFound.selector);
        locker.collectRewards(address(0xC01));
    }

    // ── fork tests (real PoolManager and PositionManager) ─────────────────

    function test_lockerV2_place_freezesSplit() public onlyFork {
        MockToken coin = _newCoin();
        (address[] memory r, uint16[] memory b,,,) = _three();
        _launch(address(coin), r, b, 3);
        IArtCoinsLpLockerV2.TokenRewardInfoV2 memory info = locker.tokenRewards(address(coin));
        assertEq(info.numPositions, 3);
        assertEq(info.rewardRecipients.length, 3);
        assertEq(locker.rewardBps(address(coin))[1], 3000);
        assertEq(locker.rewardRecipients(address(coin))[2], r[2]);
        // locker owns the nfts, holds no coin
        for (uint256 i; i < 3; ++i) {
            assertEq(IERC721Like(POSITION_MANAGER).ownerOf(info.positionId + i), address(locker));
        }
        assertEq(coin.balanceOf(address(locker)), 0);
        // every position holds liquidity; all sit at or below the start price
        // (coin only), so none is active until the first buy
        for (uint256 i; i < 3; ++i) {
            assertGt(
                IPositionManager(POSITION_MANAGER).getPositionLiquidity(info.positionId + i), 0
            );
        }
        assertEq(readLiquidity(_key(address(coin), hook)), 0);
        // second placement for the same coin reverts
        IArtCoinsFactoryV2.LockerConfigV2 memory lc = _lockerConfig(r, b, 1);
        vm.prank(launcher);
        vm.expectRevert(IArtCoinsLpLockerV2.TokenAlreadyHasRewards.selector);
        locker.placeLiquidity(
            lc,
            _poolConfig(hook),
            _key(address(coin), hook),
            SUPPLY,
            address(coin),
            type(uint256).max
        );
    }

    /// @dev D37: the real v2 token (solady) fixes the Permit2 allowance at
    ///      infinity and reverts any approve to Permit2. Placement must skip
    ///      the erc20 approve and its reset, and the coin must still collect.
    function test_lockerV2_place_realTokenV2_permit2Infinite() public onlyFork {
        IArtCoinsFactoryV2.TokenConfigV2 memory t;
        t.tokenAdmin = makeAddr("tokenAdmin");
        t.name = "Locker Test";
        t.symbol = "LKT";
        IArtCoinsFactoryV2.RestrictionConfigV2 memory restr; // not restricted
        ArtCoinsTokenV2.CanonicalPool memory canon = ArtCoinsTokenV2.CanonicalPool({
            hook: hook, poolManager: POOL_MANAGER, tickSpacing: SPACING
        });
        ArtCoinsTokenV2 coin =
            new ArtCoinsTokenV2(t, 2 * SUPPLY, restr, new address[](0), canon, launcher);
        assertEq(coin.allowance(address(locker), PERMIT2), type(uint256).max);
        // the token rejects approvals to Permit2, which is what broke placement
        vm.prank(address(locker));
        vm.expectRevert(bytes4(0x3f68539a)); // Permit2AllowanceIsFixedAtInfinity()
        coin.approve(PERMIT2, 0);
        // half the supply to this contract so it can sell
        vm.prank(launcher);
        coin.transfer(address(this), SUPPLY);

        PayableRecipient p = new PayableRecipient();
        (address[] memory r, uint16[] memory b) = _one(address(p));
        PoolKey memory key = _launch(address(coin), r, b, 3);
        IArtCoinsLpLockerV2.TokenRewardInfoV2 memory info = locker.tokenRewards(address(coin));
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

        _trade(key);
        locker.collectRewards(address(coin));
        assertGt(p.received(), 0);
        assertGt(coin.balanceOf(address(p)), 0);
        assertEq(coin.balanceOf(address(locker)), 0);
    }

    /// @dev D37 other branch: a plain erc20 gets the exact approve to Permit2,
    ///      reset to 0 after the mint, and the Permit2 allowance is zeroed too.
    function test_lockerV2_place_plainErc20_approveReset() public onlyFork {
        MockToken coin = _newCoin();
        assertEq(coin.allowance(address(locker), PERMIT2), 0);
        (address[] memory r, uint16[] memory b) = _one(address(new PayableRecipient()));
        vm.recordLogs();
        _launch(address(coin), r, b, 2);
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
        assertEq(locker.tokenRewards(address(coin)).numPositions, 2);
    }

    function test_lockerV2_place_maxPositions() public onlyFork {
        MockToken coin = _newCoin();
        (address[] memory r, uint16[] memory b) = _one(address(new PayableRecipient()));
        _launch(address(coin), r, b, Constants.MAX_LP_POSITIONS);
        assertEq(locker.tokenRewards(address(coin)).numPositions, Constants.MAX_LP_POSITIONS);
        _trade(_key(address(coin), hook));
        locker.collectRewards(address(coin));
        assertGt(r[0].balance, 0);
    }

    function test_delivery_locker_payable_pushed() public onlyFork {
        MockToken coin = _newCoin();
        PayableRecipient p = new PayableRecipient();
        (address[] memory r, uint16[] memory b) = _one(address(p));
        PoolKey memory key = _launch(address(coin), r, b, 2);
        _trade(key);
        locker.collectRewards(address(coin));
        assertApproxEqRel(p.received(), 0.02 ether, 0.01e18); // 1% of 2 eth
        assertGt(coin.balanceOf(address(p)), 0);
        assertEq(escrow.totalOwed(address(0)), 0);
        assertEq(escrow.totalOwed(address(coin)), 0);
        assertEq(address(locker).balance, 0);
        assertEq(coin.balanceOf(address(locker)), 0);
        // nothing left: second collect delivers nothing
        uint256 before = p.received();
        locker.collectRewards(address(coin));
        assertEq(p.received(), before);
    }

    function test_lockerV2_collect_revertingRecipient_noRevert() public onlyFork {
        MockToken coin = _newCoin();
        (
            address[] memory r,
            uint16[] memory b,
            PayableRecipient p,
            RevertingRecipient rv,
            GasBurner g
        ) = _three();
        PoolKey memory key = _launch(address(coin), r, b, 3);
        _trade(key);

        vm.recordLogs();
        locker.collectRewards(address(coin));
        (uint256 got0, uint256 got1) = _collected(vm.getRecordedLogs());

        // payable pushed, reverting and gas burner escrowed, no wei lost
        assertEq(p.received(), got0 * 5000 / 10_000);
        assertEq(escrow.balances(address(rv), address(0)), got0 * 3000 / 10_000);
        assertEq(address(rv).balance, 0);
        uint256 burnerShare = got0 - got0 * 5000 / 10_000 - got0 * 3000 / 10_000;
        assertEq(escrow.balances(address(g), address(0)), burnerShare);
        assertEq(p.received() + escrow.totalOwed(address(0)), got0);
        // coin side: plain transfers succeed for every recipient
        assertEq(
            coin.balanceOf(address(p)) + coin.balanceOf(address(rv)) + coin.balanceOf(address(g)),
            got1
        );
        assertEq(address(locker).balance, 0);
        assertEq(coin.balanceOf(address(locker)), 0);
    }

    function test_delivery_locker_reverting_escrowed_claimable() public onlyFork {
        MockToken coin = _newCoin();
        RevertingRecipient rv = new RevertingRecipient();
        (address[] memory r, uint16[] memory b) = _one(address(rv));
        _trade(_launch(address(coin), r, b, 1));
        vm.recordLogs();
        locker.collectRewards(address(coin));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawEscrowed;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].topics[0] == IArtCoinsLpLockerV2.RewardDelivered.selector
                    && logs[i].topics[2] == bytes32(0)
            ) {
                (, bool escrowed) = abi.decode(logs[i].data, (uint256, bool));
                sawEscrowed = escrowed;
            }
        }
        assertTrue(sawEscrowed);
        uint256 owed = escrow.balances(address(rv), address(0));
        assertGt(owed, 0);
        // the recipient redirects its own balance
        address payable dest = payable(makeAddr("dest"));
        vm.prank(address(rv));
        escrow.claimTo(address(rv), address(0), dest);
        assertEq(dest.balance, owed);
    }

    function test_delivery_locker_coinBlocked_escrowed() public onlyFork {
        BlockingToken coin = new BlockingToken();
        coin.mint(launcher, SUPPLY);
        coin.mint(address(this), 1e27);
        PayableRecipient p = new PayableRecipient();
        (address[] memory r, uint16[] memory b) = _one(address(p));
        PoolKey memory key = _launch(address(coin), r, b, 1);
        _trade(key);
        coin.setBlocked(address(p), true);
        vm.recordLogs();
        locker.collectRewards(address(coin));
        (, uint256 got1) = _collected(vm.getRecordedLogs());
        assertGt(got1, 0);
        assertEq(escrow.balances(address(p), address(coin)), got1);
        assertEq(coin.balanceOf(address(escrow)), got1);
        assertEq(coin.balanceOf(address(locker)), 0);
        assertEq(coin.allowance(address(locker), address(escrow)), 0);
    }

    function test_lockerV2_keeperReward_bpsMath() public onlyFork {
        MockToken coin = _newCoin();
        PayableRecipient p = new PayableRecipient();
        (address[] memory r, uint16[] memory b) = _one(address(p));
        _trade(_launch(address(coin), r, b, 1));
        vm.startPrank(owner);
        locker.setKeeperRewardBps(100); // 1%
        locker.setKeeperRewardCap(0.05 ether);
        vm.stopPrank();
        address keeper = makeAddr("keeper");
        vm.recordLogs();
        vm.prank(keeper);
        locker.collectRewards(address(coin));
        (uint256 got0,) = _collected(vm.getRecordedLogs());
        uint256 expected = got0 * 100 / 10_000;
        assertGt(expected, 0);
        assertLt(expected, 0.05 ether);
        assertEq(keeper.balance, expected);
        assertEq(p.received(), got0 - expected);
    }

    function test_lockerV2_keeperReward_capped_and_unpayableSkipped() public onlyFork {
        MockToken coin = _newCoin();
        PayableRecipient p = new PayableRecipient();
        (address[] memory r, uint16[] memory b) = _one(address(p));
        PoolKey memory key = _launch(address(coin), r, b, 1);
        swapExactIn(key, true, 20 ether, address(this), ""); // 0.2 eth of fees
        vm.startPrank(owner);
        locker.setKeeperRewardBps(200);
        locker.setKeeperRewardCap(0.001 ether);
        vm.stopPrank();

        // a keeper that rejects eth: reward skipped, recipients keep it all
        RevertingRecipient badKeeper = new RevertingRecipient();
        vm.recordLogs();
        vm.prank(address(badKeeper));
        locker.collectRewards(address(coin));
        (uint256 got0,) = _collected(vm.getRecordedLogs());
        assertEq(p.received(), got0);

        swapExactIn(key, true, 20 ether, address(this), "");
        address keeper = makeAddr("keeper");
        vm.recordLogs();
        vm.prank(keeper);
        locker.collectRewards(address(coin));
        (uint256 got0b,) = _collected(vm.getRecordedLogs());
        assertGt(got0b * 200 / 10_000, 0.001 ether);
        assertEq(keeper.balance, 0.001 ether);
        assertEq(p.received(), got0 + got0b - 0.001 ether);
    }

    /// @dev LF-01 regression: attacker opens an unlock, mints a position
    ///      without paying, then calls collect. Must revert.
    function test_lockerV2_collectInsideForeignUnlock_reverts() public onlyFork {
        MockToken coin = _newCoin();
        PayableRecipient p = new PayableRecipient();
        (address[] memory r, uint16[] memory b) = _one(address(p));
        PoolKey memory key = _launch(address(coin), r, b, 1);
        _trade(key);
        UnlockAttacker attacker = new UnlockAttacker(
            IPoolManager(POOL_MANAGER), IPositionManager(POSITION_MANAGER), locker
        );
        vm.expectRevert(ArtCoinsLpLockerV2.PoolManagerUnlocked.selector);
        attacker.attack(key, address(coin), 100_000, 120_000);
        // the v1 open tab entry point does not exist
        (bool ok,) = address(locker)
            .call(abi.encodeWithSignature("collectRewardsWithoutUnlock(address)", address(coin)));
        assertFalse(ok);
        // fees still collectable by the honest path
        locker.collectRewards(address(coin));
        assertGt(p.received(), 0);
    }

    /// @dev The owner cannot pull in flight shares: a rescue attempted from
    ///      inside a push hits the reentrancy lock, the share is escrowed.
    function test_lockerV2_rescue_cannotTouchInFlightShares() public onlyFork {
        MockToken coin = _newCoin();
        RescuingOwner ro = new RescuingOwner(locker);
        vm.prank(owner);
        locker.transferOwnership(address(ro));
        ro.accept();
        (address[] memory r, uint16[] memory b) = _one(address(ro));
        // launcher allowlist was set by the old owner and survives the transfer
        _trade(_launch(address(coin), r, b, 1));
        vm.recordLogs();
        locker.collectRewards(address(coin));
        (uint256 got0,) = _collected(vm.getRecordedLogs());
        assertGt(got0, 0);
        assertEq(address(ro).balance, 0);
        assertEq(escrow.balances(address(ro), address(0)), got0);
        assertEq(address(locker).balance, 0);
    }

    function test_lockerV2_receive_onlyPoolManager() public onlyFork {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(locker).call{value: 1}("");
        assertFalse(ok);
    }

    function _collected(Vm.Log[] memory logs) internal pure returns (uint256 a0, uint256 a1) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == IArtCoinsLpLockerV2.RewardsCollected.selector) {
                (a0, a1) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
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
