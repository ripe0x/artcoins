// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// independent review of the v2 factory launch flow (docs/v2/review/v2-review-factory.md).
// forks mainnet at the harness pin and deploys the real v2 stack the same way
// test/v2/FactoryV2.fork.t.sol does. after the fixes (D52, D53) `test_V2F01_*`
// is a regression that passes by asserting the fix; `test_V2F03_*` still
// passes by showing the accepted outcome (D54); `test_holds_*` pin claims that
// hold. skips cleanly without an rpc.

import {console2} from "forge-std/Test.sol";

import {Constants} from "../../../../src/Constants.sol";
import {
    ArtCoinsPoolExtensionAllowlist
} from "../../../../src/hooks/ArtCoinsPoolExtensionAllowlist.sol";
import {ArtCoinsFactoryV2} from "../../../../src/v2/ArtCoinsFactoryV2.sol";
import {ArtCoinsFeeEscrowV2} from "../../../../src/v2/ArtCoinsFeeEscrowV2.sol";
import {ArtCoinsTokenV2} from "../../../../src/v2/ArtCoinsTokenV2.sol";
import {ArtCoinsUniv4EthDevBuyV2} from "../../../../src/v2/extensions/ArtCoinsUniv4EthDevBuyV2.sol";
import {ArtCoinsVaultV2} from "../../../../src/v2/extensions/ArtCoinsVaultV2.sol";
import {ArtCoinsHookV2} from "../../../../src/v2/hooks/ArtCoinsHookV2.sol";
import {IArtCoinsFactoryV2} from "../../../../src/v2/interfaces/IArtCoinsFactoryV2.sol";
import {IArtCoinsTokenV2} from "../../../../src/v2/interfaces/IArtCoinsTokenV2.sol";
import {ArtCoinsLpLockerV2} from "../../../../src/v2/lp-lockers/ArtCoinsLpLockerV2.sol";
import {ArtCoinsMevLinearSkimV2} from "../../../../src/v2/mev-modules/ArtCoinsMevLinearSkimV2.sol";
import {ArtCoinsDeployerV2} from "../../../../src/v2/utils/ArtCoinsDeployerV2.sol";
import {ForkBase} from "../../harness/ForkBase.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

struct V2FPoolSwapData {
    bytes mevModuleSwapData;
    bytes poolExtensionSwapData;
}

contract V2FDummy {}

