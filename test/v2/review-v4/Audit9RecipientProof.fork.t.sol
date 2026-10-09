// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// v2-audit-9 A9-01 regression: the factory launch rejects an unpayable stack
// contract as the pool bounty recipient or the injected protocol recipient,
// using the same fixed reject set it applies to project reward recipients.
// setProtocolRecipient rejects the globally knowable members directly. The
// auditor's proof is flipped here to assert the launch reverts.

import {Constants} from "../../../src/Constants.sol";
import {
    ArtCoinsPoolExtensionAllowlist
} from "../../../src/hooks/ArtCoinsPoolExtensionAllowlist.sol";
import {ArtCoinsFactoryV2} from "../../../src/v2/ArtCoinsFactoryV2.sol";
import {ArtCoinsFeeEscrowV2} from "../../../src/v2/ArtCoinsFeeEscrowV2.sol";
import {ArtCoinsHookV2} from "../../../src/v2/hooks/ArtCoinsHookV2.sol";
import {IArtCoinsFactoryV2} from "../../../src/v2/interfaces/IArtCoinsFactoryV2.sol";
import {IArtCoinsHookV2} from "../../../src/v2/interfaces/IArtCoinsHookV2.sol";
import {IArtCoinsLpLockerV2} from "../../../src/v2/interfaces/IArtCoinsLpLockerV2.sol";
import {ArtCoinsLpLockerV2} from "../../../src/v2/lp-lockers/ArtCoinsLpLockerV2.sol";
import {ArtCoinsMevLinearSkimV2} from "../../../src/v2/mev-modules/ArtCoinsMevLinearSkimV2.sol";
import {ArtCoinsDeployerV2} from "../../../src/v2/utils/ArtCoinsDeployerV2.sol";
import {ForkBase} from "../harness/ForkBase.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

