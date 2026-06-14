// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IArtCoinsFactory} from "../src/interfaces/IArtCoinsFactory.sol";
import {IArtCoinsLpLocker} from "../src/interfaces/IArtCoinsLpLocker.sol";
import {
    IArtCoinsLpLockerMultiple
} from "../src/lp-lockers/interfaces/IArtCoinsLpLockerMultiple.sol";
import {ArtCoinsLpLockerMultiple} from "../src/lp-lockers/legacy/ArtCoinsLpLockerMultiple.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract MockLockerToken is ERC20 {
    constructor() ERC20("Locker Token", "LOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ArtCoinsLpLockerMultipleCapTest is Test {
    ArtCoinsLpLockerMultiple internal locker;
    MockLockerToken internal token;

    address internal owner = address(0xCAFE);
    address internal factory = address(0xFAC7);
    address internal feeLocker = address(0xFEE);
    address internal positionManager = address(0xF0F0);
    address internal permit2 = address(0xBEEF);
    address internal hook = address(0xABCD);

    function setUp() public {
        token = new MockLockerToken();
        locker = new ArtCoinsLpLockerMultiple(owner, factory, feeLocker, positionManager, permit2);
        vm.etch(positionManager, hex"60016001");
        vm.etch(permit2, hex"60016001");
    }

    function test_twelvePositionsSucceed() public {
        IArtCoinsFactory.LockerConfig memory lc = _lockerConfig(12);
        IArtCoinsFactory.PoolConfig memory pc = _poolConfig();
        PoolKey memory pk = _poolKey(pc.pairedToken);
        _mockExternalLpCalls();
        _fundAndApproveFactory(1_000_000e18);

        vm.prank(factory);
        uint256 positionId = locker.placeLiquidity(lc, pc, pk, 1_000_000e18, address(token));

        IArtCoinsLpLocker.TokenRewardInfo memory info = locker.tokenRewards(address(token));
        assertEq(positionId, 42);
        assertEq(info.positionId, 42);
        assertEq(info.numPositions, 12);
        assertEq(locker.MAX_LP_POSITIONS(), 12);
    }

    function test_thirteenPositionsRevert() public {
        IArtCoinsFactory.LockerConfig memory lc = _lockerConfig(13);
        IArtCoinsFactory.PoolConfig memory pc = _poolConfig();
        PoolKey memory pk = _poolKey(pc.pairedToken);
        _fundAndApproveFactory(1_000_000e18);

        vm.prank(factory);
        vm.expectRevert(IArtCoinsLpLockerMultiple.TooManyPositions.selector);
        locker.placeLiquidity(lc, pc, pk, 1_000_000e18, address(token));
    }

    function _fundAndApproveFactory(uint256 amount) internal {
        token.mint(factory, amount);
        vm.prank(factory);
        token.approve(address(locker), amount);
    }

    function _mockExternalLpCalls() internal {
        vm.mockCall(positionManager, abi.encodeWithSignature("nextTokenId()"), abi.encode(42));
        vm.mockCall(
            permit2,
            abi.encodeWithSignature(
                "approve(address,address,uint160,uint48)",
                address(token),
                positionManager,
                uint160(1_000_000e18),
                uint48(block.timestamp)
            ),
            abi.encode()
        );
        bytes4 modifySelector = bytes4(keccak256("modifyLiquidities(bytes,uint256)"));
        vm.mockCall(positionManager, abi.encodeWithSelector(modifySelector), abi.encode());
    }

    function _poolConfig() internal view returns (IArtCoinsFactory.PoolConfig memory pc) {
        pc = IArtCoinsFactory.PoolConfig({
            hook: hook,
            pairedToken: address(uint160(address(token)) + 1000),
            tickIfToken0IsArtCoins: 0,
            tickSpacing: 200,
            poolData: ""
        });
    }

    function _poolKey(address pairedToken) internal view returns (PoolKey memory pk) {
        pk = PoolKey({
            currency0: Currency.wrap(address(token)),
            currency1: Currency.wrap(pairedToken),
            fee: 0x800000,
            tickSpacing: 200,
            hooks: IHooks(hook)
        });
    }

    function _lockerConfig(uint256 positions)
        internal
        view
        returns (IArtCoinsFactory.LockerConfig memory lc)
    {
        address[] memory rewardAdmins = new address[](1);
        rewardAdmins[0] = owner;
        address[] memory rewardRecipients = new address[](1);
        rewardRecipients[0] = owner;
        uint16[] memory rewardBps = new uint16[](1);
        rewardBps[0] = 10_000;

        int24[] memory tickLower = new int24[](positions);
        int24[] memory tickUpper = new int24[](positions);
        uint16[] memory positionBps = new uint16[](positions);
        uint16 bpsSum = 0;
        for (uint256 i = 0; i < positions; i++) {
            tickLower[i] = int24(int256(i * 200));
            tickUpper[i] = int24(int256((i + 1) * 200));
            positionBps[i] = uint16(10_000 / positions);
            bpsSum += positionBps[i];
        }
        positionBps[positions - 1] += 10_000 - bpsSum;

        lc = IArtCoinsFactory.LockerConfig({
            locker: address(locker),
            rewardAdmins: rewardAdmins,
            rewardRecipients: rewardRecipients,
            rewardBps: rewardBps,
            tickLower: tickLower,
            tickUpper: tickUpper,
            positionBps: positionBps,
            lockerData: ""
        });
    }
}
