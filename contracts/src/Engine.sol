// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Fixed} from "./Fixed.sol";
import {Trig} from "./Trig.sol";
import {Rng} from "./Rng.sol";
import {IMap} from "./IMap.sol";

/// @notice Stateless Wolf3D world-simulation engine (M2b: movement + one guard's
/// chase AI). 1:1 transliteration of WL_AGENT.C (player movement) + WL_STATE.C /
/// WL_ACT2.C / WL_PLAY.C (actor model). The C `sim_oracle` is the ground truth.
///
/// State is `abi.encode(Player, Actor[], rndindex)` (bit-packing is a later opt).
/// actorat is omitted: with a single guard there is no actor-actor collision, so
/// TryWalk checks walls directly — faithful for this scope.
contract Engine {
    // --- WL_DEF.H constants ---
    int256 internal constant TILEGLOBAL = 0x10000;
    int256 internal constant MINDIST = 0x5800;
    int256 internal constant MINSIGHT = 0x18000; // CheckSight auto-see radius
    int256 internal constant PLAYERSIZE = MINDIST;
    int256 internal constant MINACTORDIST = 0x10000;
    int256 internal constant ANGLES = 360;
    int256 internal constant MOVESCALE = 150;
    int256 internal constant BACKMOVESCALE = 100;
    int256 internal constant ANGLESCALE = 20;
    int256 internal constant SPDPATROL = 512;
    int256 internal constant RUNSPEED = 6000;
    int256 internal constant FOCALLENGTH = 0x5700;
    int256 internal constant ACTORSIZE = 0x4000;
    int256 internal constant ATTACKRATE = 14;
    int256 internal constant STARTAMMO = 8;
    int256 internal constant TICS = 1;
    uint8 internal constant BT_STRAFE = 0x02;
    uint8 internal constant BT_USE = 3; // buttons bit index

    // --- doors (WL_ACT1.C / WL_DEF.H) ---
    uint256 internal constant OPENTICS = 300;
    uint256 internal constant DR_OPEN = 0;
    uint256 internal constant DR_CLOSED = 1;
    uint256 internal constant DR_OPENING = 2;
    uint256 internal constant DR_CLOSING = 3;
    uint256 internal constant DR_LOCK1 = 1;
    uint256 internal constant DR_LOCK4 = 4;

    // --- bonus item numbers (WL_DEF.H stat_t) ---
    uint256 internal constant BO_GIBS = 3;
    uint256 internal constant BO_ALPO = 4;
    uint256 internal constant BO_FIRSTAID = 5;
    uint256 internal constant BO_KEY1 = 6;
    uint256 internal constant BO_KEY4 = 9;
    uint256 internal constant BO_CROSS = 10;
    uint256 internal constant BO_CHALICE = 11;
    uint256 internal constant BO_BIBLE = 12;
    uint256 internal constant BO_CROWN = 13;
    uint256 internal constant BO_CLIP = 14;
    uint256 internal constant BO_CLIP2 = 15;
    uint256 internal constant BO_MACHINEGUN = 16;
    uint256 internal constant BO_CHAINGUN = 17;
    uint256 internal constant BO_FOOD = 18;
    uint256 internal constant BO_FULLHEAL = 19;
    uint256 internal constant BO_25CLIP = 20;

    // dirtype: east=0 ne=1 north=2 nw=3 west=4 sw=5 south=6 se=7 nodir=8
    int256 internal constant EAST = 0;
    int256 internal constant NORTH = 2;
    int256 internal constant WEST = 4;
    int256 internal constant SOUTH = 6;
    int256 internal constant NODIR = 8;

    // flags
    uint8 internal constant FL_SHOOTABLE = 1;
    uint8 internal constant FL_NEVERMARK = 4;
    uint8 internal constant FL_ATTACKMODE = 16;
    uint8 internal constant FL_FIRSTATTACK = 32;
    uint8 internal constant FL_AMBUSH = 64;

    // think / action ids
    uint256 internal constant TH_STAND = 1;
    uint256 internal constant TH_CHASE = 2;
    uint256 internal constant TH_DOGCHASE = 4;
    uint256 internal constant AC_BITE = 3;

    // guard + SS state ids (match the oracle's enum)
    uint256 internal constant S_GRDSTAND = 0;
    uint256 internal constant S_GRDCHASE1 = 1;
    uint256 internal constant S_GRDSHOOT1 = 7;
    uint256 internal constant S_GRDDIE1 = 10;
    uint256 internal constant S_GRDPAIN = 14;
    uint256 internal constant S_GRDPAIN1 = 15;
    uint256 internal constant S_SSSTAND = 16;
    uint256 internal constant S_SSCHASE1 = 17;
    uint256 internal constant S_SSSHOOT1 = 23;
    uint256 internal constant S_SSDIE1 = 32;
    uint256 internal constant S_SSPAIN = 36;
    uint256 internal constant S_SSPAIN1 = 37;
    uint256 internal constant S_DOGSTAND = 38;
    uint256 internal constant S_DOGCHASE1 = 39;
    uint256 internal constant S_DOGJUMP1 = 45;
    uint256 internal constant S_DOGDIE1 = 50;
    uint256 internal constant S_OFCSTAND = 54;
    uint256 internal constant S_OFCCHASE1 = 55;
    uint256 internal constant S_OFCSHOOT1 = 61;
    uint256 internal constant S_OFCDIE1 = 64;
    uint256 internal constant S_OFCPAIN = 69;
    uint256 internal constant S_OFCPAIN1 = 70;

    // classtype: guardobj=3, officerobj=4, ssobj=5, dogobj=6 (obclass = guardobj + enemy_t)
    uint8 internal constant GUARDOBJ = 3;
    uint8 internal constant OFFICEROBJ = 4;
    uint8 internal constant SSOBJ = 5;
    uint8 internal constant DOGOBJ = 6;
    uint256 internal constant EN_OFFICER = 1;
    uint256 internal constant EN_SS = 2;
    uint256 internal constant EN_DOG = 3;
    int256 internal constant HP_SS = 100;
    int256 internal constant HP_DOG = 1;
    int256 internal constant HP_OFFICER = 50;
    int256 internal constant SPDDOG = 1500;

    // direction tables (WL_STATE.C). OPPOSITE[9]; DIAGONAL[9][9] row-major.
    bytes internal constant OPPOSITE = hex"040506070001020308";
    bytes internal constant DIAGONAL =
        hex"080801080808070808" hex"080808080808080808" hex"010808080308080808"
        hex"080808080808080808" hex"080803080808050808" hex"080808080808080808"
        hex"070808080508080808" hex"080808080808080808" hex"080808080808080808";

    struct Player {
        int256 x;
        int256 y;
        int256 angle;
        uint256 tilex;
        uint256 tiley;
        int256 anglefrac;
        int256 health;
        int256 ammo;
        int256 attackcount;
        uint256 useheld; // buttonheld[bt_use] edge latch
        uint256 keys; // gamestate.keys bitmask (bo_key1..4 -> bits 0..3)
        int256 score; // gamestate.score
    }

    // Bonus items are NOT a struct array: their static data (3 bytes each: tilex,
    // tiley, itemnumber) lives in `World.itemData` straight from the Map, and the only
    // dynamic per-item state is one "taken" bit, held in the `World.itemTaken` bitmask.
    // (Building a 48-element struct array every tick was the single biggest gas cost.)

    /// @dev WL_ACT1.C doorobj_t. tilex/tiley/vertical/lock are static (from Map);
    /// action/ticcount/position are the per-tick dynamic state (packed).
    struct Door {
        uint256 tilex;
        uint256 tiley;
        uint256 vertical;
        uint256 lock;
        uint256 action; // DR_OPEN/CLOSED/OPENING/CLOSING
        int256 ticcount;
        int256 position; // leading edge 0=closed..0xffff=open
    }

    struct Actor {
        int256 x;
        int256 y;
        uint256 tilex;
        uint256 tiley;
        int256 dir;
        uint256 state;
        int256 ticcount;
        int256 distance;
        int256 hitpoints;
        uint8 flags;
        uint8 obclass;
        int256 speed;
        uint8 active;
        int256 temp2; // sight reaction countdown (SightPlayer)
    }

    struct Cmd {
        int256 controlx;
        int256 controly;
        uint8 buttons;
    }

    /// @dev Per-tick working context (mutable: p/actors/doors/rndindex; rest read-only).
    struct World {
        Player p;
        Actor[] actors;
        Door[] doors;
        bytes itemData; // static: 3 bytes/item (tilex, tiley, itemnumber), from the Map
        uint256[] itemTaken; // dynamic: bit i = item i taken (ceil(numItems/256) words)
        uint256 numItems;
        uint256 rndindex;
        bytes tiles;
        uint256 w;
        uint256 h;
        bytes trig;
        bytes rnd;
        int256 plux;
        int256 pluy;
        int256 thrustspeed;
        bool madenoise; // player fired this tic (alerts guards in the area)
    }

    // ---------------- public API ----------------

    function spawn(address map) external view returns (bytes memory) {
        World memory wd = _load(map);
        (uint256 ptx, uint256 pty, uint256 dir) = IMap(map).spawn();
        wd.p.x = (int256(ptx) << 16) + TILEGLOBAL / 2;
        wd.p.y = (int256(pty) << 16) + TILEGLOBAL / 2;
        wd.p.angle = (1 - int256(dir)) * 90;
        if (wd.p.angle < 0) wd.p.angle += ANGLES;
        wd.p.tilex = uint256(wd.p.x >> 16);
        wd.p.tiley = uint256(wd.p.y >> 16);
        wd.p.health = 100;
        wd.p.ammo = STARTAMMO;

        bytes memory guards = IMap(map).guards(); // 4 bytes each: tilex,tiley,dir,class
        uint256 n = guards.length / 4;
        wd.actors = new Actor[](n);
        for (uint256 i = 0; i < n; i++) {
            _spawnEnemy(
                wd.actors[i],
                uint8(guards[i * 4 + 3]), // enemy_t (en_guard / en_ss)
                uint8(guards[i * 4]),
                uint8(guards[i * 4 + 1]),
                uint8(guards[i * 4 + 2])
            );
        }
        return _pack(wd);
    }

    function tick(bytes calldata state, address map, Cmd calldata cmd)
        external
        view
        returns (bytes memory)
    {
        World memory wd = _load(map);
        _unpack(state, wd); // fills p, doors (dynamic), actors, rndindex

        // WL_PLAY.C PlayLoop order: MoveDoors, then the player's T_Player
        // (ControlMovement + Cmd_Use + weapon), then every actor's DoActor.
        _moveDoors(wd);
        _controlMovement(wd, cmd);
        wd.plux = wd.p.x >> 8; // UNSIGNEDSHIFT
        wd.pluy = wd.p.y >> 8;
        _cmdUse(wd, cmd);
        _playerAttack(wd, cmd);
        for (uint256 i = 0; i < wd.actors.length; i++) {
            _doActor(wd, wd.actors[i]);
        }
        _getBonuses(wd); // WL_DRAW.C ThreeDRefresh: pick up bonuses on the player tile
        return _pack(wd);
    }

    // ---------------- setup ----------------

    function _load(address map) internal view returns (World memory wd) {
        wd.w = IMap(map).width();
        wd.h = IMap(map).height();
        // read the tilemap from the Map's SSTORE2 data contract in one EXTCODECOPY
        // (skip the leading STOP byte) — far cheaper than reloading it from storage.
        uint256 n = wd.w * wd.h;
        bytes memory tl = new bytes(n);
        address p = IMap(map).tilesPtr();
        assembly {
            extcodecopy(p, add(tl, 0x20), 1, n)
        }
        wd.tiles = tl;
        wd.trig = Trig.table();
        wd.rnd = Rng.table();

        // doors: static fields from the Map (3 bytes each: tilex, tiley,
        // vertical|lock<<1), in scan order = doornum. Dynamic fields default to
        // fully closed; tick() overwrites them from the packed state. Read SSTORE2-
        // style (one EXTCODECOPY) rather than an abi-encoded storage `bytes` return.
        bytes memory dd = _readPtr(IMap(map).doorsPtr());
        uint256 nd = dd.length / 3;
        wd.doors = new Door[](nd);
        for (uint256 i = 0; i < nd; i++) {
            Door memory dr = wd.doors[i];
            dr.tilex = uint8(dd[i * 3]);
            dr.tiley = uint8(dd[i * 3 + 1]);
            uint256 vl = uint8(dd[i * 3 + 2]);
            dr.vertical = vl & 1;
            dr.lock = vl >> 1;
            dr.action = DR_CLOSED;
            dr.position = 0;
            dr.ticcount = 0;
        }

        // bonus items: just the raw static bytes from the Map (no struct array) + a
        // zeroed taken bitmask; tick() overwrites the bitmask from the state.
        wd.itemData = _readPtr(IMap(map).itemsPtr());
        wd.numItems = wd.itemData.length / 3;
        wd.itemTaken = new uint256[](wd.numItems == 0 ? 0 : (wd.numItems + 255) / 256);
    }

    /// Copy an SSTORE2 blob out of a data contract via one EXTCODECOPY (the first
    /// byte is a STOP guard; extcodesize-1 is the data length).
    function _readPtr(address p) internal view returns (bytes memory out) {
        uint256 n;
        assembly {
            n := sub(extcodesize(p), 1)
        }
        out = new bytes(n);
        assembly {
            extcodecopy(p, add(out, 0x20), 1, n)
        }
    }

    /// WL_ACT2.C SpawnStand(which): spawn a dormant guard or SS, standing and facing
    /// a cardinal direction (dir*2), at patrol speed. It wakes via T_Stand ->
    /// SightPlayer (LOS or noise), not at spawn. `active` stays ac_yes so the headless
    /// sim keeps running its think every tic.
    function _spawnEnemy(Actor memory a, uint256 which, uint256 tilex, uint256 tiley, uint256 dir)
        internal
        pure
    {
        a.tilex = tilex;
        a.tiley = tiley;
        a.x = (int256(tilex) << 16) + TILEGLOBAL / 2;
        a.y = (int256(tiley) << 16) + TILEGLOBAL / 2;
        a.dir = int256((dir & 3) * 2); // 4-way 0..3 -> dirtype east/north/west/south
        a.active = 1; // ac_yes
        a.flags = FL_SHOOTABLE;
        a.speed = SPDPATROL;
        a.temp2 = 0;
        if (which == EN_SS) {
            a.state = S_SSSTAND;
            a.obclass = SSOBJ;
            a.hitpoints = HP_SS;
        } else if (which == EN_DOG) {
            a.state = S_DOGSTAND;
            a.obclass = DOGOBJ;
            a.hitpoints = HP_DOG;
            a.speed = SPDDOG;
        } else if (which == EN_OFFICER) {
            a.state = S_OFCSTAND;
            a.obclass = OFFICEROBJ;
            a.hitpoints = HP_OFFICER;
        } else {
            a.state = S_GRDSTAND; // tictime 0 -> ticcount 0, think runs each tic
            a.obclass = GUARDOBJ;
            a.hitpoints = 25;
        }
    }

    // ---------------- player movement (WL_AGENT.C) ----------------

    function _controlMovement(World memory wd, Cmd calldata cmd) internal pure {
        Player memory p = wd.p;
        int256 angle;
        wd.thrustspeed = 0;
        if ((cmd.buttons & BT_STRAFE) != 0) {
            if (cmd.controlx > 0) {
                angle = p.angle - ANGLES / 4;
                if (angle < 0) angle += ANGLES;
                _thrust(wd, angle, cmd.controlx * MOVESCALE);
            } else if (cmd.controlx < 0) {
                angle = p.angle + ANGLES / 4;
                if (angle >= ANGLES) angle -= ANGLES;
                _thrust(wd, angle, -cmd.controlx * MOVESCALE);
            }
        } else {
            p.anglefrac += cmd.controlx;
            int256 angleunits = p.anglefrac / ANGLESCALE;
            p.anglefrac -= angleunits * ANGLESCALE;
            p.angle -= angleunits;
            if (p.angle >= ANGLES) p.angle -= ANGLES;
            if (p.angle < 0) p.angle += ANGLES;
        }
        if (cmd.controly < 0) {
            _thrust(wd, p.angle, -cmd.controly * MOVESCALE);
        } else if (cmd.controly > 0) {
            angle = p.angle + ANGLES / 2;
            if (angle >= ANGLES) angle -= ANGLES;
            _thrust(wd, angle, cmd.controly * BACKMOVESCALE);
        }
    }

    function _thrust(World memory wd, int256 angle, int256 speed) internal pure {
        wd.thrustspeed += speed;
        if (speed >= MINDIST * 2) speed = MINDIST * 2 - 1;
        int256 xmove = Fixed.fixedByFrac(speed, Trig.cosAt(wd.trig, uint256(angle)));
        int256 ymove = -Fixed.fixedByFrac(speed, Trig.sinAt(wd.trig, uint256(angle)));
        _clipMovePlayer(wd, xmove, ymove);
        wd.p.tilex = uint256(wd.p.x >> 16);
        wd.p.tiley = uint256(wd.p.y >> 16);
    }

    function _clipMovePlayer(World memory wd, int256 xmove, int256 ymove) internal pure {
        int256 basex = wd.p.x;
        int256 basey = wd.p.y;
        wd.p.x = basex + xmove;
        wd.p.y = basey + ymove;
        if (_tryMovePlayer(wd)) return;
        wd.p.x = basex + xmove;
        wd.p.y = basey;
        if (_tryMovePlayer(wd)) return;
        wd.p.x = basex;
        wd.p.y = basey + ymove;
        if (_tryMovePlayer(wd)) return;
        wd.p.x = basex;
        wd.p.y = basey;
    }

    function _tryMovePlayer(World memory wd) internal pure returns (bool) {
        int256 xl = (wd.p.x - PLAYERSIZE) >> 16;
        int256 yl = (wd.p.y - PLAYERSIZE) >> 16;
        int256 xh = (wd.p.x + PLAYERSIZE) >> 16;
        int256 yh = (wd.p.y + PLAYERSIZE) >> 16;
        for (int256 y = yl; y <= yh; y++) {
            for (int256 x = xl; x <= xh; x++) {
                if (x < 0 || x >= int256(wd.w) || y < 0 || y >= int256(wd.h)) return false;
                if (_actorTile(wd, x, y) != 0) return false; // door is solid until fully open
            }
        }
        return true;
    }

    /// @dev Effective `actorat` for a tile: a wall is its value; a door tile
    /// (`doornum|0x80`) reads as solid UNLESS the door is fully open (DR_OPEN),
    /// matching id clearing `actorat` in DoorOpening. (No actor grid, so actors
    /// don't occupy tiles here — the documented single-area simplification.)
    function _actorTile(World memory wd, int256 x, int256 y) internal pure returns (uint256) {
        if (x < 0 || x >= int256(wd.w) || y < 0 || y >= int256(wd.h)) return 1; // OOB = solid
        uint256 v = _tile(wd, uint256(y) * wd.w + uint256(x));
        if (v & 0x80 != 0) {
            if (wd.doors[v & 0x7f].action == DR_OPEN) return 0; // fully open: passable
        }
        return v;
    }

    // ---------------- doors (WL_ACT1.C / WL_AGENT.C) ----------------
    // Area connectivity (areaconnect/ConnectAreas) and audio are dropped: the
    // single-area map keeps every area connected, so doors block, slide, gate LOS
    // (via _losHit + position), auto-close, and open on bump/use — but cross-door
    // sound localization is lost (madenoise reaches every guard).

    function _moveDoors(World memory wd) internal pure {
        for (uint256 i = 0; i < wd.doors.length; i++) {
            uint256 action = wd.doors[i].action;
            if (action == DR_OPEN) _doorOpen(wd, i);
            else if (action == DR_OPENING) _doorOpening(wd, i);
            else if (action == DR_CLOSING) _doorClosing(wd, i);
        }
    }

    function _openDoor(World memory wd, uint256 d) internal pure {
        if (wd.doors[d].action == DR_OPEN) wd.doors[d].ticcount = 0; // reset open time
        else wd.doors[d].action = DR_OPENING;
    }

    function _closeDoor(World memory wd, uint256 d) internal pure {
        Door memory door = wd.doors[d];
        // don't close on anything solid: the door's own marker is set unless fully
        // open (id's `if (actorat[tilex][tiley]) return;`), nor on the player.
        if (door.action != DR_OPEN) return;
        if (wd.p.tilex == door.tilex && wd.p.tiley == door.tiley) return;
        if (door.vertical != 0) {
            if (wd.p.tiley == door.tiley) {
                if ((wd.p.x + MINDIST) >> 16 == int256(door.tilex)) return;
                if ((wd.p.x - MINDIST) >> 16 == int256(door.tilex)) return;
            }
        } else {
            if (wd.p.tilex == door.tilex) {
                if ((wd.p.y + MINDIST) >> 16 == int256(door.tiley)) return;
                if ((wd.p.y - MINDIST) >> 16 == int256(door.tiley)) return;
            }
        }
        door.action = DR_CLOSING; // (adjacent-actor straddle checks dropped: no door grid)
    }

    function _operateDoor(World memory wd, uint256 d) internal pure {
        uint256 lock = wd.doors[d].lock;
        if (lock >= DR_LOCK1 && lock <= DR_LOCK4) {
            if ((wd.p.keys & (1 << (lock - DR_LOCK1))) == 0) return; // locked: need the key
        }
        uint256 action = wd.doors[d].action;
        if (action == DR_CLOSED || action == DR_CLOSING) _openDoor(wd, d);
        else if (action == DR_OPEN || action == DR_OPENING) _closeDoor(wd, d);
    }

    function _doorOpen(World memory wd, uint256 d) internal pure {
        wd.doors[d].ticcount += TICS;
        if (wd.doors[d].ticcount >= int256(OPENTICS)) _closeDoor(wd, d);
    }

    function _doorOpening(World memory wd, uint256 d) internal pure {
        int256 position = wd.doors[d].position;
        position += TICS << 10; // slide open an adaptive amount
        if (position >= 0xffff) {
            position = 0xffff;
            wd.doors[d].ticcount = 0;
            wd.doors[d].action = DR_OPEN; // actorat cleared (now passable)
        }
        wd.doors[d].position = position;
    }

    function _doorClosing(World memory wd, uint256 d) internal pure {
        Door memory door = wd.doors[d];
        // something got inside the door? (only the player is tracked, no actor grid)
        if (wd.p.tilex == door.tilex && wd.p.tiley == door.tiley) {
            _openDoor(wd, d);
            return;
        }
        int256 position = door.position - (TICS << 10);
        if (position <= 0) {
            position = 0;
            door.action = DR_CLOSED;
            door.ticcount = 0; // normalize a closed door to all-zero (see oracle note)
        }
        door.position = position;
    }

    /// WL_AGENT.C Cmd_Use — operate the door the player faces (edge-triggered via
    /// useheld). Elevator + pushwall paths dropped.
    function _cmdUse(World memory wd, Cmd calldata cmd) internal pure {
        if (((cmd.buttons >> BT_USE) & 1) == 0) {
            wd.p.useheld = 0;
            return;
        }
        if (wd.p.useheld != 0) return;

        int256 cx;
        int256 cy;
        int256 angle = wd.p.angle;
        int256 ptx = int256(wd.p.tilex);
        int256 pty = int256(wd.p.tiley);
        if (angle < ANGLES / 8 || angle > 7 * ANGLES / 8) {
            cx = ptx + 1;
            cy = pty;
        } else if (angle < 3 * ANGLES / 8) {
            cx = ptx;
            cy = pty - 1;
        } else if (angle < 5 * ANGLES / 8) {
            cx = ptx - 1;
            cy = pty;
        } else {
            cx = ptx;
            cy = pty + 1;
        }
        if (cx < 0 || cx >= int256(wd.w) || cy < 0 || cy >= int256(wd.h)) return;
        uint256 doortile = _tile(wd, uint256(cy) * wd.w + uint256(cx));
        if (doortile & 0x80 != 0) {
            wd.p.useheld = 1;
            _operateDoor(wd, doortile & 0x7f);
        }
    }

    // ---------------- pickups (WL_AGENT.C GetBonus) ----------------
    // Render-coupled in id (WL_DRAW.C TransformTile -> the item's tile is the
    // player's); the headless equivalent is "player on the item tile". Effects
    // faithful; sound/treasurecount/lives/weapon-switching dropped (weapon pickups
    // still grant their GiveAmmo(6)).

    function _healSelf(World memory wd, int256 points) internal pure {
        wd.p.health += points;
        if (wd.p.health > 100) wd.p.health = 100;
    }

    function _giveAmmo(World memory wd, int256 n) internal pure {
        wd.p.ammo += n;
        if (wd.p.ammo > 99) wd.p.ammo = 99;
    }

    /// Apply one bonus to the player; return true if it was consumed (remove it).
    function _getBonus(World memory wd, uint256 n) internal pure returns (bool) {
        if (n == BO_FIRSTAID) {
            if (wd.p.health == 100) return false;
            _healSelf(wd, 25);
        } else if (n >= BO_KEY1 && n <= BO_KEY4) {
            wd.p.keys |= (1 << (n - BO_KEY1));
        } else if (n == BO_CROSS) {
            wd.p.score += 100;
        } else if (n == BO_CHALICE) {
            wd.p.score += 500;
        } else if (n == BO_BIBLE) {
            wd.p.score += 1000;
        } else if (n == BO_CROWN) {
            wd.p.score += 5000;
        } else if (n == BO_CLIP) {
            if (wd.p.ammo == 99) return false;
            _giveAmmo(wd, 8);
        } else if (n == BO_CLIP2) {
            if (wd.p.ammo == 99) return false;
            _giveAmmo(wd, 4);
        } else if (n == BO_25CLIP) {
            if (wd.p.ammo == 99) return false;
            _giveAmmo(wd, 25);
        } else if (n == BO_MACHINEGUN || n == BO_CHAINGUN) {
            _giveAmmo(wd, 6); // GiveWeapon -> GiveAmmo(6); weapon switch dropped
        } else if (n == BO_FULLHEAL) {
            _healSelf(wd, 99);
            _giveAmmo(wd, 25);
        } else if (n == BO_FOOD) {
            if (wd.p.health == 100) return false;
            _healSelf(wd, 10);
        } else if (n == BO_ALPO) {
            if (wd.p.health == 100) return false;
            _healSelf(wd, 4);
        } else if (n == BO_GIBS) {
            if (wd.p.health > 10) return false;
            _healSelf(wd, 1);
        } else {
            return false; // bo_spear / unknown
        }
        return true;
    }

    function _getBonuses(World memory wd) internal pure {
        for (uint256 i = 0; i < wd.numItems; i++) {
            uint256 wIdx = i >> 8;
            uint256 bit = uint256(1) << (i & 0xff);
            if (wd.itemTaken[wIdx] & bit != 0) continue;
            uint256 base = i * 3;
            if (wd.p.tilex == _itemByte(wd, base) && wd.p.tiley == _itemByte(wd, base + 1)) {
                if (_getBonus(wd, _itemByte(wd, base + 2))) wd.itemTaken[wIdx] |= bit;
            }
        }
    }

    function _itemByte(World memory wd, uint256 idx) internal pure returns (uint256 v) {
        bytes memory d = wd.itemData;
        assembly {
            v := byte(0, mload(add(add(d, 0x20), idx)))
        }
    }

    // ---------------- enemy AI (WL_STATE.C / WL_ACT2.C / WL_PLAY.C) ----------------

    function _rnd(World memory wd) internal pure returns (uint256) {
        wd.rndindex = (wd.rndindex + 1) & 0xff;
        return Rng.at(wd.rnd, wd.rndindex);
    }

    /// WL_STATE.C TryWalk (guard: CHECKSIDE on cardinals, CHECKDIAG on diagonals).
    /// A door on a cardinal step doesn't block — it's opened and the guard waits
    /// (distance = -doornum-1); a door on a diagonal blocks. Returns success.
    function _tryWalk(World memory wd, Actor memory a) internal pure returns (bool) {
        int256 tx = int256(a.tilex);
        int256 ty = int256(a.tiley);
        int256 doornum = -1;
        bool dog = a.obclass == DOGOBJ;
        if (a.dir == 0) {
            // east
            (bool blk, int256 dn) = _checkCard(wd, tx + 1, ty, dog);
            if (blk) return false;
            doornum = dn;
            tx += 1;
        } else if (a.dir == 1) {
            // northeast
            if (_checkDiag(wd, tx + 1, ty - 1) || _checkDiag(wd, tx + 1, ty) || _checkDiag(wd, tx, ty - 1)) {
                return false;
            }
            tx += 1;
            ty -= 1;
        } else if (a.dir == 2) {
            // north
            (bool blk, int256 dn) = _checkCard(wd, tx, ty - 1, dog);
            if (blk) return false;
            doornum = dn;
            ty -= 1;
        } else if (a.dir == 3) {
            // northwest
            if (_checkDiag(wd, tx - 1, ty - 1) || _checkDiag(wd, tx - 1, ty) || _checkDiag(wd, tx, ty - 1)) {
                return false;
            }
            tx -= 1;
            ty -= 1;
        } else if (a.dir == 4) {
            // west
            (bool blk, int256 dn) = _checkCard(wd, tx - 1, ty, dog);
            if (blk) return false;
            doornum = dn;
            tx -= 1;
        } else if (a.dir == 5) {
            // southwest
            if (_checkDiag(wd, tx - 1, ty + 1) || _checkDiag(wd, tx - 1, ty) || _checkDiag(wd, tx, ty + 1)) {
                return false;
            }
            tx -= 1;
            ty += 1;
        } else if (a.dir == 6) {
            // south
            (bool blk, int256 dn) = _checkCard(wd, tx, ty + 1, dog);
            if (blk) return false;
            doornum = dn;
            ty += 1;
        } else if (a.dir == 7) {
            // southeast
            if (_checkDiag(wd, tx + 1, ty + 1) || _checkDiag(wd, tx + 1, ty) || _checkDiag(wd, tx, ty + 1)) {
                return false;
            }
            tx += 1;
            ty += 1;
        } else {
            return false; // nodir
        }
        a.tilex = uint256(tx);
        a.tiley = uint256(ty);
        if (doornum != -1) {
            // a door blocks the path: start it opening and wait
            _openDoor(wd, uint256(doornum));
            a.distance = -doornum - 1;
            return true;
        }
        a.distance = TILEGLOBAL;
        return true;
    }

    /// WL_STATE.C CHECKSIDE: wall blocks; a closed/opening door yields its doornum
    /// (guard waits); an open door passes; a shootable actor on the tile blocks.
    function _checkSide(World memory wd, int256 x, int256 y)
        internal
        pure
        returns (bool blocked, int256 doornum)
    {
        doornum = -1;
        uint256 t = _actorTile(wd, x, y);
        if (t != 0) {
            if (t < 128) blocked = true; // solid wall
            else doornum = int256(t & 0x7f); // door (not open)
        } else if (_shootableActorAt(wd, x, y)) {
            blocked = true; // another guard occupies the tile
        }
    }

    /// WL_STATE.C CHECKDIAG: a wall, a non-open door, or a shootable actor all block.
    function _checkDiag(World memory wd, int256 x, int256 y) internal pure returns (bool) {
        if (_actorTile(wd, x, y) != 0) return true;
        return _shootableActorAt(wd, x, y);
    }

    /// A cardinal step: dogs use CHECKDIAG (a door blocks them — they can't open one);
    /// everyone else uses CHECKSIDE (a door opens and they wait).
    function _checkCard(World memory wd, int256 x, int256 y, bool isDog)
        internal
        pure
        returns (bool blocked, int256 doornum)
    {
        if (isDog) return (_checkDiag(wd, x, y), -1);
        return _checkSide(wd, x, y);
    }

    /// WL_STATE.C `actorat` occupancy: a tile is blocked if a shootable actor stands on
    /// it. Scanning actors is equivalent to id's grid — each actor's (tilex,tiley) is its
    /// mark (cleared-at-start/marked-at-end falls out of reading live positions in actor
    /// order), and TryWalk only ever checks tiles adjacent to the mover, never its own.
    function _shootableActorAt(World memory wd, int256 x, int256 y) internal pure returns (bool) {
        for (uint256 i = 0; i < wd.actors.length; i++) {
            Actor memory a = wd.actors[i];
            if (int256(a.tilex) == x && int256(a.tiley) == y && (a.flags & FL_SHOOTABLE) != 0) {
                return true;
            }
        }
        return false;
    }

    /// WL_STATE.C SelectChaseDir
    function _selectChaseDir(World memory wd, Actor memory a) internal pure {
        int256 olddir = a.dir;
        int256 turnaround = _opp(olddir);
        int256 deltax = int256(wd.p.tilex) - int256(a.tilex);
        int256 deltay = int256(wd.p.tiley) - int256(a.tiley);

        int256 d1 = NODIR;
        int256 d2 = NODIR;
        if (deltax > 0) d1 = EAST;
        else if (deltax < 0) d1 = WEST;
        if (deltay > 0) d2 = SOUTH;
        else if (deltay < 0) d2 = NORTH;

        if (_abs(deltay) > _abs(deltax)) {
            int256 t = d1;
            d1 = d2;
            d2 = t;
        }
        if (d1 == turnaround) d1 = NODIR;
        if (d2 == turnaround) d2 = NODIR;

        if (d1 != NODIR) {
            a.dir = d1;
            if (_tryWalk(wd, a)) return;
        }
        if (d2 != NODIR) {
            a.dir = d2;
            if (_tryWalk(wd, a)) return;
        }
        if (olddir != NODIR) {
            a.dir = olddir;
            if (_tryWalk(wd, a)) return;
        }
        if (_rnd(wd) > 128) {
            for (int256 tdir = NORTH; tdir <= WEST; tdir++) {
                if (tdir != turnaround) {
                    a.dir = tdir;
                    if (_tryWalk(wd, a)) return;
                }
            }
        } else {
            for (int256 tdir = WEST; tdir >= NORTH; tdir--) {
                if (tdir != turnaround) {
                    a.dir = tdir;
                    if (_tryWalk(wd, a)) return;
                }
            }
        }
        if (turnaround != NODIR) {
            a.dir = turnaround;
            if (_tryWalk(wd, a)) return;
        }
        a.dir = NODIR;
    }

    /// WL_STATE.C SelectDodgeDir
    function _selectDodgeDir(World memory wd, Actor memory a) internal pure {
        int256 turnaround;
        if ((a.flags & FL_FIRSTATTACK) != 0) {
            turnaround = NODIR;
            a.flags &= ~FL_FIRSTATTACK;
        } else {
            turnaround = _opp(a.dir);
        }
        int256 deltax = int256(wd.p.tilex) - int256(a.tilex);
        int256 deltay = int256(wd.p.tiley) - int256(a.tiley);

        int256[5] memory dirtry;
        if (deltax > 0) {
            dirtry[1] = EAST;
            dirtry[3] = WEST;
        } else {
            dirtry[1] = WEST;
            dirtry[3] = EAST;
        }
        if (deltay > 0) {
            dirtry[2] = SOUTH;
            dirtry[4] = NORTH;
        } else {
            dirtry[2] = NORTH;
            dirtry[4] = SOUTH;
        }

        if (_abs(deltax) > _abs(deltay)) {
            (dirtry[1], dirtry[2]) = (dirtry[2], dirtry[1]);
            (dirtry[3], dirtry[4]) = (dirtry[4], dirtry[3]);
        }
        if (_rnd(wd) < 128) {
            (dirtry[1], dirtry[2]) = (dirtry[2], dirtry[1]);
            (dirtry[3], dirtry[4]) = (dirtry[4], dirtry[3]);
        }
        dirtry[0] = _diag(dirtry[1], dirtry[2]);

        for (uint256 i = 0; i < 5; i++) {
            if (dirtry[i] == NODIR || dirtry[i] == turnaround) continue;
            a.dir = dirtry[i];
            if (_tryWalk(wd, a)) return;
        }
        if (turnaround != NODIR) {
            a.dir = turnaround;
            if (_tryWalk(wd, a)) return;
        }
        a.dir = NODIR;
    }

    /// WL_STATE.C MoveObj (guard; areabyplayer always true here)
    function _moveObj(World memory wd, Actor memory a, int256 move) internal pure {
        _stepDir(a, a.dir, move);

        int256 deltax = a.x - wd.p.x;
        if (deltax < -MINACTORDIST || deltax > MINACTORDIST) {
            a.distance -= move;
            return;
        }
        int256 deltay = a.y - wd.p.y;
        if (deltay < -MINACTORDIST || deltay > MINACTORDIST) {
            a.distance -= move;
            return;
        }
        // too close to player — back up
        _stepDir(a, a.dir, -move);
    }

    function _stepDir(Actor memory a, int256 dir, int256 move) internal pure {
        if (dir == 0) a.x += move; // east
        else if (dir == 1) { a.x += move; a.y -= move; } // ne
        else if (dir == 2) a.y -= move; // north
        else if (dir == 3) { a.x -= move; a.y -= move; } // nw
        else if (dir == 4) a.x -= move; // west
        else if (dir == 5) { a.x -= move; a.y += move; } // sw
        else if (dir == 6) a.y += move; // south
        else if (dir == 7) { a.x += move; a.y += move; } // se
    }

    /// WL_STATE.C CheckLine — DDA line-of-sight over walls (no doors in M2).
    function _checkLine(World memory wd, Actor memory a) internal pure returns (bool) {
        int256 x1 = a.x >> 8;
        int256 y1 = a.y >> 8;
        int256 xt1 = x1 >> 8;
        int256 yt1 = y1 >> 8;
        int256 x2 = wd.plux;
        int256 y2 = wd.pluy;
        int256 xt2 = int256(wd.p.tilex);
        int256 yt2 = int256(wd.p.tiley);

        int256 part;
        if (_abs(xt2 - xt1) > 0) {
            int256 xstep;
            if (xt2 > xt1) {
                part = 256 - (x1 & 0xff);
                xstep = 1;
            } else {
                part = x1 & 0xff;
                xstep = -1;
            }
            int256 deltafrac = _abs(x2 - x1);
            int256 ystep = ((y2 - y1) << 8) / deltafrac;
            if (ystep > 0x7fff) ystep = 0x7fff;
            else if (ystep < -0x7fff) ystep = -0x7fff;
            int256 yfrac = y1 + ((ystep * part) >> 8);
            int256 x = xt1 + xstep;
            int256 xend = xt2 + xstep;
            do {
                int256 y = yfrac >> 8;
                yfrac += ystep;
                if (_losHit(wd, x, y, yfrac, ystep)) return false;
                x += xstep;
            } while (x != xend);
        }
        if (_abs(yt2 - yt1) > 0) {
            int256 ystep;
            if (yt2 > yt1) {
                part = 256 - (y1 & 0xff);
                ystep = 1;
            } else {
                part = y1 & 0xff;
                ystep = -1;
            }
            int256 deltafrac = _abs(y2 - y1);
            int256 xstep = ((x2 - x1) << 8) / deltafrac;
            if (xstep > 0x7fff) xstep = 0x7fff;
            else if (xstep < -0x7fff) xstep = -0x7fff;
            int256 xfrac = x1 + ((xstep * part) >> 8);
            int256 y = yt1 + ystep;
            int256 yend = yt2 + ystep;
            do {
                int256 x = xfrac >> 8;
                xfrac += xstep;
                if (_losHit(wd, x, y, xfrac, xstep)) return false;
                y += ystep;
            } while (y != yend);
        }
        return true;
    }

    /// WL_STATE.C CheckLine inner test: a wall blocks; a door blocks unless the
    /// ray crosses above its sliding leading edge. `frac`/`step` are the just-
    /// advanced perpendicular accumulator; `intercept` is taken as a 32-bit
    /// unsigned (id's `unsigned intercept`) for the doorposition compare.
    function _losHit(World memory wd, int256 x, int256 y, int256 frac, int256 step)
        internal
        pure
        returns (bool)
    {
        if (x < 0 || x >= int256(wd.w) || y < 0 || y >= int256(wd.h)) return true; // OOB = wall
        uint256 value = _tile(wd, uint256(y) * wd.w + uint256(x));
        if (value == 0) return false;
        if (value < 128) return true; // solid wall (value>256 impossible for a byte)
        uint256 dn = value & 0x7f;
        int256 intercept = frac - step / 2;
        return uint256(uint32(int32(intercept))) > uint256(wd.doors[dn].position);
    }

    /// WL_ACT2.C T_Chase (guard)
    function _tChase(World memory wd, Actor memory a) internal pure {
        bool dodge = false;
        if (_checkLine(wd, a)) {
            int256 dx = _abs(int256(a.tilex) - int256(wd.p.tilex));
            int256 dy = _abs(int256(a.tiley) - int256(wd.p.tiley));
            int256 dist = dx > dy ? dx : dy;
            int256 chance;
            if (dist == 0 || (dist == 1 && a.distance < 0x4000)) chance = 300;
            else chance = (TICS << 4) / dist;
            if (int256(_rnd(wd)) < chance) {
                uint256 shoot = S_GRDSHOOT1;
                if (a.obclass == SSOBJ) shoot = S_SSSHOOT1;
                else if (a.obclass == OFFICEROBJ) shoot = S_OFCSHOOT1;
                _newState(a, shoot);
                return;
            }
            dodge = true;
        }
        if (a.dir == NODIR) {
            if (dodge) _selectDodgeDir(wd, a);
            else _selectChaseDir(wd, a);
            if (a.dir == NODIR) return;
        }
        int256 move = a.speed * TICS;
        while (move != 0) {
            if (a.distance < 0) {
                // waiting for a door to open
                _openDoor(wd, uint256(-a.distance - 1));
                if (wd.doors[uint256(-a.distance - 1)].action != DR_OPEN) return;
                a.distance = TILEGLOBAL; // door is now open, go ahead
            }
            if (move < a.distance) {
                _moveObj(wd, a, move);
                break;
            }
            a.x = (int256(a.tilex) << 16) + TILEGLOBAL / 2;
            a.y = (int256(a.tiley) << 16) + TILEGLOBAL / 2;
            move -= a.distance;
            if (dodge) _selectDodgeDir(wd, a);
            else _selectChaseDir(wd, a);
            if (a.dir == NODIR) return;
        }
    }

    /// WL_ACT2.C T_Shoot (guard). FL_VISABLE is render-derived => always false in
    /// the headless sim (same on both sides), so only the non-visible branch applies.
    function _tShoot(World memory wd, Actor memory a) internal pure {
        if (!_checkLine(wd, a)) return;
        int256 dx = _abs(int256(a.tilex) - int256(wd.p.tilex));
        int256 dy = _abs(int256(a.tiley) - int256(wd.p.tiley));
        int256 dist = dx > dy ? dx : dy;
        int256 hitchance = (wd.thrustspeed >= RUNSPEED) ? 160 - dist * 8 : 256 - dist * 8;
        if (int256(_rnd(wd)) < hitchance) {
            int256 damage;
            if (dist < 2) damage = int256(_rnd(wd)) >> 2;
            else if (dist < 4) damage = int256(_rnd(wd)) >> 3;
            else damage = int256(_rnd(wd)) >> 4;
            _takeDamage(wd, damage);
        }
    }

    /// WL_AGENT.C TakeDamage (core; difficulty/godmode/flash dropped).
    function _takeDamage(World memory wd, int256 points) internal pure {
        wd.p.health -= points;
        if (wd.p.health <= 0) wd.p.health = 0;
    }

    /// Player firing: a cooldown replaces the weapon animation (Cmd_Fire/T_Attack).
    function _playerAttack(World memory wd, Cmd calldata cmd) internal pure {
        if (wd.p.attackcount > 0) wd.p.attackcount -= 1;
        if ((cmd.buttons & 1) != 0 && wd.p.attackcount == 0 && wd.p.ammo > 0) {
            wd.p.ammo -= 1;
            wd.madenoise = true; // firing alerts guards in the area
            _gunAttack(wd);
            wd.p.attackcount = ATTACKRATE;
        }
    }

    /// WL_AGENT.C GunAttack. Original targets via render-derived viewx/FL_VISABLE;
    /// here the aim is computed from sim state — closest shootable actor in front
    /// (depth nx >= MINDIST via the view rotation) with clear LOS. Damage/miss
    /// math is faithful; the screen-pixel `shootdelta` cone is dropped (render-specific).
    function _gunAttack(World memory wd) internal pure {
        uint256 va = uint256(wd.p.angle);
        uint32 viewcosR = Trig.cosAt(wd.trig, va);
        uint32 viewsinR = Trig.sinAt(wd.trig, va);
        int256 viewx = wd.p.x - Fixed.fixedByFrac(FOCALLENGTH, viewcosR);
        int256 viewy = wd.p.y + Fixed.fixedByFrac(FOCALLENGTH, viewsinR);

        int256 bestnx = type(int256).max;
        int256 closest = -1;
        for (uint256 i = 0; i < wd.actors.length; i++) {
            Actor memory e = wd.actors[i];
            if ((e.flags & FL_SHOOTABLE) == 0) continue;
            int256 nx = Fixed.fixedByFrac(e.x - viewx, viewcosR)
                - Fixed.fixedByFrac(e.y - viewy, viewsinR) - ACTORSIZE;
            if (nx < MINDIST) continue;
            if (!_checkLine(wd, e)) continue;
            if (nx < bestnx) {
                bestnx = nx;
                closest = int256(i);
            }
        }
        if (closest < 0) return;

        Actor memory c = wd.actors[uint256(closest)];
        int256 dx = _abs(int256(c.tilex) - int256(wd.p.tilex));
        int256 dy = _abs(int256(c.tiley) - int256(wd.p.tiley));
        int256 dist = dx > dy ? dx : dy;
        int256 damage;
        if (dist < 2) damage = int256(_rnd(wd)) / 4;
        else if (dist < 4) damage = int256(_rnd(wd)) / 6;
        else {
            if (int256(_rnd(wd)) / 12 < dist) return; // missed
            damage = int256(_rnd(wd)) / 6;
        }
        _damageActor(c, damage);
    }

    /// WL_STATE.C DamageActor (guard is in attack mode here: no double-damage / FirstSighting).
    function _damageActor(Actor memory a, int256 damage) internal pure {
        if ((a.flags & FL_ATTACKMODE) == 0) damage = damage * 2;
        a.hitpoints -= damage;
        if (a.hitpoints <= 0) {
            _killActor(a);
            return;
        }
        if (a.obclass == DOGOBJ) return; // dogs have no pain state (1 HP)
        if (a.obclass == SSOBJ) _newState(a, (a.hitpoints & 1) == 1 ? S_SSPAIN : S_SSPAIN1);
        else if (a.obclass == OFFICEROBJ) _newState(a, (a.hitpoints & 1) == 1 ? S_OFCPAIN : S_OFCPAIN1);
        else _newState(a, (a.hitpoints & 1) == 1 ? S_GRDPAIN : S_GRDPAIN1);
    }

    /// WL_STATE.C KillActor (die animation, no longer shootable).
    function _killActor(Actor memory a) internal pure {
        uint256 die = S_GRDDIE1;
        if (a.obclass == SSOBJ) die = S_SSDIE1;
        else if (a.obclass == DOGOBJ) die = S_DOGDIE1;
        else if (a.obclass == OFFICEROBJ) die = S_OFCDIE1;
        a.tilex = uint256(a.x >> 16);
        a.tiley = uint256(a.y >> 16);
        _newState(a, die);
        a.flags &= ~FL_SHOOTABLE;
    }

    /// WL_PLAY.C DoActor — state-machine advance (no actorat marking; single guard).
    function _doActor(World memory wd, Actor memory a) internal pure {
        (uint256 tictime, uint256 think, uint256 action, uint256 nxt) = _gstate(a.state);

        if (a.ticcount == 0) {
            _think(wd, a, think);
            return;
        }

        a.ticcount -= TICS;
        while (a.ticcount <= 0) {
            (, , action, nxt) = _gstate(a.state);
            _action(wd, a, action);
            a.state = nxt;
            (tictime, think, , nxt) = _gstate(a.state);
            if (tictime == 0) {
                a.ticcount = 0;
                break;
            }
            a.ticcount += int256(tictime);
        }
        (, think, , ) = _gstate(a.state);
        _think(wd, a, think);
    }

    function _think(World memory wd, Actor memory a, uint256 id) internal pure {
        if (id == TH_CHASE) _tChase(wd, a);
        else if (id == TH_DOGCHASE) _tDogChase(wd, a);
        else if (id == TH_STAND) _sightPlayer(wd, a); // T_Stand
    }

    /// WL_STATE.C CheckSight: area connected + auto-see-if-close + facing FOV + LOS.
    function _checkSight(World memory wd, Actor memory a) internal pure returns (bool) {
        int256 deltax = wd.p.x - a.x;
        int256 deltay = wd.p.y - a.y;
        if (deltax > -MINSIGHT && deltax < MINSIGHT && deltay > -MINSIGHT && deltay < MINSIGHT)
            return true; // very close: automatic
        // only cardinal facings restrict the view cone
        if (a.dir == NORTH) { if (deltay > 0) return false; }
        else if (a.dir == EAST) { if (deltax < 0) return false; }
        else if (a.dir == SOUTH) { if (deltay < 0) return false; }
        else if (a.dir == WEST) { if (deltax > 0) return false; }
        return _checkLine(wd, a);
    }

    /// WL_STATE.C FirstSighting: wake into the class's chase with its speed multiplier
    /// (guard 3x, SS 4x, dog 2x) and set attack flags.
    function _firstSighting(Actor memory a) internal pure {
        if (a.obclass == SSOBJ) {
            _newState(a, S_SSCHASE1);
            a.speed *= 4;
        } else if (a.obclass == DOGOBJ) {
            _newState(a, S_DOGCHASE1);
            a.speed *= 2;
        } else if (a.obclass == OFFICEROBJ) {
            _newState(a, S_OFCCHASE1);
            a.speed *= 5;
        } else {
            _newState(a, S_GRDCHASE1);
            a.speed *= 3;
        }
        if (a.distance < 0) a.distance = 0;
        a.flags |= FL_ATTACKMODE | FL_FIRSTATTACK;
    }

    /// WL_STATE.C SightPlayer: first sight starts a reaction timer; on expiry, wake.
    function _sightPlayer(World memory wd, Actor memory a) internal pure {
        if ((a.flags & FL_ATTACKMODE) != 0) return; // already alerted
        if (a.temp2 != 0) {
            a.temp2 -= TICS;
            if (a.temp2 > 0) return;
            a.temp2 = 0; // time to react
        } else {
            if ((a.flags & FL_AMBUSH) != 0) {
                if (!_checkSight(wd, a)) return;
                a.flags &= ~FL_AMBUSH;
            } else if (!wd.madenoise && !_checkSight(wd, a)) {
                return;
            }
            // class-specific reaction delay (the officer is a constant — NO RNG draw)
            if (a.obclass == OFFICEROBJ) {
                a.temp2 = 2;
            } else {
                int256 r = int256(_rnd(wd));
                if (a.obclass == SSOBJ) a.temp2 = 1 + r / 6;
                else if (a.obclass == DOGOBJ) a.temp2 = 1 + r / 8;
                else a.temp2 = 1 + r / 4;
            }
            return;
        }
        _firstSighting(a);
    }

    function _action(World memory wd, Actor memory a, uint256 id) internal pure {
        if (id == 1) _tShoot(wd, a); // AC_SHOOT; AC_DEATHSCREAM (2) is render-only
        else if (id == AC_BITE) _tBite(wd, a);
    }

    /// WL_ACT2.C T_DogChase: melee chase (no LOS, always SelectDodgeDir); leap into
    /// the bite (s_dogjump1) once within byte (MINACTORDIST) range.
    function _tDogChase(World memory wd, Actor memory a) internal pure {
        if (a.dir == NODIR) {
            _selectDodgeDir(wd, a);
            if (a.dir == NODIR) return;
        }
        int256 move = a.speed * TICS;
        while (move != 0) {
            int256 dx = _abs(wd.p.x - a.x) - move;
            if (dx <= MINACTORDIST) {
                int256 dy = _abs(wd.p.y - a.y) - move;
                if (dy <= MINACTORDIST) {
                    _newState(a, S_DOGJUMP1);
                    return;
                }
            }
            if (move < a.distance) {
                _moveObj(wd, a, move);
                break;
            }
            a.x = (int256(a.tilex) << 16) + TILEGLOBAL / 2;
            a.y = (int256(a.tiley) << 16) + TILEGLOBAL / 2;
            move -= a.distance;
            _selectDodgeDir(wd, a);
            if (a.dir == NODIR) return;
        }
    }

    /// WL_ACT2.C T_Bite: the dog's melee attack.
    function _tBite(World memory wd, Actor memory a) internal pure {
        int256 dx = _abs(wd.p.x - a.x) - TILEGLOBAL;
        if (dx <= MINACTORDIST) {
            int256 dy = _abs(wd.p.y - a.y) - TILEGLOBAL;
            if (dy <= MINACTORDIST) {
                if (int256(_rnd(wd)) < 180) _takeDamage(wd, int256(_rnd(wd)) >> 4);
            }
        }
    }

    function _newState(Actor memory a, uint256 state) internal pure {
        a.state = state;
        (uint256 tictime, , , ) = _gstate(state);
        a.ticcount = int256(tictime);
    }

    /// WL_ACT2.C guard state graph: (tictime, think, action, next).
    function _gstate(uint256 s)
        internal
        pure
        returns (uint256 tictime, uint256 think, uint256 action, uint256 nxt)
    {
        if (s == 0) return (0, TH_STAND, 0, 0); // s_grdstand
        if (s == 1) return (10, TH_CHASE, 0, 2); // chase1
        if (s == 2) return (3, 0, 0, 3); // chase1s
        if (s == 3) return (8, TH_CHASE, 0, 4); // chase2
        if (s == 4) return (10, TH_CHASE, 0, 5); // chase3
        if (s == 5) return (3, 0, 0, 6); // chase3s
        if (s == 6) return (8, TH_CHASE, 0, 1); // chase4
        if (s == 7) return (20, 0, 0, 8); // shoot1
        if (s == 8) return (20, 0, 1, 9); // shoot2 (AC_SHOOT)
        if (s == 9) return (20, 0, 0, 1); // shoot3
        if (s == 10) return (15, 0, 2, 11); // die1 (AC_DEATHSCREAM)
        if (s == 11) return (15, 0, 0, 12); // die2
        if (s == 12) return (15, 0, 0, 13); // die3
        if (s == 13) return (0, 0, 0, 13); // die4 (corpse)
        if (s == 14) return (10, 0, 0, 1); // pain  -> chase1
        if (s == 15) return (10, 0, 0, 1); // pain1 -> chase1
        // --- SS (states 16..37): same graph as the guard, but a 4-shot burst ---
        if (s == 16) return (0, TH_STAND, 0, 16); // s_ssstand
        if (s == 17) return (10, TH_CHASE, 0, 18); // sschase1
        if (s == 18) return (3, 0, 0, 19); // sschase1s
        if (s == 19) return (8, TH_CHASE, 0, 20); // sschase2
        if (s == 20) return (10, TH_CHASE, 0, 21); // sschase3
        if (s == 21) return (3, 0, 0, 22); // sschase3s
        if (s == 22) return (8, TH_CHASE, 0, 17); // sschase4
        if (s == 23) return (20, 0, 0, 24); // ssshoot1
        if (s == 24) return (20, 0, 1, 25); // ssshoot2 (AC_SHOOT)
        if (s == 25) return (10, 0, 0, 26); // ssshoot3
        if (s == 26) return (10, 0, 1, 27); // ssshoot4 (AC_SHOOT)
        if (s == 27) return (10, 0, 0, 28); // ssshoot5
        if (s == 28) return (10, 0, 1, 29); // ssshoot6 (AC_SHOOT)
        if (s == 29) return (10, 0, 0, 30); // ssshoot7
        if (s == 30) return (10, 0, 1, 31); // ssshoot8 (AC_SHOOT)
        if (s == 31) return (10, 0, 0, 17); // ssshoot9 -> sschase1
        if (s == 32) return (15, 0, 2, 33); // ssdie1 (AC_DEATHSCREAM)
        if (s == 33) return (15, 0, 0, 34); // ssdie2
        if (s == 34) return (15, 0, 0, 35); // ssdie3
        if (s == 35) return (0, 0, 0, 35); // ssdie4 (corpse)
        if (s == 36) return (10, 0, 0, 17); // sspain  -> sschase1
        if (s == 37) return (10, 0, 0, 17); // sspain1 -> sschase1
        // --- dog (states 38..53): melee chase + jump/bite, no pain ---
        if (s == 38) return (0, TH_STAND, 0, 38); // s_dogstand
        if (s == 39) return (10, TH_DOGCHASE, 0, 40); // dogchase1
        if (s == 40) return (3, 0, 0, 41); // dogchase1s
        if (s == 41) return (8, TH_DOGCHASE, 0, 42); // dogchase2
        if (s == 42) return (10, TH_DOGCHASE, 0, 43); // dogchase3
        if (s == 43) return (3, 0, 0, 44); // dogchase3s
        if (s == 44) return (8, TH_DOGCHASE, 0, 39); // dogchase4
        if (s == 45) return (10, 0, 0, 46); // dogjump1
        if (s == 46) return (10, 0, AC_BITE, 47); // dogjump2 (T_Bite)
        if (s == 47) return (10, 0, 0, 48); // dogjump3
        if (s == 48) return (10, 0, 0, 49); // dogjump4
        if (s == 49) return (10, 0, 0, 39); // dogjump5 -> dogchase1
        if (s == 50) return (15, 0, 2, 51); // dogdie1 (AC_DEATHSCREAM)
        if (s == 51) return (15, 0, 0, 52); // dogdie2
        if (s == 52) return (15, 0, 0, 53); // dogdie3
        if (s == 53) return (0, 0, 0, 53); // dogdead
        // --- officer (states 54..70): guard-like, faster shot, 5 die frames ---
        if (s == 54) return (0, TH_STAND, 0, 54); // ofcstand
        if (s == 55) return (10, TH_CHASE, 0, 56); // ofcchase1
        if (s == 56) return (3, 0, 0, 57); // ofcchase1s
        if (s == 57) return (8, TH_CHASE, 0, 58); // ofcchase2
        if (s == 58) return (10, TH_CHASE, 0, 59); // ofcchase3
        if (s == 59) return (3, 0, 0, 60); // ofcchase3s
        if (s == 60) return (8, TH_CHASE, 0, 55); // ofcchase4
        if (s == 61) return (6, 0, 0, 62); // ofcshoot1
        if (s == 62) return (20, 0, 1, 63); // ofcshoot2 (AC_SHOOT)
        if (s == 63) return (10, 0, 0, 55); // ofcshoot3 -> ofcchase1
        if (s == 64) return (11, 0, 2, 65); // ofcdie1 (AC_DEATHSCREAM)
        if (s == 65) return (11, 0, 0, 66); // ofcdie2
        if (s == 66) return (11, 0, 0, 67); // ofcdie3
        if (s == 67) return (11, 0, 0, 68); // ofcdie4
        if (s == 68) return (0, 0, 0, 68); // ofcdie5 (corpse)
        if (s == 69) return (10, 0, 0, 55); // ofcpain  -> ofcchase1
        return (10, 0, 0, 55); // ofcpain1 (s==70) -> ofcchase1
    }

    // ---------------- helpers ----------------

    function _tile(World memory wd, uint256 idx) internal pure returns (uint256 v) {
        bytes memory tl = wd.tiles;
        assembly {
            v := byte(0, mload(add(add(tl, 0x20), idx)))
        }
    }

    function _opp(int256 dir) internal pure returns (int256 v) {
        bytes memory t = OPPOSITE;
        assembly {
            v := byte(0, mload(add(add(t, 0x20), dir)))
        }
    }

    function _diag(int256 d1, int256 d2) internal pure returns (int256 v) {
        bytes memory t = DIAGONAL;
        uint256 idx = uint256(d1) * 9 + uint256(d2);
        assembly {
            v := byte(0, mload(add(add(t, 0x20), idx)))
        }
    }

    function _abs(int256 v) internal pure returns (int256) {
        return v < 0 ? -v : v;
    }

    // --- state codec: header + player + active-door words + item bitmask + actor words ---
    // header: rndindex:uint8@0 | numactors:uint8@8 | numactivedoors:uint8@16 | numitems:uint16@24
    // player: x:int32@0 | y:int32@32 | angle:uint16@64 | anglefrac:int32@80 | tilex:uint8@112 |
    //         tiley:uint8@120 | health:int16@128 | ammo:int16@144 | attackcount:int16@160 |
    //         useheld:bit@176 | keys:uint8@184 | score:uint32@192
    // door:   action:uint8@0 | ticcount:int16@16 | position:uint16@32 | doornum:uint8@48
    //         (ONLY non-closed doors are stored; a closed door is the all-zero default that
    //          _load reconstructs. Decoders default every door closed, then apply these by doornum.)
    // items:  ceil(numitems/256) words, bit i = item i taken (static tilex/tiley/itemnumber from Map)
    // actor:  x:int32@0 | y:int32@32 | tilex:uint8@64 | tiley:uint8@72 | dir:uint8@80 | state:uint8@88 |
    //         ticcount:int16@96 | distance:int32@112 | hitpoints:int16@144 | flags:uint8@160 |
    //         obclass:uint8@168 | speed:int32@176 | active:uint8@208 | temp2:int16@216
    // blob order: [header][player][activedoor_0..][itemword_0..][actor_0..]

    function _pack(World memory wd) internal pure returns (bytes memory out) {
        uint256 nd = wd.doors.length;
        uint256 ni = wd.numItems;
        uint256 na = wd.actors.length;
        uint256 iw = ni == 0 ? 0 : (ni + 255) / 256;
        uint256 ad = 0; // active (non-closed) doors — the only ones we store
        for (uint256 i = 0; i < nd; i++) {
            if (wd.doors[i].action != DR_CLOSED) ad++;
        }
        out = new bytes(32 * (2 + ad + iw + na));
        uint256 header =
            (wd.rndindex & 0xff) | ((na & 0xff) << 8) | ((ad & 0xff) << 16) | ((ni & 0xffff) << 24);
        uint256 pw = _packPlayer(wd.p);
        assembly {
            mstore(add(out, 0x20), header)
            mstore(add(out, 0x40), pw)
        }
        uint256 slot = 0;
        for (uint256 i = 0; i < nd; i++) {
            if (wd.doors[i].action == DR_CLOSED) continue;
            uint256 dw = _packDoor(wd.doors[i], i);
            assembly {
                mstore(add(add(out, 0x60), mul(slot, 0x20)), dw)
            }
            slot++;
        }
        for (uint256 wIdx = 0; wIdx < iw; wIdx++) {
            uint256 bits = wd.itemTaken[wIdx]; // already a bitmask — copy the word straight in
            assembly {
                mstore(add(add(out, 0x60), mul(add(ad, wIdx), 0x20)), bits)
            }
        }
        for (uint256 i = 0; i < na; i++) {
            uint256 aw = _packActor(wd.actors[i]);
            assembly {
                mstore(add(add(out, 0x60), mul(add(add(ad, iw), i), 0x20)), aw)
            }
        }
    }

    /// Fills wd.p, wd.actors, wd.rndindex, the active door states (by doornum), and
    /// item-taken bits onto wd.doors/wd.items (whose static fields _load set from the Map;
    /// doors not present here stay closed, the default _load applied).
    function _unpack(bytes calldata b, World memory wd) internal pure {
        uint256 header;
        uint256 pw;
        assembly {
            header := calldataload(b.offset)
            pw := calldataload(add(b.offset, 0x20))
        }
        wd.rndindex = header & 0xff;
        uint256 na = (header >> 8) & 0xff;
        uint256 ad = (header >> 16) & 0xff; // active (non-closed) door count
        uint256 ni = (header >> 24) & 0xffff;
        uint256 iw = ni == 0 ? 0 : (ni + 255) / 256;
        wd.p = _unpackPlayer(pw);
        for (uint256 i = 0; i < ad; i++) {
            uint256 dw;
            assembly {
                dw := calldataload(add(b.offset, add(0x40, mul(i, 0x20))))
            }
            _unpackDoorInto(wd.doors[(dw >> 48) & 0xff], dw); // doornum from bits 48..55
        }
        for (uint256 wIdx = 0; wIdx < iw; wIdx++) {
            uint256 bits;
            assembly {
                bits := calldataload(add(b.offset, add(0x40, mul(add(ad, wIdx), 0x20))))
            }
            wd.itemTaken[wIdx] = bits; // copy the taken bitmask word straight back
        }
        wd.actors = new Actor[](na);
        for (uint256 i = 0; i < na; i++) {
            uint256 aw;
            assembly {
                aw := calldataload(add(b.offset, add(0x40, mul(add(add(ad, iw), i), 0x20))))
            }
            wd.actors[i] = _unpackActor(aw);
        }
    }

    function _packDoor(Door memory d, uint256 doornum) internal pure returns (uint256 w) {
        w = d.action & 0xff;
        w |= uint256(uint16(int16(d.ticcount))) << 16;
        w |= (uint256(d.position) & 0xffff) << 32;
        w |= (doornum & 0xff) << 48; // which door (only active doors are stored)
    }

    function _unpackDoorInto(Door memory d, uint256 w) internal pure {
        d.action = w & 0xff;
        d.ticcount = int256(int16(uint16(w >> 16)));
        d.position = int256((w >> 32) & 0xffff);
    }

    function _packPlayer(Player memory p) internal pure returns (uint256 w) {
        w = uint256(uint32(int32(p.x)));
        w |= uint256(uint32(int32(p.y))) << 32;
        w |= uint256(uint16(int16(p.angle))) << 64;
        w |= uint256(uint32(int32(p.anglefrac))) << 80;
        w |= uint256(uint8(p.tilex)) << 112;
        w |= uint256(uint8(p.tiley)) << 120;
        w |= uint256(uint16(int16(p.health))) << 128;
        w |= uint256(uint16(int16(p.ammo))) << 144;
        w |= uint256(uint16(int16(p.attackcount))) << 160;
        w |= (p.useheld & 1) << 176;
        w |= (p.keys & 0xff) << 184;
        w |= uint256(uint32(int32(p.score))) << 192;
    }

    function _unpackPlayer(uint256 w) internal pure returns (Player memory p) {
        p.x = int256(int32(uint32(w)));
        p.y = int256(int32(uint32(w >> 32)));
        p.angle = int256(int16(uint16(w >> 64)));
        p.anglefrac = int256(int32(uint32(w >> 80)));
        p.tilex = uint256(uint8(w >> 112));
        p.tiley = uint256(uint8(w >> 120));
        p.health = int256(int16(uint16(w >> 128)));
        p.ammo = int256(int16(uint16(w >> 144)));
        p.attackcount = int256(int16(uint16(w >> 160)));
        p.useheld = (w >> 176) & 1;
        p.keys = (w >> 184) & 0xff;
        p.score = int256(int32(uint32(w >> 192)));
    }

    function _packActor(Actor memory a) internal pure returns (uint256 w) {
        w = uint256(uint32(int32(a.x)));
        w |= uint256(uint32(int32(a.y))) << 32;
        w |= uint256(uint8(a.tilex)) << 64;
        w |= uint256(uint8(a.tiley)) << 72;
        w |= (uint256(a.dir) & 0xff) << 80;
        w |= (a.state & 0xff) << 88;
        w |= uint256(uint16(int16(a.ticcount))) << 96;
        w |= uint256(uint32(int32(a.distance))) << 112;
        w |= uint256(uint16(int16(a.hitpoints))) << 144;
        w |= uint256(a.flags) << 160;
        w |= uint256(a.obclass) << 168;
        w |= uint256(uint32(int32(a.speed))) << 176;
        w |= uint256(a.active) << 208;
        w |= uint256(uint16(int16(a.temp2))) << 216;
    }

    function _unpackActor(uint256 w) internal pure returns (Actor memory a) {
        a.x = int256(int32(uint32(w)));
        a.y = int256(int32(uint32(w >> 32)));
        a.tilex = uint256(uint8(w >> 64));
        a.tiley = uint256(uint8(w >> 72));
        a.dir = int256(uint256(uint8(w >> 80)));
        a.state = uint256(uint8(w >> 88));
        a.ticcount = int256(int16(uint16(w >> 96)));
        a.distance = int256(int32(uint32(w >> 112)));
        a.hitpoints = int256(int16(uint16(w >> 144)));
        a.flags = uint8(w >> 160);
        a.obclass = uint8(w >> 168);
        a.speed = int256(int32(uint32(w >> 176)));
        a.active = uint8(w >> 208);
        a.temp2 = int256(int16(uint16(w >> 216)));
    }
}
