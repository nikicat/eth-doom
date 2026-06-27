// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Engine} from "../src/Engine.sol";
import {Map} from "../src/Map.sol";
import {Session} from "../src/Session.sol";

contract SessionTest is Test {
    Engine internal engine;
    Map internal map;

    address internal player = address(0xA11CE);
    address internal burner = address(0xB0B);
    address internal stranger = address(0xBAD);

    Engine.Cmd internal noop = Engine.Cmd({controlx: 0, controly: 0, buttons: 0});

    function setUp() public {
        engine = new Engine();
        // 4x4 room: solid border, floor inside; player spawns at (1,1) facing east.
        bytes memory tiles = new bytes(16);
        for (uint256 y = 0; y < 4; y++) {
            for (uint256 x = 0; x < 4; x++) {
                if (x == 0 || y == 0 || x == 3 || y == 3) tiles[y * 4 + x] = 0x01;
            }
        }
        map = new Map(4, 4, tiles, 1, 1, 1, "", "", "", "");
        // a sane wall-clock so expiry math is meaningful
        vm.warp(1_700_000_000);
    }

    function _owned() internal returns (Session) {
        return new Session(address(engine), address(map), player);
    }

    // --- open session (owner == 0): anyone may submit (PoC / harness behavior) ---

    function test_openSession_anyoneCanSubmit() public {
        Session s = new Session(address(engine), address(map), address(0));
        assertTrue(s.isAuthorized(stranger));
        vm.prank(stranger);
        s.submitInput(noop);
        assertEq(s.tickCount(), 1);
    }

    function test_openSession_cannotDelegate() public {
        Session s = new Session(address(engine), address(map), address(0));
        vm.expectRevert(Session.SessionOpen.selector);
        s.delegate(burner, uint64(block.timestamp + 1 hours));
    }

    // --- owned session: owner submits, stranger can't ---

    function test_ownedSession_ownerSubmits_strangerReverts() public {
        Session s = _owned();
        assertTrue(s.isAuthorized(player));
        assertFalse(s.isAuthorized(stranger));

        vm.prank(player);
        s.submitInput(noop);
        assertEq(s.tickCount(), 1);

        vm.prank(stranger);
        vm.expectRevert(Session.NotAuthorized.selector);
        s.submitInput(noop);
    }

    // --- session-key delegation ---

    function test_delegate_burnerCanSubmitUntilExpiry() public {
        Session s = _owned();
        uint64 expiry = uint64(block.timestamp + 1 hours);

        vm.prank(player);
        s.delegate(burner, expiry);
        assertEq(s.sessionKeyExpiry(burner), expiry);
        assertTrue(s.isAuthorized(burner));

        // burner plays popup-free
        vm.prank(burner);
        s.submitInput(noop);
        assertEq(s.tickCount(), 1);

        // ...until the key lapses
        vm.warp(expiry);
        assertFalse(s.isAuthorized(burner));
        vm.prank(burner);
        vm.expectRevert(Session.NotAuthorized.selector);
        s.submitInput(noop);
    }

    function test_delegate_onlyOwner() public {
        Session s = _owned();
        vm.prank(stranger);
        vm.expectRevert(Session.NotOwner.selector);
        s.delegate(burner, uint64(block.timestamp + 1 hours));
    }

    function test_delegate_rejectsZeroKeyAndPastExpiry() public {
        Session s = _owned();
        vm.startPrank(player);
        vm.expectRevert(Session.ZeroKey.selector);
        s.delegate(address(0), uint64(block.timestamp + 1 hours));
        vm.expectRevert(Session.BadExpiry.selector);
        s.delegate(burner, uint64(block.timestamp)); // not strictly in the future
        vm.stopPrank();
    }

    function test_revoke_killsKeyEarly() public {
        Session s = _owned();
        uint64 expiry = uint64(block.timestamp + 1 hours);
        vm.startPrank(player);
        s.delegate(burner, expiry);
        assertTrue(s.isAuthorized(burner));
        s.revoke(burner);
        vm.stopPrank();

        assertFalse(s.isAuthorized(burner));
        assertEq(s.sessionKeyExpiry(burner), 0);
        vm.prank(burner);
        vm.expectRevert(Session.NotAuthorized.selector);
        s.submitInput(noop);
    }

    function test_revoke_onlyOwner() public {
        Session s = _owned();
        vm.prank(player);
        s.delegate(burner, uint64(block.timestamp + 1 hours));
        vm.prank(stranger);
        vm.expectRevert(Session.NotOwner.selector);
        s.revoke(burner);
    }
}
