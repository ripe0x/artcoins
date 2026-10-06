// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ForkStack} from "./ForkStack.sol";

import {ArtCoinsFactory} from "../../../src/ArtCoinsFactory.sol";
import {ArtCoinsFeeEscrow} from "../../../src/ArtCoinsFeeEscrow.sol";
import {IArtCoinsHookSkimFee} from "../../../src/hooks/interfaces/IArtCoinsHookSkimFee.sol";
import {ArtCoinsLpLocker} from "../../../src/lp-lockers/ArtCoinsLpLocker.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

interface ISkimConfigView {
    function skimConfig(PoolId)
        external
        view
        returns (uint24, uint16, uint24, uint24, address payable, address payable, address payable, address);
}

interface IMevSkimView {
    function currentSkimBps(PoolId) external view returns (uint24);
}

/// @title  HarnessForkTest
/// @notice Proves the v2 fork harness: pinned fork, fresh stack from src,
///         launch, buy and sell through the skim hook with fee flows, and a
///         swap against the live coin 111 pool crediting the live recipients.
/// Run:
///   /tmp/claude-0/forge.sh test --match-path "test/v2/harness/**" -vv
contract HarnessForkTest is ForkStack {
    uint256 internal constant SKIM_DENOM = 100_000;
    uint256 internal constant BPS = 10_000;

    function setUp() public {
        forkMainnet();
    }

    // ─── fork + live wiring ─────────────────────────────────────────────

    function test_fork_pinnedBlock_liveStackWiring() public onlyFork {
        assertEq(block.chainid, 1, "mainnet");
        assertEq(block.number, vm.envOr("FORK_BLOCK", FORK_BLOCK), "pinned block");

        LiveStack memory s = liveStack();
        ArtCoinsFactory f = ArtCoinsFactory(payable(s.factory));
        assertEq(f.owner(), LIVE_OWNER, "live factory owner");
        assertTrue(f.deprecated(), "live factory deprecated");
        assertEq(f.version(), "1", "live factory version");
        assertEq(f.deployFee(), LIVE_DEPLOY_FEE, "live deployFee");
        assertTrue(f.enabledHooks(s.hook), "hook enabled");
        assertTrue(f.enabledLockers(s.locker, s.hook), "locker enabled");
        assertTrue(f.enabledMevModules(s.mev), "mev enabled");
        assertTrue(ArtCoinsFeeEscrow(s.escrow).allowedDepositors(s.hook), "hook depositor");
        assertTrue(ArtCoinsFeeEscrow(s.escrow).allowedDepositors(s.locker), "locker depositor");

        assertEq(address(s.coin111Key.hooks), s.hook, "111 hook");
        assertTrue(s.coin111Key.currency0.isAddressZero(), "111 paired with native eth");
        assertEq(Currency.unwrap(s.coin111Key.currency1), COIN_111, "111 is currency1");
        assertEq(s.coin111Key.fee, LPFeeLibrary.DYNAMIC_FEE_FLAG, "111 dynamic fee");
        assertEq(s.coin111Key.tickSpacing, 200, "111 spacing");
        (uint160 sqrtP,,,) = readSlot0(s.coin111Key);
        assertGt(sqrtP, 0, "111 pool initialized");
        assertGt(readLiquidity(s.coin111Key), 0, "111 pool has liquidity");

        // older + legacy factories exist and are owned by the same eoa.
        assertEq(ArtCoinsFactory(payable(OLDER_FACTORY)).owner(), LIVE_OWNER, "older owner");
        assertEq(ArtCoinsFactory(payable(LEGACY_FACTORY)).owner(), LIVE_OWNER, "legacy owner");
    }

    function test_freshStack_wiringMatchesLive() public onlyFork {
        FreshStack memory s = deployFreshStack();
        ArtCoinsFactory live = ArtCoinsFactory(payable(LIVE_FACTORY));

        assertEq(s.factory.version(), live.version(), "version");
        assertEq(s.factory.defaultProtocolFeeBps(), live.defaultProtocolFeeBps(), "protocol bps");
        assertEq(s.factory.deployFee(), live.deployFee(), "deployFee");
        assertEq(s.factory.teamFeeRecipient(), s.owner, "teamFeeRecipient == owner (live too)");
        assertEq(live.teamFeeRecipient(), LIVE_OWNER, "live teamFeeRecipient == owner");
        assertFalse(s.factory.deprecated(), "fresh un-deprecated");
        assertEq(s.locker.keeperRewardBps(), ArtCoinsLpLocker(payable(LIVE_LOCKER)).keeperRewardBps());
        assertEq(
            uint160(address(s.hook)) & Hooks.ALL_HOOK_MASK,
            uint160(LIVE_HOOK) & Hooks.ALL_HOOK_MASK,
            "same hook permission bits as live"
        );
        assertTrue(s.escrow.allowedDepositors(address(s.hook)), "hook depositor");
        assertTrue(s.escrow.allowedDepositors(address(s.locker)), "locker depositor");
    }

    // ─── fresh stack: launch, buy, sell, fee flows ──────────────────────

    function test_freshStack_launchBuySell_feeFlows() public onlyFork {
        deployFreshStack();
        LaunchParams memory p = defaultLaunchParams();
        uint256 teamBefore = stack.owner.balance;
        Launched memory l = launchToken(p);

        assertEq(stack.owner.balance - teamBefore, LIVE_DEPLOY_FEE, "deploy fee to team");
        assertEq(l.numPositions, 12, "LAYER 12 position preset");
        assertEq(IERC20(l.token).balanceOf(address(stack.locker)), 0, "all supply in LP");
        (uint160 sqrtP,,,) = readSlot0(l.key);
        assertGt(sqrtP, 0, "pool initialized");

        // buy at t0: total skim = mev starting bps (90%).
        LiveSkim memory c = LiveSkim({
            baseBps: p.baselineSkimBps,
            bountyBps: p.bountyBps,
            totalBps: 90_000,
            bountyR: p.bountyRecipient,
            protoR: p.protocolRecipient
        });
        _buyAndCheckLegs(l, c, 1 ether, "t0");

        // post window: baseline only.
        skip(31 minutes);
        c.totalBps = c.baseBps;
        _buyAndCheckLegs(l, c, 1 ether, "post window");

        _sellHalfAndCheckLegs(l, c);
        _collectAndClaim(l, p);
    }

    function _buyAndCheckLegs(Launched memory l, LiveSkim memory c, uint256 ethIn, string memory tag)
        internal
    {
        uint256 bBefore = c.bountyR.balance;
        uint256 eBefore = stack.escrow.availableFees(c.protoR, address(0));
        (, uint256 got) = swapExactIn(l.key, true, ethIn, address(this), "");
        assertGt(got, 0, tag);
        (uint256 expBounty, uint256 expProto) = _expectedLegs(ethIn, c);
        assertApproxEqAbs(c.bountyR.balance - bBefore, expBounty, 2, string.concat(tag, " bounty"));
        assertApproxEqAbs(
            stack.escrow.availableFees(c.protoR, address(0)) - eBefore,
            expProto,
            2,
            string.concat(tag, " protocol")
        );
    }

    function _sellHalfAndCheckLegs(Launched memory l, LiveSkim memory c) internal {
        uint256 tokenBal = IERC20(l.token).balanceOf(address(this));
        assertGt(tokenBal, 0, "bought tokens");
        uint256 bBefore = c.bountyR.balance;
        uint256 eBefore = stack.escrow.availableFees(c.protoR, address(0));
        (, uint256 ethOut) = swapExactIn(l.key, false, tokenBal / 2, address(this), "");
        assertGt(ethOut, 0, "sell paid eth");
        assertGt(c.bountyR.balance - bBefore, 0, "sell bounty");
        assertGt(stack.escrow.availableFees(c.protoR, address(0)) - eBefore, 0, "sell protocol");
    }

    function _collectAndClaim(Launched memory l, LaunchParams memory p) internal {
        // LP fees: collect into the escrow for every reward slot.
        stack.locker.collectRewards(l.token);
        assertGt(stack.escrow.availableFees(p.rewardRecipients[0], address(0)), 0, "artist eth");
        assertGt(stack.escrow.availableFees(p.rewardRecipients[1], address(0)), 0, "project eth");
        assertGt(stack.escrow.availableFees(stack.owner, address(0)), 0, "protocol slot eth");
        assertGt(stack.escrow.availableFees(p.rewardRecipients[0], l.token), 0, "artist token");

        // escrow pays out.
        uint256 owed = stack.escrow.availableFees(p.protocolRecipient, address(0));
        uint256 pBefore = p.protocolRecipient.balance;
        stack.escrow.claim(p.protocolRecipient, address(0));
        assertEq(p.protocolRecipient.balance - pBefore, owed, "protocol claim");
    }

    function test_freshStack_taxedLaunch_canonicalBuyUntaxed() public onlyFork {
        deployFreshStack();
        LaunchParams memory p = defaultLaunchParams();
        p.taxBps = 1500;
        Launched memory l = launchToken(p);
        assertTrue(
            IArtCoinsHookSkimFee(address(stack.hook)).poolTaxEnabled(l.id), "hook detected tax"
        );
        skip(31 minutes);
        uint256 deadBefore = IERC20(l.token).balanceOf(0x000000000000000000000000000000000000dEaD);
        (, uint256 out) = swapExactIn(l.key, true, 0.5 ether, makeAddr("buyer"), "");
        assertGt(out, 0, "bought");
        assertEq(IERC20(l.token).balanceOf(makeAddr("buyer")), out, "buyer got net out");
        assertEq(
            IERC20(l.token).balanceOf(0x000000000000000000000000000000000000dEaD),
            deadBefore,
            "canonical buy not taxed"
        );
    }

    function test_freshStack_addLiquidity_blockedInWindow_openAfter() public onlyFork {
        deployFreshStack();
        Launched memory l = launchToken(defaultLaunchParams());
        (, int24 tick,,) = readSlot0(l.key);
        // one-sided eth range strictly above the current tick.
        int24 lower = (tick / 200 + 1) * 200;
        int24 upper = lower + 2000;

        vm.expectRevert();
        this.externalAddLiquidity(l, lower, upper, 1e18);

        skip(31 minutes);
        BalanceDelta d = addLiquidity(l.key, lower, upper, 1e18, "");
        assertLt(d.amount0(), 0, "paid eth");
        assertEq(d.amount1(), 0, "no token needed above tick");
    }

    function externalAddLiquidity(Launched memory l, int24 lower, int24 upper, uint128 liq) external {
        addLiquidity(l.key, lower, upper, liq, "");
    }

    // ─── live coin 111 ──────────────────────────────────────────────────

    function test_live111_buySell_skimCreditedToLiveRecipients() public onlyFork {
        LiveStack memory s = liveStack();
        LiveSkim memory c = _liveSkim(s);
        assertGt(c.baseBps, 0, "111 baseline set");

        ArtCoinsFeeEscrow escrow = ArtCoinsFeeEscrow(s.escrow);
        uint256 ethIn = 0.1 ether;
        uint256 bBefore = c.bountyR.balance;
        uint256 eBefore = escrow.availableFees(c.protoR, address(0));

        (, uint256 got) = swapExactIn(s.coin111Key, true, ethIn, address(this), "");
        assertGt(got, 0, "bought 111");

        uint256 bounty = c.bountyR.balance - bBefore;
        uint256 proto = escrow.availableFees(c.protoR, address(0)) - eBefore;
        assertGt(bounty + proto, 0, "non zero skim on live 111 buy");
        (uint256 expBounty, uint256 expProto) = _expectedLegs(ethIn, c);
        assertApproxEqAbs(bounty, expBounty, 2, "live bounty leg");
        assertApproxEqAbs(proto, expProto, 2, "live protocol leg escrowed");

        // sell it back: output side skim credited again.
        bBefore = c.bountyR.balance;
        eBefore = escrow.availableFees(c.protoR, address(0));
        (, uint256 ethOut) = swapExactIn(s.coin111Key, false, got, address(this), "");
        assertGt(ethOut, 0, "sold 111");
        assertGt(c.bountyR.balance - bBefore, 0, "live bounty on sell");
        assertGt(escrow.availableFees(c.protoR, address(0)) - eBefore, 0, "live protocol on sell");
    }

    // ─── helpers ────────────────────────────────────────────────────────

    struct LiveSkim {
        uint24 baseBps;
        uint16 bountyBps;
        uint24 totalBps;
        address payable bountyR;
        address payable protoR;
    }

    function _liveSkim(LiveStack memory s) internal view returns (LiveSkim memory c) {
        (c.baseBps, c.bountyBps,,, c.bountyR, c.protoR,,) =
            ISkimConfigView(s.hook).skimConfig(s.coin111Id);
        uint24 cur = IMevSkimView(s.mev).currentSkimBps(s.coin111Id);
        c.totalBps = cur > c.baseBps ? cur : c.baseBps;
    }

    /// @dev Exact-input buy legs: bounty = baseline * bountyBps + anti-sniper
    ///      extra; protocol = baseline remainder (no referrer in hookData).
    function _expectedLegs(uint256 ethIn, LiveSkim memory c)
        internal
        pure
        returns (uint256 bounty, uint256 proto)
    {
        uint256 baseline = ethIn * c.baseBps / SKIM_DENOM;
        uint256 total = ethIn * c.totalBps / SKIM_DENOM;
        uint256 bountyShare = baseline * c.bountyBps / BPS;
        bounty = bountyShare + (total - baseline);
        proto = baseline - bountyShare;
    }

}
