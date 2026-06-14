// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title Scripty.sol v2 Interfaces
 * @notice Interfaces for interacting with Scripty.sol v2 contracts on Ethereum Mainnet
 * @dev These contracts are deployed at:
 * - ScriptyBuilderV2: 0xD7587F110E08F4D120A231bA97d3B577A81Df022
 * - ScriptyStorageV2: 0xbD11994aABB55Da86DC246EBB17C1Be0af5b7699
 * - ETHFSV2FileStorage: 0x8FAA1AAb9DA8c75917C43Fb24fDdb513edDC3245
 */

/**
 * @notice Represents an HTML tag for the Scripty builder
 * @param name Name of the script (for fetching from storage)
 * @param contractAddress Address of the storage contract
 * @param contractData Additional data for contract calls
 * @param tagType Type of tag (0=custom, 1=script, 2=scriptBase64DataURI, etc.)
 * @param tagOpen Opening tag (e.g., "<script>")
 * @param tagClose Closing tag (e.g., "</script>")
 * @param tagContent Inline content (used when contractAddress is zero)
 */
struct HTMLTag {
    string name;
    address contractAddress;
    bytes contractData;
    uint8 tagType;
    bytes tagOpen;
    bytes tagClose;
    bytes tagContent;
}

/**
 * @notice Request structure for building HTML
 * @param headTags Tags to include in <head>
 * @param bodyTags Tags to include in <body>
 */
struct HTMLRequest {
    HTMLTag[] headTags;
    HTMLTag[] bodyTags;
}

/**
 * @title IScriptyBuilderV2
 * @notice Interface for ScriptyBuilderV2 - builds complete HTML from tags
 */
interface IScriptyBuilderV2 {
    /**
     * @notice Builds an HTML string from a request
     * @param htmlRequest The HTML request with head and body tags
     * @return Complete HTML string
     */
    function getHTMLString(HTMLRequest calldata htmlRequest) external view returns (string memory);
}

/**
 * @title IScriptyStorageV2
 * @notice Interface for ScriptyStorageV2 - stores and retrieves scripts/content
 */
interface IScriptyStorageV2 {
    /**
     * @notice Create new content in storage
     * @param name Name of the content/script
     * @param details Content data as bytes
     */
    function createContent(string calldata name, bytes calldata details) external;

    /**
     * @notice Add a chunk to existing content
     * @param name Name of the content
     * @param chunk Data chunk to add
     */
    function addChunkToContent(string calldata name, bytes calldata chunk) external;

    /**
     * @notice Get content by name
     * @param name Name of the content
     * @param data Additional data (not used by ScriptyStorage but required by interface)
     * @return Content data
     */
    function getContent(string calldata name, bytes calldata data)
        external
        view
        returns (bytes memory);
}
