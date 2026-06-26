/* wl_sim.c — movement subset of the Wolf3D simulation, transliterated 1:1.
 * Source map: WL_MAIN.C (BuildTables), WL_DRAW.C (FixedByFrac), WL_AGENT.C
 * (SpawnPlayer/ControlMovement/Thrust/ClipMove/TryMove). */
#include "wl_sim.h"
#include <math.h>

fixed  sintable[ANGLES + ANGLES / 4 + 1];
fixed *costable = sintable + ANGLEQUAD;

int   anglefrac;
long  playerxmove, playerymove;

objtype  playerent;
objtype *player = &playerent;

unsigned char tilemap[MAPSIZE][MAPSIZE];

int controlx, controly;
int buttonstate[NUMBUTTONS];

/* WL_MAIN.C BuildTables — sin/cos only (finetangent is render-side). Float
 * types and truncation are deliberately mirrored: GLOBAL1*sin(90deg) truncates
 * to 0xFFFF, so costable[0] != 0x10000. */
void BuildTables(void)
{
    int   i;
    float angle, anglestep;
    fixed value;

    angle = 0;
    anglestep = (float)(PI / 2 / ANGLEQUAD);
    for (i = 0; i <= ANGLEQUAD; i++) {
        value = (fixed)(GLOBAL1 * sin(angle));
        sintable[i] =
            sintable[i + ANGLES] =
            sintable[ANGLES / 2 - i] = value;
        sintable[ANGLES - i] =
            sintable[ANGLES / 2 + i] = value | (fixed)0x80000000L;
        angle += anglestep;
    }
}

/* WL_DRAW.C FixedByFrac (asm) made portable:
 *   result = sign(a)^sign-bit(b) applied to (|a| * (b & 0xffff)) >> 16
 * b is a signed-magnitude 32-bit number: magnitude in the low 16 bits, sign in
 * bit 31; bits 16..30 are ignored (matches the asm using only the low word). */
fixed FixedByFrac(fixed a, fixed b)
{
    int      sign = (int)(((uint32_t)b >> 31) & 1u);
    uint32_t ua;
    uint32_t frac = (uint32_t)b & 0xffffu;
    uint64_t prod;
    uint32_t res;

    if (a < 0) { ua = (uint32_t)(-(int64_t)a); sign ^= 1; }
    else        ua = (uint32_t)a;

    prod = (uint64_t)ua * (uint64_t)frac;
    res  = (uint32_t)(prod >> 16);
    return sign ? -(fixed)res : (fixed)res;
}

/* WL_AGENT.C SpawnPlayer (movement-relevant fields only). */
void SpawnPlayer(int tilex, int tiley, int dir)
{
    player->tilex = tilex;
    player->tiley = tiley;
    player->x = ((long)tilex << TILESHIFT) + TILEGLOBAL / 2;
    player->y = ((long)tiley << TILESHIFT) + TILEGLOBAL / 2;
    player->angle = (1 - dir) * 90;
    if (player->angle < 0)
        player->angle += ANGLES;
    anglefrac = 0;
    Thrust(0, 0); /* sets tilex/tiley + movement bookkeeping */
}

/* WL_AGENT.C TryMove — true if the player's PLAYERSIZE box hits no wall.
 * Actor-vs-actor checks arrive with enemies (M2). Out-of-bounds is treated as
 * solid; faithful maps have a wall border so it never triggers. */
int TryMove(objtype *ob)
{
    int xl, yl, xh, yh, x, y;

    xl = (ob->x - PLAYERSIZE) >> TILESHIFT;
    yl = (ob->y - PLAYERSIZE) >> TILESHIFT;
    xh = (ob->x + PLAYERSIZE) >> TILESHIFT;
    yh = (ob->y + PLAYERSIZE) >> TILESHIFT;

    for (y = yl; y <= yh; y++)
        for (x = xl; x <= xh; x++) {
            if (x < 0 || x >= MAPSIZE || y < 0 || y >= MAPSIZE)
                return 0;
            if (tilemap[x][y])
                return 0;
        }
    return 1;
}

/* WL_AGENT.C ClipMove — full move, else x-only, else y-only, else revert.
 * noclip and the wall-hit sound are dropped (no effect on x/y/angle). */
void ClipMove(objtype *ob, long xmove, long ymove)
{
    long basex = ob->x;
    long basey = ob->y;

    ob->x = basex + xmove;
    ob->y = basey + ymove;
    if (TryMove(ob))
        return;

    ob->x = basex + xmove;
    ob->y = basey;
    if (TryMove(ob))
        return;

    ob->x = basex;
    ob->y = basey + ymove;
    if (TryMove(ob))
        return;

    ob->x = basex;
    ob->y = basey;
}

/* WL_AGENT.C Thrust — areanumber/exit-tile tail dropped (no effect on snapshot). */
void Thrust(int angle, long speed)
{
    long xmove, ymove;

    if (speed >= MINDIST * 2)
        speed = MINDIST * 2 - 1;

    xmove = FixedByFrac(speed, costable[angle]);
    ymove = -FixedByFrac(speed, sintable[angle]);

    ClipMove(player, xmove, ymove);

    player->tilex = player->x >> TILESHIFT;
    player->tiley = player->y >> TILESHIFT;
}

/* WL_AGENT.C ControlMovement — strafe/turn + forward/back, exactly as id's. */
void ControlMovement(objtype *ob)
{
    long oldx, oldy;
    int  angle;
    int  angleunits;

    oldx = player->x;
    oldy = player->y;

    /* side to side */
    if (buttonstate[bt_strafe]) {
        if (controlx > 0) {
            angle = ob->angle - ANGLES / 4;
            if (angle < 0)
                angle += ANGLES;
            Thrust(angle, controlx * MOVESCALE);      /* left */
        } else if (controlx < 0) {
            angle = ob->angle + ANGLES / 4;
            if (angle >= ANGLES)
                angle -= ANGLES;
            Thrust(angle, -controlx * MOVESCALE);     /* right */
        }
    } else {
        anglefrac += controlx;
        angleunits = anglefrac / ANGLESCALE;
        anglefrac -= angleunits * ANGLESCALE;
        ob->angle -= angleunits;
        if (ob->angle >= ANGLES)
            ob->angle -= ANGLES;
        if (ob->angle < 0)
            ob->angle += ANGLES;
    }

    /* forward/backward */
    if (controly < 0) {
        Thrust(ob->angle, -controly * MOVESCALE);     /* forward */
    } else if (controly > 0) {
        angle = ob->angle + ANGLES / 2;
        if (angle >= ANGLES)
            angle -= ANGLES;
        Thrust(angle, controly * BACKMOVESCALE);      /* backward */
    }

    playerxmove = player->x - oldx;
    playerymove = player->y - oldy;
}
