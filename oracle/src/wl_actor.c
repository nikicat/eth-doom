/* wl_actor.c — enemy actor model + guard AI, transliterated 1:1 from Wolf3D.
 * Sources: WL_PLAY.C (DoActor), WL_STATE.C (TryWalk/SelectChaseDir/SelectDodgeDir/
 * MoveObj/CheckLine/NewState), WL_ACT2.C (T_Chase, guard state table, SpawnStand,
 * FirstSighting). M2b scope: one guard, chase movement; sight-detection (T_Stand/
 * SightPlayer) and hitscan (T_Shoot/DamageActor) are stubbed for M2c. */
#include "wl_sim.h"
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

objtype  enemies[MAXENEMIES];
int      numenemies;
void    *actorat[MAPSIZE][MAPSIZE];
int      tics = 1;
int      plux, pluy;
long     thrustspeed;
int      health = 100;   /* gamestate.health */
int      playerdead;     /* playstate == ex_died */
int      ammo = STARTAMMO;
int      attackcount;    /* fire cooldown */
int      madenoise;      /* player fired this tic (alerts guards in the area) */

static unsigned char areabyplayer[64];   /* single-area map: all reachable */
static int doorposition[256];             /* no doors in M2 (kept for CheckLine) */

/* WL_STATE.C global direction tables */
static const dirtype opposite[9] =
    { west, southwest, south, southeast, east, northeast, north, northwest, nodir };

static const dirtype diagonal[9][9] = {
/* east  */ { nodir, nodir, northeast, nodir, nodir, nodir, southeast, nodir, nodir },
/* ne    */ { nodir, nodir, nodir, nodir, nodir, nodir, nodir, nodir, nodir },
/* north */ { northeast, nodir, nodir, nodir, northwest, nodir, nodir, nodir, nodir },
/* nw    */ { nodir, nodir, nodir, nodir, nodir, nodir, nodir, nodir, nodir },
/* west  */ { nodir, nodir, northwest, nodir, nodir, nodir, southwest, nodir, nodir },
/* sw    */ { nodir, nodir, nodir, nodir, nodir, nodir, nodir, nodir, nodir },
/* south */ { southeast, nodir, nodir, nodir, southwest, nodir, nodir, nodir, nodir },
/* se    */ { nodir, nodir, nodir, nodir, nodir, nodir, nodir, nodir, nodir },
/* nodir */ { nodir, nodir, nodir, nodir, nodir, nodir, nodir, nodir, nodir },
};

/* WL_ACT2.C guard state graph (shapenum dropped). */
const statedef gstates[NUMSTATES] = {
    [S_GRDSTAND]   = { 0,  TH_STAND, AC_NONE,        S_GRDSTAND },
    [S_GRDCHASE1]  = { 10, TH_CHASE, AC_NONE,        S_GRDCHASE1S },
    [S_GRDCHASE1S] = { 3,  TH_NONE,  AC_NONE,        S_GRDCHASE2 },
    [S_GRDCHASE2]  = { 8,  TH_CHASE, AC_NONE,        S_GRDCHASE3 },
    [S_GRDCHASE3]  = { 10, TH_CHASE, AC_NONE,        S_GRDCHASE3S },
    [S_GRDCHASE3S] = { 3,  TH_NONE,  AC_NONE,        S_GRDCHASE4 },
    [S_GRDCHASE4]  = { 8,  TH_CHASE, AC_NONE,        S_GRDCHASE1 },
    [S_GRDSHOOT1]  = { 20, TH_NONE,  AC_NONE,        S_GRDSHOOT2 },
    [S_GRDSHOOT2]  = { 20, TH_NONE,  AC_SHOOT,       S_GRDSHOOT3 },
    [S_GRDSHOOT3]  = { 20, TH_NONE,  AC_NONE,        S_GRDCHASE1 },
    [S_GRDDIE1]    = { 15, TH_NONE,  AC_DEATHSCREAM, S_GRDDIE2 },
    [S_GRDDIE2]    = { 15, TH_NONE,  AC_NONE,        S_GRDDIE3 },
    [S_GRDDIE3]    = { 15, TH_NONE,  AC_NONE,        S_GRDDIE4 },
    [S_GRDDIE4]    = { 0,  TH_NONE,  AC_NONE,        S_GRDDIE4 },
    [S_GRDPAIN]    = { 10, TH_NONE,  AC_NONE,        S_GRDCHASE1 },
    [S_GRDPAIN1]   = { 10, TH_NONE,  AC_NONE,        S_GRDCHASE1 },
};

