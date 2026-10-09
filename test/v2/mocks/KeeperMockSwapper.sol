// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsKeeperV2} from "../../../src/v2/interfaces/IArtCoinsKeeperV2.sol";
import {IFeeAutoSwapperV2} from "../../../src/v2/interfaces/IFeeAutoSwapperV2.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @dev Stub fee swapper with erc165. Pays keeper rewards in eth to `msg.sender`. Fund it with eth before use.
contract KeeperMockSwapper is IERC165 {
    uint256 public flushReward;
    uint256 public convertReward;
    uint256 public flushOut;
    uint256 public convertOut;
    uint256 public flushBurn;
    uint256 public convertBurn;
    bool public flushReverts;
    bool public convertReverts;
    uint256 public flushCalls;
    uint256 public convertCalls;
    uint256 public lastMinOut;
    uint256 public accruedPaired;
    uint256 public accruedCoin;
    uint256 public nextConvertibleBlock;
    /// @dev when set, flush tries to reenter the keeper and records the revert data
    address public reenterKeeper;
    address public reenterToken;
    bytes public reenterRevertData;
    bool public reenterSucceeded;

    receive() external payable {}

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IERC165).interfaceId || id == type(IFeeAutoSwapperV2).interfaceId;
    }

    function set(
        uint256 flushReward_,
        uint256 convertReward_,
        uint256 flushOut_,
        uint256 convertOut_
    ) external {
        flushReward = flushReward_;
        convertReward = convertReward_;
        flushOut = flushOut_;
        convertOut = convertOut_;
    }

    function setBurn(uint256 flushBurn_, uint256 convertBurn_) external {
        flushBurn = flushBurn_;
        convertBurn = convertBurn_;
    }

    function setReverts(bool flush_, bool convert_) external {
        flushReverts = flush_;
        convertReverts = convert_;
    }

    function setAccrued(uint256 paired, uint256 coin_, uint256 nextBlock) external {
        accruedPaired = paired;
        accruedCoin = coin_;
        nextConvertibleBlock = nextBlock;
    }

    function setReenter(address keeper, address token) external {
        reenterKeeper = keeper;
        reenterToken = token;
    }

    function resetCalls() external {
        flushCalls = 0;
        convertCalls = 0;
        lastMinOut = 0;
    }

    function flushPaired() external returns (uint256) {
        if (flushReverts) revert IFeeAutoSwapperV2.NothingToFlush();
        ++flushCalls;
        _burn(flushBurn);
        if (reenterKeeper != address(0)) {
            try IArtCoinsKeeperV2(reenterKeeper).collectAndForward(reenterToken, false, 0) {
                reenterSucceeded = true;
            } catch (bytes memory r) {
                reenterRevertData = r;
            }
        }
        _pay(flushReward);
        return flushOut;
    }

    function convert(uint256 minOut) external returns (uint256) {
        if (convertReverts) revert IFeeAutoSwapperV2.ConvertTooEarly(block.number + 50);
        ++convertCalls;
        lastMinOut = minOut;
        _burn(convertBurn);
        _pay(convertReward);
        return convertOut;
    }

    function _burn(uint256 amount) internal view {
        uint256 start = gasleft();
        while (start - gasleft() < amount) {}
    }

    function _pay(uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "reward push failed");
    }
}

/// @dev Recipient with no erc165: every call reverts with empty data (like a treasury that only takes eth).
contract KeeperMockPlainRecipient {
    receive() external payable {}
}

/// @dev Answers supportsInterface with false for everything and counts any other call.
contract KeeperMockNotSwapper {
    uint256 public otherCalls;

    function supportsInterface(bytes4) external pure returns (bool) {
        return false;
    }

    fallback() external payable {
        ++otherCalls;
    }
}

/// @dev Claims the swapper interface, then burns all gas in the probe. The keeper caps the probe at 30k.
contract KeeperMockGasBurnerRecipient {
    function supportsInterface(bytes4) external pure returns (bool) {
        while (true) {}
        return true;
    }
}

/// @dev Returns two words (first is 1) from any call. A probe that accepts it would mistake it for a swapper.
contract KeeperMockWideReturnRecipient {
    fallback() external {
        assembly {
            mstore(0, 1)
            return(0, 64)
        }
    }
}
