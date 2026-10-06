// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// f1 factory suite. forks mainnet at the harness pin and deploys the real v2
// stack (escrow, hook mined against the live PoolManager, locker on the live
// PositionManager, linear skim module, factory). tests that need no pool run
// without a fork; the rest skip cleanly when the rpc is unreachable.

import {Vm} from "forge-std/Vm.sol";

import {Constants} from "../../src/Constants.sol";
import {ArtCoinsPoolExtensionAllowlist} from "../../src/hooks/ArtCoinsPoolExtensionAllowlist.sol";
import {ArtCoinsFactoryV2} from "../../src/v2/ArtCoinsFactoryV2.sol";
import {ArtCoinsFeeEscrowV2} from "../../src/v2/ArtCoinsFeeEscrowV2.sol";
import {ArtCoinsTokenV2} from "../../src/v2/ArtCoinsTokenV2.sol";
import {ArtCoinsDeployerV2} from "../../src/v2/utils/ArtCoinsDeployerV2.sol";
import {ArtCoinsHookV2} from "../../src/v2/hooks/ArtCoinsHookV2.sol";
import {IArtCoinsFactoryV2} from "../../src/v2/interfaces/IArtCoinsFactoryV2.sol";
import {IArtCoinsHookV2} from "../../src/v2/interfaces/IArtCoinsHookV2.sol";
import {IArtCoinsLpLockerV2} from "../../src/v2/interfaces/IArtCoinsLpLockerV2.sol";
import {IArtCoinsTokenV2} from "../../src/v2/interfaces/IArtCoinsTokenV2.sol";
import {IConstantsBound} from "../../src/v2/interfaces/IConstantsBound.sol";
import {ArtCoinsLpLockerV2} from "../../src/v2/lp-lockers/ArtCoinsLpLockerV2.sol";
import {ArtCoinsMevLinearSkimV2} from "../../src/v2/mev-modules/ArtCoinsMevLinearSkimV2.sol";
import {ForkBase} from "./harness/ForkBase.sol";
import {
    FV2Extension,
    FV2HashStub,
    FV2NoErc165Module,
    FV2Payout,
    FV2RevertingReceiver,
    FV2ToggleModule,
    FV2WrongHashModule
} from "./mocks/FactoryV2Mocks.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

