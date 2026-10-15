// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Constants} from "../../Constants.sol";
import {IArtCoinsExtensionV2} from "../interfaces/IArtCoinsExtensionV2.sol";
import {IArtCoinsFactoryV2} from "../interfaces/IArtCoinsFactoryV2.sol";
import {IArtCoinsFeeEscrowV2} from "../interfaces/IArtCoinsFeeEscrowV2.sol";
import {IArtCoinsHookV2} from "../interfaces/IArtCoinsHookV2.sol";
import {IConstantsBound} from "../interfaces/IConstantsBound.sol";
import {IArtCoinsUniv4EthDevBuyV2} from "./interfaces/IArtCoinsUniv4EthDevBuyV2.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title  ArtCoinsUniv4EthDevBuyV2
/// @notice Buys the new coin with the extension's `msgValue` from its own
///         native eth pool during the launch tx and sends it to a recipient.
/// @dev    The swap goes to the PoolManager directly: `unlock`, `swap`, `settle`
///         eth, `take` coin to the recipient. The factory passes the key of the
///         pool it just created. `receiveTokens` checks it against the launch
///         hook and the coin (currency0 native eth, currency1 the coin).
///         - `minTokenOut` from `extensionData` is nonzero. The deployer computes
///           it from the exact pool curve. The pool is created in the launch tx,
///           so the floor covers a miscalculated config and earlier extensions
///           in the same launch.
///         - The swap pays the hook skim in force like any trader. Extensions
///           run before `initializeMevModule`, so the skim is the pool baseline.
///         - The price limit is the pool boundary, so a partial fill happens
///           only when the buy exhausts all liquidity. Unspent eth goes to
///           `refundRecipient` from `extensionData`.
///         - The hook credits unused skim to this contract in the fee escrow,
///           because this contract is the PoolManager caller. The contract sets
///           `selfClaimOnly` on that escrow before the swap. After the swap it
///           claims its credit to itself, and a failed claim reverts the launch.
///           `receive` accepts eth from the escrow during the claim only.
///         - The refund is the whole eth balance after the claim, so the
///           contract holds zero eth and zero credit in the current escrow after
///           each launch. Credit left in a previous escrow stays there. The hook
///           owner chooses the escrow with `setFeeEscrow`.
contract ArtCoinsUniv4EthDevBuyV2 is ReentrancyGuard, IUnlockCallback, IArtCoinsUniv4EthDevBuyV2 {
    /// @notice The only caller of `receiveTokens`.
    address public immutable factory;
    /// @notice The Uniswap v4 PoolManager the pools live on.
    IPoolManager public immutable poolManager;

    /// @dev Transient slot holding the escrow whose claim payout `receive`
    ///      accepts. Set around the claim call.
    uint256 private constant _PAYER_SLOT = uint256(keccak256("ArtCoinsUniv4EthDevBuyV2.payer"));
    /// @dev Escrows this contract has opted into `selfClaimOnly` on.
    mapping(address escrow => bool) private _optedIn;

    modifier onlyFactory() {
        if (msg.sender != factory) revert Unauthorized();
        _;
    }

    /// @param factory_ The v2 factory. Immutable.
    /// @param poolManager_ The PoolManager. Immutable.
    constructor(address factory_, address poolManager_) {
        if (factory_ == address(0) || poolManager_ == address(0)) revert ZeroAddress();
        factory = factory_;
        poolManager = IPoolManager(poolManager_);
    }

    /// @dev Receives the escrow claim payout in `receiveTokens`.
    receive() external payable {
        uint256 payer;
        uint256 slot = _PAYER_SLOT;
        assembly ("memory-safe") {
            payer := tload(slot)
        }
        if (payer == 0 || msg.sender != address(uint160(payer))) revert UnexpectedEth();
    }

    /// @inheritdoc IArtCoinsExtensionV2
    function receiveTokens(
        IArtCoinsFactoryV2.DeploymentConfigV2 calldata config,
        PoolKey calldata poolKey,
        address token,
        uint256 extensionSupply,
        uint256 extensionIndex
    ) external payable nonReentrant onlyFactory {
        IArtCoinsFactoryV2.ExtensionConfigV2 calldata e = config.extensions[extensionIndex];
        if (e.extension != address(this)) revert WrongExtensionEntry();
        if (e.msgValue != msg.value || msg.value == 0) revert InvalidMsgValue();
        if (e.extensionBps != 0 || extensionSupply != 0) revert InvalidDevBuyBps();
        if (e.extensionData.length != 96) revert InvalidExtensionData();

        (address recipient, address refundRecipient, uint128 minOut) =
            abi.decode(e.extensionData, (address, address, uint128));
        if (recipient == address(0) || refundRecipient == address(0)) revert ZeroRecipient();
        if (minOut == 0) revert ZeroMinOut();

        if (
            Currency.unwrap(poolKey.currency0) != address(0)
                || Currency.unwrap(poolKey.currency1) != token
                || address(poolKey.hooks) != config.pool.hook
        ) revert InvalidPoolKey();

        address escrow = _escrowOf(poolKey);
        if (escrow != address(0) && !_optedIn[escrow]) {
            _optedIn[escrow] = true;
            IArtCoinsFeeEscrowV2(escrow).setSelfClaimOnly(true);
        }

        (uint256 spent, uint256 out) = abi.decode(
            poolManager.unlock(abi.encode(poolKey, msg.value, recipient, minOut)),
            (uint256, uint256)
        );

        if (escrow != address(0) && _credit(escrow) != 0) {
            uint256 slot = _PAYER_SLOT;
            assembly ("memory-safe") {
                tstore(slot, escrow)
            }
            IArtCoinsFeeEscrowV2(escrow).claimTo(address(this), address(0), payable(this));
            assembly ("memory-safe") {
                tstore(slot, 0)
            }
        }
        uint256 refunded = address(this).balance;
        if (refunded != 0) {
            (bool ok,) = refundRecipient.call{value: refunded}("");
            if (!ok) revert NativeTransferFailed();
        }

        emit EthDevBuy(token, recipient, spent, out, refunded, refundRecipient);
    }

    /// @notice PoolManager callback. Only reachable through `receiveTokens`:
    ///         only this contract calls `unlock`, and only the PoolManager calls back.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, uint256 amountIn, address recipient, uint256 minOut) =
            abi.decode(data, (PoolKey, uint256, address, uint256));

        BalanceDelta delta = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );

        uint256 spent = uint256(uint128(-delta.amount0()));
        uint256 out = uint256(uint128(delta.amount1()));
        if (out < minOut) revert SlippageExceeded(out, minOut);

        poolManager.settle{value: spent}();
        poolManager.take(key.currency1, recipient, out);
        return abi.encode(spent, out);
    }

    /// @inheritdoc IConstantsBound
    function constantsHash() external pure returns (bytes32) {
        return Constants.hash();
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IArtCoinsExtensionV2).interfaceId
            || interfaceId == type(IArtCoinsUniv4EthDevBuyV2).interfaceId
            || interfaceId == type(IConstantsBound).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    /// @dev Fee escrow of the pool's v2 hook, or zero for a hookless pool, a
    ///      foreign hook or an escrow without code.
    function _escrowOf(PoolKey calldata key) private view returns (address escrow) {
        address hook = address(key.hooks);
        if (hook.code.length == 0) return address(0);
        try IArtCoinsHookV2(hook).globals() returns (IArtCoinsHookV2.HookGlobals memory g) {
            if (g.feeEscrow.code.length != 0) escrow = g.feeEscrow;
        } catch {}
    }

    /// @dev Native credit of this contract in `escrow`.
    function _credit(address escrow) private view returns (uint256) {
        return IArtCoinsFeeEscrowV2(escrow).balances(address(this), address(0));
    }
}