static void NewState(objtype *ob, int state) {
    ob->state = state;
    ob->ticcount = gstates[state].tictime;
}

/* WL_STATE.C TryWalk collision macros. actorat holds wall tile values (<256) or
 * actor pointers; `return 0` aborts the move. */
#define CHECKDIAG(x, y)                                   \
    {                                                     \
        temp = (uintptr_t)actorat[x][y];                  \
        if (temp) {                                       \
            if (temp < 256) return 0;                     \
            if (((objtype *)temp)->flags & FL_SHOOTABLE)  \
                return 0;                                 \
        }                                                 \
    }
#define CHECKSIDE(x, y)                                   \
    {                                                     \
        temp = (uintptr_t)actorat[x][y];                  \
        if (temp) {                                       \
            if (temp < 128) return 0;                     \
            if (temp < 256) doornum = temp & 63;          \
            else if (((objtype *)temp)->flags & FL_SHOOTABLE) \
                return 0;                                 \
        }                                                 \
    }

/* WL_STATE.C TryWalk (guard path: CHECKSIDE on cardinals, CHECKDIAG on diagonals). */
static int TryWalk(objtype *ob) {
    int       doornum = -1;
    uintptr_t temp;

    switch (ob->dir) {
    case north:     CHECKSIDE(ob->tilex, ob->tiley - 1); ob->tiley--; break;
    case northeast:
        CHECKDIAG(ob->tilex + 1, ob->tiley - 1);
        CHECKDIAG(ob->tilex + 1, ob->tiley);
        CHECKDIAG(ob->tilex, ob->tiley - 1);
        ob->tilex++; ob->tiley--; break;
    case east:      CHECKSIDE(ob->tilex + 1, ob->tiley); ob->tilex++; break;
    case southeast:
        CHECKDIAG(ob->tilex + 1, ob->tiley + 1);
        CHECKDIAG(ob->tilex + 1, ob->tiley);
        CHECKDIAG(ob->tilex, ob->tiley + 1);
        ob->tilex++; ob->tiley++; break;
    case south:     CHECKSIDE(ob->tilex, ob->tiley + 1); ob->tiley++; break;
    case southwest:
        CHECKDIAG(ob->tilex - 1, ob->tiley + 1);
        CHECKDIAG(ob->tilex - 1, ob->tiley);
        CHECKDIAG(ob->tilex, ob->tiley + 1);
        ob->tilex--; ob->tiley++; break;
    case west:      CHECKSIDE(ob->tilex - 1, ob->tiley); ob->tilex--; break;
    case northwest:
        CHECKDIAG(ob->tilex - 1, ob->tiley - 1);
        CHECKDIAG(ob->tilex - 1, ob->tiley);
        CHECKDIAG(ob->tilex, ob->tiley - 1);
        ob->tilex--; ob->tiley--; break;
    case nodir:     return 0;
    default:        return 0;
    }

    if (doornum != -1) {            /* door blocking (none in M2) */
        ob->distance = -doornum - 1;
        return 1;
    }
    ob->areanumber = 0;             /* single-area map */
    ob->distance = TILEGLOBAL;
    return 1;
}

