// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {
    IUniversalRouter
} from "../../../lib/universal-router/contracts/interfaces/IUniversalRouter.sol";
import {Commands} from "../../../lib/universal-router/contracts/libraries/Commands.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";

/// @title BurnRouter
/// @notice The LAYER buy-and-burn engine. Receives LAYER and WETH, swaps
///         accumulated WETH for LAYER through the canonical LAYER/WETH pool,
///         and burns the resulting LAYER. Direct LAYER deposits are burned
///         straight away. Native ETH is wrapped on receive.
/// @dev    Initialization is one-shot and admin-gated. After initialization,
///         `layerToken` and `canonicalPoolKey` are immutable in effect — there
///         is no setter for either. The admin can adjust the minimum
///         processing threshold and pause the contract.
///
///         `processBurnWeth(minLayerOut)` is permissionless. The owner sets a
///         minimum LAYER-per-WETH floor and callers must provide a slippage
///         bound at least that strict; the V4 router then enforces the bound
///         with its `V4TooLittleReceived` revert. A minimum-threshold guard
///         prevents spam-burns of trivial WETH amounts.
///
///         **Cross-artcoin conversion is intentionally NOT supported.** Any
///         non-LAYER, non-WETH ERC20 that arrives here (e.g. fees from a
///         second artcoin's protocol slot) is **held in custody** — it is
///         never automatically swapped or burned. The only way to move
///         held tokens out is `adminSweepHeldToken(token, recipient)`,
///         which an admin (recommend: multisig) can call to send them to
///         a designated address. This is explicit by design: the protocol
///         does not try to guess the right conversion path for arbitrary
///         tokens, and never burns the wrong asset by accident.
contract BurnRouter is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── errors ──────────────────────────────────────────────────────────

    error AlreadyInitialized();
    error NotInitialized();
    error ZeroAddress();
    error InvalidPoolKey();
    error BlockedToken(address token);
    error BelowMinThreshold(uint256 wethBalance, uint256 minThreshold);
    error MinThresholdTooLow();
    error SlippageFloorNotSet();
    error MinLayerOutBelowFloor(uint256 suppliedMinLayerOut, uint256 requiredMinLayerOut);
    error NothingToBurn();
    error EthTransferFailed();

    // ─── events ──────────────────────────────────────────────────────────

    event BurnRouterInitialized(
        address indexed layerToken,
        address indexed weth,
        address indexed universalRouter,
        address permit2,
        PoolKey poolKey
    );
    event LayerBurnedDirectly(uint256 amount);
    event WethProcessedForLayerBurn(uint256 wethIn, uint256 layerOut);
    event LayerPurchasedAndBurned(uint256 layerAmount);
    event MinThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event MinLayerOutPerWethUpdated(uint256 oldFloor, uint256 newFloor);
    event EthReceived(address indexed from, uint256 amount);
    /// @notice Emitted when an admin sweeps a held non-LAYER, non-WETH token.
    /// @dev Held tokens are never converted by this contract. They sit until
    ///      an admin explicitly moves them.
    event HeldTokenSwept(address indexed token, address indexed to, uint256 amount);

    // ─── immutable-after-init state ──────────────────────────────────────

    /// @notice The LAYER token address, set at `initialize`. Immutable after.
    address public layerToken;
    /// @notice The WETH address on this chain, set at `initialize`. Immutable after.
    address public weth;
    /// @notice The Uniswap Universal Router. Immutable after init.
    IUniversalRouter public universalRouter;
    /// @notice Permit2 (allowance manager). Immutable after init.
    IAllowanceTransfer public permit2;
    /// @notice The canonical LAYER/WETH pool key. Immutable after init.
    PoolKey public canonicalPoolKey;
    /// @notice True if `weth` sorts as currency0 in the canonical pool.
    bool public wethIsCurrency0;
    /// @notice True after `initialize` runs.
    bool public initialized;

    // ─── mutable admin state ─────────────────────────────────────────────

    /// @notice Minimum WETH balance required before `processBurn` will execute a swap.
    /// @dev    Default: 0.01 ETH. Admin can adjust within bounds.
    uint256 public minProcessThreshold = 0.01 ether;
    /// @notice Lower bound for `minProcessThreshold` — guards against being set so
    ///         low that processing becomes net-negative due to gas + slippage.
    uint256 public constant MIN_THRESHOLD_FLOOR = 1e15; // 0.001 ETH
    /// @notice Owner-set minimum LAYER output required per 1 WETH input.
    /// @dev    Scaled by 1e18. Zero pauses WETH processing by causing
    ///         `processBurnWeth` to revert with `SlippageFloorNotSet`.
    uint256 public minLayerOutPerWeth;

    /// @param owner_ Initial admin (recommend multisig).
    constructor(address owner_) Ownable(owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
    }

    // ─── initialization ──────────────────────────────────────────────────

    /// @notice One-time setup binding the router to LAYER, WETH, and the canonical
    ///         LAYER/WETH pool. After this call, `layerToken` cannot change.
    /// @dev    The pool key's currencies must be exactly (LAYER, WETH) in either
    ///         sort order. The function rejects any other configuration.
    /// @param layerToken_ The deployed LAYER token address.
    /// @param weth_ The WETH address on this chain.
    /// @param universalRouter_ The Uniswap Universal Router address.
    /// @param permit2_ The Permit2 address.
    /// @param canonicalPoolKey_ The PoolKey of the LAYER/WETH pool.
    function initialize(
        address layerToken_,
        address weth_,
        address universalRouter_,
        address permit2_,
        PoolKey calldata canonicalPoolKey_
    ) external onlyOwner {
        if (initialized) revert AlreadyInitialized();
        if (
            layerToken_ == address(0) || weth_ == address(0) || universalRouter_ == address(0)
                || permit2_ == address(0)
        ) revert ZeroAddress();

        // Validate pool key currencies match (LAYER, WETH) in some order.
        address c0 = Currency.unwrap(canonicalPoolKey_.currency0);
        address c1 = Currency.unwrap(canonicalPoolKey_.currency1);
        bool layerC0 = (c0 == layerToken_ && c1 == weth_);
        bool wethC0 = (c0 == weth_ && c1 == layerToken_);
        if (!layerC0 && !wethC0) revert InvalidPoolKey();

        layerToken = layerToken_;
        weth = weth_;
        universalRouter = IUniversalRouter(universalRouter_);
        permit2 = IAllowanceTransfer(permit2_);
        canonicalPoolKey = canonicalPoolKey_;
        wethIsCurrency0 = wethC0;
        initialized = true;

        // Pre-approve permit2 to pull WETH from this contract for swaps.
        IERC20(weth_).forceApprove(permit2_, type(uint256).max);

        emit BurnRouterInitialized(
            layerToken_, weth_, universalRouter_, permit2_, canonicalPoolKey_
        );
    }

    /// @notice Updates the minimum WETH threshold required to swap. Admin only.
    /// @param newThreshold The new threshold in WETH wei.
    function setMinThreshold(uint256 newThreshold) external onlyOwner {
        if (newThreshold < MIN_THRESHOLD_FLOOR) revert MinThresholdTooLow();
        uint256 old = minProcessThreshold;
        minProcessThreshold = newThreshold;
        emit MinThresholdUpdated(old, newThreshold);
    }

    /// @notice Updates the minimum acceptable LAYER output per 1 WETH input.
    ///         Admin only. Set to 0 to pause WETH processing.
    /// @param newFloor Minimum LAYER out per WETH, scaled by 1e18.
    function setMinLayerOutPerWeth(uint256 newFloor) external onlyOwner {
        uint256 old = minLayerOutPerWeth;
        minLayerOutPerWeth = newFloor;
        emit MinLayerOutPerWethUpdated(old, newFloor);
    }

    // ─── permissionless burn paths ───────────────────────────────────────

    /// @notice Burns all LAYER currently held by this contract. Permissionless.
    /// @dev    Reverts with `NothingToBurn` if balance is zero.
    function processBurnLayer() external nonReentrant returns (uint256 burned) {
        if (!initialized) revert NotInitialized();
        burned = IERC20(layerToken).balanceOf(address(this));
        if (burned == 0) revert NothingToBurn();
        ERC20Burnable(layerToken).burn(burned);
        emit LayerBurnedDirectly(burned);
    }

    /// @notice Swaps the contract's WETH balance for LAYER, then burns the LAYER.
    ///         Permissionless. The caller supplies `minLayerOut` for slippage
    ///         protection — the V4 router reverts if not met.
    /// @dev    Wraps any native ETH in the contract to WETH first, so callers
    ///         can poll based on WETH balance. Approves the universal router
    ///         via Permit2 for the exact amount before each call.
    /// @param minLayerOut Minimum LAYER expected from the swap (slippage bound).
    /// @return wethIn WETH amount swapped.
    /// @return layerBurned LAYER bought and burned.
    function processBurnWeth(uint256 minLayerOut)
        external
        nonReentrant
        returns (uint256 wethIn, uint256 layerBurned)
    {
        if (!initialized) revert NotInitialized();

        // Wrap any native ETH first.
        uint256 ethBal = address(this).balance;
        if (ethBal > 0) IWETH9(payable(weth)).deposit{value: ethBal}();

        wethIn = IERC20(weth).balanceOf(address(this));
        if (wethIn < minProcessThreshold) {
            revert BelowMinThreshold(wethIn, minProcessThreshold);
        }
        uint256 floor = minLayerOutPerWeth;
        if (floor == 0) revert SlippageFloorNotSet();
        uint256 requiredMinLayerOut = Math.mulDiv(wethIn, floor, 1e18);
        if (minLayerOut < requiredMinLayerOut) {
            revert MinLayerOutBelowFloor(minLayerOut, requiredMinLayerOut);
        }

        // Approve universal router via Permit2 for this call.
        permit2.approve(
            weth, address(universalRouter), uint160(wethIn), uint48(block.timestamp + 1)
        );

        // Build the V4 single-hop exact-in swap.
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)
        );
        bytes[] memory params = new bytes[](3);
        // SWAP_EXACT_IN_SINGLE: pay WETH (zeroForOne = wethIsCurrency0), receive LAYER
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: canonicalPoolKey,
                zeroForOne: wethIsCurrency0,
                amountIn: uint128(wethIn),
                amountOutMinimum: uint128(minLayerOut),
                hookData: bytes("")
            })
        );
        // SETTLE_ALL: pay WETH (the input currency)
        params[1] = abi.encode(Currency.wrap(weth), wethIn);
        // TAKE_ALL: receive LAYER (the output currency) into this contract
        params[2] = abi.encode(Currency.wrap(layerToken), minLayerOut);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        uint256 layerBefore = IERC20(layerToken).balanceOf(address(this));
        universalRouter.execute(commands, inputs, block.timestamp);
        uint256 layerAfter = IERC20(layerToken).balanceOf(address(this));
        layerBurned = layerAfter - layerBefore;

        // Burn whatever we received (plus any prior dust).
        ERC20Burnable(layerToken).burn(layerAfter);

        emit WethProcessedForLayerBurn(wethIn, layerBurned);
        emit LayerPurchasedAndBurned(layerAfter);
    }

    // ─── admin escape: sweep held non-LAYER, non-WETH tokens ─────────────

    /// @notice Sweeps a held (non-LAYER, non-WETH) ERC20 to a chosen recipient.
    ///         Admin only. The contract never converts or burns these tokens
    ///         on its own — `adminSweepHeldToken` is the only way to move them.
    ///         A future protocol upgrade may add permissionless conversion
    ///         (artcoin → WETH → LAYER) by replacing this contract via
    ///         `ProtocolFeeController.setBurnRouter`.
    /// @param token The held token to sweep. Must not be LAYER or WETH —
    ///        those have dedicated processing paths (`processBurnLayer`,
    ///        `processBurnWeth`).
    /// @param recipient The address to receive the swept tokens.
    /// @param amount The amount to send.
    function adminSweepHeldToken(address token, address recipient, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        if (!initialized) revert NotInitialized();
        if (recipient == address(0)) revert ZeroAddress();
        if (token == layerToken || token == weth) revert BlockedToken(token);
        IERC20(token).safeTransfer(recipient, amount);
        emit HeldTokenSwept(token, recipient, amount);
    }

    /// @notice Returns the contract's balance of an arbitrary token. Convenience
    ///         view for monitoring held non-LAYER, non-WETH tokens. For LAYER
    ///         and WETH balances, prefer `status()` which also returns the
    ///         WETH-burn readiness flag.
    /// @param token The token to query.
    /// @return The balance held by this contract.
    function heldBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    // ─── views ───────────────────────────────────────────────────────────

    /// @notice Returns the current minimum LAYER output required for the
    ///         contract's whole WETH balance.
    function requiredMinLayerOutForCurrentWethBalance() public view returns (uint256) {
        if (!initialized) return 0;
        return requiredMinLayerOutForWethAmount(IERC20(weth).balanceOf(address(this)));
    }

    /// @notice Returns the minimum LAYER output required for a given WETH input.
    /// @param wethAmount WETH input amount.
    function requiredMinLayerOutForWethAmount(uint256 wethAmount) public view returns (uint256) {
        uint256 floor = minLayerOutPerWeth;
        if (floor == 0) return 0;
        return Math.mulDiv(wethAmount, floor, 1e18);
    }

    /// @notice Returns LAYER and WETH balances and whether processing is ready.
    /// @return layer LAYER balance.
    /// @return wethBalance WETH balance.
    /// @return readyForWethBurn True if WETH balance ≥ minProcessThreshold.
    function status()
        external
        view
        returns (uint256 layer, uint256 wethBalance, bool readyForWethBurn)
    {
        if (!initialized) return (0, 0, false);
        layer = IERC20(layerToken).balanceOf(address(this));
        wethBalance = IERC20(weth).balanceOf(address(this));
        readyForWethBurn = wethBalance >= minProcessThreshold;
    }

    // ─── ETH receive ─────────────────────────────────────────────────────

    receive() external payable {
        emit EthReceived(msg.sender, msg.value);
    }
}
