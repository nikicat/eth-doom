// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {Engine} from "../src/Engine.sol";
import {Map} from "../src/Map.sol";
import {Session} from "../src/Session.sol";
import {SessionFactory} from "../src/SessionFactory.sol";

/// @notice One-command deploy of the whole stack — Engine + SessionFactory (the
/// map-independent singletons), a Map, and an initial Session created through the
/// factory (so it's recorded + discoverable, and owned by the broadcasting account,
/// ready for `delegate(sessionKey, …)`):
///
///   forge script script/Deploy.s.sol --rpc-url $RPC --private-key $KEY --broadcast
///
/// Map source:
///   - default: a small self-contained test room (no external assets — CI/smoke-safe).
///   - MAP_JSON=<path>: a real extracted level. map-extract's level.json carries
///     tilesHex/guardsHex/doorsHex/itemsHex (flat bytes) for exactly this, so the
///     script reads them with one vm.parseBytes each — no nested-array JSON parsing.
///     (Add the file's dir to foundry.toml fs_permissions; web/public is allowed.)
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        (Engine engine, SessionFactory factory, Map map, address session) = deploy();
        vm.stopBroadcast();

        console2.log("Engine        ", address(engine));
        console2.log("SessionFactory", address(factory));
        console2.log("Map           ", address(map));
        console2.log("Session       ", session);
        console2.log("owner         ", Session(session).owner());
    }

    /// @notice The deploy steps, broadcast-free so `forge test` can call them directly.
    function deploy() public returns (Engine engine, SessionFactory factory, Map map, address session) {
        engine = new Engine();
        factory = new SessionFactory();
        map = _deployMap();
        session = factory.createSession(address(engine), address(map));
    }

    function _deployMap() internal returns (Map) {
        string memory path = vm.envOr("MAP_JSON", string(""));
        if (bytes(path).length == 0) {
            console2.log("Map: built-in test room (set MAP_JSON to deploy a real level)");
            return _testRoom();
        }
        console2.log("Map: from", path);
        string memory j = vm.readFile(path);
        return new Map(
            vm.parseJsonUint(j, ".w"),
            vm.parseJsonUint(j, ".h"),
            vm.parseBytes(vm.parseJsonString(j, ".tilesHex")),
            vm.parseJsonUint(j, ".spawn.x"),
            vm.parseJsonUint(j, ".spawn.y"),
            vm.parseJsonUint(j, ".spawn.dir"),
            vm.parseBytes(vm.parseJsonString(j, ".guardsHex")),
            vm.parseBytes(vm.parseJsonString(j, ".doorsHex")),
            vm.parseBytes(vm.parseJsonString(j, ".itemsHex"))
        );
    }

    /// 8x8 room: solid border, floor inside, player at (1,1) facing east, one guard
    /// at (5,5). Fully self-contained — no id assets — so a fresh chain gets a real,
    /// playable session to smoke-test the deploy + session-key flow against.
    function _testRoom() internal returns (Map) {
        uint256 w = 8;
        uint256 h = 8;
        bytes memory tiles = new bytes(w * h);
        for (uint256 y = 0; y < h; y++) {
            for (uint256 x = 0; x < w; x++) {
                if (x == 0 || y == 0 || x == w - 1 || y == h - 1) tiles[y * w + x] = 0x01;
            }
        }
        bytes memory guards = abi.encodePacked(uint8(5), uint8(5), uint8(0), uint8(0)); // tilex,tiley,dir,class
        return new Map(w, h, tiles, 1, 1, 1, guards, "", "");
    }
}
