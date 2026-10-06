// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @notice plain 18 decimal erc20 standing in for an artcoin or LAYER.
contract ReviewToken is ERC20, ERC20Burnable {
    constructor(string memory n) ERC20(n, n) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice minimal canonical-weth stand-in (deposit / withdraw).
contract ReviewWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "weth: eth send failed");
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}

/// @notice permit2 AllowanceTransfer subset. lib/permit2 pins solc 0.8.17 exactly,
///         which this build (0.8.26 only) cannot compile, so the two calls the
///         locker and PositionManager make are reimplemented here with the same
///         semantics (allowance + expiration per owner/token/spender).
contract Permit2Stub {
    struct Allow {
        uint160 amount;
        uint48 expiration;
    }

    mapping(address owner => mapping(address token => mapping(address spender => Allow))) public
        allowance;

    function approve(address token, address spender, uint160 amount, uint48 expiration) external {
        allowance[msg.sender][token][spender] = Allow(amount, expiration);
    }

    function transferFrom(address from, address to, uint160 amount, address token) external {
        Allow storage a = allowance[from][token][msg.sender];
        require(block.timestamp <= a.expiration, "permit2: expired");
        require(a.amount >= amount, "permit2: allowance");
        if (a.amount != type(uint160).max) a.amount -= amount;
        IERC20(token).transferFrom(from, to, amount);
    }
}
