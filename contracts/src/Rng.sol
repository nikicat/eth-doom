// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

/// @notice Wolf3D deterministic RNG table (ID_US_A.ASM). 256 bytes; `US_RndT`
/// advances a wrapping index (held in world state) and returns table[index].
/// Generated verbatim from the asm; do not hand-edit.
library Rng {
    bytes internal constant TABLE = hex"00086ddcdef1956b4bf8fe8c10424a15d32f50f29a1bcd80a1594d245f6e5530d48cd3f9164fc8321cbc348cca7844913e46b8be5bc598e0956819b2fcb6cab68dc50451b5f2912a27e39cc6e1c1db5d7aaff900af8f46ef2ef6a335a36da88702eb195c14918a4d45a64eb0add4a6715ea12932ef316fa4463c0225ab4b889c0b382a928ae549924d3d62c4876a3fc5c35660cb7165aaf7b57150fa6c07ffed81e24f6b70a667f118dfef78c63a3c528003b8428fe091e051cea32d3f5aa8723b219f5f1c8b7b627dc40f46c2fd360e6de24711a15dba57f48a14347bfb1a24112e34e7e84c1fdd5425d8a5d46ac5f2622b27affe91be5476debb8878a3ecf9";

    function table() internal pure returns (bytes memory t) {
        t = TABLE;
    }

    /// @dev table[idx & 0xff], reading from an in-memory copy.
    function at(bytes memory t, uint256 idx) internal pure returns (uint8 v) {
        assembly {
            v := byte(0, mload(add(add(t, 0x20), and(idx, 0xff))))
        }
    }
}
