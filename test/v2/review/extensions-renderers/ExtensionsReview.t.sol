// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Second-pass review proofs for src/extensions/**. The test contract plays
// the factory (extensions only check msg.sender == factory). No live pool.
// See docs/v2/review/contracts-extensions-renderers.md.

import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {ArtCoinsAirdrop} from "../../../../src/extensions/ArtCoinsAirdrop.sol";
import {ArtCoinsUniv4EthDevBuy} from "../../../../src/extensions/ArtCoinsUniv4EthDevBuy.sol";
import {ArtCoinsVault} from "../../../../src/extensions/ArtCoinsVault.sol";
import {BurnExtension} from "../../../../src/extensions/BurnExtension.sol";
import {
    LiquidityLayerAutoForwardExtension
} from "../../../../src/extensions/LiquidityLayerAutoForwardExtension.sol";
import {IArtCoinsAirdrop} from "../../../../src/extensions/interfaces/IArtCoinsAirdrop.sol";
import {IArtCoinsVault} from "../../../../src/extensions/interfaces/IArtCoinsVault.sol";
import {IArtCoinsFactory} from "../../../../src/interfaces/IArtCoinsFactory.sol";

contract XToken is ERC20 {
    constructor(uint256 s) ERC20("X", "X") {
        _mint(msg.sender, s);
    }
}

