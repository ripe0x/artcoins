// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Constants} from "../../Constants.sol";
import {IArtCoinsExtensionV2} from "../interfaces/IArtCoinsExtensionV2.sol";
import {IArtCoinsFactoryV2} from "../interfaces/IArtCoinsFactoryV2.sol";
import {IConstantsBound} from "../interfaces/IConstantsBound.sol";
import {IArtCoinsAirdropV2} from "./interfaces/IArtCoinsAirdropV2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title  ArtCoinsAirdropV2
/// @notice Escrows a launch allocation and lets leaves of a frozen merkle tree
///         claim it with a lockup then linear vesting.
///
///         What is frozen at launch (D7): root, sweep recipient, lockup,
///         vesting, supply. There is no owner, no admin, no root update, no
///         sweep redirect. Fixes against the v1 review:
///         - A1: an empty root is rejected, and tranches are keyed by
///           `(token, extensionIndex)`, so two airdrop entries in one launch
///           cannot overwrite each other.
///         - A2: the root can never be replaced. v1 let the admin swap it one
///           day after the lockup while nothing was claimed.
///         - A3: the sweep recipient must be nonzero and is fixed; the sweep
///           itself is permissionless and only ever pays that recipient.
///         - leaves are double hashed exactly as OpenZeppelin's
///           StandardMerkleTree (the openzeppelin merkle-tree js package), types
///           `["address","uint256"]`, so a leaf cannot collide with an inner node.
///         - A4: claimed amounts are tracked per leaf, not per address, so an
///           address with two leaves is paid both. The cap that the total
///           claimed never exceeds the tranche supply still holds, so an over
///           allocated tree pays first come first served. The tree builder
///           must keep the sum of allocations at or below the airdrop supply.
///
///         Windows: claims open at `lockupEnd`, vest linearly to `vestingEnd`
///         and close at `sweepTime = vestingEnd + CLAIM_EXPIRATION_INTERVAL`.
///         From `sweepTime` anyone may call `sweep`; claims revert from then on.
contract ArtCoinsAirdropV2 is ReentrancyGuard, IArtCoinsAirdropV2 {
    using SafeERC20 for IERC20;

    /// @notice The only caller of `receiveTokens`.
    address public immutable factory;

    /// @notice Time after vesting ends during which claims stay open (14 days).
    uint256 public constant CLAIM_EXPIRATION_INTERVAL = 14 days;
    /// @notice Sanity bound on each configured duration.
    uint256 public constant MAX_DURATION = 3650 days;

    mapping(address token => mapping(uint256 index => Tranche)) private _tranches;
    mapping(address token => mapping(uint256 index => mapping(bytes32 leaf => uint256))) private
        _leafClaimed;

    modifier onlyFactory() {
        if (msg.sender != factory) revert Unauthorized();
        _;
    }

    /// @param factory_ The v2 factory. Immutable.
    constructor(address factory_) {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
    }

    // ── launch entry ──────────────────────────────────────────────────────

    /// @inheritdoc IArtCoinsExtensionV2
    function receiveTokens(
        IArtCoinsFactoryV2.DeploymentConfigV2 calldata config,
        PoolKey calldata,
        address token,
        uint256 extensionSupply,
        uint256 extensionIndex
    ) external payable nonReentrant onlyFactory {
        IArtCoinsFactoryV2.ExtensionConfigV2 calldata e = config.extensions[extensionIndex];
        if (e.extension != address(this)) revert WrongExtensionEntry();
        if (e.msgValue != 0 || msg.value != 0) revert InvalidMsgValue();
        if (e.extensionBps == 0 || extensionSupply == 0) revert InvalidAirdropBps();
        if (e.extensionData.length != 128) revert InvalidExtensionData();

        (address sweepRecipient, bytes32 root, uint256 lockup, uint256 vesting) =
            abi.decode(e.extensionData, (address, bytes32, uint256, uint256));
        if (root == bytes32(0)) revert InvalidMerkleRoot();
        if (
            sweepRecipient == address(0) || sweepRecipient == token
                || sweepRecipient == address(this)
        ) {
            revert ZeroSweepRecipient();
        }
        if (lockup > MAX_DURATION || vesting > MAX_DURATION) revert DurationTooLong();

        Tranche storage t = _tranches[token][extensionIndex];
        if (t.supply != 0) revert AirdropAlreadyExists();

        uint256 lockupEnd = block.timestamp + lockup;
        uint256 vestingEnd = lockupEnd + vesting;
        uint256 sweepTime = vestingEnd + CLAIM_EXPIRATION_INTERVAL;
        t.sweepRecipient = sweepRecipient;
        t.merkleRoot = root;
        t.supply = extensionSupply;
        t.lockupEnd = lockupEnd;
        t.vestingEnd = vestingEnd;
        t.sweepTime = sweepTime;

        IERC20(token).safeTransferFrom(msg.sender, address(this), extensionSupply);

        emit AirdropCreated(
            token,
            extensionIndex,
            sweepRecipient,
            root,
            extensionSupply,
            lockupEnd,
            vestingEnd,
            sweepTime
        );
    }

    // ── claim and sweep ───────────────────────────────────────────────────

    /// @inheritdoc IArtCoinsAirdropV2
    function claim(
        address token,
        uint256 index,
        address recipient,
        uint256 allocatedAmount,
        bytes32[] calldata proof
    ) external nonReentrant {
        Tranche storage t = _tranches[token][index];
        if (t.supply == 0) revert AirdropNotCreated();
        if (block.timestamp < t.lockupEnd) revert AirdropNotUnlocked();
        if (block.timestamp >= t.sweepTime) revert ClaimWindowClosed();
        if (allocatedAmount == 0) revert ZeroClaim();
        if (t.totalClaimed >= t.supply) revert TotalMaxClaimed();

        bytes32 leaf = _leaf(recipient, allocatedAmount);
        if (!MerkleProof.verifyCalldata(proof, t.merkleRoot, leaf)) revert InvalidProof();

        uint256 done = _leafClaimed[token][index][leaf];
        if (done >= allocatedAmount) revert UserMaxClaimed();

        uint256 amount = _vested(t, allocatedAmount) - done;
        // vested() never returns less than `done` for the same leaf; the
        // subtraction above cannot underflow because `done` was paid from it.
        uint256 left = t.supply - t.totalClaimed;
        if (amount > left) amount = left;
        if (amount == 0) revert ZeroToClaim();

        uint256 newDone = done + amount;
        _leafClaimed[token][index][leaf] = newDone;
        t.totalClaimed += amount;

        IERC20(token).safeTransfer(recipient, amount);
        emit AirdropClaimed(token, index, recipient, amount, newDone, allocatedAmount);
    }

    /// @inheritdoc IArtCoinsAirdropV2
    function sweep(address token, uint256 index) external nonReentrant {
        Tranche storage t = _tranches[token][index];
        if (t.supply == 0) revert AirdropNotCreated();
        if (block.timestamp < t.sweepTime) revert SweepNotReady();
        if (t.swept) revert AlreadySwept();
        t.swept = true;

        uint256 amount = t.supply - t.totalClaimed;
        t.totalClaimed = t.supply;
        address to = t.sweepRecipient;
        if (amount != 0) IERC20(token).safeTransfer(to, amount);
        emit AirdropSwept(token, index, to, amount);
    }

    // ── views ─────────────────────────────────────────────────────────────

    /// @inheritdoc IArtCoinsAirdropV2
    function amountAvailableToClaim(
        address token,
        uint256 index,
        address recipient,
        uint256 allocatedAmount
    ) external view returns (uint256) {
        Tranche storage t = _tranches[token][index];
        if (t.supply == 0) revert AirdropNotCreated();
        if (block.timestamp < t.lockupEnd || block.timestamp >= t.sweepTime) return 0;
        uint256 done = _leafClaimed[token][index][_leaf(recipient, allocatedAmount)];
        uint256 vested = _vested(t, allocatedAmount);
        uint256 amount = vested > done ? vested - done : 0;
        uint256 left = t.supply - t.totalClaimed;
        return amount > left ? left : amount;
    }

    /// @inheritdoc IArtCoinsAirdropV2
    function leafClaimed(address token, uint256 index, address recipient, uint256 allocatedAmount)
        external
        view
        returns (uint256)
    {
        return _leafClaimed[token][index][_leaf(recipient, allocatedAmount)];
    }

    /// @inheritdoc IArtCoinsAirdropV2
    function leafHash(address account, uint256 amount) external pure returns (bytes32) {
        return _leaf(account, amount);
    }

    /// @inheritdoc IArtCoinsAirdropV2
    function tranche(address token, uint256 index) external view returns (Tranche memory) {
        return _tranches[token][index];
    }

    // ── erc165 and constants ──────────────────────────────────────────────

    /// @inheritdoc IConstantsBound
    function constantsHash() external pure returns (bytes32) {
        return Constants.hash();
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IArtCoinsExtensionV2).interfaceId
            || interfaceId == type(IConstantsBound).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    // ── internal ──────────────────────────────────────────────────────────

    /// @dev OpenZeppelin StandardMerkleTree leaf hash.
    function _leaf(address account, uint256 amount) private pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
    }

    /// @dev Linear from `lockupEnd` to `vestingEnd`; everything at or after `vestingEnd`.
    ///      Caller guarantees `block.timestamp >= lockupEnd`.
    function _vested(Tranche storage t, uint256 allocated) private view returns (uint256) {
        uint256 end = t.vestingEnd;
        if (block.timestamp >= end) return allocated;
        uint256 start = t.lockupEnd;
        return allocated * (block.timestamp - start) / (end - start);
    }
}
