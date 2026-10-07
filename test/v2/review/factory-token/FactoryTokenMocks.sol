// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsFactory} from "../../../../src/interfaces/IArtCoinsFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice minimal hook stand in. builds the pool key exactly like the real
///         hook does (sorted currencies, dynamic fee flag, this as hooks) and
///         records it. no pool manager involved.
contract FTMockHook {
    PoolKey public lastKey;

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }

    function initializePool(
        address artCoin,
        address pairedToken,
        int24,
        int24 tickSpacing,
        address,
        address,
        bytes calldata
    ) external returns (PoolKey memory key) {
        (address c0, address c1) =
            artCoin < pairedToken ? (artCoin, pairedToken) : (pairedToken, artCoin);
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 0x800000,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(this))
        });
        lastKey = key;
    }

    function lastKeyId() external view returns (bytes32) {
        return keccak256(abi.encode(lastKey));
    }

    function initializeMevModule(PoolKey calldata, bytes calldata) external {}

    function factorySetSniperFeeRecipient(PoolKey calldata, address, bool) external {}
}

/// @notice locker stand in. pulls the pool supply and records the reward
///         arrays the factory hands it (after protocol slot injection).
contract FTMockLocker {
    address[] internal _admins;
    address[] internal _recipients;
    uint16[] internal _bps;

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }

    function placeLiquidity(
        IArtCoinsFactory.LockerConfig memory lc,
        IArtCoinsFactory.PoolConfig memory,
        PoolKey memory,
        uint256 poolSupply,
        address token
    ) external returns (uint256) {
        IERC20(token).transferFrom(msg.sender, address(this), poolSupply);
        _admins = lc.rewardAdmins;
        _recipients = lc.rewardRecipients;
        _bps = lc.rewardBps;
        return 1;
    }

    function recipients() external view returns (address[] memory) {
        return _recipients;
    }

    function admins() external view returns (address[] memory) {
        return _admins;
    }

    function bps() external view returns (uint16[] memory) {
        return _bps;
    }
}

/// @notice extension stand in. pulls its allocation into itself and forwards
///         it to `beneficiary` (models a vault or dev buy that pays a chosen
///         address). `iface` lets a test flip its erc165 answer.
contract FTMockExtension {
    bool public iface = true;
    uint256 public ethReceived;
    address public beneficiary;

    function setIface(bool v) external {
        iface = v;
    }

    function setBeneficiary(address b) external {
        beneficiary = b;
    }

    function supportsInterface(bytes4) external view returns (bool) {
        return iface;
    }

    function receiveTokens(
        IArtCoinsFactory.DeploymentConfig calldata,
        PoolKey memory,
        address token,
        uint256 supply,
        uint256
    ) external payable {
        ethReceived += msg.value;
        IERC20(token).transferFrom(msg.sender, address(this), supply);
        if (beneficiary != address(0)) IERC20(token).transfer(beneficiary, supply);
    }
}

/// @notice a fee owner contract that can redirect its escrow balance via
///         `claimTo` but has no way to move an erc20 it already holds.
contract FTEscrowFeeOwner {
    function redirect(address escrow, address token, address payable to) external {
        (bool ok, bytes memory ret) = escrow.call(
            abi.encodeWithSignature("claimTo(address,address,address)", address(this), token, to)
        );
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}