/* WL_STATE.C SelectDodgeDir */
static void SelectDodgeDir(objtype *ob) {
    int      deltax, deltay, i;
    unsigned absdx, absdy;
    dirtype  dirtry[5];
    dirtype  turnaround, tdir;

    if (ob->flags & FL_FIRSTATTACK) {
        turnaround = nodir;
        ob->flags &= ~FL_FIRSTATTACK;
    } else {
        turnaround = opposite[ob->dir];
    }

    deltax = player->tilex - ob->tilex;
    deltay = player->tiley - ob->tiley;

    if (deltax > 0) { dirtry[1] = east;  dirtry[3] = west; }
    else            { dirtry[1] = west;  dirtry[3] = east; }
    if (deltay > 0) { dirtry[2] = south; dirtry[4] = north; }
    else            { dirtry[2] = north; dirtry[4] = south; }

    absdx = abs(deltax);
    absdy = abs(deltay);

    if (absdx > absdy) {
        tdir = dirtry[1]; dirtry[1] = dirtry[2]; dirtry[2] = tdir;
        tdir = dirtry[3]; dirtry[3] = dirtry[4]; dirtry[4] = tdir;
    }
    if (US_RndT() < 128) {
        tdir = dirtry[1]; dirtry[1] = dirtry[2]; dirtry[2] = tdir;
        tdir = dirtry[3]; dirtry[3] = dirtry[4]; dirtry[4] = tdir;
    }

    dirtry[0] = diagonal[dirtry[1]][dirtry[2]];

    for (i = 0; i < 5; i++) {
        if (dirtry[i] == nodir || dirtry[i] == turnaround) continue;
        ob->dir = dirtry[i];
        if (TryWalk(ob)) return;
    }
    if (turnaround != nodir) {
        ob->dir = turnaround;
        if (TryWalk(ob)) return;
    }
    ob->dir = nodir;
}

/* WL_STATE.C SelectChaseDir */
static void SelectChaseDir(objtype *ob) {
    int     deltax, deltay;
    dirtype d[3];
    dirtype tdir, olddir, turnaround;

    olddir = ob->dir;
    turnaround = opposite[olddir];

    deltax = player->tilex - ob->tilex;
    deltay = player->tiley - ob->tiley;

    d[1] = nodir;
    d[2] = nodir;
    if (deltax > 0)      d[1] = east;
    else if (deltax < 0) d[1] = west;
    if (deltay > 0)      d[2] = south;
    else if (deltay < 0) d[2] = north;

    if (abs(deltay) > abs(deltax)) { tdir = d[1]; d[1] = d[2]; d[2] = tdir; }

    if (d[1] == turnaround) d[1] = nodir;
    if (d[2] == turnaround) d[2] = nodir;

    if (d[1] != nodir) { ob->dir = d[1]; if (TryWalk(ob)) return; }
    if (d[2] != nodir) { ob->dir = d[2]; if (TryWalk(ob)) return; }

    if (olddir != nodir) { ob->dir = olddir; if (TryWalk(ob)) return; }

    if (US_RndT() > 128) {
        for (tdir = north; tdir <= west; tdir++) {
            if (tdir != turnaround) { ob->dir = tdir; if (TryWalk(ob)) return; }
        }
    } else {
        for (tdir = west; tdir >= north; tdir--) {
            if (tdir != turnaround) { ob->dir = tdir; if (TryWalk(ob)) return; }
        }
    }

    if (turnaround != nodir) {
        ob->dir = turnaround;
        if (ob->dir != nodir) { if (TryWalk(ob)) return; }
    }
    ob->dir = nodir;
}

