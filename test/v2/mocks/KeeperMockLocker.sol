// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {KeeperMockCoin} from "./KeeperMockCoin.sol";

/// @dev Stub locker. `collectRewards` pays a keeper reward (eth and coin) to `msg.sender`, like the real locker
///      does to the keeper that calls it. Fund it with eth before use.
contract KeeperMockLocker {
    address[] internal _recipients;
    uint256 public ethReward;
    uint256 public coinReward;
    uint256 public burn;
    bool public failCollect;
    uint256 public collectCalls;
    KeeperMockCoin public coin;

    constructor(KeeperMockCoin coin_) {
        coin = coin_;
    }

    receive() external payable {}

    function setRecipients(address[] calldata r) external {
        _recipients = r;
    }

    function setRewards(uint256 eth_, uint256 coin_) external {
        ethReward = eth_;
        coinReward = coin_;
    }

    function setBurn(uint256 gasToBurn) external {
        burn = gasToBurn;
    }

    function setFailCollect(bool v) external {
        failCollect = v;
    }

    function resetCalls() external {
        collectCalls = 0;
    }

    function collectRewards(address) external {
        if (failCollect) revert("nothing to collect");
        ++collectCalls;
        uint256 start = gasleft();
        while (start - gasleft() < burn) {}
        if (coinReward > 0) coin.mint(msg.sender, coinReward);
        if (ethReward > 0) {
            (bool ok,) = msg.sender.call{value: ethReward}("");
            require(ok, "reward push failed");
        }
    }

    function rewardRecipients(address) external view returns (address[] memory) {
        return _recipients;
    }
}
