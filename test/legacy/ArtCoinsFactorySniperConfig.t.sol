// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IArtCoinsFactory} from "../../src/interfaces/IArtCoinsFactory.sol";
import {IArtCoinsHook} from "../../src/interfaces/IArtCoinsHook.sol";
import {IArtCoinsLpLocker} from "../../src/interfaces/IArtCoinsLpLocker.sol";
import {ArtCoinsFactory} from "../../src/legacy/ArtCoinsFactory.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract MockFactorySniperHook is IArtCoinsHook {
    using PoolIdLibrary for PoolKey;

    mapping(PoolId => address) public sniperFeeRecipient;
    mapping(PoolId => bool) public sniperFeeRecipientLocked;
    mapping(PoolId => bool) public mevModuleEnabled;
    mapping(PoolId => uint256) public poolCreationTimestamp;

    PoolId public lastPoolId;
    uint256 public factorySetCalls;

    function initializePool(
        address artCoin,
        address pairedToken,
        int24,
        int24 tickSpacing,
        address,
        address,
        bytes calldata
    ) external returns (PoolKey memory poolKey) {
        (address c0, address c1) =
            artCoin < pairedToken ? (artCoin, pairedToken) : (pairedToken, artCoin);
        poolKey = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 0x800000,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(this))
        });
        lastPoolId = poolKey.toId();
        poolCreationTimestamp[lastPoolId] = block.timestamp;
    }

    function factorySetSniperFeeRecipient(
        PoolKey calldata poolKey,
        address recipient,
        bool lockRecipient
    ) external {
        if (lockRecipient && recipient == address(0)) {
            revert IArtCoinsHook.InvalidSniperFeeConfig();
        }
        PoolId id = poolKey.toId();
        sniperFeeRecipient[id] = recipient;
        sniperFeeRecipientLocked[id] = lockRecipient;
        factorySetCalls++;
    }

    function initializePoolOpen(address, address, int24, int24, bytes calldata)
        external
        pure
        returns (PoolKey memory)
    {
        revert("unused");
    }

    function initializeMevModule(PoolKey calldata, bytes calldata) external {}
    function mevModuleSetFee(PoolKey calldata, uint24) external {}
    function mevModuleSetSniperFee(PoolKey calldata, uint24) external {}
    function setSniperFeeRecipient(PoolKey calldata, address) external {}
    function lockSniperFeeRecipient(PoolKey calldata) external {}

    function mevModuleOperational(PoolId) external pure returns (bool) {
        return false;
    }

    function MAX_MEV_MODULE_DELAY() external pure returns (uint256) {
        return 15 minutes;
    }

    function MAX_LP_FEE() external pure returns (uint24) {
        return 100_000;
    }

    function MAX_MEV_LP_FEE() external pure returns (uint24) {
        return 990_000;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IArtCoinsHook).interfaceId
            || interfaceId == type(IArtCoinsHook).interfaceId;
    }
}

contract MockFactorySniperLocker is IArtCoinsLpLocker {
    address public recipientDuringLiquidity;
    bool public lockedDuringLiquidity;
    uint256 public placedPositions;

    function placeLiquidity(
        IArtCoinsFactory.LockerConfig memory lockerConfig,
        IArtCoinsFactory.PoolConfig memory poolConfig,
        PoolKey memory poolKey,
        uint256,
        address
    ) external returns (uint256) {
        MockFactorySniperHook hook = MockFactorySniperHook(poolConfig.hook);
        recipientDuringLiquidity = hook.sniperFeeRecipient(poolKey.toId());
        lockedDuringLiquidity = hook.sniperFeeRecipientLocked(poolKey.toId());
        placedPositions = lockerConfig.tickLower.length;
        return 1;
    }

    function collectRewards(address) external {}
    function collectRewardsWithoutUnlock(address) external {}

    function tokenRewards(address)
        external
        pure
        returns (IArtCoinsLpLocker.TokenRewardInfo memory)
    {
        revert("unused");
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IArtCoinsLpLocker).interfaceId;
    }
}

