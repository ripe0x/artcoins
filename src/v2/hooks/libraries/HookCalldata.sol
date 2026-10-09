// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  HookCalldata
/// @notice Tolerant, bounds checked parser for the swap `hookData` the v2 hook
///         accepts:
///           hookData = abi.encode(SwapData{bytes mevModuleSwapData, bytes poolExtensionSwapData})
///           mevModuleSwapData = "" or abi.encode(address refundTo)
///           poolExtensionSwapData = abi.encode(ExtensionSwapData{Attribution attribution, bytes extensionPayload})
///           Attribution = (bytes32 sourceId, address referrer, bytes16 campaignId, uint24 referralBps)
///         `referralBps` is BPS of volume, capped by the pool's maxReferralBpsOfVolume.
/// @dev    Never reverts: every offset and length is checked against the
///         calldata bounds before it is used, every sum is bounded by a small
///         multiple of `hookData.length`, so no checked arithmetic can
///         overflow. Malformed input yields an empty extension payload and/or
///         an empty attribution, never a swap revert. Values abi.decode would
///         reject (dirty high bits) yield an empty attribution.
library HookCalldata {
    struct Attribution {
        bytes32 sourceId;
        address referrer;
        bytes16 campaignId;
        uint256 referralBps;
    }

    /// @return ext The `poolExtensionSwapData` slice (empty if malformed).
    /// @return att The attribution inside it (all zero if absent or malformed).
    function decode(bytes calldata d)
        internal
        pure
        returns (bytes calldata ext, Attribution memory att)
    {
        ext = d[0:0];
        uint256 n = d.length;
        if (n < 0x60) return (ext, att);
        // outer tuple: head at t holds [offset mev, offset ext] relative to t.
        uint256 t = _word(d, 0);
        if (t > n - 0x40) return (ext, att);
        uint256 o = _word(d, t + 0x20);
        if (o > n) return (ext, att);
        uint256 p = t + o; // <= 2n
        if (p > n - 0x20) return (ext, att);
        uint256 len = _word(d, p);
        if (len > n - 0x20 - p) return (ext, att);
        ext = d[p + 0x20:p + 0x20 + len];

        // inner tuple: head at t2 holds the four attribution words.
        if (len < 0xa0) return (ext, att);
        uint256 t2 = _word(ext, 0);
        if (t2 > len - 0x80) return (ext, att);
        uint256 ref = _word(ext, t2 + 0x20);
        uint256 camp = _word(ext, t2 + 0x40);
        uint256 bps = _word(ext, t2 + 0x60);
        if (ref >> 160 != 0 || uint128(camp) != 0 || bps >> 24 != 0) return (ext, att);
        att.sourceId = bytes32(_word(ext, t2));
        att.referrer = address(uint160(ref));
        att.campaignId = bytes16(bytes32(camp));
        att.referralBps = bps;
    }

    /// @notice Optional refund address for the unfilled skim of a price
    ///         limited swap: `mevModuleSwapData == abi.encode(address)`
    ///         (exactly 32 bytes, clean high bits). Zero if absent or
    ///         malformed (the hook then refunds the PoolManager caller).
    /// @dev    Only the swapper's own over charge is at stake, and the swapper
    ///         chooses its hookData, so no authorization is needed. Never
    ///         reverts: same bounds discipline as `decode`.
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
