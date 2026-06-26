// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

/// @notice Wolf3D fixed-point primitive — WL_DRAW.C `FixedByFrac` (asm) made portable.
library Fixed {
    int256 internal constant TILEGLOBAL = 0x10000; // one 16.16 unit

    /// @dev result = (sign(a) ^ sign-bit(b)) applied to (|a| * (b & 0xffff)) >> 16.
    ///
    /// `b` is a signed-magnitude 32-bit table value: magnitude in the low 16 bits,
    /// sign in bit 31; bits 16..30 are ignored (the asm uses only the low word).
    /// The magnitude shift rounds toward zero — NOT an arithmetic shift of a signed
    /// product — which is exactly id's behaviour and differs for negative results.
    function fixedByFrac(int256 a, uint32 b) internal pure returns (int256) {
        bool sign = (b & 0x80000000) != 0;
        uint256 fracB = uint256(b & 0xFFFF);
        uint256 ua;
        if (a < 0) {
            ua = uint256(-a);
            sign = !sign;
        } else {
            ua = uint256(a);
        }
        uint256 res = (ua * fracB) >> 16;
        return sign ? -int256(res) : int256(res);
    }
}
