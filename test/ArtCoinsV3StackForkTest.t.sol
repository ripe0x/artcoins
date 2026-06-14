// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {ArtCoinsFactory} from "../src/ArtCoinsFactory.sol";
import {ArtCoinsFeeEscrow} from "../src/ArtCoinsFeeEscrow.sol";
import {ArtCoinsHookStaticFee} from "../src/hooks/ArtCoinsHookStaticFee.sol";
import {ArtCoinsPoolExtensionAllowlist} from "../src/hooks/ArtCoinsPoolExtensionAllowlist.sol";
import {IArtCoinsHookStaticFee} from "../src/hooks/interfaces/IArtCoinsHookStaticFee.sol";
import {IArtCoinsFactory} from "../src/interfaces/IArtCoinsFactory.sol";
import {IArtCoinsHook} from "../src/interfaces/IArtCoinsHook.sol";
import {ArtCoinsLpLocker} from "../src/lp-lockers/ArtCoinsLpLocker.sol";

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256) external;
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @title  ArtCoinsV3StackForkTest
/// @notice Mainnet-fork integration test for the V3 artcoins stack:
///         ArtCoinsHook (native-ETH-capable), ArtCoinsLpLocker,
///         ArtCoinsFeeEscrow. Validates the full deploy → swap →
///         collectRewards → claim loop on both native-ETH and WETH pairings.
///
///         The V3 stack is currency-agnostic: native ETH and ERC20 paired
///         pools share the same hook + locker + escrow, with `address(0)`
///         routing through native-ETH branches throughout.
///
/// Run:
///   forge test --match-contract ArtCoinsV3StackForkTest \
///     --fork-url $MAINNET_RPC_URL -vv
contract ArtCoinsV3StackForkTest is Test {
    // ─── mainnet addresses ───────────────────────────────────────────────
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // ─── stack ───────────────────────────────────────────────────────────
    ArtCoinsFactory factory;
    ArtCoinsFeeEscrow escrow;
    ArtCoinsHookStaticFee hook;
    ArtCoinsLpLocker locker;
    ArtCoinsPoolExtensionAllowlist extAllowlist;
    PoolSwapTest swapRouter;

    // ─── actors ──────────────────────────────────────────────────────────
    address owner = makeAddr("owner");
    address tokenAdmin = makeAddr("tokenAdmin");
    address teamRecipient = makeAddr("teamRecipient");
    address creatorSlot = makeAddr("creatorSlot");
    address trader = makeAddr("trader");

    bool _onFork;

    // ─── setup ───────────────────────────────────────────────────────────
    function setUp() public {
        if (POOL_MANAGER.code.length == 0) {
            console2.log("SKIPPING: not on mainnet fork");
            return;
        }
        _onFork = true;

        vm.startPrank(owner);

        // 1. Deploy fresh factory + escrow + ext allowlist.
        factory = new ArtCoinsFactory(owner);
        escrow = new ArtCoinsFeeEscrow(owner);
        extAllowlist = new ArtCoinsPoolExtensionAllowlist(owner);

        // 2. Configure factory (un-deprecate, set fee recipient).
        factory.setDeprecated(false);
        factory.setTeamFeeRecipient(teamRecipient);
        factory.setDeployFee(0);

        // 3. Deploy LP locker (binds to factory + escrow).
        locker = new ArtCoinsLpLocker(
            owner, address(factory), address(escrow), POSITION_MANAGER, PERMIT2
        );

        // 4. Allowlist locker as a depositor on the escrow.
        escrow.addDepositor(address(locker));

        vm.stopPrank();

        // 5. Mine + deploy hook. In `forge test`, the deployer of a `new
        //    Contract{salt:}()` call is `address(this)` (the test contract),
        //    NOT the canonical CREATE2 factory.
        uint160 hookFlags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory hookCtorArgs = abi.encode(
            POOL_MANAGER, address(factory), address(extAllowlist), WETH, address(escrow)
        );
        (address minedHook, bytes32 hookSalt) = HookMiner.find(
            address(this), hookFlags, type(ArtCoinsHookStaticFee).creationCode, hookCtorArgs
        );
        hook = new ArtCoinsHookStaticFee{salt: hookSalt}(
            POOL_MANAGER, address(factory), address(extAllowlist), WETH, address(escrow)
        );
        require(address(hook) == minedHook, "hook mine mismatch");

        // 6. Allowlist hook + locker on the factory.
        vm.startPrank(owner);
        factory.setHook(address(hook), true);
        factory.setLocker(address(locker), address(hook), true);
        // M-03 fix: hook needs to be an escrow depositor to route native-ETH
        // sniper-extra fees through `storeFeesNative`.
        escrow.addDepositor(address(hook));
        vm.stopPrank();

        // 7. Deploy V4 swap helper.
        swapRouter = new PoolSwapTest(IPoolManager(POOL_MANAGER));
    }

    modifier onlyFork() {
        if (!_onFork) return;
        _;
    }

    // Receive ETH from swap router / WETH unwrap.
    receive() external payable {}

    // ─── helpers ─────────────────────────────────────────────────────────

    function _baseDeploymentConfig(address pairedToken, bytes32 salt)
        internal
        view
        returns (IArtCoinsFactory.DeploymentConfig memory cfg)
    {
        cfg.tokenConfig = IArtCoinsFactory.TokenConfig({
            tokenAdmin: tokenAdmin,
            name: "TestArt",
            symbol: "TART",
            salt: salt,
            image: "",
            metadata: "",
            context: "",
            totalSupply: 0, // default 1B
            renderer: address(0)
        });

        cfg.poolConfig = IArtCoinsFactory.PoolConfig({
            hook: address(hook),
            pairedToken: pairedToken,
            tickIfToken0IsArtCoins: -100_000, // arbitrary, multiple of tickSpacing
            tickSpacing: 200,
            poolData: abi.encode(
                IArtCoinsHook.PoolInitializationData({
                    extension: address(0),
                    extensionData: "",
                    feeData: abi.encode(
                        IArtCoinsHookStaticFee.PoolStaticConfigVars({
                            artCoinFee: 10_000, // 1%
                            pairedFee: 10_000 // 1%
                        })
                    )
                })
            )
        });

        // Project-side reward slot — factory injects the 2000-bps protocol
        // slot to make total 10000. Single creator slot at 8000 bps.
        address[] memory admins = new address[](1);
        admins[0] = tokenAdmin;
        address[] memory recipients = new address[](1);
        recipients[0] = creatorSlot;
        uint16[] memory rewardBps = new uint16[](1);
        rewardBps[0] = 8000;

        // Single full-range LP position.
        int24[] memory tickLower = new int24[](1);
        int24[] memory tickUpper = new int24[](1);
        uint16[] memory positionBps = new uint16[](1);
        tickLower[0] = 0; // offset from startingTick
        tickUpper[0] = 110_400; // wide range; multiple of 200
        positionBps[0] = 10_000;

        cfg.lockerConfig = IArtCoinsFactory.LockerConfig({
            locker: address(locker),
            rewardAdmins: admins,
            rewardRecipients: recipients,
            rewardBps: rewardBps,
            tickLower: tickLower,
            tickUpper: tickUpper,
            positionBps: positionBps,
            lockerData: ""
        });

        // No MEV module (simplifies test; avoids anti-sniper fee bumps).
        cfg.mevModuleConfig =
            IArtCoinsFactory.MevModuleConfig({mevModule: address(0), mevModuleData: ""});

        // No sniper-fee recipient.
        cfg.sniperFeeConfig =
            IArtCoinsFactory.SniperFeeConfig({recipient: address(0), lockRecipient: false});

        // No extensions.
        cfg.extensionConfigs = new IArtCoinsFactory.ExtensionConfig[](0);
    }

    function _deployToken(address pairedToken, bytes32 salt)
        internal
        returns (address tokenAddr, PoolKey memory poolKey)
    {
        vm.prank(owner);
        tokenAddr = factory.deployToken(_baseDeploymentConfig(pairedToken, salt));

        // Reconstruct the pool key from the deployed config.
        bool token0IsArtCoins = tokenAddr < pairedToken;
        poolKey = PoolKey({
            currency0: Currency.wrap(token0IsArtCoins ? tokenAddr : pairedToken),
            currency1: Currency.wrap(token0IsArtCoins ? pairedToken : tokenAddr),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });
    }

    // ─── tests: native-ETH pool ──────────────────────────────────────────

    // ─── M-03 audit fix wiring ──────────────────────────────────────────

    /// @notice V3 hook stores the fee escrow as an immutable. Routing native-ETH
    ///         sniper-extra via the escrow requires the hook to know which
    ///         escrow to call.
    function test_fork_M03_hook_storesFeeEscrowImmutable() public onlyFork {
        assertEq(address(hook.feeEscrow()), address(escrow), "hook.feeEscrow mismatch");
    }

    /// @notice The hook must be an allowlisted depositor on the escrow so its
    ///         `storeFeesNative` call from `_sniperExtraFeeClaim` succeeds.
    ///         If this allowlist entry is missing, a native-ETH pool with
    ///         sniper-extra accrued would brick on the lazy flush.
    function test_fork_M03_hook_isEscrowDepositor() public onlyFork {
        assertTrue(escrow.allowedDepositors(address(hook)), "hook must be escrow depositor");
    }

    /// @notice The hook must be payable (have a `receive()` or payable fallback)
    ///         so `poolManager.take(currency0, hook, amt)` can land ETH on it
    ///         before forwarding to the escrow.
    function test_fork_M03_hook_isPayable() public onlyFork {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(hook).call{value: 0.1 ether}("");
        assertTrue(ok, "hook must accept ETH for sniper-extra routing");
        assertEq(address(hook).balance, 0.1 ether);
    }

    function test_fork_nativeEthPool_deploys() public onlyFork {
        (address tokenAddr, PoolKey memory poolKey) = _deployToken(address(0), keccak256("native1"));

        // Native ETH sorts as currency0 (address(0) < anything).
        assertEq(Currency.unwrap(poolKey.currency0), address(0), "currency0 should be native ETH");
        assertEq(Currency.unwrap(poolKey.currency1), tokenAddr, "currency1 should be artcoin");

        // Hook registered the pool with artCoinIsToken0 = false.
        assertFalse(
            hook.artCoinIsToken0(poolKey.toId()), "artcoin should be token1 in a native-ETH pool"
        );

        // LP locker recorded the position.
        assertGt(locker.tokenRewards(tokenAddr).positionId, 0, "locker should have a position id");

        // Static fee per side matches the config.
        assertEq(hook.artCoinFee(poolKey.toId()), 10_000, "artCoinFee mismatch");
        assertEq(hook.pairedFee(poolKey.toId()), 10_000, "pairedFee mismatch");
    }

    function test_fork_nativeEthPool_swapEthForArtcoin() public onlyFork {
        (address tokenAddr, PoolKey memory poolKey) =
            _deployToken(address(0), keccak256("native_buy"));

        uint256 BUY = 0.01 ether;
        vm.deal(trader, BUY);

        // Native ETH is currency0. Buying artcoin = zeroForOne true.
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(BUY),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        uint256 traderTokensBefore = IERC20(tokenAddr).balanceOf(trader);

        vm.prank(trader);
        swapRouter.swap{value: BUY}(
            poolKey,
            params,
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 traderTokensAfter = IERC20(tokenAddr).balanceOf(trader);
        assertGt(traderTokensAfter, traderTokensBefore, "trader should receive artcoin");
    }

    function test_fork_nativeEthPool_swapArtcoinForEth() public onlyFork {
        (address tokenAddr, PoolKey memory poolKey) =
            _deployToken(address(0), keccak256("native_sell"));

        // First buy some artcoin so we have something to sell.
        uint256 BUY = 0.05 ether;
        vm.deal(trader, BUY);
        vm.prank(trader);
        swapRouter.swap{value: BUY}(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(BUY),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 traderTokens = IERC20(tokenAddr).balanceOf(trader);
        uint256 sellAmount = traderTokens / 2;
        assertGt(sellAmount, 0, "should have tokens to sell");

        vm.prank(trader);
        IERC20(tokenAddr).approve(address(swapRouter), sellAmount);

        uint256 traderEthBefore = trader.balance;

        // Sell artcoin (currency1) → ETH (currency0) = oneForZero (zeroForOne false).
        vm.prank(trader);
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(sellAmount),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 traderEthAfter = trader.balance;
        assertGt(traderEthAfter, traderEthBefore, "trader should receive ETH");
    }

    function test_fork_nativeEthPool_collectRewards_creditsNativeEth() public onlyFork {
        (address tokenAddr, PoolKey memory poolKey) =
            _deployToken(address(0), keccak256("native_collect"));

        // Generate fee accrual via a buy.
        uint256 BUY = 0.05 ether;
        vm.deal(trader, BUY);
        vm.prank(trader);
        swapRouter.swap{value: BUY}(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(BUY),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Collect rewards. Both the creator slot (8000 bps) and the protocol
        // slot (2000 bps via teamRecipient) should be credited.
        locker.collectRewards(tokenAddr);

        uint256 creatorEthCredit = escrow.availableFees(creatorSlot, address(0));
        uint256 teamEthCredit = escrow.availableFees(teamRecipient, address(0));

        assertGt(creatorEthCredit, 0, "creator slot should be credited with native ETH");
        assertGt(teamEthCredit, 0, "protocol slot should be credited with native ETH");

        // Creator gets 8000 bps, protocol 2000 bps. Allow some rounding tolerance.
        // creatorEthCredit ≈ 4 * teamEthCredit
        uint256 ratio = (creatorEthCredit * 100) / teamEthCredit;
        assertGt(ratio, 380, "creator/protocol ratio too low (expected ~4x)");
        assertLt(ratio, 420, "creator/protocol ratio too high (expected ~4x)");
    }

    function test_fork_nativeEthPool_claim_sendsNativeEth() public onlyFork {
        (address tokenAddr, PoolKey memory poolKey) =
            _deployToken(address(0), keccak256("native_claim"));

        // Generate + collect fees.
        uint256 BUY = 0.05 ether;
        vm.deal(trader, BUY);
        vm.prank(trader);
        swapRouter.swap{value: BUY}(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(BUY),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        locker.collectRewards(tokenAddr);

        uint256 creatorEthCredit = escrow.availableFees(creatorSlot, address(0));
        assertGt(creatorEthCredit, 0, "fees should be credited");

        uint256 balBefore = creatorSlot.balance;
        escrow.claim(creatorSlot, address(0));
        uint256 balAfter = creatorSlot.balance;

        assertEq(balAfter - balBefore, creatorEthCredit, "claim amount mismatch");
        assertEq(escrow.availableFees(creatorSlot, address(0)), 0, "credit should be zeroed");
    }

    // ─── tests: backward-compat WETH pool ───────────────────────────────

    function test_fork_wethPool_deploys() public onlyFork {
        (address tokenAddr, PoolKey memory poolKey) = _deployToken(WETH, keccak256("weth1"));

        // WETH-paired: artcoin and WETH sort by address.
        bool token0IsArtCoins = tokenAddr < WETH;
        if (token0IsArtCoins) {
            assertEq(Currency.unwrap(poolKey.currency0), tokenAddr);
            assertEq(Currency.unwrap(poolKey.currency1), WETH);
        } else {
            assertEq(Currency.unwrap(poolKey.currency0), WETH);
            assertEq(Currency.unwrap(poolKey.currency1), tokenAddr);
        }
        assertEq(hook.artCoinIsToken0(poolKey.toId()), token0IsArtCoins);
    }

    function test_fork_wethPool_collectRewards_creditsWeth() public onlyFork {
        (address tokenAddr, PoolKey memory poolKey) = _deployToken(WETH, keccak256("weth_collect"));

        // Buy: pay WETH, receive artcoin.
        uint256 BUY = 0.05 ether;
        vm.deal(trader, BUY);
        vm.startPrank(trader);
        IWETH9(WETH).deposit{value: BUY}();
        IERC20(WETH).approve(address(swapRouter), BUY);
        vm.stopPrank();

        bool zeroForOne = WETH < tokenAddr; // pay currency0
        vm.prank(trader);
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(BUY),
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        locker.collectRewards(tokenAddr);

        // For WETH-paired: fees credited as WETH, not native ETH.
        uint256 creatorWethCredit = escrow.availableFees(creatorSlot, WETH);
        uint256 creatorEthCredit = escrow.availableFees(creatorSlot, address(0));

        assertGt(creatorWethCredit, 0, "creator should be credited with WETH");
        assertEq(creatorEthCredit, 0, "no native-ETH credit on a WETH pool");

        // Claim WETH works.
        uint256 wethBefore = IERC20(WETH).balanceOf(creatorSlot);
        escrow.claim(creatorSlot, WETH);
        uint256 wethAfter = IERC20(WETH).balanceOf(creatorSlot);
        assertEq(wethAfter - wethBefore, creatorWethCredit);
    }

    // ─── tests: locker keeper reward ────────────────────────────────────

    /// @notice A payable EOA keeper receives the keeper reward in the paired
    ///         currency (native ETH for the V3 stack's native-ETH pool).
    ///         Recipients get the post-skim split.
    function test_fork_collectRewards_paidKeeper_payableEOA() public onlyFork {
        (address tokenAddr, PoolKey memory poolKey) =
            _deployToken(address(0), keccak256("keeper_paid"));

        // Generate a sizable buy so the keeper reward saturates the cap and
        // produces a clean, predictable wei amount on the keeper.
        uint256 BUY = 5 ether;
        vm.deal(trader, BUY);
        vm.prank(trader);
        swapRouter.swap{value: BUY}(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(BUY),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Use a fresh payable EOA as the keeper.
        address payable keeper = payable(makeAddr("keeper"));
        uint256 keeperBalBefore = keeper.balance;

        uint256 cap = locker.keeperRewardCap();
        uint256 bps = locker.keeperRewardBps();

        vm.prank(keeper);
        locker.collectRewards(tokenAddr);

        uint256 keeperReward = keeper.balance - keeperBalBefore;
        assertGt(keeperReward, 0, "keeper should be paid");
        assertLe(keeperReward, cap, "keeper reward should not exceed cap");

        // Recipients still get credited — keeper reward came off the top,
        // not from a recipient's share. Each recipient's slot is non-zero.
        uint256 creatorEthCredit = escrow.availableFees(creatorSlot, address(0));
        uint256 teamEthCredit = escrow.availableFees(teamRecipient, address(0));
        assertGt(creatorEthCredit, 0, "creator slot credited post-skim");
        assertGt(teamEthCredit, 0, "team slot credited post-skim");

        // Conservation: keeper reward + sum(recipient credits) equals the
        // total paired-side fee that was claimed from the position. Computed
        // bps-from-total backwards from observed credits:
        // pairedTotal == (creatorEthCredit + teamEthCredit + keeperReward)
        uint256 pairedTotal = creatorEthCredit + teamEthCredit + keeperReward;
        uint256 expectedReward = (pairedTotal * bps) / 10_000;
        if (expectedReward > cap) expectedReward = cap;
        // Reward formula matches the contract's _payKeeperReward shape. Allow
        // 1-wei rounding tolerance from integer division.
        assertApproxEqAbs(
            keeperReward, expectedReward, 1, "keeper reward matches bps*pairedTotal/10000 capped"
        );

        // The 80/20 split ratio is preserved post-skim (both recipients
        // share the dilution proportionally).
        uint256 ratio = (creatorEthCredit * 100) / teamEthCredit;
        assertGt(ratio, 380, "ratio preserved post-skim (lower bound)");
        assertLt(ratio, 420, "ratio preserved post-skim (upper bound)");

        // No stranded balance: every wei leaves the locker, either as
        // keeper reward or as recipient credit via the fee escrow.
        assertEq(address(locker).balance, 0, "no stranded skim in locker");
    }

    /// @notice A non-payable caller silently skips the keeper reward —
    ///         `collectRewards` does NOT revert, and recipients receive
    ///         the full undiluted paired-side amount.
    function test_fork_collectRewards_nonPayableKeeper_skipsReward() public onlyFork {
        (address tokenAddr, PoolKey memory poolKey) =
            _deployToken(address(0), keccak256("keeper_skipped"));

        // Generate a buy.
        uint256 BUY = 5 ether;
        vm.deal(trader, BUY);
        vm.prank(trader);
        swapRouter.swap{value: BUY}(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(BUY),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Deploy a non-payable contract and have it call `collectRewards`.
        // The reward should be silently skipped (no revert), and recipients
        // should keep the full paired-side amount.
        NonPayableKeeper rejecting = new NonPayableKeeper(address(locker));
        uint256 rejectingBalBefore = address(rejecting).balance;

        rejecting.collect(tokenAddr); // does not revert

        assertEq(
            address(rejecting).balance, rejectingBalBefore, "rejecting caller balance unchanged"
        );

        // Recipients see the FULL paired-side amount (no skim).
        uint256 creatorEthCredit = escrow.availableFees(creatorSlot, address(0));
        uint256 teamEthCredit = escrow.availableFees(teamRecipient, address(0));
        assertGt(creatorEthCredit, 0, "creator credited");
        assertGt(teamEthCredit, 0, "team credited");

        // Crucial: total credited to recipients equals the full fee from
        // the position. Compare against the paid-keeper test by relative
        // ratio: with no skim, the 80/20 split lands on the same nominal
        // bps shares as before, but each slot's wei is slightly larger.
        // We assert the ratio (preserved either way) plus the existence
        // of both credits — the absolute floor is implicit in the
        // assertGt above.
        uint256 ratio = (creatorEthCredit * 100) / teamEthCredit;
        assertGt(ratio, 380, "ratio preserved (lower bound)");
        assertLt(ratio, 420, "ratio preserved (upper bound)");

        // "No stranded skim" invariant: the locker holds zero ETH after
        // collection regardless of whether the keeper reward was paid.
        // For the skip path, this confirms the would-be reward was rolled
        // back into the recipient distribution (not left sitting in the
        // locker). For the paid path (sibling test) this also holds —
        // ETH leaves the locker either as keeper reward or as recipient
        // credit via `feeLocker.storeFeesNative{value:}`.
        assertEq(address(locker).balance, 0, "no stranded skim in locker");
    }
}

/// @dev Contract that rejects native ETH — exercises the tolerant-skip path
///      in `ArtCoinsLpLocker._payKeeperReward`. No `receive()` and no
///      payable `fallback()`, so a low-level `call{value:}` from the
///      locker returns `ok = false`.
contract NonPayableKeeper {
    address public immutable locker;

    constructor(address locker_) {
        locker = locker_;
    }

    function collect(address token) external {
        // Cast via interface — keeps imports minimal.
        (bool ok,) = locker.call(abi.encodeWithSignature("collectRewards(address)", token));
        require(ok, "collectRewards reverted");
    }
}
