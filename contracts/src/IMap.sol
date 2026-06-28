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
    /// @notice Bonus items, 3 bytes each: tilex, tiley, itemnumber (WL_DEF.H stat_t).
    function items() external view returns (bytes memory);
    /// @notice Blocking decorations (WL_ACT1.C `block` statics), 2 bytes each: tilex, tiley.
    /// They block movement (player TryMove + enemy TryWalk) but not sight or bullets.
    function blockers() external view returns (bytes memory);
    /// @notice SSTORE2 pointers for the door/item lists (STOP byte + 3 bytes each),
    /// read each tick via EXTCODECOPY from offset 1. extcodesize-1 gives the length.
    function doorsPtr() external view returns (address);
    function itemsPtr() external view returns (address);
    /// @notice SSTORE2 pointer for the blockers list (STOP byte + 2 bytes each), read each tick.
    function blockersPtr() external view returns (address);
    /// @notice SSTORE2 pointer for the per-tile area map (STOP byte + width*height area
    /// bytes), or address(0)/empty when the level is a single area. Drives sound
    /// localization: gunfire only alerts guards in areas connected to the player's.
    function areasPtr() external view returns (address);
}
