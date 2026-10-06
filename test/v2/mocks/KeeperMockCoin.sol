// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract KeeperMockCoin is ERC20 {
    bool public failTransfers;

    constructor() ERC20("Keeper Coin", "KC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFailTransfers(bool v) external {
        failTransfers = v;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!(failTransfers && from != address(0)), "transfers disabled");
        super._update(from, to, value);
    }
}
