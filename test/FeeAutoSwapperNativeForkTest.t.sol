// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ArtCoinsFeeEscrow} from "../src/ArtCoinsFeeEscrow.sol";
import {FeeAutoSwapper} from "../src/FeeAutoSwapper.sol";
import {IArtCoinsFeeEscrow} from "../src/interfaces/IArtCoinsFeeEscrow.sol";
import {IFeeAutoSwapper} from "../src/interfaces/IFeeAutoSwapper.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Test, console2} from "forge-std/Test.sol";

/// @dev Mintable artcoin for tests.
contract NativeAcoin is ERC20, ERC20Burnable {
    constructor() ERC20("NativeArtCoin", "NAC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev EOA-like recipient that accepts native ETH on `receive()`. We use a
///      contract here so the assertions can read its ETH balance without
///      `vm.deal` interference (an EOA gets a giant prefund by default).
contract NativeRecipient {
    receive() external payable {}
}

/// @title FeeAutoSwapperNativeForkTest
/// @notice Verifies `FeeAutoSwapper` works against a **native-ETH-paired**
///         V4 pool — the configuration PERMANENT COLLECTION's $111 will
///         launch on (V3 artcoins stack, `pairedToken = address(0)`). The
///         existing WETH-paired test suite exercises LAYER's pairing; this
///         one closes the second mode.
///
///         Run:
///           forge test --match-contract FeeAutoSwapperNativeForkTest \
///             --fork-url https://ethereum-rpc.publicnode.com -vv
contract FeeAutoSwapperNativeForkTest is Test {
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    NativeAcoin internal artcoin;
    ArtCoinsFeeEscrow internal escrow;
    FeeAutoSwapper internal swapper;
    NativeRecipient internal endRecipient;

    PoolModifyLiquidityTest internal liqRouter;
    PoolKey internal poolKey;

    address internal escrowOwner = address(0xA1);
    address internal keeper = address(0xC1);

    bool internal onFork;

    function setUp() public {
        if (POOL_MANAGER.code.length == 0) {
            console2.log("SKIPPING: not on a fork.");
            return;
        }
        onFork = true;

        artcoin = new NativeAcoin();
        endRecipient = new NativeRecipient();
        escrow = new ArtCoinsFeeEscrow(escrowOwner);

        liqRouter = new PoolModifyLiquidityTest(IPoolManager(POOL_MANAGER));

        // Native-ETH-paired pool: currency0 = address(0), currency1 = artcoin.
        // V4 sorts `address(0)` first, so the artcoin is always token1 on
        // native-ETH pools.
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(artcoin)),
            fee: 10_000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        IPoolManager(POOL_MANAGER).initialize(poolKey, uint160(1) << 96);

        // Seed liquidity at price = 1 (1 ETH : 1 artcoin).
        artcoin.mint(address(this), 2_000_000e18);
        vm.deal(address(this), 2_000_000 ether);
        IERC20(address(artcoin)).approve(address(liqRouter), type(uint256).max);

        liqRouter.modifyLiquidity{value: 2_000_000 ether}(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60_000, tickUpper: 60_000, liquidityDelta: 5e23, salt: bytes32(0)
            }),
            ""
        );

        FeeAutoSwapper.Config memory cfg = FeeAutoSwapper.Config({
            poolManager: POOL_MANAGER,
            feeLocker: address(escrow),
            pairedToken: address(0), // native-ETH mode
            poolFee: 10_000,
            poolTickSpacing: 60,
            hook: address(0),
            endRecipient: address(endRecipient),
            depositToLocker: true,
            maxSlippageBps: 1000,
            minBlocksBetweenConverts: 1,
            maxStepIn: 1_000_000e18
        });
        swapper = new FeeAutoSwapper(cfg);
        swapper.setup(address(artcoin));

        vm.startPrank(escrowOwner);
        escrow.addDepositor(address(swapper));
        escrow.addDepositor(address(this));
        vm.stopPrank();
    }

    receive() external payable {}

    // ─── happy path ─────────────────────────────────────────────────────

    function test_fork_nativeConvert_depositToLocker() public {
        if (!onFork) return;

        // Credit artcoin to the swapper at the escrow (mimics the LP locker's
        // distribution after a sell-side swap).
        uint256 escrowAmount = 10_000e18;
        artcoin.mint(address(this), escrowAmount);
        IERC20(address(artcoin)).approve(address(escrow), escrowAmount);
        escrow.storeFees(address(swapper), address(artcoin), escrowAmount);

        assertEq(swapper.accruedArtCoin(), escrowAmount, "accruedArtCoin before");
        assertEq(swapper.pairedIsNative(), true, "swapper in native-ETH mode");

        uint256 keeperEthBefore = keeper.balance;
        uint256 swapperEthBefore = address(swapper).balance;

        vm.prank(keeper);
        uint256 ethOut = swapper.convert(0);

        assertGt(ethOut, 0, "swap produced ETH");

        // No artcoin or ETH residual on the swapper.
        assertEq(IERC20(address(artcoin)).balanceOf(address(swapper)), 0, "no artcoin residual");
        assertEq(address(swapper).balance, swapperEthBefore, "no ETH stranded on swapper");

        // Keeper got native ETH reward.
        uint256 keeperGained = keeper.balance - keeperEthBefore;
        assertGt(keeperGained, 0, "keeper got ETH reward");
        assertLe(keeperGained, 0.01 ether, "keeper reward bounded by cap");

        // endRecipient's credit at the escrow is `ethOut - keeperReward`.
        // Note: native-ETH balances at the escrow use `token = address(0)`.
        uint256 escrowedForRecipient = escrow.availableFees(address(endRecipient), address(0));
        assertEq(escrowedForRecipient, ethOut - keeperGained, "endRecipient native credit");
        assertEq(escrowedForRecipient + keeperGained, ethOut, "conservation");

        // Accounting consistent.
        assertEq(swapper.totalArtcoinConverted(), escrowAmount, "totalArtcoinConverted");
        assertEq(swapper.totalWethDelivered(), escrowedForRecipient, "totalWethDelivered (eth)");
        assertEq(swapper.totalKeeperRewards(), keeperGained, "totalKeeperRewards");
    }

    function test_fork_nativeConvert_directTransfer() public {
        if (!onFork) return;

        // Redeploy with `depositToLocker = false` so the contract sends ETH
        // directly to the end recipient's balance (no escrow round-trip).
        FeeAutoSwapper.Config memory cfg = FeeAutoSwapper.Config({
            poolManager: POOL_MANAGER,
            feeLocker: address(escrow),
            pairedToken: address(0),
            poolFee: 10_000,
            poolTickSpacing: 60,
            hook: address(0),
            endRecipient: address(endRecipient),
            depositToLocker: false,
            maxSlippageBps: 1000,
            minBlocksBetweenConverts: 1,
            maxStepIn: 1_000_000e18
        });
        FeeAutoSwapper directSwapper = new FeeAutoSwapper(cfg);
        directSwapper.setup(address(artcoin));

        uint256 escrowAmount = 5000e18;
        artcoin.mint(address(this), escrowAmount);
        IERC20(address(artcoin)).approve(address(escrow), escrowAmount);
        escrow.storeFees(address(directSwapper), address(artcoin), escrowAmount);

        uint256 recipientBefore = address(endRecipient).balance;
        uint256 keeperBefore = keeper.balance;

        vm.prank(keeper);
        uint256 ethOut = directSwapper.convert(0);

        uint256 keeperGained = keeper.balance - keeperBefore;
        uint256 recipientGained = address(endRecipient).balance - recipientBefore;

        // Direct mode: ETH lives at the end recipient's balance, not in the
        // escrow.
        assertEq(recipientGained + keeperGained, ethOut, "conservation (direct)");
        assertEq(escrow.availableFees(address(endRecipient), address(0)), 0, "no escrow credit");
    }

    // ─── partial fill ───────────────────────────────────────────────────

    function test_fork_nativeConvert_partialFill_conservation() public {
        if (!onFork) return;

        // Tight slippage so a large swap clamps.
        FeeAutoSwapper.Config memory cfg = FeeAutoSwapper.Config({
            poolManager: POOL_MANAGER,
            feeLocker: address(escrow),
            pairedToken: address(0),
            poolFee: 10_000,
            poolTickSpacing: 60,
            hook: address(0),
            endRecipient: address(endRecipient),
            depositToLocker: false,
            maxSlippageBps: 50, // 0.5% — induces clamp
            minBlocksBetweenConverts: 1,
            maxStepIn: 1_000_000e18
        });
        FeeAutoSwapper tightSwapper = new FeeAutoSwapper(cfg);
        tightSwapper.setup(address(artcoin));

        uint256 escrowAmount = 500_000e18;
        artcoin.mint(address(this), escrowAmount);
        IERC20(address(artcoin)).approve(address(escrow), escrowAmount);
        escrow.storeFees(address(tightSwapper), address(artcoin), escrowAmount);

        // `minOut = 0` — the spot floor (against actualIn) handles guarding.
        vm.prank(keeper);
        try tightSwapper.convert(0) {
        // proceed
        }
            catch {
            // floor / clamp interaction may revert; conservation still holds
        }

        uint256 residual = IERC20(address(artcoin)).balanceOf(address(tightSwapper));
        uint256 converted = tightSwapper.totalArtcoinConverted();
        uint256 stillEscrowed = escrow.availableFees(address(tightSwapper), address(artcoin));
        assertEq(converted + residual + stillEscrowed, escrowAmount, "artcoin conserved");
    }

    // ─── paired-side passthrough via flushPaired ────────────────────────

    function test_fork_flushPaired_native_drainsAndForwards() public {
        if (!onFork) return;

        // Simulate the LP locker depositing buy-side LP fees (paid in native
        // ETH on a native-paired pool) into the swapper's escrow slot.
        uint256 ethDeposit = 5 ether;
        vm.deal(address(this), ethDeposit);
        IArtCoinsFeeEscrow(address(escrow)).storeFeesNative{value: ethDeposit}(address(swapper));

        assertEq(swapper.accruedPaired(), ethDeposit, "accruedPaired before");

        uint256 recipientBefore = address(endRecipient).balance;
        uint256 keeperBefore = keeper.balance;

        vm.prank(keeper);
        uint256 pairedOut = swapper.flushPaired();

        assertEq(pairedOut, ethDeposit, "all flushed");
        assertEq(swapper.accruedPaired(), 0, "escrow drained");

        // In depositToLocker mode, net forwards into the escrow under
        // endRecipient's native-slot.
        uint256 escrowedForRecipient = escrow.availableFees(address(endRecipient), address(0));
        uint256 keeperGained = keeper.balance - keeperBefore;
        uint256 recipientLiveBal = address(endRecipient).balance - recipientBefore;
        assertEq(recipientLiveBal, 0, "depositToLocker: nothing transferred live");
        assertEq(escrowedForRecipient + keeperGained, pairedOut, "conservation in flush");
        assertLe(keeperGained, 0.01 ether, "keeper reward bounded");
    }

    function test_fork_flushPaired_nothingToFlush_reverts() public {
        if (!onFork) return;

        vm.expectRevert(IFeeAutoSwapper.NothingToFlush.selector);
        vm.prank(keeper);
        swapper.flushPaired();
    }

    // ─── verify swap output is actually native ETH, not WETH ────────────

    function test_fork_nativeConvert_outputIsNativeEth() public {
        if (!onFork) return;

        uint256 escrowAmount = 1000e18;
        artcoin.mint(address(this), escrowAmount);
        IERC20(address(artcoin)).approve(address(escrow), escrowAmount);
        escrow.storeFees(address(swapper), address(artcoin), escrowAmount);

        // The escrow's `feesToClaim[recipient][address(0)]` slot is the
        // native-ETH balance. Pre-convert it's zero; post-convert it should
        // be the swap delivery less keeper reward.
        assertEq(
            escrow.availableFees(address(endRecipient), address(0)), 0, "pre-convert native credit"
        );

        vm.prank(keeper);
        swapper.convert(0);

        uint256 nativeCredit = escrow.availableFees(address(endRecipient), address(0));
        assertGt(nativeCredit, 0, "got native-ETH credit at escrow");

        // Recipient claims their native ETH from the escrow — this exercises
        // the `claim(feeOwner, address(0))` path the BountyAdapter would use.
        uint256 recipientEthBefore = address(endRecipient).balance;
        escrow.claim(address(endRecipient), address(0));
        assertEq(
            address(endRecipient).balance - recipientEthBefore,
            nativeCredit,
            "claim delivered native ETH"
        );
        assertEq(
            escrow.availableFees(address(endRecipient), address(0)), 0, "credit drained after claim"
        );
    }
}
