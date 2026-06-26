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
    int256 internal constant PLAYERSIZE = MINDIST;
    int256 internal constant MINACTORDIST = 0x10000;
    int256 internal constant ANGLES = 360;
    int256 internal constant MOVESCALE = 150;
    int256 internal constant BACKMOVESCALE = 100;
    int256 internal constant ANGLESCALE = 20;
    int256 internal constant SPDPATROL = 512;
    int256 internal constant TICS = 1;
    uint8 internal constant BT_STRAFE = 0x02;

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

    // think / action ids
    uint256 internal constant TH_STAND = 1;
    uint256 internal constant TH_CHASE = 2;

    // guard state ids (match the oracle's enum)
    uint256 internal constant S_GRDSTAND = 0;
    uint256 internal constant S_GRDCHASE1 = 1;
    uint256 internal constant S_GRDSHOOT1 = 7;

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
    }

    struct Cmd {
        int256 controlx;
        int256 controly;
        uint8 buttons;
    }

    /// @dev Per-tick working context (mutable: p/actors/rndindex; rest read-only).
    struct World {
        Player p;
        Actor[] actors;
        uint256 rndindex;
        bytes tiles;
        uint256 w;
        uint256 h;
        bytes trig;
        bytes rnd;
        int256 plux;
        int256 pluy;
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

        bytes memory guards = IMap(map).guards(); // 3 bytes each: tilex,tiley,dir
        uint256 n = guards.length / 3;
        wd.actors = new Actor[](n);
        for (uint256 i = 0; i < n; i++) {
            _spawnGuard(wd.actors[i], uint8(guards[i * 3]), uint8(guards[i * 3 + 1]));
        }
        return abi.encode(wd.p, wd.actors, wd.rndindex);
    }

    function tick(bytes calldata state, address map, Cmd calldata cmd)
        external
        view
        returns (bytes memory)
    {
        World memory wd = _load(map);
        (wd.p, wd.actors, wd.rndindex) =
            abi.decode(state, (Player, Actor[], uint256));

        _controlMovement(wd, cmd);
        wd.plux = wd.p.x >> 8; // UNSIGNEDSHIFT
        wd.pluy = wd.p.y >> 8;
        for (uint256 i = 0; i < wd.actors.length; i++) {
            _doActor(wd, wd.actors[i]);
        }
        return abi.encode(wd.p, wd.actors, wd.rndindex);
    }

    // ---------------- setup ----------------

    function _load(address map) internal view returns (World memory wd) {
        wd.tiles = IMap(map).tiles();
        wd.w = IMap(map).width();
        wd.h = IMap(map).height();
        wd.trig = Trig.table();
        wd.rnd = Rng.table();
    }

    /// WL_ACT2.C SpawnStand(en_guard) + FirstSighting(guard): spawn alerted, in
    /// chase, at 3x patrol speed.
    function _spawnGuard(Actor memory a, uint256 tilex, uint256 tiley) internal pure {
        a.tilex = tilex;
        a.tiley = tiley;
        a.x = (int256(tilex) << 16) + TILEGLOBAL / 2;
        a.y = (int256(tiley) << 16) + TILEGLOBAL / 2;
        a.dir = NODIR;
        a.obclass = 3; // guardobj
        a.hitpoints = 25;
        a.active = 1; // ac_yes
        a.flags = FL_SHOOTABLE | FL_ATTACKMODE | FL_FIRSTATTACK;
        _newState(a, S_GRDCHASE1); // ticcount = tictime(chase1)=10
        a.speed = SPDPATROL * 3; // 1536
    }

    // ---------------- player movement (WL_AGENT.C) ----------------

    function _controlMovement(World memory wd, Cmd calldata cmd) internal pure {
        Player memory p = wd.p;
        int256 angle;
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
                if (_tile(wd, uint256(y) * wd.w + uint256(x)) != 0) return false;
            }
        }
        return true;
    }

    // ---------------- enemy AI (WL_STATE.C / WL_ACT2.C / WL_PLAY.C) ----------------

    function _rnd(World memory wd) internal pure returns (uint256) {
        wd.rndindex = (wd.rndindex + 1) & 0xff;
        return Rng.at(wd.rnd, wd.rndindex);
    }

    /// WL_STATE.C TryWalk (guard: CHECKSIDE on cardinals, CHECKDIAG on diagonals;
    /// walls only — single guard). Updates tilex/tiley/distance; returns success.
    function _tryWalk(World memory wd, Actor memory a) internal pure returns (bool) {
        int256 tx = int256(a.tilex);
        int256 ty = int256(a.tiley);
        if (a.dir == 0) {
            // east
            if (_wall(wd, tx + 1, ty)) return false;
            tx += 1;
        } else if (a.dir == 1) {
            // northeast
            if (_wall(wd, tx + 1, ty - 1) || _wall(wd, tx + 1, ty) || _wall(wd, tx, ty - 1)) return false;
            tx += 1;
            ty -= 1;
        } else if (a.dir == 2) {
            // north
            if (_wall(wd, tx, ty - 1)) return false;
            ty -= 1;
        } else if (a.dir == 3) {
            // northwest
            if (_wall(wd, tx - 1, ty - 1) || _wall(wd, tx - 1, ty) || _wall(wd, tx, ty - 1)) return false;
            tx -= 1;
            ty -= 1;
        } else if (a.dir == 4) {
            // west
            if (_wall(wd, tx - 1, ty)) return false;
            tx -= 1;
        } else if (a.dir == 5) {
            // southwest
            if (_wall(wd, tx - 1, ty + 1) || _wall(wd, tx - 1, ty) || _wall(wd, tx, ty + 1)) return false;
            tx -= 1;
            ty += 1;
        } else if (a.dir == 6) {
            // south
            if (_wall(wd, tx, ty + 1)) return false;
            ty += 1;
        } else if (a.dir == 7) {
            // southeast
            if (_wall(wd, tx + 1, ty + 1) || _wall(wd, tx + 1, ty) || _wall(wd, tx, ty + 1)) return false;
            tx += 1;
            ty += 1;
        } else {
            return false; // nodir
        }
        a.tilex = uint256(tx);
        a.tiley = uint256(ty);
        a.distance = TILEGLOBAL;
        return true;
    }

    function _wall(World memory wd, int256 x, int256 y) internal pure returns (bool) {
        if (x < 0 || x >= int256(wd.w) || y < 0 || y >= int256(wd.h)) return true;
        return _tile(wd, uint256(y) * wd.w + uint256(x)) != 0;
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
                if (_wall(wd, x, y)) return false;
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
                if (_wall(wd, x, y)) return false;
                y += ystep;
            } while (y != yend);
        }
        return true;
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
                _newState(a, S_GRDSHOOT1);
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
            if (a.distance < 0) a.distance = TILEGLOBAL; // door (none)
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
            _action(a, action);
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
        // TH_STAND (SightPlayer) and TH_PATH stubbed for later milestones
    }

    function _action(Actor memory, uint256) internal pure {
        // AC_SHOOT (hitscan) / AC_DEATHSCREAM are M2c; no-op here
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
        return (0, 0, 0, 13); // die4
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
}
