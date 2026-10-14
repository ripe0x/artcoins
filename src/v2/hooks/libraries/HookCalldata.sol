// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  HookCalldata
/// @notice Tolerant, bounds checked parser for the swap `hookData` the v2 hook
///         accepts:
///           hookData = abi.encode(SwapData{bytes mevModuleSwapData, bytes poolExtensionSwapData})
///           mevModuleSwapData = "" or abi.encode(address refundTo)
///           poolExtensionSwapData = "" or abi.encode(address referrer, bytes extensionPayload)
/// @dev    Never reverts: every offset and length is checked against the
///         calldata bounds before it is used, every sum is bounded by a small
///         multiple of `hookData.length`, so no checked arithmetic can
///         overflow. Malformed input yields an empty extension payload and/or
///         a zero referrer, never a swap revert. A referrer word with dirty
///         high bits yields a zero referrer.
library HookCalldata {
    /// @notice Parses the extension slice and the referrer out of `hookData`.
    /// @param d The swap `hookData`.
    /// @return ext The `poolExtensionSwapData` slice (empty if malformed).
    /// @return referrer The referrer named in it (zero if absent or malformed).
    /// @dev    Never reverts.
    function decode(bytes calldata d) internal pure returns (bytes calldata ext, address referrer) {
        ext = d[0:0];
        uint256 n = d.length;
        if (n < 0x60) return (ext, referrer);
        // outer tuple: head at t holds [offset mev, offset ext] relative to t.
        uint256 t = _word(d, 0);
        if (t > n - 0x40) return (ext, referrer);
        uint256 o = _word(d, t + 0x20);
        if (o > n) return (ext, referrer);
        uint256 p = t + o; // <= 2n
        if (p > n - 0x20) return (ext, referrer);
        uint256 len = _word(d, p);
        if (len > n - 0x20 - p) return (ext, referrer);
        ext = d[p + 0x20:p + 0x20 + len];

        // inner tuple: the first head word is the referrer.
        if (len < 0x40) return (ext, referrer);
        uint256 ref = _word(ext, 0);
        if (ref >> 160 != 0) return (ext, referrer);
        referrer = address(uint160(ref));
    }

    /// @notice Optional refund address for the unfilled skim of a price
    ///         limited swap: `mevModuleSwapData == abi.encode(address)`
    ///         (exactly 32 bytes, clean high bits). Zero if absent or
    ///         malformed (the hook then refunds the PoolManager caller).
    /// @dev    The swapper chooses its hookData and the refund is its own over
    ///         charge, so no authorization applies. Never reverts: same bounds
    ///         checks as `decode`.
    /// @param d The swap `hookData`.
    /// @return to The refund address, or 0.
    function refundTo(bytes calldata d) internal pure returns (address to) {
        uint256 n = d.length;
        if (n < 0x60) return address(0);
        uint256 t = _word(d, 0);
        if (t > n - 0x40) return address(0);
        uint256 o = _word(d, t);
        if (o > n) return address(0);
        uint256 p = t + o; // <= 2n
        if (p > n - 0x40) return address(0);
        if (_word(d, p) != 0x20) return address(0);
        uint256 w = _word(d, p + 0x20);
        if (w >> 160 != 0) return address(0);
        to = address(uint160(w));
    }

    /// @dev Caller guarantees `i + 32 <= d.length`.
    function _word(bytes calldata d, uint256 i) private pure returns (uint256 w) {
        assembly ("memory-safe") {
            w := calldataload(add(d.offset, i))
        }
    }
}