/* WL_STATE.C MoveObj (guard: no ghost/spectre self-damage). */
static void MoveObj(objtype *ob, long move) {
    long deltax, deltay;

    switch (ob->dir) {
    case north:     ob->y -= move; break;
    case northeast: ob->x += move; ob->y -= move; break;
    case east:      ob->x += move; break;
    case southeast: ob->x += move; ob->y += move; break;
    case south:     ob->y += move; break;
    case southwest: ob->x -= move; ob->y += move; break;
    case west:      ob->x -= move; break;
    case northwest: ob->x -= move; ob->y -= move; break;
    case nodir:     return;
    default:        return;
    }

    if (areabyplayer[ob->areanumber]) {
        deltax = ob->x - player->x;
        if (deltax < -MINACTORDIST || deltax > MINACTORDIST) goto moveok;
        deltay = ob->y - player->y;
        if (deltay < -MINACTORDIST || deltay > MINACTORDIST) goto moveok;

        /* back up — too close to player */
        switch (ob->dir) {
        case north:     ob->y += move; break;
        case northeast: ob->x -= move; ob->y += move; break;
        case east:      ob->x -= move; break;
        case southeast: ob->x -= move; ob->y -= move; break;
        case south:     ob->y -= move; break;
        case southwest: ob->x += move; ob->y -= move; break;
        case west:      ob->x += move; break;
        case northwest: ob->x += move; ob->y += move; break;
        case nodir:     return;
        }
        return;
    }
moveok:
    ob->distance -= move;
}

/* WL_STATE.C CheckLine — straight-line LOS over the tilemap (door logic dead in M2). */
static int CheckLine(objtype *ob) {
    int x1, y1, xt1, yt1, x2, y2, xt2, yt2;
    int x, y, xdist, ydist, xstep, ystep;
    int partial, delta, xfrac, yfrac, deltafrac;
    long ltemp;
    unsigned value, intercept;

    x1 = ob->x >> UNSIGNEDSHIFT;
    y1 = ob->y >> UNSIGNEDSHIFT;
    xt1 = x1 >> 8;
    yt1 = y1 >> 8;
    x2 = plux;  y2 = pluy;
    xt2 = player->tilex;  yt2 = player->tiley;

    xdist = abs(xt2 - xt1);
    if (xdist > 0) {
        if (xt2 > xt1) { partial = 256 - (x1 & 0xff); xstep = 1; }
        else           { partial = x1 & 0xff;         xstep = -1; }
        deltafrac = abs(x2 - x1);
        delta = y2 - y1;
        ltemp = ((long)delta << 8) / deltafrac;
        if (ltemp > 0x7fffl)       ystep = 0x7fff;
        else if (ltemp < -0x7fffl) ystep = -0x7fff;
        else                       ystep = ltemp;
        yfrac = y1 + (((long)ystep * partial) >> 8);
        x = xt1 + xstep;
        xt2 += xstep;
        do {
            y = yfrac >> 8;
            yfrac += ystep;
            value = (unsigned)tilemap[x][y];
            x += xstep;
            if (!value) continue;
            if (value < 128 || value > 256) return 0;
            value &= ~0x80;
            intercept = yfrac - ystep / 2;
            if (intercept > (unsigned)doorposition[value]) return 0;
        } while (x != xt2);
    }

    ydist = abs(yt2 - yt1);
    if (ydist > 0) {
        if (yt2 > yt1) { partial = 256 - (y1 & 0xff); ystep = 1; }
        else           { partial = y1 & 0xff;         ystep = -1; }
        deltafrac = abs(y2 - y1);
        delta = x2 - x1;
        ltemp = ((long)delta << 8) / deltafrac;
        if (ltemp > 0x7fffl)       xstep = 0x7fff;
        else if (ltemp < -0x7fffl) xstep = -0x7fff;
        else                       xstep = ltemp;
        xfrac = x1 + (((long)xstep * partial) >> 8);
        y = yt1 + ystep;
        yt2 += ystep;
        do {
            x = xfrac >> 8;
            xfrac += xstep;
            value = (unsigned)tilemap[x][y];
            y += ystep;
            if (!value) continue;
            if (value < 128 || value > 256) return 0;
            value &= ~0x80;
            intercept = xfrac - xstep / 2;
            if (intercept > (unsigned)doorposition[value]) return 0;
        } while (y != yt2);
    }
    return 1;
}

