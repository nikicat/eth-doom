// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

/// @notice Immutable per-level data. Tiles are row-major: tile(x,y) = tiles[y*width + x],
/// value 0 = passable, 1..63 = solid wall (plane-0 semantics).
interface IMap {
    function width() external view returns (uint256);
    function height() external view returns (uint256);
    function tiles() external view returns (bytes memory);
    /// @notice SSTORE2 pointer: the tilemap is the deployed code at this address
    /// (one STOP byte, then `width*height` tile bytes). Read via EXTCODECOPY from offset 1.
    function tilesPtr() external view returns (address);
    function spawn() external view returns (uint256 x, uint256 y, uint256 dir);
    /// @notice Guard spawns, 3 bytes each: tilex, tiley, dir.
    function guards() external view returns (bytes memory);
    /// @notice Doors in scan order (= doornum), 3 bytes each: tilex, tiley,
    /// (vertical | lock<<1). The tilemap encodes door tiles as `doornum | 0x80`.
    function doors() external view returns (bytes memory);
}