contract ArtCoinsFactorySniperConfigTest is Test {
    using PoolIdLibrary for PoolKey;

    ArtCoinsFactory internal factory;
    MockFactorySniperHook internal hook;
    MockFactorySniperLocker internal locker;

    address internal owner = address(0xCAFE);
    address internal tokenAdmin = address(0xA11CE);
    address internal feeSink = address(0xFEE);
    address internal pairedToken = address(0xBEEF);
    address internal burnRouter = address(0xB0A);

    function setUp() public {
        vm.startPrank(owner);
        factory = new ArtCoinsFactory(owner);
        hook = new MockFactorySniperHook();
        locker = new MockFactorySniperLocker();

        factory.setTeamFeeRecipient(feeSink);
        factory.setDeployFee(0);
        factory.setHook(address(hook), true);
        factory.setLocker(address(locker), address(hook), true);
        factory.setDeprecated(false);
        vm.stopPrank();
    }

    function test_deployTokenConfiguresAndLocksSniperRecipientBeforeLiquidity() public {
        IArtCoinsFactory.DeploymentConfig memory dc = _baseConfig();
        dc.sniperFeeConfig =
            IArtCoinsFactory.SniperFeeConfig({recipient: burnRouter, lockRecipient: true});

        factory.deployToken(dc);

        PoolId pid = hook.lastPoolId();
        assertEq(hook.sniperFeeRecipient(pid), burnRouter);
        assertTrue(hook.sniperFeeRecipientLocked(pid));
        assertEq(locker.recipientDuringLiquidity(), burnRouter);
        assertTrue(locker.lockedDuringLiquidity());
        assertEq(hook.factorySetCalls(), 1);
    }

    function test_deployTokenRejectsLockedZeroSniperRecipient() public {
        IArtCoinsFactory.DeploymentConfig memory dc = _baseConfig();
        dc.sniperFeeConfig =
            IArtCoinsFactory.SniperFeeConfig({recipient: address(0), lockRecipient: true});

        vm.expectRevert(IArtCoinsHook.InvalidSniperFeeConfig.selector);
        factory.deployToken(dc);
    }

    function test_deployTokenDefaultSniperConfigPreservesLegacyDeployments() public {
        IArtCoinsFactory.DeploymentConfig memory dc = _baseConfig();

        factory.deployToken(dc);

        PoolId pid = hook.lastPoolId();
        assertEq(hook.sniperFeeRecipient(pid), address(0));
        assertFalse(hook.sniperFeeRecipientLocked(pid));
        assertEq(locker.recipientDuringLiquidity(), address(0));
        assertFalse(locker.lockedDuringLiquidity());
        assertEq(hook.factorySetCalls(), 0);
    }

    function _baseConfig() internal view returns (IArtCoinsFactory.DeploymentConfig memory dc) {
        dc.tokenConfig = IArtCoinsFactory.TokenConfig({
            tokenAdmin: tokenAdmin,
            name: "Sniper Test",
            symbol: "SNIP",
            salt: bytes32(0),
            image: "",
            metadata: "",
            context: "",
            totalSupply: 1_000_000e18,
            renderer: address(0)
        });

        dc.poolConfig = IArtCoinsFactory.PoolConfig({
            hook: address(hook),
            pairedToken: pairedToken,
            tickIfToken0IsArtCoins: 0,
            tickSpacing: 200,
            poolData: ""
        });

        address[] memory rewardAdmins = new address[](1);
        rewardAdmins[0] = tokenAdmin;
        address[] memory rewardRecipients = new address[](1);
        rewardRecipients[0] = tokenAdmin;
        uint16[] memory rewardBps = new uint16[](1);
        rewardBps[0] = 8000;
        int24[] memory tickLower = new int24[](1);
        tickLower[0] = -200;
        int24[] memory tickUpper = new int24[](1);
        tickUpper[0] = 200;
        uint16[] memory positionBps = new uint16[](1);
        positionBps[0] = 10_000;

        dc.lockerConfig = IArtCoinsFactory.LockerConfig({
            locker: address(locker),
            rewardAdmins: rewardAdmins,
            rewardRecipients: rewardRecipients,
            rewardBps: rewardBps,
            tickLower: tickLower,
            tickUpper: tickUpper,
            positionBps: positionBps,
            lockerData: ""
        });

        dc.mevModuleConfig =
            IArtCoinsFactory.MevModuleConfig({mevModule: address(0), mevModuleData: ""});
        dc.extensionConfigs = new IArtCoinsFactory.ExtensionConfig[](0);
    }
}