/* WL_ACT2.C T_Chase (guard only). */
static void T_Chase(objtype *ob) {
    long move;
    int  dx, dy, dist, chance, dodge = 0;

    if (CheckLine(ob)) {
        dx = abs((int)ob->tilex - (int)player->tilex);
        dy = abs((int)ob->tiley - (int)player->tiley);
        dist = dx > dy ? dx : dy;
        if (!dist || (dist == 1 && ob->distance < 0x4000)) chance = 300;
        else chance = (tics << 4) / dist;

        if (US_RndT() < chance) { NewState(ob, S_GRDSHOOT1); return; }
        dodge = 1;
    }

    if (ob->dir == nodir) {
        if (dodge) SelectDodgeDir(ob); else SelectChaseDir(ob);
        if (ob->dir == nodir) return;
    }

    move = ob->speed * tics;
    while (move) {
        if (ob->distance < 0) ob->distance = TILEGLOBAL;   /* door (none) */
        if (move < ob->distance) { MoveObj(ob, move); break; }
        ob->x = ((long)ob->tilex << TILESHIFT) + TILEGLOBAL / 2;
        ob->y = ((long)ob->tiley << TILESHIFT) + TILEGLOBAL / 2;
        move -= ob->distance;
        if (dodge) SelectDodgeDir(ob); else SelectChaseDir(ob);
        if (ob->dir == nodir) return;
    }
}

/* WL_STATE.C CheckSight: area connected + auto-see-if-close + facing FOV + LOS. */
int CheckSight(objtype *ob) {
    long deltax, deltay;
    if (!areabyplayer[ob->areanumber]) return 0;
    deltax = player->x - ob->x;
    deltay = player->y - ob->y;
    if (deltax > -MINSIGHT && deltax < MINSIGHT && deltay > -MINSIGHT && deltay < MINSIGHT)
        return 1;                       /* very close: automatic */
    switch (ob->dir) {                  /* only cardinal facings restrict the view */
    case north: if (deltay > 0) return 0; break;
    case east:  if (deltax < 0) return 0; break;
    case south: if (deltay < 0) return 0; break;
    case west:  if (deltax > 0) return 0; break;
    }
    return CheckLine(ob);
}

/* WL_STATE.C FirstSighting (guard): wake into chase, 3x speed, attack flags. */
void FirstSighting(objtype *ob) {
    NewState(ob, S_GRDCHASE1);
    ob->speed *= 3;
    if (ob->distance < 0) ob->distance = 0;
    ob->flags |= FL_ATTACKMODE | FL_FIRSTATTACK;
}

/* WL_STATE.C SightPlayer: first sight starts a reaction timer; on expiry, wake.
 * (Boss/other-class reaction values dropped — guard only.) */
int SightPlayer(objtype *ob) {
    if (ob->flags & FL_ATTACKMODE) return 1;   /* already alerted */
    if (ob->temp2) {
        ob->temp2 -= tics;             /* count down reaction time */
        if (ob->temp2 > 0) return 0;
        ob->temp2 = 0;                 /* time to react */
    } else {
        if (!areabyplayer[ob->areanumber]) return 0;
        if (ob->flags & FL_AMBUSH) {
            if (!CheckSight(ob)) return 0;
            ob->flags &= ~FL_AMBUSH;
        } else if (!madenoise && !CheckSight(ob)) {
            return 0;
        }
        ob->temp2 = 1 + US_RndT() / 4;  /* guard reaction delay */
        return 0;
    }
    FirstSighting(ob);
    return 1;
}

static void T_Stand(objtype *ob) { SightPlayer(ob); }

/* WL_AGENT.C TakeDamage (core: rendering/flash/difficulty=baby/godmode dropped). */
static void TakeDamage(int points, objtype *attacker) {
    (void)attacker;
    health -= points;
    if (health <= 0) {
        health = 0;
        playerdead = 1;
    }
}

