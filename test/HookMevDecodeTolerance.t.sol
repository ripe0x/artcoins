// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ArtCoinsFeeEscrow} from "../src/ArtCoinsFeeEscrow.sol";
import {ArtCoinsHookStaticFee} from "../src/hooks/ArtCoinsHookStaticFee.sol";
import {ArtCoinsPoolExtensionAllowlist} from "../src/hooks/ArtCoinsPoolExtensionAllowlist.sol";
import {IArtCoinsHookStaticFee} from "../src/hooks/interfaces/IArtCoinsHookStaticFee.sol";
import {IArtCoinsHook} from "../src/interfaces/IArtCoinsHook.sol";
import {ArtCoinsMevLinearFees} from "../src/mev-modules/ArtCoinsMevLinearFees.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

/// @notice Minimal ERC20 with a mutable `admin()` so the hook's
///         `onlyTokenAdmin` modifier resolves; mint helper for LP seeding.
contract MockTokenAdmin is ERC20 {
    address public admin;

    constructor(string memory n, string memory s, address a) ERC20(n, s) {
        admin = a;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setAdmin(address a) external {
        admin = a;
    }
}

/// @title  HookMevDecodeToleranceForkTest
/// @notice Fork test for the MEV-window `swapData` decode tolerance in
///         `ArtCoinsHook._runMevModule`. Deploys the (current, non-legacy)
///         `ArtCoinsHookStaticFee`, binds a fee-dialing MEV module
///         (`ArtCoinsMevLinearFees`) and initializes it so it is OPERATIONAL,
///         seeds LP, then drives swaps that carry MALFORMED non-empty
///         `swapData`.
///
///         The fix wraps the `abi.decode(swapData, (PoolSwapData))` in a
///         try/catch (`_decodeSwapDataTolerant`). Pre-fix, while the MEV
///         module is operational, `_runMevModule` did a BARE decode of
///         `swapData` and any wrong-shaped payload reverted the ENTIRE swap.
///         These tests assert the swap COMPLETES (token delivered) with such a
///         payload. The `mevModuleOperational` gate is the only thing standing
///         between the decode and the trader, so the malformed payload must
///         reach the bare decode — making the test non-vacuous.
///
/// Run:
///   forge test --match-contract HookMevDecodeToleranceForkTest \
///     --fork-url $MAINNET_RPC_URL -vv
contract HookMevDecodeToleranceForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    int24 constant TICK_SPACING = 200;
    uint24 constant LP_FEE_PPM = 10_000; // 1% base LP fee

    ArtCoinsHookStaticFee internal hook;
    ArtCoinsMevLinearFees internal mevModule;
    ArtCoinsPoolExtensionAllowlist internal allowlist;
    ArtCoinsFeeEscrow internal feeEscrow;
    PoolModifyLiquidityTest internal liqRouter;
    PoolSwapTest internal swapRouter;
    MockTokenAdmin internal token;

    PoolKey internal poolKey;
    bool internal _onFork;
    address internal admin = address(this);

    function setUp() public {
        if (POOL_MANAGER.code.length == 0) {
            console2.log("SKIPPING: not on mainnet fork");
            return;
        }
        _onFork = true;

        allowlist = new ArtCoinsPoolExtensionAllowlist(admin);
        token = new MockTokenAdmin("Test", "TEST", admin);
        feeEscrow = new ArtCoinsFeeEscrow(admin);

        // Mine + deploy the static-fee hook. Factory = address(this) so this
        // test may call the `onlyFactory` initializePool / initializeMevModule
        // paths directly (same pattern as ArtCoinsHookSkimFeeForkTest).
        uint160 hookFlags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory ctorArgs = abi.encode(
            POOL_MANAGER,
            address(this), // pretend-factory
            address(allowlist),
            WETH,
            address(feeEscrow)
        );
        (address hookAddr, bytes32 salt) = HookMiner.find(
            address(this), hookFlags, type(ArtCoinsHookStaticFee).creationCode, ctorArgs
        );
        hook = new ArtCoinsHookStaticFee{salt: salt}(
            POOL_MANAGER, address(this), address(allowlist), WETH, address(feeEscrow)
        );
        require(address(hook) == hookAddr, "Hook address mismatch");
        feeEscrow.addDepositor(address(hook));

        // Fee-dialing MEV module. Bound as the pool's MEV module via
        // initializePool, then turned operational via initializeMevModule.
        mevModule = new ArtCoinsMevLinearFees();

        bytes memory feeData = abi.encode(
            IArtCoinsHookStaticFee.PoolStaticConfigVars({
                artCoinFee: LP_FEE_PPM, pairedFee: LP_FEE_PPM
            })
        );
        bytes memory poolInit = abi.encode(
            IArtCoinsHook.PoolInitializationData({
                extension: address(0), extensionData: "", feeData: feeData
            })
        );
        int24 startingTick = -190_400;
        poolKey = IArtCoinsHook(address(hook))
            .initializePool(
                address(token),
                address(0), // paired = native ETH (ETH sorts as currency0)
                startingTick,
                TICK_SPACING,
                address(0), // locker irrelevant here
                address(mevModule),
                poolInit
            );

        // Seed LP BEFORE enabling the MEV module (the MEV gate blocks public
        // adds while operational; the factory-path seed here is fine pre-init).
        liqRouter = new PoolModifyLiquidityTest(IPoolManager(POOL_MANAGER));
        swapRouter = new PoolSwapTest(IPoolManager(POOL_MANAGER));
        uint256 lpAmount = 100_000_000e18;
        token.mint(address(this), lpAmount);
        IERC20(address(token)).approve(address(liqRouter), type(uint256).max);
        IERC20(address(token)).approve(address(swapRouter), type(uint256).max);

        vm.deal(address(this), 300 ether);

        int24 lower = -(startingTick + 60_000);
        int24 upper = -startingTick;
        uint128 L = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), lpAmount
        );
        liqRouter.modifyLiquidity{value: 100 ether}(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: lower,
                tickUpper: upper,
                liquidityDelta: int256(uint256(L)),
                salt: bytes32(0)
            }),
            ""
        );

        // Enable the MEV module (default 69% -> 1% over 69 min). Operational
        // immediately and stays so for the base hook's MAX_MEV_MODULE_DELAY
        // (15 min) window, which is what `_runMevModule` gates on.
        IArtCoinsHook(address(hook)).initializeMevModule(poolKey, "");

        vm.deal(address(this), 100 ether);
    }

    receive() external payable {}

    modifier onlyFork() {
        if (!_onFork) return;
        _;
    }

    // ─── helpers ──────────────────────────────────────────────────────────

    function _buy(uint256 ethIn, bytes memory hookData) internal {
        swapRouter.swap{value: ethIn}(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, // ETH (currency0) -> token
                amountSpecified: -int256(ethIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    // ─── precondition: the MEV gate is the path under test ───────────────

    /// @notice Sanity that the MEV module IS operational right after setUp.
    ///         If this ever flips false, the malformed-data tests below would
    ///         be vacuous (they'd skip the bare-decode path entirely), so this
    ///         pins the precondition that makes them meaningful.
    function test_mevModuleOperational_precondition() public onlyFork {
        assertTrue(
            hook.mevModuleOperational(poolKey.toId()),
            "MEV module must be operational for the decode path to run"
        );
    }

    // ─── the fix: malformed swapData must not revert in the MEV window ────

    /// @notice A swap carrying a single-uint256 payload (a wrong shape for the
    ///         `PoolSwapData` 2-bytes-tuple) must NOT revert while the MEV
    ///         module is operational; the swap completes and delivers token.
    ///         Pre-fix this reverted in `_runMevModule`'s bare decode.
    function test_malformedSwapData_uint_doesNotRevert_mevWindow() public onlyFork {
        assertTrue(hook.mevModuleOperational(poolKey.toId()), "precondition: operational");

        bytes memory malformed = abi.encode(uint256(123));
        uint256 balBefore = IERC20(address(token)).balanceOf(address(this));

        _buy(1 ether, malformed); // must not revert

        uint256 received = IERC20(address(token)).balanceOf(address(this)) - balBefore;
        assertGt(received, 0, "swap completed: token delivered despite malformed swapData");
    }

    /// @notice A three-word payload decoded as `PoolSwapData` (a 2-bytes-tuple)
    ///         reads word[0]=1 as the first field's offset — an invalid pointer
    ///         into the middle of a word — and the bare decode reverts. The
    ///         tolerant path swallows it and the swap completes.
    ///
    ///         (Note: the `abi.encode(bytes(""), bytes("x"))` 2-tuple shape the
    ///         docs warn about is NOT used here — it is structurally a *valid*
    ///         `(bytes,bytes)` and decodes cleanly even pre-fix, so it would be
    ///         a vacuous case for this guard.)
    function test_malformedSwapData_threeWord_doesNotRevert_mevWindow() public onlyFork {
        assertTrue(hook.mevModuleOperational(poolKey.toId()), "precondition: operational");

        bytes memory malformed = abi.encode(uint256(1), uint256(2), uint256(3));
        uint256 balBefore = IERC20(address(token)).balanceOf(address(this));

        _buy(1 ether, malformed); // must not revert

        uint256 received = IERC20(address(token)).balanceOf(address(this)) - balBefore;
        assertGt(received, 0, "swap completed: token delivered despite 3-word swapData");
    }

    /// @notice Truncated garbage bytes (a payload whose declared dynamic
    ///         offsets point past its own length) is tolerated too.
    function test_malformedSwapData_garbage_doesNotRevert_mevWindow() public onlyFork {
        assertTrue(hook.mevModuleOperational(poolKey.toId()), "precondition: operational");

        bytes memory malformed = hex"deadbeef";
        uint256 balBefore = IERC20(address(token)).balanceOf(address(this));

        _buy(1 ether, malformed); // must not revert

        uint256 received = IERC20(address(token)).balanceOf(address(this)) - balBefore;
        assertGt(received, 0, "swap completed: token delivered despite garbage swapData");
    }

    /// @notice Control: a WELL-FORMED PoolSwapData (empty inner fields) also
    ///         completes — confirms the swap itself is healthy in this fixture,
    ///         so a malformed-data revert (pre-fix) is attributable to the
    ///         decode, not to unrelated swap setup.
    function test_wellFormedSwapData_doesNotRevert_mevWindow() public onlyFork {
        assertTrue(hook.mevModuleOperational(poolKey.toId()), "precondition: operational");

        bytes memory wellFormed = abi.encode(
            IArtCoinsHook.PoolSwapData({mevModuleSwapData: "", poolExtensionSwapData: ""})
        );
        uint256 balBefore = IERC20(address(token)).balanceOf(address(this));

        _buy(1 ether, wellFormed); // must not revert

        uint256 received = IERC20(address(token)).balanceOf(address(this)) - balBefore;
        assertGt(received, 0, "swap completed with well-formed swapData");
    }
}
