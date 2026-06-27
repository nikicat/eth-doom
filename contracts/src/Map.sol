// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {IMap} from "./IMap.sol";

/// @notice Immutable map. The tilemap is stored SSTORE2-style — as the runtime
/// bytecode of a tiny data contract — so the engine reads it each tick with one
/// EXTCODECOPY instead of ~w*h/32 cold SLOADs (the prior `bytes` in storage cost
/// ~270k gas/tick for a 64x64 level). Guards stay in storage; they're read once
/// at spawn, not per tick.
contract Map is IMap {
    uint256 public immutable width;
    uint256 public immutable height;
    uint256 private immutable _spawnX;
    uint256 private immutable _spawnY;
    uint256 private immutable _spawnDir;
    address private immutable _tilesPtr; // data contract: STOP byte + w*h tile bytes
    address private immutable _doorsPtr; // STOP byte + 3 bytes/door (read each tick)
    address private immutable _itemsPtr; // STOP byte + 3 bytes/item (read each tick)
    bytes private _guards;

    constructor(
        uint256 w,
        uint256 h,
        bytes memory t,
        uint256 sx,
        uint256 sy,
        uint256 sdir,
        bytes memory g,
        bytes memory d,
        bytes memory it
    ) {
        require(t.length == w * h, "bad tiles length");
        require(g.length % 3 == 0, "bad guards length");
        require(d.length % 3 == 0, "bad doors length");
        require(it.length % 3 == 0, "bad items length");
        width = w;
        height = h;
        _spawnX = sx;
        _spawnY = sy;
        _spawnDir = sdir;
        _tilesPtr = _sstore2(t);
        _doorsPtr = _sstore2(d); // SSTORE2: doors/items are read every tick, like tiles
        _itemsPtr = _sstore2(it);
        _guards = g;
    }

    /// SSTORE2 write: deploy `data` as a contract's runtime code (1 STOP byte +
    /// data, so the data can never be executed) and return its address.
    function _sstore2(bytes memory data) private returns (address pointer) {
        // 11-byte creation preamble returns the rest of the code as runtime, then
        // a STOP guard byte, then the data (Solmate SSTORE2 layout).
        bytes memory creationCode = abi.encodePacked(hex"600B5981380380925939F300", data);
        assembly {
            pointer := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        require(pointer != address(0), "tiles deploy failed");
    }

    function tilesPtr() external view returns (address) {
        return _tilesPtr;
    }

    function doorsPtr() external view returns (address) {
        return _doorsPtr;
    }

    function itemsPtr() external view returns (address) {
        return _itemsPtr;
    }

    /// Copy an SSTORE2 blob out of a data contract (skip the leading STOP byte).
    function _readPtr(address p) private view returns (bytes memory out) {
        uint256 n;
        assembly {
            n := sub(extcodesize(p), 1)
        }
        out = new bytes(n);
        assembly {
            extcodecopy(p, add(out, 0x20), 1, n)
        }
    }

    /// Backward-compatible view: copy the whole tilemap out of the data contract.
    function tiles() external view returns (bytes memory tl) {
        uint256 n = width * height;
        tl = new bytes(n);
        address p = _tilesPtr;
        assembly {
            extcodecopy(p, add(tl, 0x20), 1, n) // offset 1 skips the STOP byte
        }
    }

    function spawn() external view returns (uint256, uint256, uint256) {
        return (_spawnX, _spawnY, _spawnDir);
    }

    function guards() external view returns (bytes memory) {
        return _guards;
    }

    function doors() external view returns (bytes memory) {
        return _readPtr(_doorsPtr);
    }

    function items() external view returns (bytes memory) {
        return _readPtr(_itemsPtr);
    }
}