/* WL_ACT2.C T_Shoot (guard). FL_VISABLE is render-derived, hence always false in
 * the headless sim (same on both sides) — so only the non-visible hitchance
 * branches apply. Sounds dropped. */
static void T_Shoot(objtype *ob) {
    int dx, dy, dist, hitchance, damage;

    if (!CheckLine(ob)) return; /* player behind a wall */

    dx = abs((int)ob->tilex - (int)player->tilex);
    dy = abs((int)ob->tiley - (int)player->tiley);
    dist = dx > dy ? dx : dy;

    if (thrustspeed >= RUNSPEED)
        hitchance = 160 - dist * 8;
    else
        hitchance = 256 - dist * 8;

    if (US_RndT() < hitchance) {
        if (dist < 2)      damage = US_RndT() >> 2;
        else if (dist < 4) damage = US_RndT() >> 3;
        else               damage = US_RndT() >> 4;
        TakeDamage(damage, ob);
    }
}

/* WL_STATE.C KillActor (guard: die animation, no longer shootable; points/item dropped). */
static void KillActor(objtype *ob) {
    ob->tilex = ob->x >> TILESHIFT;
    ob->tiley = ob->y >> TILESHIFT;
    NewState(ob, S_GRDDIE1);
    ob->flags &= ~FL_SHOOTABLE;
}

/* WL_STATE.C DamageActor (guard is in attack mode here, so no double-damage / FirstSighting). */
static void DamageActor(objtype *ob, int damage) {
    if (!(ob->flags & FL_ATTACKMODE))
        damage <<= 1;
    ob->hitpoints -= damage;
    if (ob->hitpoints <= 0) {
        KillActor(ob);
        return;
    }
    if (ob->hitpoints & 1) NewState(ob, S_GRDPAIN);
    else                   NewState(ob, S_GRDPAIN1);
}

/* WL_AGENT.C GunAttack — player hitscan. The original picks the on-screen target via
 * viewx/FL_VISABLE (render-derived); here the aim is computed from sim state: the
 * closest shootable actor that is in front (depth nx >= MINDIST via the view rotation)
 * with a clear line of sight. The screen-pixel `shootdelta` cone is the one part
 * dropped (it's render-config-specific). Damage/miss math is faithful. */
static void GunAttack(void) {
    int   va = player->angle;
    fixed viewsin = sintable[va], viewcos = costable[va];
    fixed viewx = player->x - FixedByFrac(FOCALLENGTH, viewcos);
    fixed viewy = player->y + FixedByFrac(FOCALLENGTH, viewsin);
    objtype *closest = NULL;
    long bestnx = 0x7fffffffL;

    for (int i = 0; i < numenemies; i++) {
        objtype *e = &enemies[i];
        if (!(e->flags & FL_SHOOTABLE)) continue;
        fixed gx = e->x - viewx, gy = e->y - viewy;
        fixed nx = FixedByFrac(gx, viewcos) - FixedByFrac(gy, viewsin) - ACTORSIZE;
        if (nx < MINDIST) continue;     /* behind / too close */
        if (!CheckLine(e)) continue;    /* line of sight blocked */
        if (nx < bestnx) { bestnx = nx; closest = e; }
    }
    if (!closest) return;

    int dx = abs((int)closest->tilex - (int)player->tilex);
    int dy = abs((int)closest->tiley - (int)player->tiley);
    int dist = dx > dy ? dx : dy;
    int damage;
    if (dist < 2)      damage = US_RndT() / 4;
    else if (dist < 4) damage = US_RndT() / 6;
    else {
        if (US_RndT() / 12 < dist) return; /* missed */
        damage = US_RndT() / 6;
    }
    DamageActor(closest, damage);
}

/* Player firing: a simple cooldown replaces the weapon animation (Cmd_Fire/T_Attack). */
void PlayerAttack(int buttons) {
    if (attackcount > 0) attackcount--;
    if ((buttons & 1) && attackcount == 0 && ammo > 0) { /* bt_attack = bit 0 */
        ammo--;
        madenoise = 1;          /* firing alerts guards in the area */
        GunAttack();
        attackcount = ATTACKRATE;
    }
}

