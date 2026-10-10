// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

/// @title  ForkBase
/// @notice Shared mainnet fork base for every v2 test. Pins one block, carries
///         the canonical mainnet v4 infra and live artcoins addresses, and
///         wraps the v4 test routers for swaps and liquidity.
/// @dev    Usage: call `forkMainnet()` in `setUp`, then start every test with
///         `skipUnlessFork()` (or use the `onlyFork` modifier). When the rpc is
///         unreachable, `forkMainnet()` returns false and the tests are marked
///         skipped, so ci without network stays green.
///         Rpc: `MAINNET_RPC_URL`, default tenderly public gateway.
///         Block: `FORK_BLOCK`, overridable with env `FORK_BLOCK`.
///         Opt out of forking entirely with env `SKIP_FORK_TESTS=true`.
abstract contract ForkBase is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ─── fork pin ────────────────────────────────────────────────────────

    /// @notice Pinned mainnet block (chain head 26_130_319 minus 50, read
    ///         2026-10-06). Pinning makes reruns hit foundry's on-disk rpc
    ///         cache, which is what keeps the tenderly gateway under its rate
    ///         limit. Bump deliberately; document the new block in
    ///         docs/v2/review/harness.md.
    uint256 internal constant FORK_BLOCK = 26_130_269;

    string internal constant DEFAULT_MAINNET_RPC = "https://mainnet.gateway.tenderly.co";

    // ─── canonical mainnet infra (values taken from test/ and script/) ──

    /// @dev test/ArtCoinsHookSkimFeeForkTest.t.sol, script/DeployV1Stack.s.sol
    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    /// @dev script/DeployV1Stack.s.sol
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    /// @dev script/DeployV1Stack.s.sol
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    /// @dev script/DeployV1Stack.s.sol; equals live locker.positionManager()
    address internal constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    /// @dev test/MainnetLaunchRehearsalForkTest.t.sol
    address internal constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    /// @dev Not in the repo (not in the registry). Uniswap canonical
    ///      mainnet StateView; verified on chain at FORK_BLOCK:
    ///      poolManager() == POOL_MANAGER and getSlot0(coin 111 pool) answers.
    address internal constant STATE_VIEW = 0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227;
    /// @dev Canonical CREATE2 proxy used by `forge script --broadcast`.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // ─── live artcoins (owner table, cross checked with cast at FORK_BLOCK) ──

    /// @dev factory.version()=="1", deprecated, deployFee 0.069 eth.
    address internal constant LIVE_FACTORY = 0x49596c375c139E79bb937bcf826068a8F78D4e0e;
    /// @dev ArtCoinsHookSkimFee; hook.factory()==LIVE_FACTORY.
    address internal constant LIVE_HOOK = 0x636c050296B5Cc528D8785169Bf8923716FCa9cc;
    /// @dev ArtCoinsLpLocker; locker.factory()==LIVE_FACTORY, keeperRewardBps 0.
    address internal constant LIVE_LOCKER = 0x866ea3Dc2bf7A3e77374619cf50EB697FA766aab;
    /// @dev ArtCoinsFeeEscrow; hook.feeEscrow()==locker.feeLocker()==this.
    address internal constant LIVE_ESCROW = 0x7559689765aE86cBB38e68CD1294830CccB125F2;
    /// @dev ArtCoinsMevLinearSkim.
    address internal constant LIVE_MEV_SKIM = 0xb038D597365FfD108D63C265Bb0621444a1D8B83;
    /// @dev hook.poolExtensionAllowlist() (not in the owner table; read on chain).
    address internal constant LIVE_POOL_EXT_ALLOWLIST = 0xd6D5fb5CfE386d0eB73a09cba5d190beb802e6E8;
    /// @dev Coin "111" (name "permanent collection"), tax enabled, on the current stack.
    address internal constant COIN_111 = 0x61C9d89fe1212F6b55fF888816A151463287B8ae;
    /// @dev Older open factory, static fee hook only, zero coins.
    address internal constant OLDER_FACTORY = 0xF051cd4C4F3F36F9f24d8a19d60Ee8F84FC6793e;
    /// @dev Legacy deprecated factory, one coin (LAYER).
    address internal constant LEGACY_FACTORY = 0xD1595A2742C392d1c109b616b4F08918D02292f9;
    /// @dev Single eoa owning factory, locker, escrow (and teamFeeRecipient of LIVE_FACTORY).
    address internal constant LIVE_OWNER = 0xCB43078C32423F5348Cab5885911C3B5faE217F9;
    /// @dev Site default referrer, equals the registry protocol payout.
    address internal constant UI_DEFAULT_REFERRER = 0x41c3BD8A36f8fE9Bb77900ca02400b32BB35A6A4;

    // ─── state ───────────────────────────────────────────────────────────

    bool internal onFork;
    uint256 internal forkId;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liqRouter;

    /// @dev PoolSwapTest / PoolModifyLiquidityTest refund leftover ETH to the
    ///      caller. Override if a derived test needs its own receive logic.
    receive() external payable virtual {}

    // ─── fork lifecycle ──────────────────────────────────────────────────

    /// @notice Fork mainnet at the pinned block and deploy the v4 test
    ///         routers. Returns false (and leaves `onFork` false) when the rpc
    ///         is unreachable or `SKIP_FORK_TESTS=true`.
    function forkMainnet() internal returns (bool) {
        if (vm.envOr("SKIP_FORK_TESTS", false)) {
            console2.log("SKIP_FORK_TESTS=true: fork tests skipped");
            return false;
        }
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(DEFAULT_MAINNET_RPC));
        if (bytes(rpc).length == 0) rpc = DEFAULT_MAINNET_RPC;
        uint256 blockNumber = vm.envOr("FORK_BLOCK", FORK_BLOCK);
        try vm.createSelectFork(rpc, blockNumber) returns (uint256 id) {
            forkId = id;
        } catch {
            console2.log("fork unavailable: tests will be skipped");
            return false;
        }
        if (POOL_MANAGER.code.length == 0) return false;
        onFork = true;
        swapRouter = new PoolSwapTest(IPoolManager(POOL_MANAGER));
        liqRouter = new PoolModifyLiquidityTest(IPoolManager(POOL_MANAGER));
        vm.label(POOL_MANAGER, "PoolManager");
        vm.label(WETH, "WETH");
        vm.label(LIVE_FACTORY, "liveFactory");
        vm.label(LIVE_HOOK, "liveHook");
        vm.label(LIVE_LOCKER, "liveLocker");
        vm.label(LIVE_ESCROW, "liveEscrow");
        vm.label(LIVE_MEV_SKIM, "liveMevSkim");
        vm.label(COIN_111, "coin111");
        return true;
    }

    /// @notice Marks the running test skipped when no fork is active.
    function skipUnlessFork() internal {
        if (!onFork) vm.skip(true);
    }

    modifier onlyFork() {
        skipUnlessFork();
        _;
    }

    // ─── funding ─────────────────────────────────────────────────────────

    /// @notice Mint real WETH (deposit backed) to `to`.
    function dealWeth(address to, uint256 amount) internal {
        vm.deal(address(this), address(this).balance + amount);
        IWETH9(payable(WETH)).deposit{value: amount}();
        if (to != address(this)) IERC20(WETH).transfer(to, amount);
    }

    // ─── swaps ───────────────────────────────────────────────────────────

    /// @notice Exact-input swap through `PoolSwapTest`. The harness (this
    ///         contract) pays the input, then forwards the realized output
    ///         to `recipient`. Native input is funded from this contract's
    ///         ETH balance (topped up with `vm.deal` when short); ERC20 input
    ///         must already be held by this contract.
    /// @return delta     PoolManager delta for the router (caller view).
    /// @return amountOut Output actually received (balance diff, so a
    ///                   transfer tax is net of tax).
    function swapExactIn(
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountIn,
        address recipient,
        bytes memory hookData
    ) internal returns (BalanceDelta delta, uint256 amountOut) {
        Currency outC = zeroForOne ? key.currency1 : key.currency0;
        uint256 value = _fundInput(zeroForOne ? key.currency0 : key.currency1, amountIn);
        uint256 outBefore = _bal(outC, address(this));
        delta = _routerSwap(key, zeroForOne, amountIn, value, hookData);
        amountOut = _bal(outC, address(this)) - outBefore;
        _forwardOutput(outC, recipient, amountOut);
    }

    function _fundInput(Currency inC, uint256 amountIn) private returns (uint256 value) {
        if (inC.isAddressZero()) {
            if (address(this).balance < amountIn) vm.deal(address(this), amountIn);
            return amountIn;
        }
        IERC20(Currency.unwrap(inC)).approve(address(swapRouter), amountIn);
        return 0;
    }

    function _routerSwap(
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 value,
        bytes memory hookData
    ) private returns (BalanceDelta) {
        IPoolManager.SwapParams memory sp = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });
        PoolSwapTest.TestSettings memory ts =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        return swapRouter.swap{value: value}(key, sp, ts, hookData);
    }

    function _forwardOutput(Currency outC, address recipient, uint256 amount) private {
        if (recipient == address(this) || amount == 0) return;
        if (outC.isAddressZero()) {
            (bool ok,) = recipient.call{value: amount}("");
            require(ok, "ForkBase: eth forward failed");
        } else {
            IERC20(Currency.unwrap(outC)).transfer(recipient, amount);
        }
    }

    // ─── liquidity ───────────────────────────────────────────────────────

    /// @notice Add `liquidity` to `[tickLower, tickUpper)` via
    ///         `PoolModifyLiquidityTest`. Funds native ETH automatically
    ///         (rounded up, refunded by the router); ERC20 sides must be held
    ///         by this contract. Reverts inside a skim MEV window (the hook
    ///         blocks public LP adds while the module is operational).
    function addLiquidity(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        bytes memory hookData
    ) internal returns (BalanceDelta delta) {
        uint256 value = _fundLiquidity(key, tickLower, tickUpper, liquidity);
        IPoolManager.ModifyLiquidityParams memory mp = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(uint256(liquidity)),
            salt: bytes32(0)
        });
        delta = liqRouter.modifyLiquidity{value: value}(key, mp, hookData);
    }

    function _fundLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity)
        private
        returns (uint256 value)
    {
        // currency1 is never native; the router pulls it via transferFrom.
        IERC20(Currency.unwrap(key.currency1)).approve(address(liqRouter), type(uint256).max);
        if (!key.currency0.isAddressZero()) {
            IERC20(Currency.unwrap(key.currency0)).approve(address(liqRouter), type(uint256).max);
            return 0;
        }
        (uint160 sqrtP,,,) = readSlot0(key);
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);
        if (sqrtP < sqrtB) {
            value = SqrtPriceMath.getAmount0Delta(
                sqrtP > sqrtA ? sqrtP : sqrtA, sqrtB, liquidity, true
            ) + 1;
        }
        if (address(this).balance < value) vm.deal(address(this), value);
    }

    // ─── reads ───────────────────────────────────────────────────────────

    function readSlot0(PoolKey memory key)
        internal
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        return IPoolManager(POOL_MANAGER).getSlot0(key.toId());
    }

    function readLiquidity(PoolKey memory key) internal view returns (uint128) {
        return IPoolManager(POOL_MANAGER).getLiquidity(key.toId());
    }

    function _bal(Currency c, address who) internal view returns (uint256) {
        return c.isAddressZero() ? who.balance : IERC20(Currency.unwrap(c)).balanceOf(who);
    }
}
