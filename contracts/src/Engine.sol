// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Fixed} from "./Fixed.sol";
import {Trig} from "./Trig.sol";
import {IMap} from "./IMap.sol";

/// @notice Stateless Wolf3D world-simulation engine (movement subset, M1).
/// 1:1 transliteration of WL_AGENT.C (ControlMovement/Thrust/ClipMove/TryMove)
/// + WL_MAIN.C (BuildTables → Trig) + WL_DRAW.C FixedByFrac (→ Fixed). The C
/// `sim_oracle` is the differential-test ground truth for these functions.
contract Engine {
    // --- WL_DEF.H constants ---
    int256 internal constant TILEGLOBAL = 0x10000;
    int256 internal constant MINDIST = 0x5800;
    int256 internal constant PLAYERSIZE = MINDIST;
    int256 internal constant ANGLES = 360;
    int256 internal constant MOVESCALE = 150;
    int256 internal constant BACKMOVESCALE = 100;
    int256 internal constant ANGLESCALE = 20;
    uint8 internal constant BT_STRAFE = 0x02; // enum bit 1

    /// @dev Player state (matches the oracle snapshot fields, incl. the persistent
    /// `anglefrac` turn accumulator).
    struct St {
        int256 x;
        int256 y;
        int256 angle;
        uint256 tilex;
        uint256 tiley;
        int256 anglefrac;
    }

    /// @dev One tic of input (already device-scaled, as in id's controlx/controly).
    struct Cmd {
        int256 controlx;
        int256 controly;
        uint8 buttons;
    }

    /// @dev Per-tick working context, loaded once from the Map + Trig table.
    struct Ctx {
        bytes tiles;
        uint256 w;
        uint256 h;
        bytes trig;
    }

    // ---- public API ----

    /// @notice Initial state for a map (WL_AGENT.C SpawnPlayer; Thrust(0,0) just
    /// fixes tilex/tiley here).
    function spawn(address map) external view returns (bytes32) {
        (uint256 tx, uint256 ty, uint256 dir) = IMap(map).spawn();
        St memory st;
        st.x = (int256(tx) << 16) + TILEGLOBAL / 2;
        st.y = (int256(ty) << 16) + TILEGLOBAL / 2;
        st.angle = (1 - int256(dir)) * 90;
        if (st.angle < 0) st.angle += ANGLES;
        st.tilex = uint256(st.x >> 16);
        st.tiley = uint256(st.y >> 16);
        return _pack(st);
    }

    /// @notice Advance the world exactly one tic. Stateless: pure function of
    /// (state, map, cmd). The whole player snapshot packs into one 256-bit word.
    function tick(bytes32 state, address map, Cmd calldata cmd)
        external
        view
        returns (bytes32)
    {
        St memory st = _unpack(state);
        Ctx memory ctx = Ctx({
            tiles: IMap(map).tiles(),
            w: IMap(map).width(),
            h: IMap(map).height(),
            trig: Trig.table()
        });
        _controlMovement(st, cmd, ctx);
        return _pack(st);
    }

    // ---- movement (WL_AGENT.C) ----

    function _controlMovement(St memory st, Cmd calldata cmd, Ctx memory ctx) internal pure {
        int256 angle;

        // side to side
        if (cmd.buttons & BT_STRAFE != 0) {
            if (cmd.controlx > 0) {
                angle = st.angle - ANGLES / 4;
                if (angle < 0) angle += ANGLES;
                _thrust(st, angle, cmd.controlx * MOVESCALE, ctx); // left
            } else if (cmd.controlx < 0) {
                angle = st.angle + ANGLES / 4;
                if (angle >= ANGLES) angle -= ANGLES;
                _thrust(st, angle, -cmd.controlx * MOVESCALE, ctx); // right
            }
        } else {
            st.anglefrac += cmd.controlx;
            int256 angleunits = st.anglefrac / ANGLESCALE; // truncates toward zero, as in C
            st.anglefrac -= angleunits * ANGLESCALE;
            st.angle -= angleunits;
            if (st.angle >= ANGLES) st.angle -= ANGLES;
            if (st.angle < 0) st.angle += ANGLES;
        }

        // forward/backward
        if (cmd.controly < 0) {
            _thrust(st, st.angle, -cmd.controly * MOVESCALE, ctx); // forward
        } else if (cmd.controly > 0) {
            angle = st.angle + ANGLES / 2;
            if (angle >= ANGLES) angle -= ANGLES;
            _thrust(st, angle, cmd.controly * BACKMOVESCALE, ctx); // backward
        }
    }

    function _thrust(St memory st, int256 angle, int256 speed, Ctx memory ctx) internal pure {
        if (speed >= MINDIST * 2) speed = MINDIST * 2 - 1;

        int256 xmove = Fixed.fixedByFrac(speed, Trig.cosAt(ctx.trig, uint256(angle)));
        int256 ymove = -Fixed.fixedByFrac(speed, Trig.sinAt(ctx.trig, uint256(angle)));

        _clipMove(st, xmove, ymove, ctx);

        st.tilex = uint256(st.x >> 16);
        st.tiley = uint256(st.y >> 16);
    }

    function _clipMove(St memory st, int256 xmove, int256 ymove, Ctx memory ctx) internal pure {
        int256 basex = st.x;
        int256 basey = st.y;

        st.x = basex + xmove;
        st.y = basey + ymove;
        if (_tryMove(st, ctx)) return;

        st.x = basex + xmove;
        st.y = basey;
        if (_tryMove(st, ctx)) return;

        st.x = basex;
        st.y = basey + ymove;
        if (_tryMove(st, ctx)) return;

        st.x = basex;
        st.y = basey;
    }

    function _tryMove(St memory st, Ctx memory ctx) internal pure returns (bool) {
        int256 xl = (st.x - PLAYERSIZE) >> 16;
        int256 yl = (st.y - PLAYERSIZE) >> 16;
        int256 xh = (st.x + PLAYERSIZE) >> 16;
        int256 yh = (st.y + PLAYERSIZE) >> 16;

        for (int256 y = yl; y <= yh; y++) {
            for (int256 x = xl; x <= xh; x++) {
                if (x < 0 || x >= int256(ctx.w) || y < 0 || y >= int256(ctx.h)) {
                    return false; // out of bounds = solid
                }
                if (_tile(ctx, uint256(y) * ctx.w + uint256(x)) != 0) {
                    return false; // wall
                }
            }
        }
        return true;
    }

    function _tile(Ctx memory ctx, uint256 idx) internal pure returns (uint256 v) {
        bytes memory tl = ctx.tiles;
        assembly {
            v := byte(0, mload(add(add(tl, 0x20), idx)))
        }
    }

    // ---- state codec: pack the snapshot into one 256-bit word ----
    // layout (LSB first): x:int32 | y:int32 | angle:uint16 | anglefrac:int32 |
    //                     tilex:uint8 | tiley:uint8   (128 bits used)

    function _pack(St memory s) internal pure returns (bytes32) {
        uint256 w = uint256(uint32(int32(s.x)));
        w |= uint256(uint32(int32(s.y))) << 32;
        w |= uint256(uint16(int16(s.angle))) << 64;
        w |= uint256(uint32(int32(s.anglefrac))) << 80;
        w |= uint256(uint8(s.tilex)) << 112;
        w |= uint256(uint8(s.tiley)) << 120;
        return bytes32(w);
    }

    function _unpack(bytes32 b) internal pure returns (St memory s) {
        uint256 w = uint256(b);
        s.x = int256(int32(uint32(w)));
        s.y = int256(int32(uint32(w >> 32)));
        s.angle = int256(int16(uint16(w >> 64)));
        s.anglefrac = int256(int32(uint32(w >> 80)));
        s.tilex = uint256(uint8(w >> 112));
        s.tiley = uint256(uint8(w >> 120));
    }
}