static void dispatch_think(int id, objtype *ob) {
    switch (id) {
    case TH_STAND: T_Stand(ob); break;
    case TH_CHASE: T_Chase(ob); break;
    default: break;
    }
}
static void dispatch_action(int id, objtype *ob) {
    switch (id) {
    case AC_SHOOT: T_Shoot(ob); break;
    default: break;
    }
}

/* WL_PLAY.C DoActor — per-tic state-machine advance (no RemoveObj: guard corpses
 * stay; states never go null in M2). */
void DoActor(objtype *ob) {
    int id;

    if (!ob->active && !areabyplayer[ob->areanumber]) return;

    if (!(ob->flags & (FL_NONMARK | FL_NEVERMARK)))
        actorat[ob->tilex][ob->tiley] = NULL;

    if (!ob->ticcount) {
        id = gstates[ob->state].think;
        if (id) dispatch_think(id, ob);
        if (ob->flags & FL_NEVERMARK) return;
        if ((ob->flags & FL_NONMARK) && actorat[ob->tilex][ob->tiley]) return;
        actorat[ob->tilex][ob->tiley] = ob;
        return;
    }

    ob->ticcount -= tics;
    while (ob->ticcount <= 0) {
        id = gstates[ob->state].action;
        if (id) dispatch_action(id, ob);
        ob->state = gstates[ob->state].next;
        if (!gstates[ob->state].tictime) { ob->ticcount = 0; goto think; }
        ob->ticcount += gstates[ob->state].tictime;
    }
think:
    id = gstates[ob->state].think;
    if (id) dispatch_think(id, ob);
    if (ob->flags & FL_NEVERMARK) return;
    if ((ob->flags & FL_NONMARK) && actorat[ob->tilex][ob->tiley]) return;
    actorat[ob->tilex][ob->tiley] = ob;
}

void InitActors(void) {
    int x, y, i;
    numenemies = 0;
    memset(actorat, 0, sizeof(actorat));
    for (x = 0; x < MAPSIZE; x++)
        for (y = 0; y < MAPSIZE; y++)
            if (tilemap[x][y])
                actorat[x][y] = (void *)(uintptr_t)tilemap[x][y];
    for (i = 0; i < 64; i++) areabyplayer[i] = 1;
}

/* Spawn a guard already alerted (stand -> SpawnStand -> FirstSighting), so it
 * begins in s_grdchase1 at chase speed. Sight detection arrives in a later step. */
void SpawnGuard(int tilex, int tiley, int dir) {
    objtype *ob = &enemies[numenemies++];
    memset(ob, 0, sizeof(*ob));

    /* SpawnNewObj(tilex,tiley,&s_grdstand): tictime 0 => ticcount 0, no RNG */
    ob->state = S_GRDSTAND;
    ob->ticcount = 0;
    ob->tilex = tilex;
    ob->tiley = tiley;
    ob->x = ((long)tilex << TILESHIFT) + TILEGLOBAL / 2;
    ob->y = ((long)tiley << TILESHIFT) + TILEGLOBAL / 2;
    ob->areanumber = 0;
    actorat[tilex][tiley] = ob;

    /* SpawnStand(en_guard): dormant, facing a cardinal dir (dir*2), patrol speed.
     * It wakes via T_Stand -> SightPlayer (LOS or noise), not at spawn. `active`
     * stays ac_yes so the headless sim keeps running its think every tic. */
    ob->dir = (dir & 3) * 2;          /* 4-way 0..3 -> dirtype east/north/west/south */
    ob->obclass = guardobj;
    ob->speed = SPDPATROL;
    ob->flags = FL_SHOOTABLE;
    ob->hitpoints = 25;
    ob->temp2 = 0;
    ob->active = ac_yes;
}
