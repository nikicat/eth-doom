// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {IMap} from "./IMap.sol";

/// @notice Minimal immutable map. M1 stores tiles in storage for simplicity; an
/// SSTORE2 bytecode blob (read via CODECOPY) is the planned gas optimization.
contract Map is IMap {
    uint256 public immutable width;
    uint256 public immutable height;
    uint256 private immutable _spawnX;
    uint256 private immutable _spawnY;
    uint256 private immutable _spawnDir;
    bytes private _tiles;

    constructor(uint256 w, uint256 h, bytes memory t, uint256 sx, uint256 sy, uint256 sdir) {
        require(t.length == w * h, "bad tiles length");
        width = w;
        height = h;
        _tiles = t;
        _spawnX = sx;
        _spawnY = sy;
        _spawnDir = sdir;
    }

    function tiles() external view returns (bytes memory) {
        return _tiles;
    }

    function spawn() external view returns (uint256, uint256, uint256) {
        return (_spawnX, _spawnY, _spawnDir);
    }
}
