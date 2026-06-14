// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FeeAutoSwapper} from "../src/FeeAutoSwapper.sol";
import {ArtCoinsFeeLocker} from "../src/legacy/ArtCoinsFeeLocker.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

/// @dev Local mintable token.
contract AcoinInv is ERC20, ERC20Burnable {
    constructor() ERC20("ArtCoin", "AC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Handler exposes a minimal API to the fuzzer:
///   - `deposit`: credit some artcoin to the swapper at the fee locker
///   - `convertFire`: call `swapper.convert` with a fuzzed minOut
contract Handler is CommonBase, StdCheats, StdUtils {
    FeeAutoSwapper public immutable swapper;
    ArtCoinsFeeLocker public immutable feeLocker;
    AcoinInv public immutable artcoin;

    /// @notice Sum of all artcoin amounts handler has ever escrowed for the
    ///         swapper. The conservation invariant compares this against
    ///         everything the swapper currently knows + what's still owed.
    uint256 public totalDeposited;
    uint256 public callsDeposit;
    uint256 public callsConvert;
    uint256 public callsConvertSucceeded;

    constructor(FeeAutoSwapper _swapper, ArtCoinsFeeLocker _feeLocker, AcoinInv _artcoin) {
        swapper = _swapper;
        feeLocker = _feeLocker;
        artcoin = _artcoin;
    }

    /// @notice Push a fuzz-sized amount of artcoin into the fee locker for the
    ///         swapper. Mimics what an LP locker's reward distribution does.
    function deposit(uint96 amount) external {
        // Bound to a reasonable range. Zero deposits are no-ops at the locker
        // but stress the conservation accounting.
        amount = uint96(bound(uint256(amount), 1e15, 100_000e18));
        artcoin.mint(address(this), amount);
        artcoin.approve(address(feeLocker), amount);
        feeLocker.storeFees(address(swapper), address(artcoin), amount);
        totalDeposited += amount;
        callsDeposit++;
    }

    /// @notice Step the swapper. The fuzzer chooses both minOut (0..max) and
    ///         caller identity. Most reverts are legit (pacing, nothing, floor)
    ///         so we swallow them and only care about state consistency.
    function convertFire(uint8 callerSeed, uint96 minOut) external {
        callsConvert++;
        if (block.number < swapper.nextConvertibleBlock()) {
            vm.roll(swapper.nextConvertibleBlock());
        }

        // Pick a caller from a small set so msg.sender varies.
        address caller = address(uint160(uint256(keccak256(abi.encode(callerSeed, "h"))) | 1));

        vm.prank(caller);
        try swapper.convert(uint256(minOut)) {
            callsConvertSucceeded++;
        } catch {
            // ignored — convert can legitimately revert (nothing to convert,
            // pacing, slippage). The invariants assert state consistency, not
            // call-success.
        }
    }
}

/// @title FeeAutoSwapperInvariants
/// @notice Property-based fuzzing of `FeeAutoSwapper`'s accounting invariants.
///         Targets the conservation property the contract relies on: every
///         artcoin that enters the system either (a) stays escrowed at the
///         fee locker, (b) sits as residual in the swapper after a partial
///         fill, or (c) is recorded in `totalArtcoinConverted` having been
///         swapped to WETH. Nothing else.
///
///         Skips on a non-fork environment. Run:
///           forge test --match-contract FeeAutoSwapperInvariants \
///             --fork-url https://ethereum-rpc.publicnode.com -vv
contract FeeAutoSwapperInvariants is StdInvariant, Test {
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    AcoinInv internal artcoin;
    ArtCoinsFeeLocker internal feeLocker;
    FeeAutoSwapper internal swapper;
    Handler internal handler;
    PoolModifyLiquidityTest internal liqRouter;
    PoolKey internal poolKey;

    address internal feeLockerOwner = address(0xA1);
    address internal swapperOwner = address(0xA2);
    address internal endRecipient = address(0xB1);

    // Snapshots for monotonic invariants.
    uint256 internal _lastTotalArtcoinConverted;
    uint256 internal _lastTotalWethDelivered;
    uint256 internal _lastTotalKeeperRewards;
    uint256 internal _lastConvertBlock;

    bool internal onFork;

    function setUp() public {
        if (POOL_MANAGER.code.length == 0) {
            // Not on a mainnet fork: skip the whole suite. Without a fork there
            // is no PoolManager to seed against, so `setUp` cannot register a
            // fuzz target — `vm.skip(true)` marks the invariant suite skipped
            // instead of failing with "No contracts to fuzz".
            vm.skip(true);
            return;
        }
        onFork = true;

        artcoin = new AcoinInv();
        feeLocker = new ArtCoinsFeeLocker(feeLockerOwner);

        liqRouter = new PoolModifyLiquidityTest(IPoolManager(POOL_MANAGER));

        poolKey = _buildKey(address(artcoin), WETH);
        IPoolManager(POOL_MANAGER).initialize(poolKey, uint160(1) << 96);

        // Seed pool with the same shape used by `DemoFeeFlowForkTest`. Sized
        // to give the fuzzer headroom while staying within numbers the
        // test contract can fund via `vm.deal`.
        artcoin.mint(address(this), 2_000_000e18);
        vm.deal(address(this), 2_000_000 ether);
        IWETH9(payable(WETH)).deposit{value: 2_000_000 ether}();

        IERC20(address(artcoin)).approve(address(liqRouter), type(uint256).max);
        IERC20(WETH).approve(address(liqRouter), type(uint256).max);

        liqRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60_000, tickUpper: 60_000, liquidityDelta: 5e23, salt: bytes32(0)
            }),
            ""
        );

        FeeAutoSwapper.Config memory cfg = FeeAutoSwapper.Config({
            poolManager: POOL_MANAGER,
            feeLocker: address(feeLocker),
            pairedToken: WETH,
            poolFee: 10_000,
            poolTickSpacing: 60,
            hook: address(0),
            endRecipient: endRecipient,
            depositToLocker: true,
            maxSlippageBps: 1000,
            minBlocksBetweenConverts: 1,
            maxStepIn: 1_000_000e18
        });
        swapper = new FeeAutoSwapper(cfg);
        swapper.setup(address(artcoin));

        handler = new Handler(swapper, feeLocker, artcoin);

        vm.startPrank(feeLockerOwner);
        feeLocker.addDepositor(address(swapper));
        feeLocker.addDepositor(address(handler));
        vm.stopPrank();

        targetContract(address(handler));

        bytes4[] memory sels = new bytes4[](2);
        sels[0] = handler.deposit.selector;
        sels[1] = handler.convertFire.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    // ─── invariants ─────────────────────────────────────────────────────

    /// @notice Conservation across the swapper: every artcoin handler has
    ///         deposited must be findable somewhere — converted, held as
    ///         partial-fill residual, or still owed at the fee locker.
    function invariant_artcoinConservation() public view {
        if (!onFork) return;
        uint256 converted = swapper.totalArtcoinConverted();
        uint256 held = IERC20(address(artcoin)).balanceOf(address(swapper));
        uint256 escrowed = feeLocker.availableFees(address(swapper), address(artcoin));
        assertEq(
            converted + held + escrowed,
            handler.totalDeposited(),
            "artcoin conservation: converted + held + escrowed != totalDeposited"
        );
    }

    /// @notice No WETH lingers on the swapper. Every `convert` forwards all
    ///         swap output to (a) the fee locker / endRecipient, and
    ///         (b) the keeper. Anything left would mean an accounting hole.
    function invariant_noWethStranded() public view {
        if (!onFork) return;
        assertEq(IERC20(WETH).balanceOf(address(swapper)), 0, "WETH stranded on swapper");
    }

    /// @notice `totalArtcoinConverted` monotonic.
    function invariant_artcoinConvertedMonotonic() public {
        if (!onFork) return;
        uint256 cur = swapper.totalArtcoinConverted();
        assertGe(cur, _lastTotalArtcoinConverted, "totalArtcoinConverted regressed");
        _lastTotalArtcoinConverted = cur;
    }

    /// @notice `totalWethDelivered` monotonic.
    function invariant_wethDeliveredMonotonic() public {
        if (!onFork) return;
        uint256 cur = swapper.totalWethDelivered();
        assertGe(cur, _lastTotalWethDelivered, "totalWethDelivered regressed");
        _lastTotalWethDelivered = cur;
    }

    /// @notice `totalKeeperRewards` monotonic.
    function invariant_keeperRewardsMonotonic() public {
        if (!onFork) return;
        uint256 cur = swapper.totalKeeperRewards();
        assertGe(cur, _lastTotalKeeperRewards, "totalKeeperRewards regressed");
        _lastTotalKeeperRewards = cur;
    }

    /// @notice `lastConvertBlock` monotonic.
    function invariant_lastConvertBlockMonotonic() public {
        if (!onFork) return;
        uint256 cur = swapper.lastConvertBlock();
        assertGe(cur, _lastConvertBlock, "lastConvertBlock regressed");
        _lastConvertBlock = cur;
    }

    /// @notice WETH output accounting consistency: every wei of swap output
    ///         is either credited at the fee locker for `endRecipient` (because
    ///         we're in `depositToLocker` mode here) or paid to some keeper.
    ///         The handler can't deposit WETH, so the sum across all keepers
    ///         the handler ever chose must equal `totalKeeperRewards`.
    ///         `totalWethDelivered` mirrors what's escrowed at the locker for
    ///         endRecipient.
    function invariant_wethOutputAccounting() public view {
        if (!onFork) return;
        // depositToLocker = true → all delivered WETH lives in the locker
        // under endRecipient's slot. The handler never makes endRecipient a
        // keeper (handler synthesizes its own caller addresses), so the
        // locker balance is exactly `totalWethDelivered`.
        assertEq(
            feeLocker.availableFees(endRecipient, WETH),
            swapper.totalWethDelivered(),
            "endRecipient locker balance != totalWethDelivered"
        );
    }

    function _buildKey(address coin, address w) internal pure returns (PoolKey memory) {
        (address c0, address c1) = coin < w ? (coin, w) : (w, coin);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 10_000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }
}