contract ExtensionsReviewTest is Test {
    using PoolIdLibrary for PoolKey;

    uint256 constant SUPPLY = 1_000_000_000e18;
    address admin = makeAddr("deployerAdmin");
    address alice = makeAddr("alice");
    XToken token;
    PoolKey pk;

    function setUp() public {
        token = new XToken(SUPPLY);
    }

    function _leaf(address who, uint256 amt) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(who, amt))));
    }

    function _dc(IArtCoinsFactory.ExtensionConfig[] memory ecs)
        internal
        pure
        returns (IArtCoinsFactory.DeploymentConfig memory dc)
    {
        dc.extensionConfigs = ecs;
    }

    function _airdropCfg(address ext, uint16 bps, bytes32 root, address adm, uint256 lock)
        internal
        pure
        returns (IArtCoinsFactory.ExtensionConfig memory)
    {
        return IArtCoinsFactory.ExtensionConfig({
            extension: ext,
            msgValue: 0,
            extensionBps: bps,
            extensionData: abi.encode(
                IArtCoinsAirdrop.AirdropV2ExtensionData({
                    admin: adm, merkleRoot: root, lockupDuration: lock, vestingDuration: 0
                })
            )
        });
    }

    // ─── A1: same-deploy duplicate airdrop with a zero root first ──────

    function test_bug_A1_airdrop_zeroRootThenSecondEntryStrandsFirstTranche() public {
        ArtCoinsAirdrop air = new ArtCoinsAirdrop(address(this));
        IArtCoinsFactory.ExtensionConfig[] memory ecs = new IArtCoinsFactory.ExtensionConfig[](2);
        // entry 0: "set the root later" (zero root), 10%
        ecs[0] = _airdropCfg(address(air), 1000, bytes32(0), admin, 0);
        // entry 1: real root, 5%. factory._prepareExtensions does not dedupe.
        ecs[1] = _airdropCfg(address(air), 500, _leaf(alice, 1e18), admin, 0);
        IArtCoinsFactory.DeploymentConfig memory dc = _dc(ecs);
        uint256 s0 = SUPPLY * 1000 / 10_000;
        uint256 s1 = SUPPLY * 500 / 10_000;

        token.approve(address(air), s0);
        air.receiveTokens(dc, pk, address(token), s0, 0);
        token.approve(address(air), s1);
        air.receiveTokens(dc, pk, address(token), s1, 1); // AirdropAlreadyExists not hit

        (,, uint256 tracked,,,,,) = air.airdrops(address(token));
        assertEq(tracked, s1, "accounting overwritten by second entry");
        assertEq(token.balanceOf(address(air)), s0 + s1);

        vm.warp(block.timestamp + 14 days + 1);
        vm.prank(admin);
        air.adminClaim(address(token), admin);
        // first tranche is stuck forever: no rescue, adminClaim is one-shot.
        assertEq(token.balanceOf(address(air)), s0);
        vm.prank(admin);
        vm.expectRevert(IArtCoinsAirdrop.AdminClaimed.selector);
        air.adminClaim(address(token), admin);
    }

    // ─── A2: admin replaces a live root after lockup + 1 day ───────────

    function test_bug_A2_airdrop_adminSwapsRootAndTakesEverything() public {
        ArtCoinsAirdrop air = new ArtCoinsAirdrop(address(this));
        IArtCoinsFactory.ExtensionConfig[] memory ecs = new IArtCoinsFactory.ExtensionConfig[](1);
        uint256 s = SUPPLY * 1000 / 10_000;
        ecs[0] = _airdropCfg(address(air), 1000, _leaf(alice, s), admin, 0); // alice gets 100%
        token.approve(address(air), s);
        air.receiveTokens(_dc(ecs), pk, address(token), s, 0);

        // alice has not claimed within the first day (or her tx is pending).
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(admin);
        air.updateMerkleRoot(address(token), _leaf(admin, s));
        vm.prank(admin);
        air.claim(address(token), admin, s, new bytes32[](0));
        assertEq(token.balanceOf(admin), s, "admin took the whole airdrop");

        vm.expectRevert();
        air.claim(address(token), alice, s, new bytes32[](0));
    }

    // ─── A3: zero admin accepted, unclaimed remainder unrecoverable ────

    function test_bug_A3_airdrop_zeroAdminLocksUnclaimedForever() public {
        ArtCoinsAirdrop air = new ArtCoinsAirdrop(address(this));
        IArtCoinsFactory.ExtensionConfig[] memory ecs = new IArtCoinsFactory.ExtensionConfig[](1);
        uint256 s = SUPPLY / 10;
        ecs[0] = _airdropCfg(address(air), 1000, _leaf(alice, 1e18), address(0), 0);
        token.approve(address(air), s);
        air.receiveTokens(_dc(ecs), pk, address(token), s, 0);
        air.claim(address(token), alice, 1e18, new bytes32[](0));

        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(IArtCoinsAirdrop.Unauthorized.selector);
        air.adminClaim(address(token), address(this));
        assertEq(token.balanceOf(address(air)), s - 1e18, "remainder stuck");
    }

    // ─── V1: vault admin can be set to zero, bricking all claims ───────

    function test_bug_V1_vault_zeroAdminBricksClaims() public {
        ArtCoinsVault v = new ArtCoinsVault(address(this));
        IArtCoinsFactory.ExtensionConfig[] memory ecs = new IArtCoinsFactory.ExtensionConfig[](1);
        ecs[0] = IArtCoinsFactory.ExtensionConfig({
            extension: address(v),
            msgValue: 0,
            extensionBps: 1000,
            extensionData: abi.encode(
                IArtCoinsVault.VaultExtensionData({
                    admin: admin, lockupDuration: 7 days, vestingDuration: 90 days
                })
            )
        });
        uint256 s = SUPPLY / 10;
        token.approve(address(v), s);
        v.receiveTokens(_dc(ecs), pk, address(token), s, 0);

        vm.prank(admin);
        v.editAllocationAdmin(address(token), address(0)); // no zero check
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(); // ERC20InvalidReceiver(0)
        v.claim(address(token));
        vm.prank(admin);
        vm.expectRevert(IArtCoinsVault.Unauthorized.selector);
        v.editAllocationAdmin(address(token), admin);
        assertEq(token.balanceOf(address(v)), s, "allocation stuck forever");
    }

    // ─── claim that holds: vault vesting math ──────────────────────────

    function testFuzz_holds_vaultVestingMonotoneAndComplete(uint256 t1, uint256 t2) public {
        ArtCoinsVault v = new ArtCoinsVault(address(this));
        IArtCoinsFactory.ExtensionConfig[] memory ecs = new IArtCoinsFactory.ExtensionConfig[](1);
        ecs[0] = IArtCoinsFactory.ExtensionConfig({
            extension: address(v),
            msgValue: 0,
            extensionBps: 1,
            extensionData: abi.encode(
                IArtCoinsVault.VaultExtensionData({
                    admin: admin, lockupDuration: 7 days, vestingDuration: 90 days
                })
            )
        });
        uint256 s = 123_456_789_123_456_789_123; // odd amount to exercise rounding
        token.approve(address(v), s);
        v.receiveTokens(_dc(ecs), pk, address(token), s, 0);
        uint256 start = block.timestamp;
        t1 = bound(t1, 0, 200 days);
        t2 = bound(t2, t1, 200 days);

        vm.warp(start + t1);
        if (t1 < 7 days) {
            assertEq(v.amountAvailableToClaim(address(token)), 0, "unlocked before cliff");
        } else if (v.amountAvailableToClaim(address(token)) > 0) {
            v.claim(address(token));
        }
        vm.warp(start + t2);
        if (v.amountAvailableToClaim(address(token)) > 0) v.claim(address(token));
        assertLe(token.balanceOf(admin), s);
        vm.warp(start + 97 days);
        if (v.amountAvailableToClaim(address(token)) > 0) v.claim(address(token));
        assertEq(token.balanceOf(admin), s, "not fully vested at end");
    }

    // ─── claim that holds: receiveTokens is factory-only everywhere ────

    function test_holds_receiveTokensOnlyFactory() public {
        IArtCoinsFactory.DeploymentConfig memory dc;
        address[4] memory exts = [
            address(new ArtCoinsAirdrop(address(0xFAC))),
            address(new ArtCoinsVault(address(0xFAC))),
            address(new ArtCoinsUniv4EthDevBuy(address(0xFAC), address(1), address(2), address(3))),
            address(new BurnExtension(address(0xFAC)))
        ];
        for (uint256 i = 0; i < exts.length; i++) {
            vm.expectRevert();
            ArtCoinsVault(exts[i]).receiveTokens(dc, pk, address(token), 1, 0);
        }
    }

    // ─── LL1: auto-forward extension on a native-ETH pool always reverts ──

    function test_bug_LL1_autoForward_nativeEthPoolRevertsEverySwap() public {
        address hook = address(0xB00C);
        LiquidityLayerAutoForwardExtension ext = new LiquidityLayerAutoForwardExtension(
            hook, address(0x10C), address(0xFEE), address(0xBFC), address(0xB0B), address(this)
        );
        PoolKey memory nativePk = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 0x800000,
            tickSpacing: 200,
            hooks: IHooks(hook)
        });
        vm.startPrank(hook);
        ext.initializePreLockerSetup(nativePk, false, "");
        IPoolManager.SwapParams memory sp = IPoolManager.SwapParams({
            zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0
        });
        // pipeline does IERC20(address(0)).balanceOf(pfc) outside any try:
        // the whole afterSwap reverts, rolling back the counter write too.
        vm.expectRevert();
        ext.afterSwap(nativePk, sp, BalanceDelta.wrap(0), false, "");
        vm.stopPrank();
        assertEq(ext.totalTrades(nativePk.toId()), 0, "counter never advances");
    }
}
