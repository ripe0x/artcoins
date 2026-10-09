// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// test only base for test/v2/HookV2*.fork.t.sol. self contained (does not use
// the shared harness): forks mainnet at a pinned block, deploys the v2 hook
// with HookMiner against the live PoolManager, and acts as the launcher.
// without an rpc the fork tests skip themselves; owner and decoder tests still
// run because the hook constructor needs no PoolManager code.

import {Test} from "forge-std/Test.sol";

import {Constants} from "../../../src/Constants.sol";
import {
    ArtCoinsPoolExtensionAllowlist
} from "../../../src/hooks/ArtCoinsPoolExtensionAllowlist.sol";
import {PCAttribution, PCSwapData} from "../../../src/hooks/interfaces/IArtCoinsHookSkimFee.sol";
import {IArtCoinsHook} from "../../../src/interfaces/IArtCoinsHook.sol";
import {ArtCoinsFeeEscrowV2} from "../../../src/v2/ArtCoinsFeeEscrowV2.sol";
import {ArtCoinsTokenV2} from "../../../src/v2/ArtCoinsTokenV2.sol";
import {ArtCoinsHookV2} from "../../../src/v2/hooks/ArtCoinsHookV2.sol";
import {IArtCoinsFactoryV2} from "../../../src/v2/interfaces/IArtCoinsFactoryV2.sol";
import {IArtCoinsHookV2} from "../../../src/v2/interfaces/IArtCoinsHookV2.sol";
import {ArtCoinsMevLinearSkimV2} from "../../../src/v2/mev-modules/ArtCoinsMevLinearSkimV2.sol";
import {HV2ConstantsStub, HV2SwapSeqRouter, IHV2Erc20} from "./HookV2Mocks.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