contract V2FFactoryReviewTest is ForkBase {
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );
    int24 internal constant START = -200_000;
    int24 internal constant TS = 200;
    uint16 internal constant PROTOCOL_BPS = 2000;
    uint256 internal constant FEE = 0.01 ether;
    /// EIP-7825 (fusaka) per transaction gas cap on mainnet.
    uint256 internal constant TX_GAS_CAP = 16_777_216;

    ArtCoinsFactoryV2 internal factory;
    ArtCoinsDeployerV2 internal deployer;
    ArtCoinsFeeEscrowV2 internal escrow;
    ArtCoinsHookV2 internal hook;
    ArtCoinsLpLockerV2 internal locker;
    ArtCoinsMevLinearSkimV2 internal mev;
    ArtCoinsVaultV2 internal vault;
    ArtCoinsUniv4EthDevBuyV2 internal devBuy;

    address payable internal protocolR = payable(makeAddr("v2f.protocolRecipient"));
    address internal team = makeAddr("v2f.team");
    address internal alice = makeAddr("v2f.alice");
    address internal admin = makeAddr("v2f.tokenAdmin");
    address internal project = makeAddr("v2f.project");
    address internal referrerEoa = makeAddr("v2f.referrer");
    address payable internal bounty = payable(makeAddr("v2f.bounty"));

    function setUp() public {
        forkMainnet();
        if (!onFork) return;
        require(
            alice.code.length == 0 && protocolR.code.length == 0 && bounty.code.length == 0
                && referrerEoa.code.length == 0,
            "actor has code"
        );
        vm.deal(alice, 100 ether);

        factory = new ArtCoinsFactoryV2(address(this), POOL_MANAGER, PROTOCOL_BPS, FEE);
        deployer = new ArtCoinsDeployerV2(address(factory));
        factory.setTokenDeployer(address(deployer));

        escrow = new ArtCoinsFeeEscrowV2(address(this));
        ArtCoinsPoolExtensionAllowlist allowlist = new ArtCoinsPoolExtensionAllowlist(address(this));
        bytes memory args =
            abi.encode(POOL_MANAGER, address(this), address(escrow), address(allowlist));
        (address at, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(ArtCoinsHookV2).creationCode, args);
        hook = new ArtCoinsHookV2{salt: salt}(
            IPoolManager(POOL_MANAGER), address(this), address(escrow), address(allowlist)
        );
        require(address(hook) == at, "miner mismatch");
        locker = new ArtCoinsLpLockerV2(address(this), POSITION_MANAGER, PERMIT2, address(escrow));
        escrow.addDepositor(address(hook), true);
        escrow.addDepositor(address(locker), true);
        locker.setLauncher(address(factory), true);
        mev = new ArtCoinsMevLinearSkimV2(address(hook));
        vault = new ArtCoinsVaultV2(address(factory));
        devBuy = new ArtCoinsUniv4EthDevBuyV2(address(factory), POOL_MANAGER);

        hook.setLauncher(address(factory), true);
        factory.setHook(address(hook), true);
        factory.setLocker(address(locker), true);
        factory.setMevModule(address(mev), true);
        factory.setExtension(address(vault), true);
        factory.setExtension(address(devBuy), true);
        factory.setProtocolRecipient(protocolR);
        factory.setTeamFeeRecipient(team);
        factory.setDeprecated(false);
    }

    // ── builders ──────────────────────────────────────────────────────────

    function _cfg() internal view returns (IArtCoinsFactoryV2.DeploymentConfigV2 memory c) {
        c.token.tokenAdmin = admin;
        c.token.name = "Factory Review";
        c.token.symbol = "V2F";
        c.token.salt = bytes32(uint256(7));
        c.token.image = "ipfs://image";
        c.token.description = "{}";

        c.pool.hook = address(hook);
        c.pool.tickIfToken0IsCoin = START;
        c.pool.tickSpacing = TS;

        c.fee = IArtCoinsFactoryV2.FeeConfigV2({
            lpFeePips: 5000, baselineSkimBps: 600, bountyBps: 8333, bountyRecipient: bounty
        });

        c.locker.locker = address(locker);
        c.locker.rewardRecipients = new address[](1);
        c.locker.rewardRecipients[0] = project;
        c.locker.rewardBps = new uint16[](1);
        c.locker.rewardBps[0] = 10_000 - PROTOCOL_BPS;
        c.locker.tickLower = new int24[](2);
        c.locker.tickUpper = new int24[](2);
        c.locker.positionBps = new uint16[](2);
        c.locker.tickLower[0] = START;
        c.locker.tickUpper[0] = -120_000;
        c.locker.positionBps[0] = 6000;
        c.locker.tickLower[1] = -160_000;
        c.locker.tickUpper[1] = -100_000;
        c.locker.positionBps[1] = 4000;

        c.mev = IArtCoinsFactoryV2.MevConfigV2({
            module: address(mev),
            startingSkimBps: Constants.DEFAULT_START_SKIM_BPS,
            windowSeconds: Constants.DEFAULT_MEV_WINDOW
        });
    }

    function _key(address token) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TS,
            hooks: IHooks(address(hook))
        });
    }

    function _filled(uint256 n) internal pure returns (string memory) {
        bytes memory b = new bytes(n);
        for (uint256 i; i < n; ++i) {
            b[i] = "a";
        }
        return string(b);
    }

    // ══════════════════════════════════════════════════════════════════════
    // gas: typical and maximum configs vs EIP-7825
    // ══════════════════════════════════════════════════════════════════════

    function _intrinsic(bytes memory data) internal pure returns (uint256 std, uint256 floor) {
        uint256 z;
        uint256 nz;
        for (uint256 i; i < data.length; ++i) {
            if (data[i] == 0) ++z;
            else ++nz;
        }
        std = 21_000 + 4 * z + 16 * nz;
        floor = 21_000 + 10 * (z + 4 * nz); // EIP-7623
    }

    function _measure(
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c,
        uint256 value,
        string memory tag
    ) internal returns (address token, uint256 total) {
        bytes memory data = abi.encodeCall(IArtCoinsFactoryV2.deployToken, (c));
        (uint256 std, uint256 floor) = _intrinsic(data);
        vm.prank(alice);
        uint256 g = gasleft();
        token = factory.deployToken{value: value}(c);
        uint256 exec = g - gasleft();
        total = exec + std;
        if (floor > total) total = floor;
        console2.log(tag);
        console2.log("  calldata bytes", data.length);
        console2.log("  execution gas", exec);
        console2.log("  tx gas (exec + intrinsic)", total);
    }

    function test_gas_typicalLaunch() public onlyFork {
        (, uint256 total) = _measure(_cfg(), FEE, "typical: 2 positions, mev, no tax, no ext");
        assertLt(total, TX_GAS_CAP);
    }

    /// every cap at its maximum: strings at D30 caps, 7 reward slots, 14
    /// positions, VENUE with 16 exempt and 32 venues, 10 extensions (9 vaults
    /// plus a dev buy). reports whether the factory accepts a config that no
    /// mainnet transaction can carry.
    function _maxCfg(bool strings, bool slots, bool tax, bool ext)
        internal
        returns (IArtCoinsFactoryV2.DeploymentConfigV2 memory c, uint256 value)
    {
        c = _cfg();
        value = FEE;
        if (strings) {
            c.token.name = _filled(64);
            c.token.symbol = _filled(16);
            c.token.image = _filled(2048);
            c.token.description = _filled(4096);
        }
        if (slots) {
            c.locker.rewardRecipients = new address[](6);
            c.locker.rewardBps = new uint16[](6);
            for (uint256 i; i < 6; ++i) {
                c.locker.rewardRecipients[i] = address(uint160(0xbeef0 + i));
                c.locker.rewardBps[i] = i == 5 ? 1335 : 1333;
            }
            c.locker.tickLower = new int24[](14);
            c.locker.tickUpper = new int24[](14);
            c.locker.positionBps = new uint16[](14);
            for (uint256 i; i < 14; ++i) {
                // forge-lint: disable-next-line(unsafe-typecast)
                int24 lo = START + int24(int256(i)) * 2000;
                c.locker.tickLower[i] = lo;
                c.locker.tickUpper[i] = lo + 40_000;
                c.locker.positionBps[i] = i == 13 ? 718 : 714;
            }
        }
        if (tax) {
            // a restricted coin with a large allowlist (the assembled set the
            // factory seeds on top stays under Constants.MAX_ALLOWED).
            c.restriction.restricted = true;
            c.restriction.allowed = new address[](20);
            for (uint256 i; i < c.restriction.allowed.length; ++i) {
                c.restriction.allowed[i] = address(uint160(0xc0ffee00 + i));
            }
        }
        if (ext) {
            c.extensions = new IArtCoinsFactoryV2.ExtensionConfigV2[](Constants.MAX_EXTENSIONS);
            for (uint256 i; i < 9; ++i) {
                c.extensions[i] = IArtCoinsFactoryV2.ExtensionConfigV2({
                    extension: address(vault),
                    msgValue: 0,
                    extensionBps: 1000,
                    extensionData: abi.encode(
                        address(uint160(0xa11ce0 + i)), uint256(7 days), uint256(90 days)
                    )
                });
            }
            c.extensions[9] = IArtCoinsFactoryV2.ExtensionConfigV2({
                extension: address(devBuy),
                msgValue: 1 ether,
                extensionBps: 0,
                extensionData: abi.encode(alice, alice, uint128(1))
            });
            value += 1 ether;
        }
    }

    /// V2F-03 / D54 under D73: every cap at its maximum (strings at D30 caps, 7
    /// reward slots, 14 positions, a restricted coin with 20 allowlist entries,
    /// 10 extensions: 9 vaults plus a dev buy). Retiring the tax config made the
    /// heaviest launch cheaper than the old VENUE 16 exempt + 32 venues config,
    /// so it now fits under the EIP-7825 per tx gas cap; the D54 residual is
    /// resolved for the shapes the config can express.
    function test_V2F03_maxConfigLaunch_underTxGasCap() public onlyFork {
        (IArtCoinsFactoryV2.DeploymentConfigV2 memory c, uint256 v) =
            _maxCfg(true, true, true, true);
        console2.log("token creationCode bytes", type(ArtCoinsTokenV2).creationCode.length);
        (address token, uint256 total) = _measure(c, v, "max: every cap at its limit");
        assertTrue(factory.isCoin(token));
        assertLt(total, TX_GAS_CAP, "the heaviest launch fits under the EIP-7825 cap");
    }

    function test_gas_breakdown() public onlyFork {
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c;
        uint256 v;
        (c, v) = _maxCfg(true, false, false, false);
        c.token.salt = bytes32(uint256(101));
        _measure(c, v, "strings at caps only");
        (c, v) = _maxCfg(false, true, false, false);
        c.token.salt = bytes32(uint256(102));
        _measure(c, v, "7 slots + 14 positions only");
        (c, v) = _maxCfg(false, false, true, false);
        c.token.salt = bytes32(uint256(103));
        _measure(c, v, "restricted + 20 allowlist entries only");
        (c, v) = _maxCfg(false, false, false, true);
        c.token.salt = bytes32(uint256(104));
        _measure(c, v, "10 extensions (9 vaults + dev buy) only");
        (c, v) = _maxCfg(true, true, true, false);
        c.token.salt = bytes32(uint256(105));
        _measure(c, v, "all caps except extensions");
    }

    // ══════════════════════════════════════════════════════════════════════
    // claims that hold
    // ══════════════════════════════════════════════════════════════════════

    /// Restricted coin with a dev buy in the launch tx, then a public buy and
    /// sell through the canonical pool. A direct transfer to the PoolManager
    /// with no granted allowance still reverts, so restriction is live.
    function test_holds_restrictedCoinLaunchesWithDevBuyAndTrades() public onlyFork {
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _cfg();
        c.restriction.restricted = true;
        c.extensions = new IArtCoinsFactoryV2.ExtensionConfigV2[](1);
        c.extensions[0] = IArtCoinsFactoryV2.ExtensionConfigV2({
            extension: address(devBuy),
            msgValue: 0.5 ether,
            extensionBps: 0,
            extensionData: abi.encode(alice, alice, uint128(1))
        });
        vm.prank(alice);
        address token = factory.deployToken{value: FEE + 0.5 ether}(c);
        IERC20 coin = IERC20(token);
        assertTrue(IArtCoinsTokenV2(token).restricted());
        uint256 devOut = coin.balanceOf(alice);
        assertGt(devOut, 0, "dev buy delivered");
        assertEq(coin.balanceOf(address(factory)), 0);
        assertEq(address(factory).balance, 0);

        PoolKey memory key = _key(token);
        (, uint256 bought) = swapExactIn(key, true, 0.2 ether, address(this), "");
        assertGt(bought, 0, "buy");
        uint256 eth0 = address(this).balance;
        swapExactIn(key, false, bought / 2, address(this), "");
        assertGt(address(this).balance, eth0, "sell");

        vm.prank(alice);
        vm.expectRevert();
        coin.transfer(POOL_MANAGER, 1);
    }
}