contract Audit9RecipientProofForkTest is ForkBase {
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );
    int24 internal constant START = -200_000;
    int24 internal constant TS = 200;
    uint16 internal constant PROTOCOL_BPS = 2000;
    uint256 internal constant FEE = 0.01 ether;

    ArtCoinsFactoryV2 internal factory;
    ArtCoinsDeployerV2 internal deployer;
    ArtCoinsFeeEscrowV2 internal escrow;
    ArtCoinsHookV2 internal hook;
    ArtCoinsLpLockerV2 internal locker;
    ArtCoinsMevLinearSkimV2 internal mev;

    address payable internal protocolR = payable(makeAddr("a9.protocolRecipient"));
    address internal team = makeAddr("a9.team");
    address internal alice = makeAddr("a9.alice");
    address internal admin = makeAddr("a9.tokenAdmin");
    address internal project = makeAddr("a9.project");
    address payable internal bounty = payable(makeAddr("a9.bounty"));

    function setUp() public {
        forkMainnet();
        if (!onFork) return;
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

        hook.setLauncher(address(factory), true);
        factory.setHook(address(hook), true);
        factory.setLocker(address(locker), true);
        factory.setMevModule(address(mev), true);
        factory.setProtocolRecipient(protocolR);
        factory.setTeamFeeRecipient(team);
        factory.setDeprecated(false);
    }

    function _cfg() internal view returns (IArtCoinsFactoryV2.DeploymentConfigV2 memory c) {
        c.token.tokenAdmin = admin;
        c.token.name = "Audit9";
        c.token.symbol = "A9";
        c.token.salt = bytes32(uint256(1));
        c.token.description = "{}";

        c.pool.hook = address(hook);
        c.pool.tickIfToken0IsCoin = START;
        c.pool.tickSpacing = TS;

        c.fee = IArtCoinsFactoryV2.FeeConfigV2({
            lpFeePips: 5000,
            baselineSkimBps: 600,
            bountyBps: 8000,
            maxReferralBpsOfVolume: 25,
            bountyRecipient: bounty
        });

        c.locker.locker = address(locker);
        c.locker.rewardRecipients = new address[](1);
        c.locker.rewardRecipients[0] = project;
        c.locker.rewardBps = new uint16[](1);
        c.locker.rewardBps[0] = 10_000 - PROTOCOL_BPS;
        c.locker.tickLower = new int24[](1);
        c.locker.tickUpper = new int24[](1);
        c.locker.positionBps = new uint16[](1);
        c.locker.tickLower[0] = START;
        c.locker.tickUpper[0] = -100_000;
        c.locker.positionBps[0] = 10_000;

        c.mev = IArtCoinsFactoryV2.MevConfigV2(address(0), 0, 0);
    }

    function _rejectSet() internal view returns (address[6] memory) {
        return [
            address(factory),
            POOL_MANAGER,
            address(hook),
            address(locker),
            address(deployer),
            address(escrow)
        ];
    }

    /// A9-01: an unpayable stack contract as the bounty recipient reverts the launch.
    function test_A9_01_bountyRecipientStackContract_reverts() public onlyFork {
        address[6] memory bad = _rejectSet();
        for (uint256 i; i < bad.length; ++i) {
            IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _cfg();
            c.token.salt = bytes32(uint256(100 + i));
            c.fee.bountyRecipient = payable(bad[i]);
            vm.prank(alice);
            vm.expectRevert(
                abi.encodeWithSelector(IArtCoinsFactoryV2.RecipientCannotReceive.selector, bad[i])
            );
            factory.deployToken{value: FEE}(c);
        }
    }

    /// A9-01: an unpayable stack contract as the injected protocol recipient
    /// reverts the launch (the launch-specific members are not knowable at
    /// setProtocolRecipient time, so the launch is the check that catches them).
    function test_A9_01_protocolRecipientStackContract_reverts() public onlyFork {
        factory.setProtocolRecipient(payable(address(hook)));
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _cfg();
        c.token.salt = bytes32(uint256(200));
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtCoinsFactoryV2.RecipientCannotReceive.selector, address(hook)
            )
        );
        factory.deployToken{value: FEE}(c);
    }

    /// A9-01: setProtocolRecipient rejects the globally knowable members directly.
    function test_A9_01_setProtocolRecipient_knowableReverts() public onlyFork {
        vm.expectRevert(
            abi.encodeWithSelector(IArtCoinsFactoryV2.RecipientCannotReceive.selector, POOL_MANAGER)
        );
        factory.setProtocolRecipient(payable(POOL_MANAGER));

        vm.expectRevert(
            abi.encodeWithSelector(
                IArtCoinsFactoryV2.RecipientCannotReceive.selector, address(factory)
            )
        );
        factory.setProtocolRecipient(payable(address(factory)));

        vm.expectRevert(
            abi.encodeWithSelector(
                IArtCoinsFactoryV2.RecipientCannotReceive.selector, address(deployer)
            )
        );
        factory.setProtocolRecipient(payable(address(deployer)));
    }

    /// A9-02: an escrow rotated out of the hook and locker is still rejected by
    /// both recipient setters, because each keeps every escrow it was wired to.
    function test_A9_02_rotatedOutEscrowRejectedByBothSetters() public onlyFork {
        vm.prank(alice);
        address coin = factory.deployToken{value: FEE}(_cfg());
        PoolId pid = factory.deploymentInfo(coin).poolId;
        address oldEscrow = address(escrow);

        // rotate both the hook and the locker to a fresh escrow
        ArtCoinsFeeEscrowV2 escrow2 = new ArtCoinsFeeEscrowV2(address(this));
        escrow2.addDepositor(address(hook), true);
        escrow2.addDepositor(address(locker), true);
        hook.setFeeEscrow(address(escrow2));
        locker.setFeeEscrow(address(escrow2));

        // the coin admin cannot point either recipient at the rotated-out escrow
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IArtCoinsHookV2.RecipientCannotReceive.selector, oldEscrow)
        );
        hook.setBountyRecipient(pid, payable(oldEscrow));

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IArtCoinsLpLockerV2.RecipientCannotReceive.selector, oldEscrow)
        );
        locker.setRewardRecipient(coin, 0, oldEscrow);
    }
}
