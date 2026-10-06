// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LibString} from "solady/utils/LibString.sol";

/// @title  SvgText
/// @notice Safe handling of token controlled strings (name, symbol, description,
///         image url, admin strings) that end up inside svg text nodes, svg or
///         html attribute values, or json string fields.
///
///         Every entry point first runs `clean`, a single bounded pass that
///         - truncates to at most `maxBytes` output bytes on a utf8 character
///           boundary (a multibyte sequence is never split),
///         - replaces every byte that is not part of a strictly valid utf8
///           sequence (overlongs, surrogates, > U+10FFFF, stray continuation or
///           truncated lead bytes) with `?`,
///         - replaces C0 controls (including tab, newline, carriage return),
///           DEL and C1 controls (U+0080 to U+009F) with a space, and replaces
///           the non characters U+FFFE and U+FFFF with `?`.
///         The result is always valid utf8 and valid xml 1.0 character data, so
///         the svg and json built from it stay well formed for any input bytes.
///
///         `text` and `attr` then escape `& < > " '` with solady
///         `LibString.escapeHTML` (covers all five), so the output is safe in a
///         text node and in a single or double quoted attribute value. The json
///         helpers apply `LibString.escapeJSON`, the same helper v1 uses.
///
///         Not covered: an escaped url is still a url. Consumers that follow
///         `href` values are their own responsibility (an svg rendered through
///         `<img>` does not execute scripts or load external resources).
library SvgText {
    /// @dev json `name` field.
    uint256 internal constant NAME_MAX = 256;
    /// @dev json `symbol` field.
    uint256 internal constant SYMBOL_MAX = 64;
    /// @dev json description / metadata field.
    uint256 internal constant DESC_MAX = 4096;
    /// @dev image, external and animation urls. Longer values are dropped, not
    ///      truncated: a cut url points at the wrong thing.
    uint256 internal constant URL_MAX = 16_384;

    /// @notice Text node content: `clean` then escape `& < > " '`.
    function text(string memory s, uint256 maxBytes) internal pure returns (string memory) {
        return LibString.escapeHTML(clean(s, maxBytes));
    }

    /// @notice Attribute value content (single or double quoted): same output as `text`.
    function attr(string memory s, uint256 maxBytes) internal pure returns (string memory) {
        return LibString.escapeHTML(clean(s, maxBytes));
    }

    /// @notice Attribute url: `""` when longer than `maxBytes`, else `attr`.
    function attrUrl(string memory s, uint256 maxBytes) internal pure returns (string memory) {
        return LibString.escapeHTML(cleanOrEmpty(s, maxBytes));
    }

    /// @notice json string content (no surrounding quotes): `clean` then `escapeJSON`.
    function jsonText(string memory s, uint256 maxBytes) internal pure returns (string memory) {
        return LibString.escapeJSON(clean(s, maxBytes));
    }

    /// @notice json url content: `""` when longer than `maxBytes`, else `jsonText`.
    function jsonUrl(string memory s, uint256 maxBytes) internal pure returns (string memory) {
        return LibString.escapeJSON(cleanOrEmpty(s, maxBytes));
    }

    /// @notice `""` when `s` is longer than `maxBytes`, else `clean(s, maxBytes)`.
    function cleanOrEmpty(string memory s, uint256 maxBytes) internal pure returns (string memory) {
        if (bytes(s).length > maxBytes) return "";
        return clean(s, maxBytes);
    }

    /// @notice utf8 safe truncation plus sanitising, see the contract comment.
    /// @dev    One pass, at most `min(len, maxBytes)` output bytes, output is never
    ///         longer than the input. Work is linear in `min(len, maxBytes) + 3`.
    function clean(string memory s, uint256 maxBytes) internal pure returns (string memory result) {
        /// @solidity memory-safe-assembly
        assembly {
            result := mload(0x40)
            let o := add(result, 0x20)
            let p := add(s, 0x20)
            let end := add(p, mload(s))
            let cap := mload(s)
            if lt(maxBytes, cap) { cap := maxBytes }
            let limit := add(o, cap)
            for {} lt(p, end) {} {
                let w := mload(p)
                let rem := sub(end, p)
                let c := byte(0, w)
                // consumed bytes `n`, action `kind`: 0 copy, 1 space, 2 question mark.
                let n := 1
                let kind := 2
                switch lt(c, 0x80)
                case 1 {
                    kind := 0
                    if or(lt(c, 0x20), eq(c, 0x7f)) { kind := 1 }
                }
                default {
                    // two byte sequence, lead C2..DF
                    if and(gt(c, 0xc1), lt(c, 0xe0)) {
                        if and(gt(rem, 1), eq(and(byte(1, w), 0xc0), 0x80)) {
                            n := 2
                            kind := 0
                            // C1 controls U+0080..U+009F
                            if and(eq(c, 0xc2), lt(byte(1, w), 0xa0)) { kind := 1 }
                        }
                    }
                    // three byte sequence, lead E0..EF
                    if and(gt(c, 0xdf), lt(c, 0xf0)) {
                        if gt(rem, 2) {
                            let b1 := byte(1, w)
                            let lo := 0x80
                            let hi := 0xbf
                            if eq(c, 0xe0) { lo := 0xa0 }
                            if eq(c, 0xed) { hi := 0x9f }
                            let b2 := byte(2, w)
                            if and(
                                and(iszero(lt(b1, lo)), iszero(gt(b1, hi))),
                                eq(and(b2, 0xc0), 0x80)
                            ) {
                                n := 3
                                kind := 0
                                // U+FFFE, U+FFFF
                                if and(eq(c, 0xef), and(eq(b1, 0xbf), gt(b2, 0xbd))) {
                                    kind := 2
                                }
                            }
                        }
                    }
                    // four byte sequence, lead F0..F4
                    if and(gt(c, 0xef), lt(c, 0xf5)) {
                        if gt(rem, 3) {
                            let b1 := byte(1, w)
                            let lo := 0x80
                            let hi := 0xbf
                            if eq(c, 0xf0) { lo := 0x90 }
                            if eq(c, 0xf4) { hi := 0x8f }
                            if and(
                                and(iszero(lt(b1, lo)), iszero(gt(b1, hi))),
                                and(
                                    eq(and(byte(2, w), 0xc0), 0x80),
                                    eq(and(byte(3, w), 0xc0), 0x80)
                                )
                            ) {
                                n := 4
                                kind := 0
                            }
                        }
                    }
                }
                let m := 1
                if iszero(kind) { m := n }
                // never write past the cap, never emit half a character
                if gt(add(o, m), limit) { break }
                switch kind
                case 0 {
                    for { let j := 0 } lt(j, m) { j := add(j, 1) } {
                        mstore8(add(o, j), byte(j, w))
                    }
                }
                case 1 { mstore8(o, 0x20) }
                default { mstore8(o, 0x3f) }
                o := add(o, m)
                p := add(p, n)
            }
            mstore(o, 0) // zeroize the slot after the string
            mstore(result, sub(o, add(result, 0x20)))
            mstore(0x40, and(add(o, 0x3f), not(0x1f)))
        }
    }
}
