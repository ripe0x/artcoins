// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title LiquiditySupportReceiver
/// @notice Minimal holder for the project-side "liquidity support" allocation.
///         Receives LAYER and WETH (or any ERC20) and exposes balances. The
///         actual `processAddLiquidity()` path — which would add liquidity
///         back to the canonical LAYER/WETH pool — is intentionally a TODO
///         in this pass, to keep the surface area small and audited.
///
///         For now, the admin (multisig) can sweep accumulated balances to
///         a designated future liquidity-add contract via `adminWithdraw`.
///         The contract explicitly does NOT send funds to a deployer EOA by
///         default — `adminWithdraw` requires an explicit recipient that the
///         admin chooses each time.
/// @dev    LAYER's project-side allocates 12.5% of the project share (= 0.10%
///         of trading volume at 1% total fee) to this contract.
contract LiquiditySupportReceiver is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Reverts when zero address is supplied where a real account is required.
    error ZeroAddress();
    /// @notice Reverts when a withdrawal exceeds the contract's balance.
    error InsufficientBalance();
    /// @notice Reverts when ETH transfer fails.
    error EthTransferFailed();

    /// @notice The LAYER token address (immutable, set at construction).
    address public immutable layerToken;
    /// @notice The WETH address (immutable, set at construction).
    address public immutable weth;

    /// @notice Emitted when the admin sweeps a balance to a recipient.
    /// @param token The token swept (or address(0) for native ETH).
    /// @param recipient The recipient address.
    /// @param amount The amount transferred.
    event AdminWithdraw(address indexed token, address indexed recipient, uint256 amount);
    /// @notice Emitted when the contract receives ETH.
    /// @param from The sender of the ETH.
    /// @param amount The amount received.
    event EthReceived(address indexed from, uint256 amount);

    /// @param owner_ Initial admin (recommend multisig).
    /// @param layerToken_ The LAYER token address.
    /// @param weth_ The WETH address on this chain.
    constructor(address owner_, address layerToken_, address weth_) Ownable(owner_) {
        if (owner_ == address(0) || layerToken_ == address(0) || weth_ == address(0)) {
            revert ZeroAddress();
        }
        layerToken = layerToken_;
        weth = weth_;
    }

    /// @notice Returns this contract's LAYER and WETH balances in one call.
    /// @return layer LAYER balance.
    /// @return wethBalance WETH balance.
    function balances() external view returns (uint256 layer, uint256 wethBalance) {
        layer = IERC20(layerToken).balanceOf(address(this));
        wethBalance = IERC20(weth).balanceOf(address(this));
    }

    /// @notice Returns the balance of an arbitrary ERC20 held here.
    /// @param token The ERC20 address.
    /// @return The token balance.
    function balanceOf(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /// @notice Sweeps an ERC20 balance to a chosen recipient. Admin only.
    /// @dev    The recipient is supplied per-call so the admin can route to
    ///         a future liquidity-add contract without ever embedding a
    ///         hard-coded EOA. Admin authority is presumed multisig-held.
    /// @param token The ERC20 to withdraw.
    /// @param recipient The recipient address.
    /// @param amount The amount to withdraw.
    function adminWithdraw(address token, address recipient, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        if (recipient == address(0)) revert ZeroAddress();
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (amount > bal) revert InsufficientBalance();

        IERC20(token).safeTransfer(recipient, amount);
        emit AdminWithdraw(token, recipient, amount);
    }

    /// @notice Sweeps native ETH to a chosen recipient. Admin only.
    /// @dev    Included as a safety hatch — accumulated WETH is the expected
    ///         currency, but if ETH ever lands here (e.g. via selfdestruct
    ///         or coinbase rewards), the admin can recover it.
    /// @param recipient The recipient address.
    /// @param amount The amount to withdraw.
    function adminWithdrawEth(address payable recipient, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount > address(this).balance) revert InsufficientBalance();

        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit AdminWithdraw(address(0), recipient, amount);
    }

    /// @notice Accept ETH (e.g. from WETH unwrap or stray transfers).
    receive() external payable {
        emit EthReceived(msg.sender, msg.value);
    }
}