contract FactoryV2ForkTest is ForkBase {
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );
    int24 internal constant START = -200_000;
    int24 internal constant TS = 200;
    uint16 internal constant PROTOCOL_BPS = 2000;
    uint256 internal constant FEE = 0.01 ether;

    bytes32 internal immutable TOKEN_CREATED_SIG = IArtCoinsFactoryV2.TokenCreatedV2.selector;

    ArtCoinsFactoryV2 internal factory;
    ArtCoinsDeployerV2 internal deployer;
    ArtCoinsFeeEscrowV2 internal escrow;
    ArtCoinsHookV2 internal hook;
    /// @dev the locker launches go through (stub by default, see setUp).
    address internal locker;
    ArtCoinsLpLockerV2 internal realLocker;
    ArtCoinsMevLinearSkimV2 internal mev;
    FV2Payout internal payout;

    address payable internal protocolR = payable(makeAddr("fv2.protocolRecipient"));
    address internal team = makeAddr("fv2.team");
    address internal alice = makeAddr("fv2.alice");
    address internal mallory = makeAddr("fv2.mallory");
    address internal admin = makeAddr("fv2.tokenAdmin");
    address internal project = makeAddr("fv2.project");
    address payable internal bounty = payable(makeAddr("fv2.bounty"));

    function setUp() public {
        forkMainnet();
        factory = new ArtCoinsFactoryV2(address(this), POOL_MANAGER, PROTOCOL_BPS, FEE);
        // D38: deployer is its own contract, bound to the factory at construction
        deployer = new ArtCoinsDeployerV2(address(factory));
        factory.setTokenDeployer(address(deployer));
        // plain makeAddr labels can collide with live mainnet contracts
        // ("alice" has code at the pin): every actor here must be an eoa.
        require(
            alice.code.length == 0 && mallory.code.length == 0 && team.code.length == 0,
            "actor has code"
        );
        vm.deal(alice, 100 ether);
        vm.deal(mallory, 100 ether);
        if (!onFork) return;

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
        realLocker =
            new ArtCoinsLpLockerV2(address(this), POSITION_MANAGER, PERMIT2, address(escrow));
        escrow.addDepositor(address(hook), true);
        escrow.addDepositor(address(realLocker), true);
        realLocker.setLauncher(address(factory), true);
        factory.setLocker(address(realLocker), true);
        // real locker (D37 skips the erc20 approve to permit2 for solady tokens)
        locker = address(realLocker);
        mev = new ArtCoinsMevLinearSkimV2(address(hook));
        payout = new FV2Payout();

        hook.setLauncher(address(factory), true);
        // D46: the launch placement adds on a taxed canonical pool; the deploy
        // script registers the locker as a hook launcher.
        hook.setLauncher(locker, true);
        require(hook.isLauncher(locker), "D46: locker must be a hook launcher");

        factory.setHook(address(hook), true);
        factory.setLocker(locker, true);
        factory.setMevModule(address(mev), true);
        factory.setEscrow(address(escrow), true);
        factory.setProtocolRecipient(protocolR);
        factory.setReferralPayout(payable(address(payout)));
        factory.setTeamFeeRecipient(team);
        factory.setDeprecated(false);
    }

    // ── config builders ───────────────────────────────────────────────────

    function _cfg() internal view returns (IArtCoinsFactoryV2.DeploymentConfigV2 memory c) {
        c.token.tokenAdmin = admin;
        c.token.name = "Factory V2 Test";
        c.token.symbol = "FV2";
        c.token.salt = bytes32(uint256(1));
        c.token.image = "ipfs://image";
        c.token.metadata = "{}";
        c.token.context = "f1";

        c.pool.hook = address(hook);
        c.pool.tickIfToken0IsArtCoin = START;
        c.pool.tickSpacing = TS;

        c.fee = IArtCoinsFactoryV2.FeeConfigV2({
            lpFee: 5000,
            baselineSkimBps: 6000,
            bountyBps: 8333,
            maxReferralBpsOfVolume: 250,
            bountyRecipient: bounty
        });

        c.locker.locker = locker;
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
        // tax none, no extensions
    }

    function _ext(address e, uint256 value, uint16 bps)
        internal
        pure
        returns (IArtCoinsFactoryV2.ExtensionConfigV2 memory)
    {
        return IArtCoinsFactoryV2.ExtensionConfigV2({
            extension: e, msgValue: value, extensionBps: bps, extensionData: ""
        });
    }

    function _deploy(address from, IArtCoinsFactoryV2.DeploymentConfigV2 memory c)
        internal
        returns (address)
    {
        vm.prank(from);
        return factory.deployToken{value: FEE}(c);
    }

    function _expectRevertDeploy(IArtCoinsFactoryV2.DeploymentConfigV2 memory c, bytes memory err)
        internal
    {
        vm.prank(alice);
        vm.expectRevert(err);
        factory.deployToken{value: FEE}(c);
    }

    function _newExt() internal returns (FV2Extension e) {
        e = new FV2Extension();
        factory.setExtension(address(e), true);
    }

    // ══════════════════════════════════════════════════════════════════════
    // b4: launch hijack
    // ══════════════════════════════════════════════════════════════════════

    function test_launch_predictTokenMatches() public onlyFork {
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _cfg();
        address predicted = factory.predictToken(alice, c);
        assertEq(predicted.code.length, 0, "not yet deployed");
        address token = _deploy(alice, c);
        assertEq(token, predicted, "predict");
        assertTrue(factory.isArtCoin(token), "isArtCoin");
        assertEq(factory.configHash(c), keccak256(abi.encode(c)), "configHash");

        IArtCoinsFactoryV2.DeploymentInfoV2 memory info = factory.deploymentInfo(token);
        assertEq(info.token, token);
        assertEq(info.hook, address(hook));
        assertEq(info.locker, locker);
        assertEq(info.mevModule, address(mev));
        assertEq(PoolId.unwrap(info.poolId), ArtCoinsTokenV2(token).canonicalPoolId());
        assertEq(info.launchedAt, block.timestamp);
        assertEq(info.extensions.length, 0);

        // the factory holds nothing after a launch
        assertEq(IERC20(token).balanceOf(address(factory)), 0, "factory coin");
        assertEq(address(factory).balance, 0, "factory eth");
        // a redeploy of the same (sender, config) collides
        vm.prank(alice);
        vm.expectRevert();
        factory.deployToken{value: FEE}(c);
        // unknown token
        vm.expectRevert(IArtCoinsFactoryV2.NotFound.selector);
        factory.deploymentInfo(address(0xBEEF));
    }

    function test_launch_frontrunCopiedConfig_differentAddress() public onlyFork {
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _cfg();
        address victimPredicted = factory.predictToken(alice, c);

        // mallory copies the exact config from the mempool and lands first
        address m = _deploy(mallory, c);
        assertTrue(m != victimPredicted, "copied config, other sender: other address");
        assertEq(m, factory.predictToken(mallory, c));

        // mallory also tries the hijack shape: same token config, her own split
        IArtCoinsFactoryV2.DeploymentConfigV2 memory h = _cfg();
        h.locker.rewardRecipients[0] = mallory;
        h.token.salt = bytes32(uint256(2));
        address m2 = _deploy(mallory, h);
        assertTrue(m2 != victimPredicted);

        // the victim's launch is neither blocked nor captured
        address v = _deploy(alice, c);
        assertEq(v, victimPredicted, "victim lands at its predicted address");
        assertEq(IArtCoinsLpLockerV2(locker).rewardRecipients(v)[0], project);
        assertEq(ArtCoinsTokenV2(v).admin(), admin);
    }

    function test_launch_changedLockerConfig_differentAddress() public onlyFork {
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _cfg();
        IArtCoinsFactoryV2.DeploymentConfigV2 memory d = _cfg();
        d.locker.rewardRecipients[0] = mallory;
        assertTrue(factory.configHash(c) != factory.configHash(d), "hash binds the split");
        assertTrue(factory.predictToken(alice, c) != factory.predictToken(alice, d));

        // every other non token section also moves the address
        IArtCoinsFactoryV2.DeploymentConfigV2 memory e = _cfg();
        e.locker.positionBps[0] = 5000;
        e.locker.positionBps[1] = 5000;
        assertTrue(factory.predictToken(alice, c) != factory.predictToken(alice, e), "positions");
        e = _cfg();
        e.mev.windowSeconds = 60 minutes;
        assertTrue(factory.predictToken(alice, c) != factory.predictToken(alice, e), "mev");
        e = _cfg();
        e.fee.bountyBps = 1;
        assertTrue(factory.predictToken(alice, c) != factory.predictToken(alice, e), "fee");
        e = _cfg();
        e.pool.tickIfToken0IsArtCoin = START + TS;
        assertTrue(factory.predictToken(alice, c) != factory.predictToken(alice, e), "pool");

        address a = _deploy(alice, d);
        assertEq(a, factory.predictToken(alice, d));
        assertTrue(a != factory.predictToken(alice, c));
    }

    // ══════════════════════════════════════════════════════════════════════
    // d4: tax sink, d5: constants, d6: version tag
    // ══════════════════════════════════════════════════════════════════════

    function test_factoryV2_taxSinkOutsideAllowedSet_reverts() public onlyFork {
        address outsider = makeAddr("fv2.outsider");
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _cfg();
        c.tax.mode = Constants.TAX_MODE_VENUE;
        c.tax.taxBps = 1000;
        c.tax.taxBpsMax = 2000;
        c.tax.taxSink = outsider;
        _expectRevertDeploy(
            c, abi.encodeWithSelector(IArtCoinsFactoryV2.TaxSinkNotAllowed.selector, outsider)
        );
        c.tax.taxSink = address(0);
        _expectRevertDeploy(
            c, abi.encodeWithSelector(IArtCoinsFactoryV2.TaxSinkNotAllowed.selector, address(0))
        );

        // hard mode: sink is display only but still limited
        IArtCoinsFactoryV2.DeploymentConfigV2 memory hd = _cfg();
        hd.tax.mode = Constants.TAX_MODE_HARD;
        hd.tax.taxSink = outsider;
        _expectRevertDeploy(
            hd, abi.encodeWithSelector(IArtCoinsFactoryV2.TaxSinkNotAllowed.selector, outsider)
        );

        // none mode carries no tax data at all
        IArtCoinsFactoryV2.DeploymentConfigV2 memory n = _cfg();
        n.tax.taxSink = Constants.DEAD;
        _expectRevertDeploy(n, abi.encodeWithSelector(IArtCoinsFactoryV2.InvalidTaxConfig.selector));

        // caps
        c.tax.taxSink = Constants.DEAD;
        c.tax.taxBpsMax = Constants.TAX_BPS_ABSOLUTE_MAX + 1;
        _expectRevertDeploy(c, abi.encodeWithSelector(IArtCoinsFactoryV2.InvalidTaxConfig.selector));
        c.tax.taxBpsMax = 2000;
        c.tax.exempt = new address[](Constants.MAX_TAX_EXEMPT + 1);
        for (uint256 i; i < c.tax.exempt.length; ++i) {
            c.tax.exempt[i] = address(uint160(0x1000 + i));
        }
        _expectRevertDeploy(c, abi.encodeWithSelector(IArtCoinsFactoryV2.InvalidTaxConfig.selector));
        // FT-07: an eoa cannot be exempted, even if the owner lists it (defense in depth)
        c.tax.exempt = new address[](1);
        c.tax.exempt[0] = makeAddr("fv2.exemptEoa");
        factory.setExemptAllowed(c.tax.exempt[0], true);
        _expectRevertDeploy(c, abi.encodeWithSelector(IArtCoinsFactoryV2.InvalidTaxConfig.selector));
        c.tax.exempt = new address[](0);
        c.tax.venues = new IArtCoinsFactoryV2.TaxVenue[](Constants.MAX_TAX_VENUES + 1);
        _expectRevertDeploy(c, abi.encodeWithSelector(IArtCoinsFactoryV2.InvalidTaxConfig.selector));
        c.tax.venues = new IArtCoinsFactoryV2.TaxVenue[](0);

        // allowed: DEAD, and the pool's bounty recipient
        address t1 = _deploy(alice, c);
        assertEq(ArtCoinsTokenV2(t1).taxSink(), Constants.DEAD);
        assertEq(ArtCoinsTokenV2(t1).taxMode(), Constants.TAX_MODE_VENUE);
        c.tax.taxSink = bounty;
        address t2 = _deploy(alice, c);
        assertEq(ArtCoinsTokenV2(t2).taxSink(), bounty);
        // FT-06: the token's canonical pool is the pool the factory created
        assertEq(
            ArtCoinsTokenV2(t2).canonicalPoolId(), PoolId.unwrap(factory.deploymentInfo(t2).poolId)
        );
        assertEq(ArtCoinsTokenV2(t2).canonicalHook(), address(hook));
        assertEq(hook.poolInfo(factory.deploymentInfo(t2).poolId).taxMode, Constants.TAX_MODE_VENUE);

        hd.tax.taxSink = address(0);
        address t3 = _deploy(alice, hd);
        assertEq(ArtCoinsTokenV2(t3).taxMode(), Constants.TAX_MODE_HARD);
    }

    /// needs no fork: the wiring setters run before any pool exists.
    function test_constants_mismatchedModule_rejected() public {
        address h = address(hook) == address(0) ? address(0x1234) : address(hook);
        FV2WrongHashModule wrong = new FV2WrongHashModule(h);
        vm.expectRevert(
            abi.encodeWithSelector(IConstantsBound.ConstantsMismatch.selector, address(wrong))
        );
        factory.setMevModule(address(wrong), true);

        // a v1 shaped module (no erc165) is refused even with the right hash (D22)
        FV2NoErc165Module v1ish = new FV2NoErc165Module();
        vm.expectRevert(
            abi.encodeWithSelector(IArtCoinsFactoryV2.InvalidMevModule.selector, address(v1ish))
        );
        factory.setMevModule(address(v1ish), true);

        FV2HashStub badHash = new FV2HashStub(keccak256("other"), POOL_MANAGER);
        vm.expectRevert(
            abi.encodeWithSelector(IConstantsBound.ConstantsMismatch.selector, address(badHash))
        );
        factory.setHook(address(badHash), true);
        vm.expectRevert(
            abi.encodeWithSelector(IConstantsBound.ConstantsMismatch.selector, address(badHash))
        );
        factory.setLocker(address(badHash), true);
        vm.expectRevert(
            abi.encodeWithSelector(IConstantsBound.ConstantsMismatch.selector, address(badHash))
        );
        factory.setEscrow(address(badHash), true);

        // no code at all is a mismatch, not a raw revert
        address eoa = makeAddr("fv2.eoa");
        vm.expectRevert(abi.encodeWithSelector(IConstantsBound.ConstantsMismatch.selector, eoa));
        factory.setLocker(eoa, true);

        // right hash, other PoolManager
        FV2HashStub otherPm = new FV2HashStub(Constants.hash(), address(0xdead01));
        vm.expectRevert(
            abi.encodeWithSelector(ArtCoinsFactoryV2.PoolManagerMismatch.selector, address(otherPm))
        );
        factory.setHook(address(otherPm), true);

        assertEq(factory.constantsHash(), Constants.hash());
    }

    function test_versionTag_consistentAcrossTokenHookFactory() public onlyFork {
        address token = _deploy(alice, _cfg());
        IArtCoinsFactoryV2.DeploymentInfoV2 memory info = factory.deploymentInfo(token);
        IArtCoinsHookV2.PoolInfo memory p = hook.poolInfo(info.poolId);
        assertEq(Constants.STACK_VERSION, 2);
        assertEq(factory.STACK_VERSION(), Constants.STACK_VERSION, "factory");
        assertEq(info.version, Constants.STACK_VERSION, "deploymentInfo");
        assertEq(ArtCoinsTokenV2(token).launcherVersion(), Constants.STACK_VERSION, "token");
        assertEq(p.version, Constants.STACK_VERSION, "hook pool");
        assertEq(ArtCoinsTokenV2(token).launcher(), address(factory), "token launcher");
        assertEq(p.launcher, address(factory), "hook launcher");
        assertTrue(hook.isOfficialPool(info.poolId));
        assertEq(p.token, token);
        assertEq(p.locker, locker);
        assertEq(p.mevModule, address(mev));
        // injected recipients
        IArtCoinsHookV2.SkimConfig memory s = hook.skimConfig(info.poolId);
        assertEq(s.protocolRecipient, protocolR);
        assertEq(s.referralPayout, address(payout));
        assertEq(s.bountyRecipient, bounty);
        assertEq(s.quoteToken, address(0));
        // the module window started in the launch tx
        assertEq(mev.windowEnd(info.poolId), block.timestamp + Constants.DEFAULT_MEV_WINDOW);
    }

    // ══════════════════════════════════════════════════════════════════════
    // deploy fee, deprecated gate, protocol bps
    // ══════════════════════════════════════════════════════════════════════

    function test_deployFee_exact_paysTeam() public onlyFork {
        uint256 teamBefore = team.balance;
        uint256 aliceBefore = alice.balance;
        vm.expectEmit(true, false, false, true, address(factory));
        emit IArtCoinsFactoryV2.DeployFeePaid(team, FEE);
        _deploy(alice, _cfg());
        assertEq(team.balance - teamBefore, FEE, "team");
        assertEq(aliceBefore - alice.balance, FEE, "alice");
        assertEq(address(factory).balance, 0, "factory eth");
    }

    function test_deployFee_excess_refunded() public onlyFork {
        uint256 teamBefore = team.balance;
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        factory.deployToken{value: FEE + 1.5 ether}(_cfg());
        assertEq(team.balance - teamBefore, FEE, "team gets the fee only");
        assertEq(aliceBefore - alice.balance, FEE, "excess back to sender");
        assertEq(address(factory).balance, 0, "factory eth");
    }

    function test_deployFee_short_reverts() public onlyFork {
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _cfg();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IArtCoinsFactoryV2.MsgValueMismatch.selector, FEE, FEE - 1)
        );
        factory.deployToken{value: FEE - 1}(c);

        // with extension value, the requirement is fee + sum(msgValue)
        FV2Extension e = _newExt();
        c.extensions = new IArtCoinsFactoryV2.ExtensionConfigV2[](1);
        c.extensions[0] = _ext(address(e), 1 ether, 100);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtCoinsFactoryV2.MsgValueMismatch.selector, FEE + 1 ether, FEE + 1 ether - 1
            )
        );
        factory.deployToken{value: FEE + 1 ether - 1}(c);
    }

    function test_deployFee_noTeamRecipient_reverts_andZeroFeeOk() public onlyFork {
        factory.setTeamFeeRecipient(address(0));
        _expectRevertDeploy(
            _cfg(), abi.encodeWithSelector(IArtCoinsFactoryV2.TeamFeeRecipientNotSet.selector)
        );
        factory.setDeployFee(0);
        vm.prank(alice);
        address t = factory.deployToken(_cfg());
        assertTrue(factory.isArtCoin(t));
        // a recipient that refuses eth reverts the launch (the owner picked it)
        factory.setDeployFee(FEE);
        factory.setTeamFeeRecipient(address(new FV2RevertingReceiver()));
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _cfg();
        c.token.salt = bytes32(uint256(9));
        _expectRevertDeploy(
            c, abi.encodeWithSelector(IArtCoinsFactoryV2.EthTransferFailed.selector)
        );
    }

    function test_deprecated_gate_ownerBypasses() public onlyFork {
        factory.setDeprecated(true);
        _expectRevertDeploy(_cfg(), abi.encodeWithSelector(IArtCoinsFactoryV2.Deprecated.selector));
        // owner bypasses, both entries
        address t = factory.deployToken{value: FEE}(_cfg());
        assertTrue(factory.isArtCoin(t));
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _cfg();
        c.token.salt = bytes32(uint256(7));
        address t2 = factory.deployTokenAsOwner{value: FEE}(c, PROTOCOL_BPS);
        assertTrue(factory.isArtCoin(t2));
        factory.setDeprecated(false);
        IArtCoinsFactoryV2.DeploymentConfigV2 memory d = _cfg();
        d.token.salt = bytes32(uint256(8));
        _deploy(alice, d);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.setDeprecated(true);
    }

    function test_protocolBps_ownerOnlyOverride() public onlyFork {
        // public path always appends the default protocol slot
        address t = _deploy(alice, _cfg());
        address[] memory r = IArtCoinsLpLockerV2(locker).rewardRecipients(t);
        uint16[] memory b = IArtCoinsLpLockerV2(locker).rewardBps(t);
        assertEq(r.length, 2);
        assertEq(r[0], project);
        assertEq(b[0], 10_000 - PROTOCOL_BPS);
        assertEq(r[1], protocolR, "protocol slot appended last");
        assertEq(b[1], PROTOCOL_BPS);

        // FT-03: a public caller cannot pick the protocol bps
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _cfg();
        c.locker.rewardBps[0] = 10_000;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.deployTokenAsOwner{value: FEE}(c, 0);
        // and a public caller cannot dodge the slot by claiming the whole split
        _expectRevertDeploy(
            c, abi.encodeWithSelector(IArtCoinsFactoryV2.ProjectSideBpsMismatch.selector)
        );

        // owner with 0: no protocol slot
        address t0 = factory.deployTokenAsOwner{value: FEE}(c, 0);
        r = IArtCoinsLpLockerV2(locker).rewardRecipients(t0);
        assertEq(r.length, 1);
        assertEq(r[0], project);

        // owner above the cap
        vm.expectRevert(IArtCoinsFactoryV2.ProtocolFeeBpsTooHigh.selector);
        factory.deployTokenAsOwner{value: FEE}(c, Constants.MAX_PROTOCOL_FEE_BPS + 1);

        // owner at the cap
        c.locker.rewardBps[0] = 10_000 - Constants.MAX_PROTOCOL_FEE_BPS;
        address t3 = factory.deployTokenAsOwner{value: FEE}(c, Constants.MAX_PROTOCOL_FEE_BPS);
        b = IArtCoinsLpLockerV2(locker).rewardBps(t3);
        assertEq(b[1], Constants.MAX_PROTOCOL_FEE_BPS);

        // the event carries the bps used
        vm.recordLogs();
        c.token.salt = bytes32(uint256(77));
        c.locker.rewardBps[0] = 10_000 - 1234;
        factory.deployTokenAsOwner{value: FEE}(c, 1234);
        (,,,, uint16 usedBps,,,) = _decodeCreated(vm.getRecordedLogs());
        assertEq(usedBps, 1234);
    }

    // ══════════════════════════════════════════════════════════════════════
    // extensions
    // ══════════════════════════════════════════════════════════════════════

    function test_extensions_valueAndSupplyIsolated() public onlyFork {
        FV2Extension e1 = _newExt();
        FV2Extension e2 = _newExt();
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _cfg();
        c.extensions = new IArtCoinsFactoryV2.ExtensionConfigV2[](2);
        c.extensions[0] = _ext(address(e1), 1 ether, 1000);
        c.extensions[1] = _ext(address(e2), 2 ether, 500);
        // stray eth already on the factory is never spent by a deployer
        vm.deal(address(factory), 5 ether);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        address t = factory.deployToken{value: FEE + 3 ether + 0.25 ether}(c);

        assertEq(e1.receivedValue(), 1 ether, "e1 value");
        assertEq(e2.receivedValue(), 2 ether, "e2 value");
        assertEq(address(e1).balance, 1 ether);
        assertEq(address(e2).balance, 2 ether);
        assertEq(e1.expectedValue(), 1 ether);
        uint256 supply = Constants.DEFAULT_TOKEN_SUPPLY;
        assertEq(IERC20(t).balanceOf(address(e1)), supply * 1000 / 10_000, "e1 supply");
        assertEq(IERC20(t).balanceOf(address(e2)), supply * 500 / 10_000, "e2 supply");
        assertEq(aliceBefore - alice.balance, FEE + 3 ether, "alice pays fee + values only");
        assertEq(address(factory).balance, 5 ether, "stray eth untouched");
        assertEq(IERC20(t).balanceOf(address(factory)), 0);
        assertEq(IERC20(t).allowance(address(factory), address(e1)), 0);

        address[] memory exts = factory.deploymentInfo(t).extensions;
        assertEq(exts.length, 2);
        assertEq(exts[0], address(e1));
        assertEq(exts[1], address(e2));

        // the owner can move the stray eth
        factory.rescue(address(0), team, 5 ether);
        assertEq(address(factory).balance, 0);
    }

    function test_extensions_mustPullExactShare() public onlyFork {
        FV2Extension e = _newExt();
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _cfg();
        c.extensions = new IArtCoinsFactoryV2.ExtensionConfigV2[](1);
        c.extensions[0] = _ext(address(e), 0, 1000);
        e.setMode(1);
        _expectRevertDeploy(
            c, abi.encodeWithSelector(ArtCoinsFactoryV2.SupplyNotPulled.selector, address(e))
        );
        e.setMode(2);
        _expectRevertDeploy(
            c, abi.encodeWithSelector(ArtCoinsFactoryV2.SupplyNotPulled.selector, address(e))
        );
    }

    function test_extensions_reentry_blocked() public onlyFork {
        FV2Extension e = _newExt();
        e.setMode(3);
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _cfg();
        c.extensions = new IArtCoinsFactoryV2.ExtensionConfigV2[](1);
        c.extensions[0] = _ext(address(e), 0, 1000);
        _expectRevertDeploy(
            c,
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
    }

    function test_extensions_enabledAndCaps() public onlyFork {
        FV2Extension e = new FV2Extension(); // not enabled
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _cfg();
        c.extensions = new IArtCoinsFactoryV2.ExtensionConfigV2[](1);
        c.extensions[0] = _ext(address(e), 0, 1000);
        _expectRevertDeploy(
            c, abi.encodeWithSelector(IArtCoinsFactoryV2.ExtensionNotEnabled.selector)
        );

        factory.setExtension(address(e), true);
        c.extensions[0] = _ext(address(e), 0, Constants.MAX_EXTENSION_BPS + 1);
        _expectRevertDeploy(
            c, abi.encodeWithSelector(IArtCoinsFactoryV2.MaxExtensionBpsExceeded.selector)
        );

        c.extensions = new IArtCoinsFactoryV2.ExtensionConfigV2[](Constants.MAX_EXTENSIONS + 1);
        for (uint256 i; i < c.extensions.length; ++i) {
            c.extensions[i] = _ext(address(e), 0, 1);
        }
        _expectRevertDeploy(
            c, abi.encodeWithSelector(IArtCoinsFactoryV2.MaxExtensionsExceeded.selector)
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    // locker bps, fee and mev bounds (FT-10)
    // ══════════════════════════════════════════════════════════════════════

    function test_bpsSumRules() public onlyFork {
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _cfg();
        // project side must be exactly BPS minus the protocol slot
        c.locker.rewardBps[0] = 10_000 - PROTOCOL_BPS + 1;
        _expectRevertDeploy(
            c, abi.encodeWithSelector(IArtCoinsFactoryV2.ProjectSideBpsMismatch.selector)
        );
        c.locker.rewardBps[0] = 10_000 - PROTOCOL_BPS - 1;
        _expectRevertDeploy(
            c, abi.encodeWithSelector(IArtCoinsFactoryV2.ProjectSideBpsMismatch.selector)
        );

        // FT-10: mismatched arrays revert, nothing is truncated
        c = _cfg();
        c.locker.rewardRecipients = new address[](2);
        c.locker.rewardRecipients[0] = project;
        c.locker.rewardRecipients[1] = mallory;
        _expectRevertDeploy(
            c, abi.encodeWithSelector(ArtCoinsFactoryV2.ArrayLengthMismatch.selector)
        );
        c = _cfg();
        c.locker.tickUpper = new int24[](1);
        c.locker.tickUpper[0] = -120_000;
        _expectRevertDeploy(
            c, abi.encodeWithSelector(ArtCoinsFactoryV2.ArrayLengthMismatch.selector)
        );

        // a zero bps project slot
        c = _cfg();
        c.locker.rewardRecipients = new address[](2);
        c.locker.rewardRecipients[0] = project;
        c.locker.rewardRecipients[1] = mallory;
        c.locker.rewardBps = new uint16[](2);
        c.locker.rewardBps[0] = 10_000 - PROTOCOL_BPS;
        _expectRevertDeploy(
            c, abi.encodeWithSelector(ArtCoinsFactoryV2.InvalidRewardSlots.selector)
        );

        // too many slots once the protocol slot is appended
        c = _cfg();
        uint256 n = Constants.MAX_REWARD_PARTICIPANTS; // + protocol = MAX + 1
        c.locker.rewardRecipients = new address[](n);
        c.locker.rewardBps = new uint16[](n);
        uint256 left = 10_000 - PROTOCOL_BPS;
        for (uint256 i; i < n; ++i) {
            c.locker.rewardRecipients[i] = address(uint160(0x5000 + i));
            uint16 bb = i == n - 1 ? uint16(left) : uint16((10_000 - PROTOCOL_BPS) / n);
            c.locker.rewardBps[i] = bb;
            left -= bb;
        }
        _expectRevertDeploy(
            c, abi.encodeWithSelector(ArtCoinsFactoryV2.InvalidRewardSlots.selector)
        );

        // positions must sum to BPS
        c = _cfg();
        c.locker.positionBps[1] = 3999;
        _expectRevertDeploy(c, abi.encodeWithSelector(ArtCoinsFactoryV2.InvalidPositions.selector));

        // bounty share capped by the minimum protocol share
        factory.setMinProtocolSkimShareBps(2000);
        c = _cfg();
        _expectRevertDeploy(
            c,
            abi.encodeWithSelector(
                IArtCoinsFactoryV2.BountyBpsTooHigh.selector, uint16(8333), uint16(8000)
            )
        );
        c.fee.bountyBps = 8000;
        address t = _deploy(alice, c);
        assertEq(hook.skimConfig(factory.deploymentInfo(t).poolId).bountyBps, 8000);

        // fee caps
        c = _cfg();
        c.fee.lpFee = Constants.MAX_LP_FEE + 1;
        _expectRevertDeploy(
            c, abi.encodeWithSelector(ArtCoinsFactoryV2.FeeConfigOutOfBounds.selector)
        );
        c = _cfg();
        c.fee.baselineSkimBps = Constants.MAX_BASELINE_SKIM_BPS + 1;
        _expectRevertDeploy(
            c, abi.encodeWithSelector(ArtCoinsFactoryV2.FeeConfigOutOfBounds.selector)
        );
        c = _cfg();
        c.fee.maxReferralBpsOfVolume = Constants.MAX_REFERRAL_CAP_OF_VOLUME + 1;
        _expectRevertDeploy(
            c, abi.encodeWithSelector(ArtCoinsFactoryV2.FeeConfigOutOfBounds.selector)
        );

        // supply floor
        c = _cfg();
        c.token.totalSupply = Constants.MIN_TOKEN_SUPPLY - 1;
        _expectRevertDeploy(
            c, abi.encodeWithSelector(IArtCoinsFactoryV2.TotalSupplyTooLow.selector)
        );
    }

    function test_mevConfigBounds() public onlyFork {
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _cfg();
        c.mev.windowSeconds = Constants.MAX_MEV_WINDOW + 1;
        _expectRevertDeploy(c, abi.encodeWithSelector(IArtCoinsFactoryV2.InvalidMevConfig.selector));
        c.mev.windowSeconds = Constants.MIN_MEV_WINDOW - 1;
        _expectRevertDeploy(c, abi.encodeWithSelector(IArtCoinsFactoryV2.InvalidMevConfig.selector));
        c = _cfg();
        c.mev.startingSkimBps = Constants.MAX_SKIM_BPS + 1;
        _expectRevertDeploy(c, abi.encodeWithSelector(IArtCoinsFactoryV2.InvalidMevConfig.selector));
        c = _cfg();
        c.mev.startingSkimBps = c.fee.baselineSkimBps - 1;
        _expectRevertDeploy(c, abi.encodeWithSelector(IArtCoinsFactoryV2.InvalidMevConfig.selector));

        // a module bound to another hook
        ArtCoinsMevLinearSkimV2 other = new ArtCoinsMevLinearSkimV2(address(0x1234));
        factory.setMevModule(address(other), true);
        c = _cfg();
        c.mev.module = address(other);
        _expectRevertDeploy(
            c, abi.encodeWithSelector(IArtCoinsFactoryV2.InvalidMevModule.selector, address(other))
        );

        // no module: config must be empty, launch works, hook still started
        c = _cfg();
        c.mev.module = address(0);
        _expectRevertDeploy(c, abi.encodeWithSelector(IArtCoinsFactoryV2.InvalidMevConfig.selector));
        c.mev.startingSkimBps = 0;
        c.mev.windowSeconds = 0;
        address t = _deploy(alice, c);
        IArtCoinsFactoryV2.DeploymentInfoV2 memory info = factory.deploymentInfo(t);
        assertEq(info.mevModule, address(0));
        assertEq(hook.poolInfo(info.poolId).mevModule, address(0));
        // initializeMevModule ran in the launch tx: a second call by the factory is refused
        vm.prank(address(factory));
        vm.expectRevert(IArtCoinsHookV2.MevModuleAlreadyInitialized.selector);
        hook.initializeMevModule(_key(t), "");
    }

    /// the factory mirrors the token constructor so a bad config fails with a clear error
    function test_tokenCtorRules_mirroredUpFront() public onlyFork {
        // renderer without code
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _cfg();
        c.token.renderer = makeAddr("fv2.noCode");
        _expectRevertDeploy(c, abi.encodeWithSelector(IArtCoinsTokenV2.InvalidRenderer.selector));

        c = _cfg();
        c.tax.mode = Constants.TAX_MODE_VENUE;
        c.tax.taxBps = 1000;
        c.tax.taxBpsMax = 2000;
        c.tax.taxSink = Constants.DEAD;
        // duplicate exempt
        c.tax.exempt = new address[](2);
        c.tax.exempt[0] = locker;
        c.tax.exempt[1] = locker;
        _expectRevertDeploy(c, abi.encodeWithSelector(IArtCoinsFactoryV2.InvalidTaxConfig.selector));
        c.tax.exempt = new address[](0);

        // venue: unknown kind, zero factory, duplicate derivation
        c.tax.venues = new IArtCoinsFactoryV2.TaxVenue[](1);
        c.tax.venues[0] = IArtCoinsFactoryV2.TaxVenue({
            kind: 3,
            factory: address(0x5C69),
            initCodeHash: bytes32(uint256(1)),
            counterToken: WETH,
            v3Fee: 0
        });
        _expectRevertDeploy(c, abi.encodeWithSelector(IArtCoinsFactoryV2.InvalidTaxConfig.selector));
        c.tax.venues[0].kind = 1;
        c.tax.venues[0].factory = address(0);
        _expectRevertDeploy(c, abi.encodeWithSelector(IArtCoinsFactoryV2.InvalidTaxConfig.selector));
        c.tax.venues = new IArtCoinsFactoryV2.TaxVenue[](2);
        c.tax.venues[0] = IArtCoinsFactoryV2.TaxVenue({
            kind: 1,
            factory: address(0x5C69),
            initCodeHash: bytes32(uint256(1)),
            counterToken: WETH,
            v3Fee: 0
        });
        // v3Fee is ignored by a v2 style derivation: same pool
        c.tax.venues[1] = IArtCoinsFactoryV2.TaxVenue({
            kind: 1,
            factory: address(0x5C69),
            initCodeHash: bytes32(uint256(1)),
            counterToken: WETH,
            v3Fee: 3000
        });
        _expectRevertDeploy(c, abi.encodeWithSelector(IArtCoinsFactoryV2.InvalidTaxConfig.selector));

        // distinct venues launch, and the token lists them
        c.tax.venues[1].kind = 2;
        c.tax.exempt = new address[](1);
        c.tax.exempt[0] = locker;
        address t = _deploy(alice, c);
        assertTrue(ArtCoinsTokenV2(t).isTaxExempt(locker));
    }

    /// cross package (D37): the real v2 locker places liquidity for the real v2
    /// token although solady fixes the token's Permit2 allowance at infinity.
    function test_realLocker_launch() public onlyFork {
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _cfg();
        assertEq(c.locker.locker, address(realLocker));
        address t = _deploy(alice, c);
        IArtCoinsLpLockerV2.TokenRewardInfoV2 memory info = realLocker.tokenRewards(t);
        assertEq(info.numPositions, 2);
        assertEq(info.token, t);
        assertEq(realLocker.rewardRecipients(t)[1], protocolR);
        assertEq(IERC20(t).balanceOf(address(factory)), 0);
        assertEq(IERC20(t).balanceOf(address(realLocker)), 0);
    }

    /// D38: the deployer is an owner set pointer, bound to this factory.
    function test_tokenDeployer_setAndRequired() public {
        ArtCoinsFactoryV2 f = new ArtCoinsFactoryV2(address(this), POOL_MANAGER, 0, 0);
        assertEq(f.tokenDeployer(), address(0));
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c;
        c.token.tokenAdmin = admin;
        vm.expectRevert(ArtCoinsFactoryV2.DeployerNotSet.selector);
        f.deployToken(c); // owner bypasses the deprecated gate, then hits the deployer check
        vm.expectRevert(ArtCoinsFactoryV2.DeployerNotSet.selector);
        f.predictToken(alice, c);

        // bound to another factory, no code, zero
        vm.expectRevert(
            abi.encodeWithSelector(ArtCoinsFactoryV2.InvalidDeployer.selector, address(deployer))
        );
        f.setTokenDeployer(address(deployer));
        address noCode = makeAddr("fv2.noCodeDeployer");
        vm.expectRevert(abi.encodeWithSelector(ArtCoinsFactoryV2.InvalidDeployer.selector, noCode));
        f.setTokenDeployer(noCode);
        vm.expectRevert(IArtCoinsFactoryV2.ZeroAddress.selector);
        f.setTokenDeployer(address(0));

        // owner only
        ArtCoinsDeployerV2 d = new ArtCoinsDeployerV2(address(f));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        f.setTokenDeployer(address(d));

        vm.expectEmit(true, true, false, false, address(f));
        emit ArtCoinsFactoryV2.TokenDeployerSet(address(0), address(d));
        f.setTokenDeployer(address(d));
        assertEq(f.tokenDeployer(), address(d));
        assertEq(d.factory(), address(f));
    }

    /// D38: replacing the deployer moves every future address; prediction follows it.
    function test_tokenDeployer_replaced_predictFollows() public onlyFork {
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _cfg();
        address before = factory.predictToken(alice, c);
        ArtCoinsDeployerV2 d2 = new ArtCoinsDeployerV2(address(factory));
        factory.setTokenDeployer(address(d2));
        address afterSwap = factory.predictToken(alice, c);
        assertTrue(afterSwap != before);
        assertEq(_deploy(alice, c), afterSwap);
    }

    /// D47 / V2A-02: exempt entries come from the owner allowlist or the implicit set.
    function test_exemptAllowlist() public onlyFork {
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _cfg();
        c.tax.mode = Constants.TAX_MODE_VENUE;
        c.tax.taxBps = 1000;
        c.tax.taxBpsMax = 2000;
        c.tax.taxSink = Constants.DEAD;
        c.tax.exempt = new address[](1);

        // a deployer's own forwarder (any contract) is refused
        address forwarder = address(new FV2Payout());
        c.tax.exempt[0] = forwarder;
        _expectRevertDeploy(
            c, abi.encodeWithSelector(ArtCoinsFactoryV2.ExemptNotAllowed.selector, forwarder)
        );
        // so are sweepable periphery contracts unless the owner lists them (it must not)
        c.tax.exempt[0] = POSITION_MANAGER;
        _expectRevertDeploy(
            c, abi.encodeWithSelector(ArtCoinsFactoryV2.ExemptNotAllowed.selector, POSITION_MANAGER)
        );

        // owner listing: owner only, nonzero, evented
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.setExemptAllowed(forwarder, true);
        vm.expectRevert(IArtCoinsFactoryV2.ZeroAddress.selector);
        factory.setExemptAllowed(address(0), true);
        vm.expectEmit(true, false, false, true, address(factory));
        emit ArtCoinsFactoryV2.ExemptAllowedSet(forwarder, true);
        factory.setExemptAllowed(forwarder, true);
        assertTrue(factory.exemptAllowed(forwarder));

        c.tax.exempt[0] = forwarder;
        address t1 = _deploy(alice, c);
        assertTrue(ArtCoinsTokenV2(t1).isTaxExempt(forwarder), "listed passes");

        // delisting affects new launches
        factory.setExemptAllowed(forwarder, false);
        c.token.salt = bytes32(uint256(31));
        _expectRevertDeploy(
            c, abi.encodeWithSelector(ArtCoinsFactoryV2.ExemptNotAllowed.selector, forwarder)
        );

        // implicit: this launch's locker and hook, enabled escrows, enabled extensions
        FV2Extension e = _newExt();
        c.tax.exempt = new address[](4);
        c.tax.exempt[0] = locker;
        c.tax.exempt[1] = address(hook);
        c.tax.exempt[2] = address(escrow);
        c.tax.exempt[3] = address(e);
        address t2 = _deploy(alice, c);
        assertTrue(ArtCoinsTokenV2(t2).isTaxExempt(locker), "locker passes without listing");
        assertTrue(ArtCoinsTokenV2(t2).isTaxExempt(address(hook)));
        assertTrue(ArtCoinsTokenV2(t2).isTaxExempt(address(escrow)));
        assertTrue(ArtCoinsTokenV2(t2).isTaxExempt(address(e)));
        assertFalse(factory.exemptAllowed(locker));
    }

    /// D46: a taxed launch still places its liquidity (locker is a hook
    /// launcher) and the pool trades both ways.
    function test_taxedLaunch_hard_placesAndTrades() public onlyFork {
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _cfg();
        c.tax.mode = Constants.TAX_MODE_HARD;
        _launchAndTrade(c);
    }

    function test_taxedLaunch_venue_placesAndTrades() public onlyFork {
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _cfg();
        c.tax.mode = Constants.TAX_MODE_VENUE;
        c.tax.taxBps = 1000;
        c.tax.taxBpsMax = 2000;
        c.tax.taxSink = Constants.DEAD;
        c.tax.exempt = new address[](1);
        c.tax.exempt[0] = locker;
        _launchAndTrade(c);
    }

    function _launchAndTrade(IArtCoinsFactoryV2.DeploymentConfigV2 memory c) internal {
        assertTrue(hook.isLauncher(locker), "D46: locker is a hook launcher");
        address t = _deploy(alice, c);
        assertEq(realLocker.tokenRewards(t).numPositions, 2, "liquidity placed");
        assertEq(IERC20(t).balanceOf(address(factory)), 0);
        PoolKey memory key = _key(t);

        // buy: exact eth in
        uint256 before = IERC20(t).balanceOf(address(this));
        swapRouter.swap{value: 0.1 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.1 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 bought = IERC20(t).balanceOf(address(this)) - before;
        assertGt(bought, 0, "bought");

        // sell half back: exact coin in
        IERC20(t).approve(address(swapRouter), type(uint256).max);
        uint256 ethBefore = address(this).balance;
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(bought / 2),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertEq(IERC20(t).balanceOf(address(this)), before + bought - bought / 2, "sold");
        assertGt(address(this).balance, ethBefore, "eth back");
    }

    /// D30: string caps are checked before any deploy work, same error as the token.
    function test_tokenStrings_capPasses_capPlusOneReverts() public onlyFork {
        ArtCoinsTokenV2 ref = ArtCoinsTokenV2(_deploy(alice, _cfg()));
        uint256[5] memory caps = [
            ref.MAX_NAME_BYTES(),
            ref.MAX_SYMBOL_BYTES(),
            ref.MAX_IMAGE_BYTES(),
            ref.MAX_METADATA_BYTES(),
            ref.MAX_CONTEXT_BYTES()
        ];
        assertEq(caps[0], 64);
        assertEq(caps[1], 16);
        assertEq(caps[2], 2048);
        assertEq(caps[3], 4096);
        assertEq(caps[4], 4096);

        for (uint8 f; f < 5; ++f) {
            IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _cfg();
            c.token.salt = bytes32(uint256(100 + f));
            _setString(c, f, string(new bytes(caps[f] + 1)));
            _expectRevertDeploy(
                c, abi.encodeWithSelector(IArtCoinsTokenV2.StringTooLong.selector, f, caps[f] + 1)
            );
        }
        // every field at its cap at once
        IArtCoinsFactoryV2.DeploymentConfigV2 memory ok = _cfg();
        ok.token.salt = bytes32(uint256(200));
        for (uint8 f; f < 5; ++f) {
            _setString(ok, f, string(_filled(caps[f])));
        }
        ArtCoinsTokenV2 t = ArtCoinsTokenV2(_deploy(alice, ok));
        assertEq(bytes(t.name()).length, 64);
        assertEq(bytes(t.symbol()).length, 16);
        assertEq(bytes(t.context()).length, 4096);
    }

    function _filled(uint256 n) internal pure returns (bytes memory b) {
        b = new bytes(n);
        for (uint256 i; i < n; ++i) {
            b[i] = "a";
        }
    }

    function _setString(IArtCoinsFactoryV2.DeploymentConfigV2 memory c, uint8 f, string memory v)
        internal
        pure
    {
        if (f == 0) c.token.name = v;
        else if (f == 1) c.token.symbol = v;
        else if (f == 2) c.token.image = v;
        else if (f == 3) c.token.metadata = v;
        else c.token.context = v;
    }

    // ══════════════════════════════════════════════════════════════════════
    // event, dust
    // ══════════════════════════════════════════════════════════════════════

    function test_event_fullConfig() public onlyFork {
        FV2Extension e = _newExt();
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _cfg();
        c.tax.mode = Constants.TAX_MODE_VENUE;
        c.tax.taxBps = 500;
        c.tax.taxBpsMax = 1500;
        c.tax.taxSink = bounty;
        c.tax.exempt = new address[](1);
        c.tax.exempt[0] = locker;
        c.extensions = new IArtCoinsFactoryV2.ExtensionConfigV2[](1);
        c.extensions[0] = _ext(address(e), 0.5 ether, 700);
        c.token.renderer = address(0);

        vm.recordLogs();
        vm.prank(alice);
        address t = factory.deployToken{value: FEE + 0.5 ether}(c);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (
            address sender,
            address token,
            bytes32 pid,
            uint16 ver,
            uint16 usedBps,
            uint256 poolSupply,
            uint256 extSupply,
            IArtCoinsFactoryV2.DeploymentConfigV2 memory got
        ) = _decodeCreated(logs);
        assertEq(sender, alice);
        assertEq(token, t);
        assertEq(pid, PoolId.unwrap(factory.deploymentInfo(t).poolId));
        assertEq(ver, Constants.STACK_VERSION);
        assertEq(usedBps, PROTOCOL_BPS);
        uint256 share = Constants.DEFAULT_TOKEN_SUPPLY * 700 / 10_000;
        assertEq(extSupply, share);
        assertEq(poolSupply, Constants.DEFAULT_TOKEN_SUPPLY - share);
        // the whole config round trips byte for byte
        assertEq(keccak256(abi.encode(got)), keccak256(abi.encode(c)), "full config");
        assertEq(got.tax.taxSink, bounty);
        assertEq(got.tax.exempt[0], locker);
        assertEq(got.extensions[0].msgValue, 0.5 ether);
        assertEq(got.locker.rewardRecipients[0], project);

        // the remaining non indexed fields
        (, bytes32 h, address pr, address rp,,,,) = abi.decode(
            _createdData(logs),
            (
                uint16,
                bytes32,
                address,
                address,
                uint16,
                uint256,
                uint256,
                IArtCoinsFactoryV2.DeploymentConfigV2
            )
        );
        assertEq(h, factory.configHash(c));
        assertEq(pr, protocolR);
        assertEq(rp, address(payout));
    }

    /// FT-09: floor dust from the extension shares goes to the pool, never to the team.
    function test_dust_toPool_neverTeam() public onlyFork {
        FV2Extension e1 = _newExt();
        FV2Extension e2 = _newExt();
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _cfg();
        uint256 supply = 1e18 + 7;
        c.token.totalSupply = supply;
        c.extensions = new IArtCoinsFactoryV2.ExtensionConfigV2[](2);
        c.extensions[0] = _ext(address(e1), 0, 3333);
        c.extensions[1] = _ext(address(e2), 0, 3333);

        vm.recordLogs();
        address t = _deploy(alice, c);
        (,,,,, uint256 poolSupply, uint256 extSupply,) = _decodeCreated(vm.getRecordedLogs());

        uint256 s1 = supply * 3333 / 10_000;
        assertTrue(s1 * 10_000 != supply * 3333, "the split really floors");
        assertEq(IERC20(t).balanceOf(address(e1)), s1);
        assertEq(IERC20(t).balanceOf(address(e2)), s1);
        assertEq(extSupply, 2 * s1);
        assertEq(poolSupply, supply - 2 * s1, "dust in the pool supply");
        assertEq(poolSupply + extSupply, supply);
        assertEq(IERC20(t).totalSupply(), supply);
        assertEq(IERC20(t).balanceOf(address(factory)), 0, "factory holds no dust");
        assertEq(IERC20(t).balanceOf(team), 0, "team gets no coin");
        assertEq(IERC20(t).balanceOf(locker), 0, "locker holds none");
    }

    // ══════════════════════════════════════════════════════════════════════
    // owner (no fork needed)
    // ══════════════════════════════════════════════════════════════════════

    /// FT-04: a module or extension whose erc165 or constants answer breaks
    /// can still be disabled; disabling never calls the target.
    function test_disable_failingModule() public {
        FV2ToggleModule m = new FV2ToggleModule(address(0x1234));
        factory.setMevModule(address(m), true);
        assertTrue(factory.enabledMevModules(address(m)));
        m.setBroken(true);
        vm.expectRevert(
            abi.encodeWithSelector(IArtCoinsFactoryV2.InvalidMevModule.selector, address(m))
        );
        factory.setMevModule(address(m), true);
        vm.expectEmit(true, false, false, true, address(factory));
        emit IArtCoinsFactoryV2.MevModuleSet(address(m), false);
        factory.setMevModule(address(m), false);
        assertFalse(factory.enabledMevModules(address(m)));

        FV2Extension e = new FV2Extension();
        factory.setExtension(address(e), true);
        e.setBroken(true);
        factory.setExtension(address(e), false);
        assertFalse(factory.enabledExtensions(address(e)));

        // hooks and lockers whose code is gone can be disabled too
        FV2HashStub h = new FV2HashStub(Constants.hash(), POOL_MANAGER);
        factory.setHook(address(h), true);
        factory.setLocker(address(h), true);
        vm.etch(address(h), hex"fe");
        factory.setHook(address(h), false);
        factory.setLocker(address(h), false);
        assertFalse(factory.enabledHooks(address(h)));
        assertFalse(factory.enabledLockers(address(h)));
    }

    function test_disabledModule_blocksLaunch() public onlyFork {
        factory.setMevModule(address(mev), false);
        _expectRevertDeploy(
            _cfg(), abi.encodeWithSelector(IArtCoinsFactoryV2.MevModuleNotEnabled.selector)
        );
        factory.setMevModule(address(mev), true);
        factory.setLocker(locker, false);
        _expectRevertDeploy(
            _cfg(), abi.encodeWithSelector(IArtCoinsFactoryV2.LockerNotEnabled.selector)
        );
        factory.setLocker(locker, true);
        factory.setHook(address(hook), false);
        _expectRevertDeploy(
            _cfg(), abi.encodeWithSelector(IArtCoinsFactoryV2.HookNotEnabled.selector)
        );
    }

    function test_owner_setterBounds() public {
        assertTrue(
            new ArtCoinsFactoryV2(address(this), POOL_MANAGER, 0, 0).deprecated(),
            "ships deprecated"
        );
        assertEq(factory.owner(), address(this));

        vm.expectRevert(IArtCoinsFactoryV2.DeployFeeTooHigh.selector);
        factory.setDeployFee(Constants.MAX_DEPLOY_FEE + 1);
        factory.setDeployFee(Constants.MAX_DEPLOY_FEE);
        assertEq(factory.deployFee(), Constants.MAX_DEPLOY_FEE);

        vm.expectRevert(IArtCoinsFactoryV2.ProtocolFeeBpsTooHigh.selector);
        factory.setDefaultProtocolFeeBps(Constants.MAX_PROTOCOL_FEE_BPS + 1);
        factory.setDefaultProtocolFeeBps(Constants.MAX_PROTOCOL_FEE_BPS);
        assertEq(factory.defaultProtocolFeeBps(), Constants.MAX_PROTOCOL_FEE_BPS);

        vm.expectRevert(IArtCoinsFactoryV2.MinProtocolSkimShareTooHigh.selector);
        factory.setMinProtocolSkimShareBps(uint16(Constants.BPS + 1));
        factory.setMinProtocolSkimShareBps(uint16(Constants.BPS));

        vm.expectRevert(IArtCoinsFactoryV2.ZeroAddress.selector);
        factory.setProtocolRecipient(payable(address(0)));
        vm.expectRevert(IArtCoinsFactoryV2.ZeroAddress.selector);
        factory.setReferralPayout(payable(address(0)));
        vm.expectRevert(IArtCoinsFactoryV2.ZeroAddress.selector);
        factory.setHook(address(0), true);

        vm.expectRevert(ArtCoinsFactoryV2.RenounceDisabled.selector);
        factory.renounceOwnership();

        // constructor bounds
        vm.expectRevert(IArtCoinsFactoryV2.ProtocolFeeBpsTooHigh.selector);
        new ArtCoinsFactoryV2(address(this), POOL_MANAGER, Constants.MAX_PROTOCOL_FEE_BPS + 1, 0);
        vm.expectRevert(IArtCoinsFactoryV2.DeployFeeTooHigh.selector);
        new ArtCoinsFactoryV2(address(this), POOL_MANAGER, 0, Constants.MAX_DEPLOY_FEE + 1);

        // every owner entry is gated
        vm.startPrank(alice);
        bytes memory err =
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice);
        vm.expectRevert(err);
        factory.setDeployFee(0);
        vm.expectRevert(err);
        factory.setDefaultProtocolFeeBps(0);
        vm.expectRevert(err);
        factory.setMinProtocolSkimShareBps(0);
        vm.expectRevert(err);
        factory.setProtocolRecipient(payable(alice));
        vm.expectRevert(err);
        factory.setReferralPayout(payable(alice));
        vm.expectRevert(err);
        factory.setTeamFeeRecipient(alice);
        vm.expectRevert(err);
        factory.setHook(alice, false);
        vm.expectRevert(err);
        factory.setLocker(alice, false);
        vm.expectRevert(err);
        factory.setMevModule(alice, false);
        vm.expectRevert(err);
        factory.setExtension(alice, false);
        vm.expectRevert(err);
        factory.setEscrow(alice, false);
        vm.expectRevert(err);
        factory.rescue(address(0), alice, 0);
        vm.stopPrank();

        // two step ownership
        factory.transferOwnership(alice);
        assertEq(factory.owner(), address(this));
        vm.prank(alice);
        factory.acceptOwnership();
        assertEq(factory.owner(), alice);
    }

    function test_rescue_ethAndErc20() public {
        vm.deal(address(factory), 1 ether);
        uint256 before = team.balance;
        factory.rescue(address(0), team, 1 ether);
        assertEq(team.balance - before, 1 ether);
        vm.expectRevert(IArtCoinsFactoryV2.ZeroAddress.selector);
        factory.rescue(address(0), address(0), 0);
    }

    // ── helpers ───────────────────────────────────────────────────────────

    function _key(address token) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TS,
            hooks: IHooks(address(hook))
        });
    }

    function _createdData(Vm.Log[] memory logs) internal view returns (bytes memory) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(factory) && logs[i].topics[0] == TOKEN_CREATED_SIG) {
                return logs[i].data;
            }
        }
        revert("TokenCreatedV2 not found");
    }

    function _decodeCreated(Vm.Log[] memory logs)
        internal
        view
        returns (
            address sender,
            address token,
            bytes32 poolId,
            uint16 version,
            uint16 protocolBps,
            uint256 poolSupply,
            uint256 extensionsSupply,
            IArtCoinsFactoryV2.DeploymentConfigV2 memory config
        )
    {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(factory) || l.topics[0] != TOKEN_CREATED_SIG) continue;
            sender = address(uint160(uint256(l.topics[1])));
            token = address(uint160(uint256(l.topics[2])));
            poolId = l.topics[3];
            (version,,,, protocolBps, poolSupply, extensionsSupply, config) = abi.decode(
                l.data,
                (
                    uint16,
                    bytes32,
                    address,
                    address,
                    uint16,
                    uint256,
                    uint256,
                    IArtCoinsFactoryV2.DeploymentConfigV2
                )
            );
            return
                (sender, token, poolId, version, protocolBps, poolSupply, extensionsSupply, config);
        }
        revert("TokenCreatedV2 not found");
    }
}
