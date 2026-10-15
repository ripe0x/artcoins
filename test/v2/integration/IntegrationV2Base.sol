// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// package i1: shared base for the v2 end to end suite. forks mainnet at the
// harness pin, deploys the full v2 stack with the deploy script's own routine
// (script/v2/DeployV2Lib.sol via ForkStack.deployV2Stack, owner = broadcaster
// = the live owner eoa), and launches coins through the real factory, hook,
// locker and anti sniper module. skips cleanly without an rpc.

import {ForkStack} from "../harness/ForkStack.sol";
import {I1DeltaRouter} from "./mocks/I1Mocks.sol";

import {Constants} from "../../../src/Constants.sol";
import {IArtCoinsHook} from "../../../src/interfaces/IArtCoinsHook.sol";
import {ArtCoinsTokenV2} from "../../../src/v2/ArtCoinsTokenV2.sol";
import {IArtCoinsFactoryV2} from "../../../src/v2/interfaces/IArtCoinsFactoryV2.sol";
import {IArtCoinsHookV2} from "../../../src/v2/interfaces/IArtCoinsHookV2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Vm} from "forge-std/Vm.sol";

abstract contract IntegrationV2Base is ForkStack {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant D = Constants.BPS;

    // credits engine coin (CREDITS-ENGINE-INTERFACE.md section 4, example.json)
    uint24 internal constant BASELINE = 600;
    uint16 internal constant BOUNTY_BPS = 8333;
    uint24 internal constant START_SKIM = 6869;
    uint32 internal constant WINDOW = 4140;

    // uniswap v3 mainnet (test/v2/TokenV2.fork.t.sol)
    address internal constant V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    bytes32 internal constant V3_INIT =
        0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;

    // event topics
    bytes32 internal constant SKIM_SPLIT_SIG =
        keccak256("SkimSplit(bytes32,uint256,uint256,uint256,uint256)");
    bytes32 internal constant SKIM_REFUNDED_SIG =
        keccak256("SkimRefunded(bytes32,address,uint256)");
    bytes32 internal constant FEE_DELIVERED_SIG =
        keccak256("FeeDelivered(bytes32,uint8,address,uint256,bool)");

    address internal admin = makeAddr("i1.admin");
    address internal stranger = makeAddr("i1.stranger");
    IPoolManager internal pm = IPoolManager(POOL_MANAGER);
    I1DeltaRouter internal deltaRouter;

    /// sum of the hook's skim events in a log window.
    struct Legs {
        uint256 volume;
        uint256 bounty;
        uint256 protocol;
        uint256 referral;
        uint256 refunded;
        uint256 splits;
    }

    function setUp() public virtual {
        forkMainnet();
        if (!onFork) return;
        deployV2Stack(); // sets `v2` and `v2Params`; owner = broadcaster = LIVE_OWNER
        deltaRouter = new I1DeltaRouter(pm);
        vm.label(admin, "i1.admin");
        vm.label(stranger, "i1.stranger");
    }

    // ── configs ───────────────────────────────────────────────────────────

    /// The credits engine coin of CREDITS-ENGINE-INTERFACE.md section 4: VENUE
    /// at 0 bps (cap 10%), treasury as bounty recipient, 69 minute skim from 68.69% to the 6% baseline.
    function _creditsConfig(address treasury)
        internal
        view
        returns (IArtCoinsFactoryV2.DeploymentConfigV2 memory c)
    {
        c.token = IArtCoinsFactoryV2.TokenConfigV2({
            tokenAdmin: admin,
            name: "credits engine",
            symbol: "CREDITS",
            salt: bytes32(uint256(1)),
            image: "ipfs://credits",
            description: "{}",
            totalSupply: 0,
            renderer: address(0)
        });
        c.pool = IArtCoinsFactoryV2.PoolConfigV2({
            hook: address(v2.hook),
            tickIfToken0IsCoin: -200_000,
            tickSpacing: 200,
            extension: address(0),
            extensionData: ""
        });
        c.fee = IArtCoinsFactoryV2.FeeConfigV2({
            baselineSkimBps: BASELINE,
            bountyBps: BOUNTY_BPS,
            bountyRecipient: payable(treasury),
            referralBps: 0
        });
        int24[] memory lo = new int24[](3);
        lo[0] = -200_000;
        lo[1] = -160_000;
        lo[2] = -120_000;
        int24[] memory hi = new int24[](3);
        hi[0] = -120_000;
        hi[1] = -100_000;
        hi[2] = -60_000;
        uint16[] memory pos = new uint16[](3);
        pos[0] = 5000;
        pos[1] = 3000;
        pos[2] = 2000;
        c.locker = IArtCoinsFactoryV2.LockerConfigV2({
            locker: address(v2.locker), tickLower: lo, tickUpper: hi, positionBps: pos
        });
        c.mev = IArtCoinsFactoryV2.MevConfigV2({
            module: address(v2.mev), startingSkimBps: START_SKIM, windowSeconds: WINDOW
        });
        c.restriction =
            IArtCoinsFactoryV2.RestrictionConfigV2({restricted: false, allowed: new address[](0)});
        c.extensions = new IArtCoinsFactoryV2.ExtensionConfigV2[](0);
    }

    /// Same coin, plain erc20 (not restricted).
    function _noneConfig(address bounty)
        internal
        view
        returns (IArtCoinsFactoryV2.DeploymentConfigV2 memory c)
    {
        c = _creditsConfig(bounty);
        c.token.symbol = "NONE";
    }

    /// Restricted coin: wallet to wallet transfers revert unless allowlisted.
    function _restrictedConfig(address bounty)
        internal
        view
        returns (IArtCoinsFactoryV2.DeploymentConfigV2 memory c)
    {
        c = _creditsConfig(bounty);
        c.token.symbol = "REST";
        c.restriction.restricted = true;
    }

    /// One narrow position holding the whole pool supply: about 2.2 eth buys
    /// it out, so a larger buy fills partially at any price limit.
    function _narrow(IArtCoinsFactoryV2.DeploymentConfigV2 memory c) internal pure {
        int24[] memory lo = new int24[](1);
        lo[0] = -200_000;
        int24[] memory hi = new int24[](1);
        hi[0] = -199_000;
        uint16[] memory pos = new uint16[](1);
        pos[0] = 10_000;
        c.locker.tickLower = lo;
        c.locker.tickUpper = hi;
        c.locker.positionBps = pos;
    }

    // ── launch ────────────────────────────────────────────────────────────

    function _ownerLaunch(IArtCoinsFactoryV2.DeploymentConfigV2 memory c)
        internal
        returns (address token)
    {
        uint256 fee = v2.factory.deployFee();
        vm.deal(LIVE_OWNER, LIVE_OWNER.balance + fee);
        vm.prank(LIVE_OWNER);
        token = v2.factory.deployToken{value: fee}(c);
        vm.label(token, c.token.symbol);
    }

    function _key(address token) internal view returns (PoolKey memory) {
        return v2.locker.lockedLiquidity(token).poolKey;
    }

    function _pid(address token) internal view returns (PoolId) {
        return _key(token).toId();
    }

    function _pastWindow() internal {
        vm.warp(vm.getBlockTimestamp() + Constants.MAX_MEV_WINDOW + 1);
        vm.roll(vm.getBlockNumber() + 1);
    }

    // ── swaps ─────────────────────────────────────────────────────────────

    function _buy(PoolKey memory key, uint256 ethIn) internal returns (uint256 out) {
        (, out) = swapExactIn(key, true, ethIn, address(this), "");
    }

    function _sell(PoolKey memory key, uint256 coinIn) internal returns (uint256 out) {
        (, out) = swapExactIn(key, false, coinIn, address(this), "");
    }

    function _buyAndSell(PoolKey memory key, uint256 ethIn) internal {
        uint256 got = _buy(key, ethIn);
        assertGt(got, 0, "bought");
        uint256 e = _sell(key, got / 2);
        assertGt(e, 0, "sold");
    }

    // ── hookData ──────────────────────────────────────────────────────────

    /// @dev hookData naming `referrer`.
    function _referral(address referrer) internal pure returns (bytes memory) {
        return abi.encode(
            IArtCoinsHook.PoolSwapData({
                mevModuleSwapData: "", poolExtensionSwapData: abi.encode(referrer, bytes(""))
            })
        );
    }

    function _refundData(address to) internal pure returns (bytes memory) {
        return abi.encode(
            IArtCoinsHook.PoolSwapData({
                mevModuleSwapData: abi.encode(to), poolExtensionSwapData: ""
            })
        );
    }

    // ── logs and reads ────────────────────────────────────────────────────

    function _legs(Vm.Log[] memory logs) internal view returns (Legs memory l) {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory g = logs[i];
            if (g.emitter != address(v2.hook) || g.topics.length == 0) continue;
            if (g.topics[0] == SKIM_SPLIT_SIG) {
                (uint256 v, uint256 b, uint256 p, uint256 r) =
                    abi.decode(g.data, (uint256, uint256, uint256, uint256));
                l.volume += v;
                l.bounty += b;
                l.protocol += p;
                l.referral += r;
                l.splits++;
            } else if (g.topics[0] == SKIM_REFUNDED_SIG) {
                l.refunded += abi.decode(g.data, (uint256));
            }
        }
    }

    /// FeeDelivered sums for `to`: pushed directly vs credited in the escrow.
    function _delivered(Vm.Log[] memory logs, address to)
        internal
        view
        returns (uint256 pushed, uint256 escrowed)
    {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory g = logs[i];
            if (
                g.emitter != address(v2.hook) || g.topics.length != 4
                    || g.topics[0] != FEE_DELIVERED_SIG
            ) {
                continue;
            }
            if (address(uint160(uint256(g.topics[3]))) != to) continue;
            (uint256 amt, bool esc) = abi.decode(g.data, (uint256, bool));
            if (esc) escrowed += amt;
            else pushed += amt;
        }
    }

    function _escrowed(address who) internal view returns (uint256) {
        return v2.escrow.balances(who, address(0));
    }

    function _owed() internal view returns (uint256) {
        return v2.escrow.totalOwed(address(0));
    }

    function _assertHookHoldsNothing(PoolKey memory key) internal view {
        assertEq(address(v2.hook).balance, 0, "hook eth");
        assertEq(pm.balanceOf(address(v2.hook), key.currency0.toId()), 0, "hook eth claims");
        assertEq(pm.balanceOf(address(v2.hook), key.currency1.toId()), 0, "hook coin claims");
        assertEq(IERC20(Currency.unwrap(key.currency1)).balanceOf(address(v2.hook)), 0, "hook coin");
    }

    /// true when `needle` appears anywhere in `hay` (revert reasons wrapped by
    /// the PoolManager or a router).
    function _contains(bytes memory hay, bytes4 needle) internal pure returns (bool) {
        if (hay.length < 4) return false;
        for (uint256 i; i + 4 <= hay.length; ++i) {
            if (
                hay[i] == needle[0] && hay[i + 1] == needle[1] && hay[i + 2] == needle[2]
                    && hay[i + 3] == needle[3]
            ) return true;
        }
        return false;
    }

    function _token(address t) internal pure returns (ArtCoinsTokenV2) {
        return ArtCoinsTokenV2(t);
    }
}
