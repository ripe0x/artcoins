// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsExtension} from "../interfaces/IArtCoinsExtension.sol";
import {IArtCoinsFactory} from "../interfaces/IArtCoinsFactory.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title BurnExtension
/// @notice Factory deploy-time extension that immediately burns its full token
///         allocation. Used for the LAYER continuity burn (260.2M) and any
///         future artcoin that wants a launch-time burn.
/// @dev    Conforms to IArtCoinsExtension. Pulls tokens from the factory via
///         the standard pre-approved-allowance pattern, then calls `burn()`
///         on the token (relies on ArtCoinsToken being ERC20Burnable).
contract BurnExtension is IArtCoinsExtension {
    /// @notice Reverts when a non-factory caller invokes `receiveTokens`.
    error Unauthorized();
    /// @notice Reverts when factory passes nonzero msg.value (burn never needs ETH).
    error UnexpectedMsgValue();
    /// @notice Reverts when factory passes zero supply (must be > 0 to burn).
    error ZeroSupply();

    /// @notice The factory authorized to call `receiveTokens`.
    address public immutable factory;

    /// @notice Emitted when a token's continuity burn executes.
    /// @param token The token that was burned.
    /// @param amount The amount burned (in wei).
    event TokensBurned(address indexed token, uint256 amount);

    /// @param factory_ The ArtCoins factory address.
    constructor(address factory_) {
        factory = factory_;
    }

    /// @inheritdoc IArtCoinsExtension
    /// @dev Pulls `extensionSupply` of `token` from the factory and burns it.
    ///      Burns via `ERC20Burnable.burn(amount)` from this contract's balance,
    ///      so the burn is reflected in the token's `totalSupply()` immediately
    ///      after deployment. The amount burned is exactly the share allocated
    ///      via `extensionBps × totalSupply / 10_000`.
    function receiveTokens(
        IArtCoinsFactory.DeploymentConfig calldata,
        PoolKey memory,
        address token,
        uint256 extensionSupply,
        uint256
    ) external payable {
        if (msg.sender != factory) revert Unauthorized();
        if (msg.value != 0) revert UnexpectedMsgValue();
        if (extensionSupply == 0) revert ZeroSupply();

        // Pull tokens from factory (factory pre-approves before calling).
        SafeERC20.safeTransferFrom(IERC20(token), factory, address(this), extensionSupply);

        // Burn from this contract's balance.
        ERC20Burnable(token).burn(extensionSupply);

        emit TokensBurned(token, extensionSupply);
    }

    /// @notice ERC-165 introspection.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IArtCoinsExtension).interfaceId || interfaceId == 0x01ffc9a7; // IERC165
    }
}
