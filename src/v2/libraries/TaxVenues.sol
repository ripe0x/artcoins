// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsFactoryV2} from "../interfaces/IArtCoinsFactoryV2.sol";

/// @title  TaxVenues
/// @notice Derives the CREATE2 address of a v2 or v3 style pool that pairs
///         `self` with `venue.counterToken`. A derived address is a hash, so a
///         venue admin cannot aim it at an existing holder.
library TaxVenues {
    /// @notice Uniswap v2 style pair: salt = keccak256(abi.encodePacked(t0, t1)).
    uint8 internal constant KIND_V2 = 1;
    /// @notice Uniswap v3 style pool: salt = keccak256(abi.encode(t0, t1, fee)).
    uint8 internal constant KIND_V3 = 2;

    /// @dev Returns address(0) for an unknown kind, a zero factory, or a
    ///      counter token equal to `self`; callers treat that as invalid.
    function derive(IArtCoinsFactoryV2.TaxVenue memory venue, address self)
        internal
        pure
        returns (address pool)
    {
        address counter = venue.counterToken;
        if (venue.factory == address(0) || counter == self) return address(0);
        (address t0, address t1) = self < counter ? (self, counter) : (counter, self);
        bytes32 salt;
        if (venue.kind == KIND_V2) {
            salt = keccak256(abi.encodePacked(t0, t1));
        } else if (venue.kind == KIND_V3) {
            salt = keccak256(abi.encode(t0, t1, venue.v3Fee));
        } else {
            return address(0);
        }
        pool = address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(hex"ff", venue.factory, salt, venue.initCodeHash))
                )
            )
        );
    }
}
