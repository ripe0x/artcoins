// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMetadataRenderer} from "../interfaces/IMetadataRenderer.sol";
import {
    HTMLRequest,
    HTMLTag,
    IScriptyBuilderV2,
    IScriptyStorageV2
} from "../interfaces/IScripty.sol";
import {LiquidityLayerCounterPoolExtension} from "./LiquidityLayerCounterPoolExtension.sol";

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LibString} from "solady/utils/LibString.sol";

/// @notice Minimal subset of the ArtCoinsToken interface this renderer reads.
interface IRenderableToken {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function totalSupply() external view returns (uint256);
}

/// @title LiquidityLayerOnchainRenderer
/// @notice ERC-7572 metadata renderer that returns a fully self-contained
///         data URI for `contractURI(token)`. The animation_url it embeds is
///         itself a `data:text/html;base64,...` document built on-chain via
///         ScriptyBuilderV2 from:
///           - Per-token JS variables (bit-stream pulled live from the
///             LiquidityLayerCounterPoolExtension, total trades, token-as-seed)
///           - The Mona Lisa background image, stored in ScriptyStorageV2
///           - The animation sketch, stored in ScriptyStorageV2 by name
///
/// @dev    Bit-stream serialization: each `tradeChunk(poolId, i)` (a uint256
///         where bit `n` = trade index `(256*i + n)`) is serialized as 32
///         little-endian bytes. The browser-side sketch then unpacks trade
///         index `i` as `bytes[i >> 3] >> (i & 7) & 1`. No other re-ordering.
///
///         Pattern modeled after `ToBeAMachineRenderer` (mainnet 0xfe4c33...)
///         which uses ScriptyBuilder v2 for the same self-contained data-URI
///         shape.
contract LiquidityLayerOnchainRenderer is IMetadataRenderer {
    using Strings for uint256;

    string internal constant DEFAULT_NAME = "Liquidity Layer";
    string internal constant DEFAULT_SYMBOL = "LAYER";

    /// @notice The counter pool extension this renderer reads buy/sell trades from.
    LiquidityLayerCounterPoolExtension public immutable counter;

    /// @notice ScriptyBuilderV2 (canonical address on mainnet, sepolia, base, etc.).
    IScriptyBuilderV2 public immutable scriptyBuilder;

    /// @notice ScriptyStorageV2 (canonical address; same on every chain we care about).
    IScriptyStorageV2 public immutable scriptyStorage;

    address public owner;

    /// @notice Scripty content name for the LL sketch JS (loaded as
    ///         `<script src="data:text/javascript;base64,...">` via tagType 2).
    string public sketchScriptName;

    /// @notice Scripty content name for the Mona Lisa image bytes.
    string public monaAssetName;

    /// @notice MIME type of the asset stored under `monaAssetName` (e.g. "image/jpeg").
    string public monaMimeType;

    /// @notice Optional Scripty content name for a static "history" bit-stream
    ///         prepended to the live counter data. Used to seed the new L1
    ///         token's animation with the trades that happened on the
    ///         predecessor (Base) Liquidity Layer pool. Empty = no history.
    /// @dev    Bit-stream layout matches the live counter chunks: bit `n`
    ///         within the byte stream corresponds to trade index `n`,
    ///         LSB-first within each byte. Padded to a byte boundary; the
    ///         last byte's tail may contain a small number of zero bits
    ///         that show as phantom sells in the animation.
    string public historyAssetName;

    /// @notice Optional override for the JSON `image` field. If non-empty,
    ///         it's used verbatim as the metadata JSON's `image` value
    ///         (e.g. "ipfs://bafkrei…" for a high-quality static thumbnail).
    ///         If empty, the renderer falls back to a `data:image/...;base64,`
    ///         URI built from the on-chain Mona asset. The animation_url's
    ///         canvas backdrop ALWAYS uses the on-chain Mona so the rendered
    ///         HTML stays self-contained regardless of this setting.
    string public imageOverrideUri;

    /// @notice Optional name override for the JSON `name` field. Empty falls
    ///         back to `IRenderableToken(token).name()`.
    string public nameOverride;

    /// @notice Optional symbol override for the JSON `symbol` field. Also used
    ///         as the unit suffix in the burn line of the description. Empty
    ///         falls back to `IRenderableToken(token).symbol()`.
    string public symbolOverride;

    /// @notice Initial supply (in wei units, before decimals) used to compute
    ///         total burned = `initialSupply - token.totalSupply()`. Set to
    ///         the supply at deploy time. Zero = skip the burn line.
    uint256 public initialSupply;

    /// @notice Decimals to apply when formatting the burn amount as a human-
    ///         readable integer. Defaults to 18 to match the standard ERC20
    ///         convention used by the launcher's ArtCoinsToken.
    uint8 public supplyDecimals;

    /// @notice Description text used in the metadata JSON. Rendered as the
    ///         first line; the renderer appends a newline + "Total burned: N
    ///         <symbol>" when initialSupply is non-zero.
    string public projectDescription;

    error NotOwner();
    error EmptyAsset();

    event OwnershipTransferred(address indexed from, address indexed to);
    event SketchScriptUpdated(string name);
    event MonaAssetUpdated(string name, string mime);
    event HistoryAssetUpdated(string name);
    event ImageOverrideUpdated(string uri);
    event NameOverrideUpdated(string name);
    event SymbolOverrideUpdated(string symbol);
    event SupplyConfigUpdated(uint256 initialSupply, uint8 decimals);
    event ProjectDescriptionUpdated(string description);

    constructor(
        address initialOwner,
        LiquidityLayerCounterPoolExtension counter_,
        IScriptyBuilderV2 scriptyBuilder_,
        IScriptyStorageV2 scriptyStorage_,
        string memory sketchScriptName_,
        string memory monaAssetName_,
        string memory monaMimeType_,
        string memory projectDescription_
    ) {
        owner = initialOwner;
        counter = counter_;
        scriptyBuilder = scriptyBuilder_;
        scriptyStorage = scriptyStorage_;
        sketchScriptName = sketchScriptName_;
        monaAssetName = monaAssetName_;
        monaMimeType = monaMimeType_;
        projectDescription = projectDescription_;
        supplyDecimals = 18; // ArtCoinsToken default
        emit OwnershipTransferred(address(0), initialOwner);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function transferOwnership(address to) external onlyOwner {
        emit OwnershipTransferred(owner, to);
        owner = to;
    }

    function setSketchScriptName(string calldata n) external onlyOwner {
        sketchScriptName = n;
        emit SketchScriptUpdated(n);
    }

    function setMonaAsset(string calldata n, string calldata mime) external onlyOwner {
        monaAssetName = n;
        monaMimeType = mime;
        emit MonaAssetUpdated(n, mime);
    }

    function setHistoryAsset(string calldata n) external onlyOwner {
        historyAssetName = n;
        emit HistoryAssetUpdated(n);
    }

    function setImageOverrideUri(string calldata uri) external onlyOwner {
        imageOverrideUri = uri;
        emit ImageOverrideUpdated(uri);
    }

    function setNameOverride(string calldata n) external onlyOwner {
        nameOverride = n;
        emit NameOverrideUpdated(n);
    }

    function setSymbolOverride(string calldata s) external onlyOwner {
        symbolOverride = s;
        emit SymbolOverrideUpdated(s);
    }

    function setSupplyConfig(uint256 _initialSupply, uint8 _decimals) external onlyOwner {
        initialSupply = _initialSupply;
        supplyDecimals = _decimals;
        emit SupplyConfigUpdated(_initialSupply, _decimals);
    }

    function setProjectDescription(string calldata d) external onlyOwner {
        projectDescription = d;
        emit ProjectDescriptionUpdated(d);
    }

    // ─── IMetadataRenderer ───────────────────────────────────────────────

    /// @inheritdoc IMetadataRenderer
    function contractURI(address token) external view returns (string memory) {
        PoolId poolId = counter.poolForToken(token);

        bytes memory monaBytes = scriptyStorage.getContent(monaAssetName, "");
        if (monaBytes.length == 0) revert EmptyAsset();
        string memory monaDataUri =
            string.concat("data:", monaMimeType, ";base64,", Base64.encode(monaBytes));

        bytes memory historyBytes = bytes(historyAssetName).length > 0
            ? scriptyStorage.getContent(historyAssetName, "")
            : new bytes(0);

        string memory html = _buildHtml(token, poolId, monaDataUri, historyBytes);

        // The animation always points its canvas at the on-chain Mona to stay
        // self-contained, but the JSON `image` field can be any URI: an
        // owner-supplied imageOverrideUri (e.g. an IPFS gateway URL pointing
        // at a higher-quality thumbnail) takes precedence; otherwise the
        // on-chain Mona is inlined as a data URI here too.
        string memory jsonImage =
            bytes(imageOverrideUri).length > 0 ? imageOverrideUri : monaDataUri;

        string memory tokenName = _tokenName(token);
        string memory tokenSymbol = _tokenSymbol(token);
        string memory description = _buildDescription(token, tokenSymbol);

        bytes memory json = abi.encodePacked(
            '{"name":"',
            LibString.escapeJSON(tokenName),
            '","symbol":"',
            LibString.escapeJSON(tokenSymbol),
            '","description":"',
            description,
            '","image":"',
            LibString.escapeJSON(jsonImage),
            '","animation_url":"data:text/html;base64,',
            Base64.encode(bytes(html)),
            '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(json));
    }

    /// @dev Build a JSON-safe description: project text, then a literal `\n`
    ///      escape, then "Total burned: N <symbol>". The newline is emitted
    ///      as the two characters `\` `n` (NOT a real 0x0a) because that's
    ///      how JSON encodes newlines within strings — marketplaces decode
    ///      the JSON and present the line break correctly.
    function _buildDescription(address token, string memory tokenSymbol)
        internal
        view
        returns (string memory)
    {
        // Total burned = max(0, initialSupply - currentSupply). When
        // `initialSupply` is unset (zero) we still print a "Total burned: 0"
        // line so the description shape is stable regardless of config.
        uint256 currentSupply = _currentSupply(token);
        uint256 burnedWei = initialSupply > currentSupply ? initialSupply - currentSupply : 0;
        uint256 divisor = supplyDecimals == 0 ? 1 : 10 ** uint256(supplyDecimals);
        uint256 burnedWhole = burnedWei / divisor;

        return string(
            abi.encodePacked(
                LibString.escapeJSON(projectDescription),
                "\\nTotal burned: ",
                burnedWhole.toString(),
                " ",
                LibString.escapeJSON(tokenSymbol)
            )
        );
    }

    function _tokenName(address token) internal view returns (string memory) {
        if (bytes(nameOverride).length > 0) return nameOverride;
        if (token.code.length > 0) {
            try IRenderableToken(token).name() returns (string memory n) {
                return n;
            } catch {}
        }
        return DEFAULT_NAME;
    }

    function _tokenSymbol(address token) internal view returns (string memory) {
        if (bytes(symbolOverride).length > 0) return symbolOverride;
        if (token.code.length > 0) {
            try IRenderableToken(token).symbol() returns (string memory s) {
                return s;
            } catch {}
        }
        return DEFAULT_SYMBOL;
    }

    function _currentSupply(address token) internal view returns (uint256) {
        if (token.code.length > 0) {
            try IRenderableToken(token).totalSupply() returns (uint256 s) {
                return s;
            } catch {}
        }
        return initialSupply;
    }

    // ─── HTML assembly ───────────────────────────────────────────────────

    function _buildHtml(
        address token,
        PoolId poolId,
        string memory monaDataUri,
        bytes memory historyBytes
    ) internal view returns (string memory) {
        // Live counter trades, packed into byte-aligned chunks.
        uint256 counterTotal = counter.totalTrades(poolId);
        bytes memory counterBytes = _readBitStream(poolId, counterTotal);

        // Concatenate history (already byte-aligned) + live counter bytes.
        // Trade indices in the JS unpacker map straight to bit positions in
        // this concatenated stream; the 0-7 zero pad bits at the end of the
        // history blob show as a small number of phantom sells at the
        // boundary (negligible vs ~22K total trades).
        bytes memory bitStream = bytes.concat(historyBytes, counterBytes);
        uint256 totalBits = (historyBytes.length * 8) + counterTotal;

        string memory seedHex = _addressToHex(token);

        bytes memory dataScript = abi.encodePacked(
            "const LL_TOTAL=",
            totalBits.toString(),
            ";const LL_BITS=\"",
            Base64.encode(bitStream),
            "\";const LL_SEED=\"",
            seedHex,
            "\";"
        );

        bytes memory assetShim = abi.encodePacked("window.LL_ASSETS={mona:\"", monaDataUri, "\"};");

        HTMLRequest memory req;
        req.headTags = new HTMLTag[](0);
        req.bodyTags = new HTMLTag[](3);

        // 1. Per-token data variables.
        req.bodyTags[0] = HTMLTag({
            name: "",
            contractAddress: address(0),
            contractData: "",
            tagType: 1, // <script>...</script>
            tagOpen: "",
            tagClose: "",
            tagContent: dataScript
        });

        // 2. Asset shim — exposes the Mona Lisa to the sketch.
        req.bodyTags[1] = HTMLTag({
            name: "",
            contractAddress: address(0),
            contractData: "",
            tagType: 1,
            tagOpen: "",
            tagClose: "",
            tagContent: assetShim
        });

        // 3. The sketch — pulled from ScriptyStorage by name; ScriptyBuilder
        //    emits `<script src="data:text/javascript;base64,...">`. tagType 2
        //    protects '%' from URL-decoding by some marketplace front-ends.
        req.bodyTags[2] = HTMLTag({
            name: sketchScriptName,
            contractAddress: address(scriptyStorage),
            contractData: "",
            tagType: 2,
            tagOpen: "",
            tagClose: "",
            tagContent: ""
        });

        return scriptyBuilder.getHTMLString(req);
    }

    /// @dev Pull every chunk for the pool and serialize each as 32
    ///      little-endian bytes. Trade index `i` ends up at output byte
    ///      `i >> 3`, bit `i & 7` (LSB-first within byte). The trailing
    ///      bytes beyond `total` bits are zero-fill that the JS unpacker
    ///      ignores.
    function _readBitStream(PoolId poolId, uint256 total) internal view returns (bytes memory) {
        if (total == 0) return new bytes(0);
        uint256 nChunks = (total + 255) / 256;
        bytes memory out = new bytes(nChunks * 32);
        for (uint256 i = 0; i < nChunks; i++) {
            uint256 chunk = counter.tradeChunk(poolId, i);
            uint256 base = i * 32;
            for (uint256 b = 0; b < 32; b++) {
                out[base + b] = bytes1(uint8(chunk >> (b * 8)));
            }
        }
        return out;
    }

    function _addressToHex(address a) internal pure returns (string memory) {
        bytes memory hexChars = "0123456789abcdef";
        bytes memory out = new bytes(42);
        out[0] = "0";
        out[1] = "x";
        uint160 v = uint160(a);
        for (uint256 i = 0; i < 20; i++) {
            uint8 byteVal = uint8(v >> ((19 - i) * 8));
            out[2 + i * 2] = hexChars[byteVal >> 4];
            out[2 + i * 2 + 1] = hexChars[byteVal & 0x0f];
        }
        return string(out);
    }
}
