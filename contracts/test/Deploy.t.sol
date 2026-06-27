// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {Engine} from "../src/Engine.sol";
import {Map} from "../src/Map.sol";
import {Session} from "../src/Session.sol";
import {SessionFactory} from "../src/SessionFactory.sol";

contract DeployTest is Test {
    /// The default (no MAP_JSON) path deploys the built-in test room and a live,
    /// owned, advancing session recorded in the factory.
    function test_deploy_testRoom_spawnsAdvancingOwnedSession() public {
        Deploy d = new Deploy();
        (Engine engine, SessionFactory factory, Map map, address session) = d.deploy();

        assertTrue(address(engine) != address(0));
        assertTrue(address(map) != address(0));
        assertEq(factory.sessionCount(), 1);
        assertEq(factory.sessions(0), session);

        Session s = Session(session);
        // bound to this engine/map, owned by whoever drove createSession (here `d`).
        assertEq(address(s.engine()), address(engine));
        assertEq(s.map(), address(map));
        address owner = s.owner();
        assertEq(owner, address(d));
        assertGt(s.getState().length, 0);

        // owner advances the world one tick; the burner flow would delegate first.
        vm.prank(owner);
        s.submitInput(Engine.Cmd({controlx: 200, controly: 0, buttons: 0}));
        assertEq(s.tickCount(), 1);
    }
}