abstract contract HookV2ForkBase is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    /// @dev same pin as test/v2/harness/ForkBase.sol.
    uint256 internal constant FORK_BLOCK = 26_130_269;
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );
    int24 internal constant TS = 200;
    int24 internal constant FULL_LO = -887_200;
    int24 internal constant FULL_HI = 887_200;
    uint256 internal constant LIQ = 1000e18;

    // default pool fee config (coin 111 live values)
    uint24 internal constant BASELINE = 6000;
    uint16 internal constant BOUNTY_BPS = 8333;
    uint24 internal constant MAX_REF = 250;
    uint24 internal constant LP_FEE = 5000;

    bool internal onFork;
    IPoolManager internal pm = IPoolManager(POOL_MANAGER);
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liqRouter;
    /// settles from currencyDelta like V4Router; PoolSwapTest cannot be used
    /// for partial quote specified fills (its returned delta equality check
    /// does not hold once the refund is credited inside the swap, D42).
    HV2SwapSeqRouter internal seq;
    ArtCoinsFeeEscrowV2 internal escrow;
    ArtCoinsPoolExtensionAllowlist internal allowlist;
    ArtCoinsHookV2 internal hook;
    HV2ConstantsStub internal lockerStub;
    address payable internal protocolR = payable(makeAddr("protocolRecipient"));
    address payable internal bountyEoa = payable(makeAddr("bountyEoa"));
    uint256 internal tokenNonce;

    struct Launch {
        bool restricted;
        address bounty;
        uint24 baseline;
        uint16 bountyBps;
        uint24 maxRef;
        address module;
        address extension;
        bytes mevConfig;
    }

    receive() external payable virtual {}

    /// @dev This base is the token's `launcher()` (the factory) in these tests;
    ///      the hook reads `factory.tokenDeployer()` in its fail-closed reject set.
    function tokenDeployer() external view returns (address) {
        return address(this);
    }

    function setUp() public virtual {
        if (!vm.envOr("SKIP_FORK_TESTS", false)) {
            string memory rpc =
                vm.envOr("MAINNET_RPC_URL", string("https://mainnet.gateway.tenderly.co"));
            if (bytes(rpc).length == 0) rpc = "https://mainnet.gateway.tenderly.co";
            try vm.createSelectFork(rpc, FORK_BLOCK) {
                onFork = POOL_MANAGER.code.length != 0;
            } catch {}
        }

        escrow = new ArtCoinsFeeEscrowV2(address(this));
        allowlist = new ArtCoinsPoolExtensionAllowlist(address(this));
        bytes memory args =
            abi.encode(POOL_MANAGER, address(this), address(escrow), address(allowlist));
        (address at, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(ArtCoinsHookV2).creationCode, args);
        hook = new ArtCoinsHookV2{salt: salt}(
            IPoolManager(POOL_MANAGER), address(this), address(escrow), address(allowlist)
        );
        require(address(hook) == at, "miner mismatch");
        escrow.addDepositor(address(hook), true);
        hook.setLauncher(address(this), true);

        lockerStub = new HV2ConstantsStub(Constants.hash());

        if (onFork) {
            swapRouter = new PoolSwapTest(pm);
            liqRouter = new PoolModifyLiquidityTest(pm);
            seq = new HV2SwapSeqRouter(pm);
            vm.deal(address(seq), 10_000 ether);
        }
        vm.deal(address(this), 1_000_000 ether);
    }

    modifier onlyFork() {
        if (!onFork) {
            vm.skip(true);
            return;
        }
        _;
    }

    // ─── launch ──────────────────────────────────────────────────────────

    function _defaults(address bounty) internal view returns (Launch memory l) {
        l.bounty = bounty;
        l.baseline = BASELINE;
        l.bountyBps = BOUNTY_BPS;
        l.maxRef = MAX_REF;
    }

    function _newToken(bool restricted, address, address hook_)
        internal
        returns (ArtCoinsTokenV2 token)
    {
        IArtCoinsFactoryV2.TokenConfigV2 memory t;
        t.tokenAdmin = address(this);
        t.name = "Hook V2 Test";
        t.symbol = "HV2T";
        t.salt = bytes32(++tokenNonce);
        IArtCoinsFactoryV2.RestrictionConfigV2 memory r;
        r.restricted = restricted;
        if (restricted) {
            // the test contract and its routers move coin directly; allowlist
            // them so the restriction tests the hook granted allowance only
            // where a swap actually routes coin through the PoolManager.
            r.allowed = new address[](4);
            r.allowed[0] = address(this);
            r.allowed[1] = address(swapRouter);
            r.allowed[2] = address(liqRouter);
            r.allowed[3] = address(seq);
        }
        token = new ArtCoinsTokenV2(
            t,
            1_000_000_000e18,
            r,
            new address[](0),
            ArtCoinsTokenV2.CanonicalPool({
                hook: hook_, poolManager: POOL_MANAGER, tickSpacing: TS
            }),
            address(this)
        );
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(liqRouter), type(uint256).max);
    }

    function _params(Launch memory l, address token)
        internal
        view
        returns (IArtCoinsHookV2.PoolInitParams memory p)
    {
        p.token = token;
        p.tickIfToken0IsCoin = 0;
        p.tickSpacing = TS;
        p.locker = address(lockerStub);
        p.mevModule = l.module;
        p.extension = l.extension;
        p.skim = IArtCoinsHookV2.SkimConfig({
            baselineSkimBps: l.baseline,
            bountyBps: l.bountyBps,
            maxReferralBpsOfVolume: l.maxRef,
            lpFee: LP_FEE,
            bountyRecipient: payable(l.bounty),
            protocolRecipient: protocolR
        });
    }

    /// launcher flow: init pool, place full range liquidity (salt 0), start the window.
    function _launch(Launch memory l) internal returns (PoolKey memory key, ArtCoinsTokenV2 token) {
        token = _newToken(l.restricted, l.bounty, address(hook));
        key = hook.initializePool(_params(l, address(token)));
        _modify(key, FULL_LO, FULL_HI, int256(LIQ), 0);
        hook.initializeMevModule(key, l.mevConfig);
    }

    function _launchSimple(address bounty) internal returns (PoolKey memory key) {
        (key,) = _launch(_defaults(bounty));
    }

    // ─── actions ─────────────────────────────────────────────────────────

    function _modify(PoolKey memory key, int24 lo, int24 hi, int256 liq, bytes32 salt) internal {
        liqRouter.modifyLiquidity{value: liq > 0 ? 2000 ether : 0}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: lo, tickUpper: hi, liquidityDelta: liq, salt: salt
            }),
            ""
        );
    }

    function _swap(
        PoolKey memory key,
        bool zeroForOne,
        int256 amount,
        uint160 limit,
        bytes memory hd
    ) internal returns (BalanceDelta d) {
        if (limit == 0) {
            limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        }
        d = swapRouter.swap{value: 1000 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne, amountSpecified: amount, sqrtPriceLimitX96: limit
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hd
        );
        _assertHookHoldsNothing(key);
    }

    /// one swap through `seq`; returns the router's net deltas (negative =
    /// paid) as V4Router would settle them.
    function _swapNet(
        PoolKey memory key,
        bool zeroForOne,
        int256 amount,
        uint160 limit,
        bytes memory hd
    ) internal returns (int256 net0, int256 net1) {
        if (!zeroForOne) {
            IHV2Erc20(Currency.unwrap(key.currency1)).transfer(address(seq), 1000e18);
        }
        HV2SwapSeqRouter.Step[] memory st = new HV2SwapSeqRouter.Step[](1);
        st[0] = HV2SwapSeqRouter.Step(key, zeroForOne, amount, limit, hd);
        seq.run(st);
        net0 = seq.lastNet0();
        net1 = seq.lastNet1();
        _assertHookHoldsNothing(key);
    }

    /// invariant: no erc6909 claim and no eth on the hook after any swap.
    function _assertHookHoldsNothing(PoolKey memory key) internal view {
        assertEq(pm.balanceOf(address(hook), key.currency0.toId()), 0, "hook eth claims");
        assertEq(pm.balanceOf(address(hook), key.currency1.toId()), 0, "hook coin claims");
        assertEq(address(hook).balance, 0, "hook eth");
    }

    function _attribution(address referrer, uint24 bps) internal pure returns (bytes memory) {
        PCSwapData memory inner = PCSwapData({
            attribution: PCAttribution({
                sourceId: bytes32("src"),
                referrer: referrer,
                campaignId: bytes16("cmp"),
                referralBps: bps
            }),
            extensionPayload: hex"c0ffee"
        });
        return abi.encode(
            IArtCoinsHook.PoolSwapData({
                mevModuleSwapData: "", poolExtensionSwapData: abi.encode(inner)
            })
        );
    }

    function _escrowed(address who) internal view returns (uint256) {
        return escrow.balances(who, address(0));
    }

    function _lpFee(PoolKey memory key) internal view returns (uint24 fee) {
        (,,, fee) = pm.getSlot0(key.toId());
    }
}
