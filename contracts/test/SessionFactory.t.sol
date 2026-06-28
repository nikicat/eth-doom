// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Engine} from "../src/Engine.sol";
import {Map} from "../src/Map.sol";
import {Session} from "../src/Session.sol";
import {SessionFactory} from "../src/SessionFactory.sol";

contract SessionFactoryTest is Test {
    Engine internal engine;
    Map internal map;
    SessionFactory internal factory;

    function setUp() public {
        engine = new Engine();
        // 4x4 room: solid border, floor inside; player spawns at (1,1) facing east.
        bytes memory tiles = new bytes(16);
        for (uint256 y = 0; y < 4; y++) {
            for (uint256 x = 0; x < 4; x++) {
                if (x == 0 || y == 0 || x == 3 || y == 3) tiles[y * 4 + x] = 0x01;
            }
        }
        map = new Map(4, 4, tiles, 1, 1, 1, "", "", "", "", "", ""); // no guards/doors/items/areas/blockers/pushwalls
        factory = new SessionFactory();
    }

    function test_createSession_spawnsAndAdvances() public {
        assertEq(factory.sessionCount(), 0);

        address s = factory.createSession(address(engine), address(map));
        assertEq(factory.sessionCount(), 1);
        assertEq(factory.sessions(0), s);

        Session session = Session(s);
        // a fresh session has a spawned (non-empty) world state...
        assertGt(session.getState().length, 0);
        // ...and advances one tick per input without reverting.
        uint256 t0 = session.tickCount();
        session.submitInput(Engine.Cmd({controlx: 200, controly: 0, buttons: 0})); // turn right
        assertEq(session.tickCount(), t0 + 1);
    }

    function test_manySessionsShareEngineAndMap() public {
        address a = factory.createSession(address(engine), address(map));
        address b = factory.createSession(address(engine), address(map));
        assertTrue(a != b);
        assertEq(factory.sessionCount(), 2);

        // both instances are bound to the one engine + map deployment (immutable)
        assertEq(address(Session(a).engine()), address(engine));
        assertEq(Session(a).map(), address(map));
        assertEq(address(Session(b).engine()), address(engine));
        assertEq(Session(b).map(), address(map));

        // independent state: advancing one doesn't touch the other
        Session(a).submitInput(Engine.Cmd({controlx: 0, controly: 0, buttons: 0}));
        assertEq(Session(a).tickCount(), 1);
        assertEq(Session(b).tickCount(), 0);
    }
}
