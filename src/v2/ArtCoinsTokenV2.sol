// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solady/tokens/ERC20.sol";
import {LibString} from "solady/utils/LibString.sol";

import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {Constants} from "../Constants.sol";
import {IMetadataRenderer} from "../interfaces/IMetadataRenderer.sol";
import {TaxVenues} from "./libraries/TaxVenues.sol";

import {IArtCoinsFactoryV2} from "./interfaces/IArtCoinsFactoryV2.sol";
import {IArtCoinsTokenV2} from "./interfaces/IArtCoinsTokenV2.sol";
import {IConstantsBound} from "./interfaces/IConstantsBound.sol";

/// @title  ArtCoinsTokenV2
/// @notice v2 art coin. Solady ERC20 with Permit and the fixed infinite
///         Permit2 allowance. No votes extension (v1 had none either, despite
///         older docs).
///
///         Tax modes, immutable per token:
///         | mode  | rule |
///         |---|---|
///         | NONE  | plain erc20 |
///         | VENUE | coin leaving a venue (the PoolManager or a listed v2/v3 pool) to a non exempt recipient pays `taxBps` to `taxSink`. PoolManager outflows are exempt up to the canonical budget the canonical hook attested this tx. listed venue outflows never draw budget. coin the hook reports entering the canonical pool cancels unused budget (D34) |
///         | HARD  | any transfer from or to the PoolManager reverts unless covered by a same tx, per direction allowance granted by the canonical hook. grants net against each other (D34). any transfer touching a listed venue reverts |
///
///         Frozen at construction: name, symbol, supply, launcher, mode,
///         taxBpsMax, taxSink, canonical hook, pool id, PoolManager, exempt set.
///         Token admin may tune `taxBps` within `taxBpsMax` (VENUE only) and
///         the cosmetic fields (image, metadata, renderer). Venue admin may only
///         add venues, and may renounce.
/// @dev    Deployed by `ArtCoinsDeployerV2` via CREATE2. The whole supply is
///         minted to the launcher (the factory).
contract ArtCoinsTokenV2 is ERC20, IArtCoinsTokenV2, IConstantsBound {
    using PoolIdLibrary for PoolKey;

    /// @notice Launch inputs the token cannot derive from its own config.
    ///         All supplied by the factory from the pool and fee config.
    struct CanonicalPool {
        address hook; // canonical v4 hook (PoolConfigV2.hook)
        address poolManager; // the hook's PoolManager
        int24 tickSpacing; // PoolConfigV2.tickSpacing
        address bountyRecipient; // FeeConfigV2.bountyRecipient, the only non DEAD tax sink allowed
    }

    // ── additive events (not in the frozen interface) ─────────────────────

    /// @notice An address on the frozen exempt set, emitted once each at construction.
    event TaxExemptSet(address indexed account);

    // ── constants ─────────────────────────────────────────────────────────

    /// @dev VENUE: exemption budget the canonical hook attested this tx.
    bytes32 private constant _BUDGET_SLOT = keccak256("artcoins.tokenV2.canonicalBudget");
    /// @dev HARD: remaining PoolManager to holder allowance this tx.
    bytes32 private constant _FLOW_OUT_SLOT = keccak256("artcoins.tokenV2.flowOut");
    /// @dev HARD: remaining holder to PoolManager allowance this tx.
    bytes32 private constant _FLOW_IN_SLOT = keccak256("artcoins.tokenV2.flowIn");
    /// @dev Gas for the token0/token1 probe in `addTaxVenue`.
    uint256 private constant _PROBE_GAS = 30_000;

    /// @notice D30 string caps in bytes, enforced at construction and in every
    ///         setter, so a renderer's gas budget is provable. The factory checks
    ///         the same caps before deploying.
    uint256 public constant MAX_NAME_BYTES = 64;
    uint256 public constant MAX_SYMBOL_BYTES = 16;
    uint256 public constant MAX_IMAGE_BYTES = 2048;
    uint256 public constant MAX_METADATA_BYTES = 4096;
    uint256 public constant MAX_CONTEXT_BYTES = 4096;
    /// @notice `StringTooLong.field` codes.
    uint8 public constant FIELD_NAME = 0;
    uint8 public constant FIELD_SYMBOL = 1;
    uint8 public constant FIELD_IMAGE = 2;
    uint8 public constant FIELD_METADATA = 3;
    uint8 public constant FIELD_CONTEXT = 4;

    // ── immutables ────────────────────────────────────────────────────────

    /// @inheritdoc IArtCoinsTokenV2
    uint8 public immutable taxMode;
    /// @inheritdoc IArtCoinsTokenV2
    uint16 public immutable taxBpsMax;
    /// @inheritdoc IArtCoinsTokenV2
    address public immutable taxSink;
    /// @inheritdoc IArtCoinsTokenV2
    address public immutable canonicalHook;
    /// @inheritdoc IArtCoinsTokenV2
    bytes32 public immutable canonicalPoolId;
    /// @inheritdoc IArtCoinsTokenV2
    address public immutable poolManager;
    /// @inheritdoc IArtCoinsTokenV2
    address public immutable launcher;
    address private immutable _originalAdmin;

    // ── storage ───────────────────────────────────────────────────────────

    string private _name;
    string private _symbol;
    string private _metadata;
    string private _context;
    string private _image;
    address private _admin;
    bool private _verified;
    address private _metadataRenderer;

    /// @inheritdoc IArtCoinsTokenV2
    uint16 public taxBps;
    /// @inheritdoc IArtCoinsTokenV2
    address public venueAdmin;

    mapping(address => bool) private _taxVenue;
    mapping(address => bool) private _taxExempt;
    address[] private _venueList;
    address[] private _exemptList;

    // ── construction ──────────────────────────────────────────────────────

    /// @param t        Token config. `totalSupply` is ignored; `supply` is what is minted.
    /// @param supply   Supply minted to `launcher_`.
    /// @param tax      Tax config. See `_initTax` for the per mode rules.
    /// @param canon    Canonical pool inputs from the factory.
    /// @param launcher_ The factory. Receives the supply and is the `launcher` tag.
    constructor(
        IArtCoinsFactoryV2.TokenConfigV2 memory t,
        uint256 supply,
        IArtCoinsFactoryV2.TaxConfigV2 memory tax,
        CanonicalPool memory canon,
        address launcher_
    ) {
        if (t.tokenAdmin == address(0) || launcher_ == address(0)) {
            revert ZeroAddress();
        }
        if (t.renderer != address(0) && t.renderer.code.length == 0) revert InvalidRenderer();
        if (canon.hook == address(0) || canon.poolManager == address(0) || canon.tickSpacing <= 0) {
            revert TaxConfigInvalid();
        }

        _cap(t.name, MAX_NAME_BYTES, FIELD_NAME);
        _cap(t.symbol, MAX_SYMBOL_BYTES, FIELD_SYMBOL);
        _cap(t.image, MAX_IMAGE_BYTES, FIELD_IMAGE);
        _cap(t.metadata, MAX_METADATA_BYTES, FIELD_METADATA);
        _cap(t.context, MAX_CONTEXT_BYTES, FIELD_CONTEXT);

        _name = t.name;
        _symbol = t.symbol;
        _originalAdmin = t.tokenAdmin;
        _admin = t.tokenAdmin;
        _image = t.image;
        _metadata = t.metadata;
        _context = t.context;
        _metadataRenderer = t.renderer;
        launcher = launcher_;

        canonicalHook = canon.hook;
        poolManager = canon.poolManager;
        // Native eth (address 0) always sorts first; the hook creates dynamic fee pools.
        canonicalPoolId = PoolId.unwrap(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(address(this)),
                fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
                tickSpacing: canon.tickSpacing,
                hooks: IHooks(canon.hook)
            }).toId()
        );

        uint8 mode = tax.mode;
        if (mode == Constants.TAX_MODE_NONE) {
            // nothing may be configured: a dormant config must not hide a sink or a list.
            if (
                tax.taxBps != 0 || tax.taxBpsMax != 0 || tax.taxSink != address(0)
                    || tax.venueAdmin != address(0) || tax.exempt.length != 0
                    || tax.venues.length != 0
            ) revert TaxConfigInvalid();
        } else if (mode == Constants.TAX_MODE_VENUE) {
            if (
                tax.taxBpsMax == 0 || tax.taxBpsMax > Constants.TAX_BPS_ABSOLUTE_MAX
                    || tax.taxBps > tax.taxBpsMax
            ) revert TaxConfigInvalid();
            // sink: DEAD or the pool's bounty recipient (D10).
            if (
                tax.taxSink != Constants.DEAD
                    && (tax.taxSink == address(0) || tax.taxSink != canon.bountyRecipient)
            ) revert TaxConfigInvalid();
        } else if (mode == Constants.TAX_MODE_HARD) {
            // no rate, no exempt set: nothing is ever taxed. the sink is unused;
            // it may be left 0 or set to an allowed value for display.
            if (tax.taxBps != 0 || tax.taxBpsMax != 0 || tax.exempt.length != 0) {
                revert TaxConfigInvalid();
            }
            if (
                tax.taxSink != address(0) && tax.taxSink != Constants.DEAD
                    && tax.taxSink != canon.bountyRecipient
            ) revert TaxConfigInvalid();
        } else {
            revert TaxConfigInvalid();
        }

        taxMode = mode;
        taxBpsMax = tax.taxBpsMax;
        taxSink = tax.taxSink;

        if (mode != Constants.TAX_MODE_NONE) {
            taxBps = tax.taxBps;
            venueAdmin = tax.venueAdmin == address(0) ? t.tokenAdmin : tax.venueAdmin;
            _initExempt(tax.exempt);
            _initVenues(tax.venues, canon.hook, canon.poolManager, launcher_);
            emit TaxEnabled(
                canonicalPoolId, canon.hook, mode, tax.taxBps, tax.taxBpsMax, tax.taxSink
            );
        }

        _mint(launcher_, supply);
    }

    /// @dev Exempt entries must be contracts that exist at launch (the
    ///      locker, a position manager), never this token, and at most
    ///      MAX_TAX_EXEMPT. An externally owned account cannot be exempted, so
    ///      a deployer cannot list its own wallet and buy untaxed (FT-07).
    function _cap(string memory v, uint256 max, uint8 field) private pure {
        uint256 len = bytes(v).length;
        if (len > max) revert StringTooLong(field, len);
    }

    function _initExempt(address[] memory exempt) private {
        uint256 n = exempt.length;
        if (n > Constants.MAX_TAX_EXEMPT) revert TaxConfigInvalid();
        for (uint256 i; i < n; ++i) {
            address a = exempt[i];
            if (a == address(this) || a.code.length == 0 || _taxExempt[a]) {
                revert TaxConfigInvalid();
            }
            _taxExempt[a] = true;
            _exemptList.push(a);
            emit TaxExemptSet(a);
        }
    }

    function _initVenues(
        IArtCoinsFactoryV2.TaxVenue[] memory venues,
        address hook,
        address pm,
        address launcher_
    ) private {
        uint256 n = venues.length;
        if (n > Constants.MAX_TAX_VENUES) revert TooManyTaxVenues();
        for (uint256 i; i < n; ++i) {
            address pool = TaxVenues.derive(venues[i], address(this));
            if (pool == address(0)) revert InvalidTaxVenue(address(0));
            _addVenue(pool, hook, pm, launcher_);
        }
    }

    // ── erc20 ─────────────────────────────────────────────────────────────

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /// @dev Solady inlines balance moves in `transfer`/`transferFrom`, so both
    ///      are overridden and routed through `_route`. `transferFrom` debits
    ///      the full `amount` once (Permit2 short circuit preserved).
    function transfer(address to, uint256 amount) public override returns (bool) {
        _route(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _route(from, to, amount);
        return true;
    }

    /// @inheritdoc IArtCoinsTokenV2
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// @inheritdoc IArtCoinsTokenV2
    function burnFrom(address account, uint256 amount) external {
        _spendAllowance(account, msg.sender, amount);
        _burn(account, amount);
    }

    // ── tax path ──────────────────────────────────────────────────────────

    /// @dev Single chokepoint for every holder to holder move. Mint and burn
    ///      never touch the PoolManager or a venue and skip it.
    function _route(address from, address to, uint256 amount) private {
        uint8 mode = taxMode;
        if (mode == Constants.TAX_MODE_HARD) {
            _hardCheck(from, to, amount);
        } else if (mode == Constants.TAX_MODE_VENUE) {
            if (_venueTax(from, to, amount)) return;
        }
        _transfer(from, to, amount);
    }

    /// @dev HARD. PoolManager flows consume the hook's same tx grant for that
    ///      direction, exactly. Listed venues are walled off both ways. A zero
    ///      amount needs no grant.
    function _hardCheck(address from, address to, uint256 amount) private {
        address pm = poolManager;
        if (from == pm) _consumeFlow(_FLOW_OUT_SLOT, from, to, amount);
        else if (to == pm) _consumeFlow(_FLOW_IN_SLOT, from, to, amount);
        if (_taxVenue[from]) revert VenueTransferBlocked(from);
        if (_taxVenue[to]) revert VenueTransferBlocked(to);
    }

    function _consumeFlow(bytes32 slot, address from, address to, uint256 amount) private {
        uint256 a = _tload(slot);
        if (amount > a) revert CanonicalFlowRequired(from, to, amount);
        unchecked {
            _tstore(slot, a - amount);
        }
    }

    /// @dev VENUE. Returns true when it moved the funds itself (taxed).
    ///      Budget is drawn only on PoolManager outflows (b1), including those
    ///      to exempt recipients, so budget a canonical buy attested cannot
    ///      survive the tx for a later side pool outflow. Listed v2/v3 venue
    ///      outflows are taxed in full and never touch the budget.
    function _venueTax(address from, address to, uint256 amount) private returns (bool) {
        uint16 bps = taxBps;
        if (bps == 0 || amount == 0) return false;
        uint256 exemptAmt;
        if (from == poolManager) {
            exemptAmt = _consumeBudget(amount);
        } else if (!_taxVenue[from]) {
            return false;
        }
        if (_taxExempt[to]) return false;
        uint256 tax = ((amount - exemptAmt) * bps) / Constants.BPS;
        if (tax == 0) return false;
        // tax <= amount, no underflow.
        _transfer(from, to, amount - tax);
        _transfer(from, taxSink, tax);
        emit TaxApplied(from, to, amount, tax, amount - tax);
        return true;
    }

    function _consumeBudget(uint256 amount) private returns (uint256 exemptAmt) {
        uint256 b = _tload(_BUDGET_SLOT);
        if (b == 0) return 0;
        exemptAmt = b >= amount ? amount : b;
        unchecked {
            _tstore(_BUDGET_SLOT, b - exemptAmt);
        }
    }

    /// @inheritdoc IArtCoinsTokenV2
    /// @dev Calls for another pool, another mode or a zero amount are no ops,
    ///      never reverts, so a hook misroute cannot brick a swap.
    function attestCanonicalBudget(bytes32 poolId, uint256 outAmount) external {
        if (msg.sender != canonicalHook) revert NotCanonicalHook();
        if (taxMode != Constants.TAX_MODE_VENUE || poolId != canonicalPoolId || outAmount == 0) {
            return;
        }
        _tstore(_BUDGET_SLOT, _tload(_BUDGET_SLOT) + outAmount);
    }

    /// @inheritdoc IArtCoinsTokenV2
    /// @dev D34 netting. A canonical flow first cancels the outstanding
    ///      allowance of the opposite direction; only the remainder is
    ///      granted. HARD: out cancels unused in, in cancels unused out, so at
    ///      most one direction is ever outstanding and a round trip, a remove
    ///      then re add, or an add then remove inside one unlock leaves nothing
    ///      for a side pool take or settle. VENUE: `inAmount` (coin entering
    ///      the canonical pool: a sell or an lp add) cancels unused budget;
    ///      `outAmount` is ignored (budget is added by `attestCanonicalBudget`).
    ///      No op for another pool or in NONE.
    function grantCanonicalFlow(bytes32 poolId, uint256 outAmount, uint256 inAmount) external {
        if (msg.sender != canonicalHook) revert NotCanonicalHook();
        if (poolId != canonicalPoolId) return;
        uint8 mode = taxMode;
        if (mode == Constants.TAX_MODE_HARD) {
            if (outAmount != 0) _netGrant(_FLOW_IN_SLOT, _FLOW_OUT_SLOT, outAmount);
            if (inAmount != 0) _netGrant(_FLOW_OUT_SLOT, _FLOW_IN_SLOT, inAmount);
        } else if (mode == Constants.TAX_MODE_VENUE && inAmount != 0) {
            uint256 b = _tload(_BUDGET_SLOT);
            unchecked {
                _tstore(_BUDGET_SLOT, b > inAmount ? b - inAmount : 0);
            }
        }
    }

    /// @dev Cancels up to `amount` of `cancelSlot`, adds the rest to `addSlot`.
    function _netGrant(bytes32 cancelSlot, bytes32 addSlot, uint256 amount) private {
        uint256 c = _tload(cancelSlot);
        if (c >= amount) {
            unchecked {
                _tstore(cancelSlot, c - amount);
            }
            return;
        }
        if (c != 0) _tstore(cancelSlot, 0);
        unchecked {
            amount -= c;
        }
        _tstore(addSlot, _tload(addSlot) + amount);
    }

    /// @notice Remaining same tx allowances. VENUE: (budget, 0, 0). HARD: (0, out, in).
    function pendingCanonical()
        external
        view
        returns (uint256 budget, uint256 flowOut, uint256 flowIn)
    {
        return (_tload(_BUDGET_SLOT), _tload(_FLOW_OUT_SLOT), _tload(_FLOW_IN_SLOT));
    }

    function _tload(bytes32 slot) private view returns (uint256 v) {
        assembly ("memory-safe") {
            v := tload(slot)
        }
    }

    function _tstore(bytes32 slot, uint256 v) private {
        assembly ("memory-safe") {
            tstore(slot, v)
        }
    }

    // ── tax admin ─────────────────────────────────────────────────────────

    /// @inheritdoc IArtCoinsTokenV2
    function setTaxBps(uint16 newBps) external {
        if (msg.sender != _admin) revert NotAdmin();
        if (taxMode != Constants.TAX_MODE_VENUE) revert TaxNotEnabled();
        if (newBps > taxBpsMax) revert TaxBpsTooHigh();
        uint16 old = taxBps;
        taxBps = newBps;
        emit TaxBpsUpdated(old, newBps);
    }

    /// @inheritdoc IArtCoinsTokenV2
    /// @dev The venue must be a contract that reports this token as its
    ///      `token0()` or `token1()` (v2 and v3 pools do). This stops a venue
    ///      admin from listing an arbitrary holder (a wallet, a cex, a safe)
    ///      to tax its outflows (VENUE) or freeze it (HARD). Venues without
    ///      that shape can still be pre listed via `addDerivedTaxVenue`.
    function addTaxVenue(address venue) external {
        _onlyVenueAdmin();
        if (!_reportsThisToken(venue)) revert InvalidTaxVenue(venue);
        _addVenue(venue, canonicalHook, poolManager, launcher);
    }

    /// @inheritdoc IArtCoinsTokenV2
    function addDerivedTaxVenue(IArtCoinsFactoryV2.TaxVenue calldata venue)
        external
        returns (address pool)
    {
        _onlyVenueAdmin();
        pool = TaxVenues.derive(venue, address(this));
        if (pool == address(0)) revert InvalidTaxVenue(address(0));
        _addVenue(pool, canonicalHook, poolManager, launcher);
    }

    /// @inheritdoc IArtCoinsTokenV2
    function renounceVenueAdmin() external {
        _onlyVenueAdmin();
        venueAdmin = address(0);
        emit VenueAdminRenounced();
    }

    function _onlyVenueAdmin() private view {
        if (taxMode == Constants.TAX_MODE_NONE) revert TaxNotEnabled();
        if (msg.sender != venueAdmin || msg.sender == address(0)) revert NotVenueAdmin();
    }

    /// @dev The PoolManager is the implicit venue and must never be listed
    ///      (in HARD it would block the canonical pool). The hook, the
    ///      launcher and this token are refused for the same reason.
    function _addVenue(address venue, address hook, address pm, address launcher_) private {
        if (
            venue == address(0) || venue == address(this) || venue == pm || venue == hook
                || venue == launcher_ || _taxVenue[venue]
        ) revert InvalidTaxVenue(venue);
        if (_venueList.length >= Constants.MAX_TAX_VENUES) revert TooManyTaxVenues();
        _taxVenue[venue] = true;
        _venueList.push(venue);
        emit TaxVenueAdded(venue);
    }

    function _reportsThisToken(address venue) private view returns (bool) {
        if (venue.code.length == 0) return false;
        return _probe(venue, 0x0dfe1681) || _probe(venue, 0xd21220a7); // token0(), token1()
    }

    /// @dev Gas capped static probe; reads one word, ignores the rest.
    function _probe(address venue, bytes4 sel) private view returns (bool hit) {
        address self = address(this);
        assembly ("memory-safe") {
            mstore(0x00, sel)
            let ok := staticcall(_PROBE_GAS, venue, 0x00, 0x04, 0x00, 0x20)
            hit := and(and(ok, gt(returndatasize(), 0x1f)), eq(mload(0x00), self))
        }
    }

    // ── tax reads ─────────────────────────────────────────────────────────

    /// @inheritdoc IArtCoinsTokenV2
    function isTaxVenue(address account) external view returns (bool) {
        return taxMode != Constants.TAX_MODE_NONE && (account == poolManager || _taxVenue[account]);
    }

    /// @inheritdoc IArtCoinsTokenV2
    function isTaxExempt(address account) external view returns (bool) {
        return _taxExempt[account];
    }

    /// @notice Listed v2/v3 venues (the PoolManager is implicit). <= MAX_TAX_VENUES.
    function taxVenues() external view returns (address[] memory) {
        return _venueList;
    }

    /// @notice The frozen exempt set. <= MAX_TAX_EXEMPT.
    function taxExemptList() external view returns (address[] memory) {
        return _exemptList;
    }

    /// @inheritdoc IArtCoinsTokenV2
    function launcherVersion() external pure returns (uint16) {
        return Constants.STACK_VERSION;
    }

    /// @inheritdoc IConstantsBound
    function constantsHash() external pure returns (bytes32) {
        return Constants.hash();
    }

    // ── admin and metadata (as v1) ────────────────────────────────────────

    /// @inheritdoc IArtCoinsTokenV2
    function updateAdmin(address admin_) external {
        if (msg.sender != _admin) revert NotAdmin();
        if (admin_ == address(0)) revert ZeroAddress();
        address oldAdmin = _admin;
        _admin = admin_;
        emit UpdateAdmin(oldAdmin, admin_);
    }

    /// @inheritdoc IArtCoinsTokenV2
    /// @dev Freezes the rate, image, metadata and renderer. Does not touch the venue admin.
    function renounceAdmin() external {
        if (msg.sender != _admin) revert NotAdmin();
        address oldAdmin = _admin;
        _admin = address(0);
        emit UpdateAdmin(oldAdmin, address(0));
        emit AdminRenounced(oldAdmin);
    }

    /// @inheritdoc IArtCoinsTokenV2
    function updateImage(string calldata image_) external {
        if (msg.sender != _admin) revert NotAdmin();
        _cap(image_, MAX_IMAGE_BYTES, FIELD_IMAGE);
        _image = image_;
        emit UpdateImage(image_);
        emit ContractURIUpdated();
    }

    /// @inheritdoc IArtCoinsTokenV2
    function updateMetadata(string calldata metadata_) external {
        if (msg.sender != _admin) revert NotAdmin();
        _cap(metadata_, MAX_METADATA_BYTES, FIELD_METADATA);
        _metadata = metadata_;
        emit UpdateMetadata(metadata_);
        emit ContractURIUpdated();
    }

    /// @inheritdoc IArtCoinsTokenV2
    /// @dev Zero falls back to the built in json. A non zero renderer must have code.
    function setMetadataRenderer(address renderer_) external {
        if (msg.sender != _admin) revert NotAdmin();
        if (renderer_ != address(0) && renderer_.code.length == 0) revert InvalidRenderer();
        _metadataRenderer = renderer_;
        emit MetadataRendererUpdated(renderer_);
        emit ContractURIUpdated();
    }

    /// @inheritdoc IArtCoinsTokenV2
    function verify() external {
        if (msg.sender != _originalAdmin) revert NotOriginalAdmin();
        if (_verified) revert AlreadyVerified();
        _verified = true;
        emit Verified(msg.sender, address(this));
    }

    /// @inheritdoc IArtCoinsTokenV2
    function contractURI() external view returns (string memory) {
        return _resolveURI();
    }

    /// @inheritdoc IArtCoinsTokenV2
    function tokenURI() external view returns (string memory) {
        return _resolveURI();
    }

    function _resolveURI() private view returns (string memory) {
        address r = _metadataRenderer;
        if (r != address(0)) return IMetadataRenderer(r).contractURI(address(this));
        return _defaultContractURI();
    }

    /// @dev Every interpolated field goes through `LibString.escapeJSON`
    ///      (quotes, backslash, control chars), so any name bytes give valid json.
    function _defaultContractURI() private view returns (string memory) {
        string memory json = string.concat(
            '{"name":"',
            LibString.escapeJSON(_name),
            '","symbol":"',
            LibString.escapeJSON(_symbol),
            '","description":"',
            LibString.escapeJSON(_metadata),
            '","image":"',
            LibString.escapeJSON(_image),
            '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    /// @inheritdoc IArtCoinsTokenV2
    function admin() external view returns (address) {
        return _admin;
    }

    /// @inheritdoc IArtCoinsTokenV2
    function originalAdmin() external view returns (address) {
        return _originalAdmin;
    }

    /// @inheritdoc IArtCoinsTokenV2
    function imageUrl() external view returns (string memory) {
        return _image;
    }

    /// @inheritdoc IArtCoinsTokenV2
    function metadata() external view returns (string memory) {
        return _metadata;
    }

    /// @inheritdoc IArtCoinsTokenV2
    function context() external view returns (string memory) {
        return _context;
    }

    /// @inheritdoc IArtCoinsTokenV2
    function metadataRenderer() external view returns (address) {
        return _metadataRenderer;
    }

    /// @inheritdoc IArtCoinsTokenV2
    function isVerified() external view returns (bool) {
        return _verified;
    }

    /// @notice ERC-165: erc20, erc165, IArtCoinsTokenV2.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC20).interfaceId || interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IArtCoinsTokenV2).interfaceId;
    }
}
