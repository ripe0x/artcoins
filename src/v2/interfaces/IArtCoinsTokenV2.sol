// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsFactoryV2} from "./IArtCoinsFactoryV2.sol";

/// @title  IArtCoinsTokenV2
/// @notice v2 art coin surface beyond erc20. Tax mode, cap, sink, canonical
///         pool and launcher are immutable. Mode VENUE taxes coin leaving a
///         venue to a non exempt recipient; mode HARD blocks PoolManager
///         flows not granted by the canonical hook in the same tx and any
///         transfer touching a listed venue.
interface IArtCoinsTokenV2 {
    // ── events ────────────────────────────────────────────────────────────

    event TaxEnabled(
        bytes32 indexed canonicalPoolId,
        address indexed canonicalHook,
        uint8 mode,
        uint16 taxBps,
        uint16 taxBpsMax,
        address taxSink
    );
    event TaxApplied(
        address indexed from, address indexed to, uint256 gross, uint256 tax, uint256 net
    );
    event TaxBpsUpdated(uint16 oldBps, uint16 newBps);
    event TaxVenueAdded(address indexed venue);
    event VenueAdminRenounced();

    event Verified(address indexed admin, address indexed token);
    event UpdateImage(string image);
    event UpdateMetadata(string metadata);
    event UpdateAdmin(address indexed oldAdmin, address indexed newAdmin);
    event MetadataRendererUpdated(address indexed renderer);
    event ContractURIUpdated();
    event AdminRenounced(address indexed admin);

    // ── errors ────────────────────────────────────────────────────────────

    error NotAdmin();
    error NotOriginalAdmin();
    error NotVenueAdmin();
    error NotCanonicalHook();
    error AlreadyVerified();
    error ZeroAddress();
    error InvalidRenderer();
    error TaxNotEnabled();
    error TaxBpsTooHigh();
    error TaxConfigInvalid();
    error TooManyTaxVenues();
    error InvalidTaxVenue(address venue);
    /// @notice HARD mode: PoolManager flow not covered by a same tx canonical grant.
    error CanonicalFlowRequired(address from, address to, uint256 amount);
    /// @notice HARD mode: transfer touching a listed venue.
    error VenueTransferBlocked(address venue);
    /// @notice D30: a string field exceeds its byte cap. `field`: 0 name, 1 symbol,
    ///         2 image, 3 metadata, 4 context. Caps 64, 16, 2048, 4096, 4096 bytes.
    error StringTooLong(uint8 field, uint256 len);

    // ── tax reads ─────────────────────────────────────────────────────────

    /// @notice Constants.TAX_MODE_NONE, _VENUE or _HARD.
    function taxMode() external view returns (uint8);
    /// @notice Current rate in BPS, within [0, taxBpsMax]. VENUE mode only.
    function taxBps() external view returns (uint16);
    function taxBpsMax() external view returns (uint16);
    /// @notice Constants.DEAD or the pool's bounty recipient.
    function taxSink() external view returns (address);
    function canonicalHook() external view returns (address);
    function canonicalPoolId() external view returns (bytes32);
    function poolManager() external view returns (address);
    /// @notice May add venues; 0 once renounced.
    function venueAdmin() external view returns (address);
    function isTaxVenue(address account) external view returns (bool);
    function isTaxExempt(address account) external view returns (bool);

    // ── version tag ───────────────────────────────────────────────────────

    /// @notice Factory that launched this token.
    function launcher() external view returns (address);
    /// @notice Constants.STACK_VERSION.
    function launcherVersion() external pure returns (uint16);

    // ── tax admin ─────────────────────────────────────────────────────────

    /// @notice Token admin. `newBps <= taxBpsMax`.
    function setTaxBps(uint16 newBps) external;
    /// @notice Venue admin. Add only, no removal path.
    function addTaxVenue(address venue) external;
    /// @notice Venue admin. Derives the v2/v3 pool address from this token and adds it.
    function addDerivedTaxVenue(IArtCoinsFactoryV2.TaxVenue calldata venue)
        external
        returns (address pool);
    /// @notice Venue admin. Freezes the venue list.
    function renounceVenueAdmin() external;

    // ── canonical hook only ───────────────────────────────────────────────

    /// @notice VENUE mode: realized coin leaving the PoolManager from the
    ///         canonical pool this tx; exempts that much of PoolManager outflow.
    function attestCanonicalBudget(bytes32 poolId, uint256 outAmount) external;
    /// @notice HARD mode: per direction allowance for PoolManager transfers
    ///         this tx, cumulative, consumed exactly.
    function grantCanonicalFlow(bytes32 poolId, uint256 outAmount, uint256 inAmount) external;

    // ── metadata (as v1) ──────────────────────────────────────────────────

    function admin() external view returns (address);
    function originalAdmin() external view returns (address);
    function imageUrl() external view returns (string memory);
    function metadata() external view returns (string memory);
    function context() external view returns (string memory);
    function metadataRenderer() external view returns (address);
    function isVerified() external view returns (bool);
    function contractURI() external view returns (string memory);
    function tokenURI() external view returns (string memory);
    function updateAdmin(address admin_) external;
    function renounceAdmin() external;
    function updateImage(string calldata image_) external;
    function updateMetadata(string calldata metadata_) external;
    function setMetadataRenderer(address renderer_) external;
    function verify() external;
    function burn(uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
}
