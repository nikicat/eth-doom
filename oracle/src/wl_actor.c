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
int      playstate;      /* exit_t: ex_stillplaying until the elevator switch is used */
int      ammo = STARTAMMO;
int      weapon = wp_pistol, bestweapon = wp_pistol; /* NewGame: start with the pistol */
int      attackcount;    /* fire cooldown */
int      madenoise;      /* player fired this tic (alerts guards in the area) */

/* WL_ACT1.C area connectivity. areamap = per-tile area; areaconnect[a][b] counts the
 * non-closed doors joining areas a and b; areabyplayer[a] = a reachable from the player's
 * area through open doors. Gunfire (madenoise) only alerts guards where areabyplayer is set. */
unsigned char areamap[MAPSIZE][MAPSIZE];

/* pushwall state (WL_ACT1.C). A record per triggered wall (several may slide at once); a
 * record persists once complete (the relocation is permanent). */
int pwall_count;
int pw_startx[MAXPWALLS], pw_starty[MAXPWALLS], pw_dir[MAXPWALLS];
int pw_state[MAXPWALLS], pw_oldtile[MAXPWALLS], pw_curx[MAXPWALLS], pw_cury[MAXPWALLS];
unsigned char pushwallat[MAPSIZE][MAPSIZE];
static const int pwdx[4] = {0, 1, 0, -1}; /* di_north, di_east, di_south, di_west */
static const int pwdy[4] = {-1, 0, 1, 0};
static unsigned char areaconnect[NUMAREAS][NUMAREAS];
static unsigned char areabyplayer[NUMAREAS];

void RecursiveConnect(int area) {
    int i;
    for (i = 0; i < NUMAREAS; i++)
        if (areaconnect[area][i] && !areabyplayer[i]) {
            areabyplayer[i] = 1;
            RecursiveConnect(i);
        }
}

void ConnectAreas(void) {
    memset(areabyplayer, 0, sizeof areabyplayer);
    areabyplayer[player->areanumber] = 1;
    RecursiveConnect(player->areanumber);
}

/* WL_ACT1.C door globals. doorposition: leading edge 0=closed..0xffff=open. */
doorobj_t doorobjlist[MAXDOORS];
int       doornum;
unsigned  doorposition[MAXDOORS];
int       useheld;                        /* buttonheld[bt_use] edge latch */

/* WL_ACT1.C bonus statics + WL_AGENT.C gamestate bits the pickups touch. */
statobj_t statobjlist[MAXSTATS];
int       numstats;
int       keys;
long      score;

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
    /* WL_ACT2.C SS: same chase/die graph as the guard, but a 4-shot burst. */
    [S_SSSTAND]    = { 0,  TH_STAND, AC_NONE,        S_SSSTAND },
    [S_SSCHASE1]   = { 10, TH_CHASE, AC_NONE,        S_SSCHASE1S },
    [S_SSCHASE1S]  = { 3,  TH_NONE,  AC_NONE,        S_SSCHASE2 },
    [S_SSCHASE2]   = { 8,  TH_CHASE, AC_NONE,        S_SSCHASE3 },
    [S_SSCHASE3]   = { 10, TH_CHASE, AC_NONE,        S_SSCHASE3S },
    [S_SSCHASE3S]  = { 3,  TH_NONE,  AC_NONE,        S_SSCHASE4 },
    [S_SSCHASE4]   = { 8,  TH_CHASE, AC_NONE,        S_SSCHASE1 },
    [S_SSSHOOT1]   = { 20, TH_NONE,  AC_NONE,        S_SSSHOOT2 },
    [S_SSSHOOT2]   = { 20, TH_NONE,  AC_SHOOT,       S_SSSHOOT3 },
    [S_SSSHOOT3]   = { 10, TH_NONE,  AC_NONE,        S_SSSHOOT4 },
    [S_SSSHOOT4]   = { 10, TH_NONE,  AC_SHOOT,       S_SSSHOOT5 },
    [S_SSSHOOT5]   = { 10, TH_NONE,  AC_NONE,        S_SSSHOOT6 },
    [S_SSSHOOT6]   = { 10, TH_NONE,  AC_SHOOT,       S_SSSHOOT7 },
    [S_SSSHOOT7]   = { 10, TH_NONE,  AC_NONE,        S_SSSHOOT8 },
    [S_SSSHOOT8]   = { 10, TH_NONE,  AC_SHOOT,       S_SSSHOOT9 },
    [S_SSSHOOT9]   = { 10, TH_NONE,  AC_NONE,        S_SSCHASE1 },
    [S_SSDIE1]     = { 15, TH_NONE,  AC_DEATHSCREAM, S_SSDIE2 },
    [S_SSDIE2]     = { 15, TH_NONE,  AC_NONE,        S_SSDIE3 },
    [S_SSDIE3]     = { 15, TH_NONE,  AC_NONE,        S_SSDIE4 },
    [S_SSDIE4]     = { 0,  TH_NONE,  AC_NONE,        S_SSDIE4 },
    [S_SSPAIN]     = { 10, TH_NONE,  AC_NONE,        S_SSCHASE1 },
    [S_SSPAIN1]    = { 10, TH_NONE,  AC_NONE,        S_SSCHASE1 },
    /* WL_ACT2.C dog: melee-only chase (T_DogChase), jumps to bite, no pain. */
    [S_DOGSTAND]   = { 0,  TH_STAND,    AC_NONE,        S_DOGSTAND },
    [S_DOGCHASE1]  = { 10, TH_DOGCHASE, AC_NONE,        S_DOGCHASE1S },
    [S_DOGCHASE1S] = { 3,  TH_NONE,     AC_NONE,        S_DOGCHASE2 },
    [S_DOGCHASE2]  = { 8,  TH_DOGCHASE, AC_NONE,        S_DOGCHASE3 },
    [S_DOGCHASE3]  = { 10, TH_DOGCHASE, AC_NONE,        S_DOGCHASE3S },
    [S_DOGCHASE3S] = { 3,  TH_NONE,     AC_NONE,        S_DOGCHASE4 },
    [S_DOGCHASE4]  = { 8,  TH_DOGCHASE, AC_NONE,        S_DOGCHASE1 },
    [S_DOGJUMP1]   = { 10, TH_NONE,     AC_NONE,        S_DOGJUMP2 },
    [S_DOGJUMP2]   = { 10, TH_NONE,     AC_BITE,        S_DOGJUMP3 },
    [S_DOGJUMP3]   = { 10, TH_NONE,     AC_NONE,        S_DOGJUMP4 },
    [S_DOGJUMP4]   = { 10, TH_NONE,     AC_NONE,        S_DOGJUMP5 },
    [S_DOGJUMP5]   = { 10, TH_NONE,     AC_NONE,        S_DOGCHASE1 },
    [S_DOGDIE1]    = { 15, TH_NONE,     AC_DEATHSCREAM, S_DOGDIE2 },
    [S_DOGDIE2]    = { 15, TH_NONE,     AC_NONE,        S_DOGDIE3 },
    [S_DOGDIE3]    = { 15, TH_NONE,     AC_NONE,        S_DOGDEAD },
    [S_DOGDEAD]    = { 0,  TH_NONE,     AC_NONE,        S_DOGDEAD },
    /* WL_ACT2.C officer: guard-like, but a faster single shot (6/20/10) + 5 die frames. */
    [S_OFCSTAND]   = { 0,  TH_STAND, AC_NONE,        S_OFCSTAND },
    [S_OFCCHASE1]  = { 10, TH_CHASE, AC_NONE,        S_OFCCHASE1S },
    [S_OFCCHASE1S] = { 3,  TH_NONE,  AC_NONE,        S_OFCCHASE2 },
    [S_OFCCHASE2]  = { 8,  TH_CHASE, AC_NONE,        S_OFCCHASE3 },
    [S_OFCCHASE3]  = { 10, TH_CHASE, AC_NONE,        S_OFCCHASE3S },
    [S_OFCCHASE3S] = { 3,  TH_NONE,  AC_NONE,        S_OFCCHASE4 },
    [S_OFCCHASE4]  = { 8,  TH_CHASE, AC_NONE,        S_OFCCHASE1 },
    [S_OFCSHOOT1]  = { 6,  TH_NONE,  AC_NONE,        S_OFCSHOOT2 },
    [S_OFCSHOOT2]  = { 20, TH_NONE,  AC_SHOOT,       S_OFCSHOOT3 },
    [S_OFCSHOOT3]  = { 10, TH_NONE,  AC_NONE,        S_OFCCHASE1 },
    [S_OFCDIE1]    = { 11, TH_NONE,  AC_DEATHSCREAM, S_OFCDIE2 },
    [S_OFCDIE2]    = { 11, TH_NONE,  AC_NONE,        S_OFCDIE3 },
    [S_OFCDIE3]    = { 11, TH_NONE,  AC_NONE,        S_OFCDIE4 },
    [S_OFCDIE4]    = { 11, TH_NONE,  AC_NONE,        S_OFCDIE5 },
    [S_OFCDIE5]    = { 0,  TH_NONE,  AC_NONE,        S_OFCDIE5 },
    [S_OFCPAIN]    = { 10, TH_NONE,  AC_NONE,        S_OFCCHASE1 },
    [S_OFCPAIN1]   = { 10, TH_NONE,  AC_NONE,        S_OFCCHASE1 },
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
/* cardinal step: dogs use CHECKDIAG (a door blocks them — they can't open one);
 * everyone else uses CHECKSIDE (a door opens and they wait). */
#define CHECKCARD(x, y)                                   \
    {                                                     \
        if (ob->obclass == dogobj) CHECKDIAG(x, y)        \
        else CHECKSIDE(x, y)                              \
    }

/* WL_STATE.C TryWalk (guard path: CHECKSIDE on cardinals, CHECKDIAG on diagonals). */
static int TryWalk(objtype *ob) {
    int       doornum = -1;
    uintptr_t temp;

    switch (ob->dir) {
    case north:     CHECKCARD(ob->tilex, ob->tiley - 1); ob->tiley--; break;
    case northeast:
        CHECKDIAG(ob->tilex + 1, ob->tiley - 1);
        CHECKDIAG(ob->tilex + 1, ob->tiley);
        CHECKDIAG(ob->tilex, ob->tiley - 1);
        ob->tilex++; ob->tiley--; break;
    case east:      CHECKCARD(ob->tilex + 1, ob->tiley); ob->tilex++; break;
    case southeast:
        CHECKDIAG(ob->tilex + 1, ob->tiley + 1);
        CHECKDIAG(ob->tilex + 1, ob->tiley);
        CHECKDIAG(ob->tilex, ob->tiley + 1);
        ob->tilex++; ob->tiley++; break;
    case south:     CHECKCARD(ob->tilex, ob->tiley + 1); ob->tiley++; break;
    case southwest:
        CHECKDIAG(ob->tilex - 1, ob->tiley + 1);
        CHECKDIAG(ob->tilex - 1, ob->tiley);
        CHECKDIAG(ob->tilex, ob->tiley + 1);
        ob->tilex--; ob->tiley++; break;
    case west:      CHECKCARD(ob->tilex - 1, ob->tiley); ob->tilex--; break;
    case northwest:
        CHECKDIAG(ob->tilex - 1, ob->tiley - 1);
        CHECKDIAG(ob->tilex - 1, ob->tiley);
        CHECKDIAG(ob->tilex, ob->tiley - 1);
        ob->tilex--; ob->tiley--; break;
    case nodir:     return 0;
    default:        return 0;
    }

    if (doornum != -1) {            /* a door blocks the path: start it opening */
        OpenDoor(doornum);
        ob->distance = -doornum - 1;
        return 1;
    }
    ob->areanumber = areamap[ob->tilex][ob->tiley]; /* WL_STATE.C: area of the new tile */
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

/* =========================================================================
 * DOORS (WL_ACT1.C). Area connectivity (areaconnect/ConnectAreas) and audio
 * (PlaySoundLocTile) are dropped: the single-area map keeps areabyplayer all-
 * true, so doors still block, slide, gate line-of-sight (CheckLine reads
 * doorposition), auto-close, and open on bump/use — only cross-door sound
 * localization is lost. Door-jamb side marks (|0x40) are render-only.
 * ========================================================================= */

void InitDoorList(void) {
    int i;
    doornum = 0;
    useheld = 0;
    memset(doorposition, 0, sizeof doorposition);
    memset(areaconnect, 0, sizeof areaconnect);
    memset(areabyplayer, 0, sizeof areabyplayer);
    for (i = 0; i < MAXDOORS; i++) doorobjlist[i].action = dr_closed;
}

void SpawnDoor(int tilex, int tiley, int vertical, int lock) {
    doorposition[doornum] = 0;                  /* doors start fully closed */
    doorobjlist[doornum].tilex = tilex;
    doorobjlist[doornum].tiley = tiley;
    doorobjlist[doornum].vertical = vertical;
    doorobjlist[doornum].lock = lock;
    doorobjlist[doornum].action = dr_closed;
    doorobjlist[doornum].ticcount = 0;
    tilemap[tilex][tiley] = doornum | 0x80;     /* a special "door" tile */
    actorat[tilex][tiley] = (void *)(uintptr_t)(doornum | 0x80); /* solid wall */
    /* WL_ACT1.C: give the door tile a side neighbor's area number (*map = *(map-1)) */
    if (vertical) areamap[tilex][tiley] = areamap[tilex - 1][tiley];
    else          areamap[tilex][tiley] = areamap[tilex][tiley - 1];
    doornum++;
}

/* The two areas a door joins — its perpendicular neighbors' area numbers (WL_ACT1.C). */
static void DoorAreas(int door, int *a1, int *a2) {
    int tx = doorobjlist[door].tilex, ty = doorobjlist[door].tiley;
    if (doorobjlist[door].vertical) { *a1 = areamap[tx + 1][ty]; *a2 = areamap[tx - 1][ty]; }
    else                            { *a1 = areamap[tx][ty - 1]; *a2 = areamap[tx][ty + 1]; }
}

void OpenDoor(int door) {
    if (doorobjlist[door].action == dr_open)
        doorobjlist[door].ticcount = 0;         /* reset open time */
    else
        doorobjlist[door].action = dr_opening;  /* start it opening */
}

void CloseDoor(int door) {
    int tilex = doorobjlist[door].tilex;
    int tiley = doorobjlist[door].tiley;

    /* don't close on anything solid / on the player straddling the doorway */
    if (actorat[tilex][tiley]) return;
    if (player->tilex == tilex && player->tiley == tiley) return;
    if (doorobjlist[door].vertical) {
        if (player->tiley == tiley) {
            if (((player->x + MINDIST) >> TILESHIFT) == tilex) return;
            if (((player->x - MINDIST) >> TILESHIFT) == tilex) return;
        }
    } else {
        if (player->tilex == tilex) {
            if (((player->y + MINDIST) >> TILESHIFT) == tiley) return;
            if (((player->y - MINDIST) >> TILESHIFT) == tiley) return;
        }
    }
    /* (adjacent-actor straddle checks via actorat[tilex±1] dropped: no door grid) */

    doorobjlist[door].action = dr_closing;
    actorat[tilex][tiley] = (void *)(uintptr_t)(door | 0x80); /* make solid again */
}

void OperateDoor(int door) {
    int lock = doorobjlist[door].lock;
    if (lock >= dr_lock1 && lock <= dr_lock4) {
        if (!(keys & (1 << (lock - dr_lock1))))
            return;                             /* locked: need the matching key */
    }
    switch (doorobjlist[door].action) {
    case dr_closed:
    case dr_closing:
        OpenDoor(door);
        break;
    case dr_open:
    case dr_opening:
        CloseDoor(door);
        break;
    }
}

static void DoorOpen(int door) {
    if ((doorobjlist[door].ticcount += tics) >= OPENTICS)
        CloseDoor(door);
}

static void DoorOpening(int door) {
    long position = doorposition[door];
    if (!position) {                            /* just starting to open: connect the areas */
        int a1, a2;
        DoorAreas(door, &a1, &a2);
        areaconnect[a1][a2]++;
        areaconnect[a2][a1]++;
        ConnectAreas();
    }
    position += tics << 10;                      /* slide open an adaptive amount */
    if (position >= 0xffff) {
        position = 0xffff;
        doorobjlist[door].ticcount = 0;
        doorobjlist[door].action = dr_open;
        actorat[doorobjlist[door].tilex][doorobjlist[door].tiley] = 0;
    }
    doorposition[door] = position;
}

static void DoorClosing(int door) {
    int  tilex = doorobjlist[door].tilex;
    int  tiley = doorobjlist[door].tiley;
    long position;

    if (((uintptr_t)actorat[tilex][tiley] != (unsigned)(door | 0x80))
        || (player->tilex == tilex && player->tiley == tiley)) {
        OpenDoor(door);                         /* something got inside */
        return;
    }
    position = doorposition[door];
    position -= tics << 10;
    if (position <= 0) {
        int a1, a2;
        position = 0;
        doorobjlist[door].action = dr_closed;
        DoorAreas(door, &a1, &a2);              /* fully closed: disconnect the areas */
        areaconnect[a1][a2]--;
        areaconnect[a2][a1]--;
        ConnectAreas();
        doorobjlist[door].ticcount = 0;         /* normalize: a closed door is all-zero
                                                 * dynamic state (lets the packed state drop
                                                 * it). ticcount is never read while closed
                                                 * (reset again on the next open), so this is
                                                 * determinism-neutral, applied on both sides. */
    }
    doorposition[door] = position;
}

void MoveDoors(void) {
    int door;
    for (door = 0; door < doornum; door++)
        switch (doorobjlist[door].action) {
        case dr_open:    DoorOpen(door); break;
        case dr_opening: DoorOpening(door); break;
        case dr_closing: DoorClosing(door); break;
        }
}

/* Is tile (x,y) occupied by the player or a live actor? Replaces id's actorat grid
 * for the pushwall block-check (a wall can't be pushed into an occupied tile). */
static int ActorOnTile(int x, int y) {
    if (player->tilex == x && player->tiley == y) return 1;
    for (int i = 0; i < numenemies; i++)
        if ((enemies[i].flags & FL_SHOOTABLE) && enemies[i].tilex == x && enemies[i].tiley == y)
            return 1;
    return 0;
}

/* WL_ACT1.C PushWall — start a secret wall sliding toward `dir`, appending a record. The
 * first destination tile must be clear. Re-trigger is prevented by clearing the tile's
 * pushwallat marker (Cmd_Use only calls here when the marker is set) — so several distinct
 * secret walls can each be pushed (E1L1 has 5). id's 0xc0 render marker is dropped — a
 * relocated wall is a plain solid tile (the sim cares only solid-vs-floor; the sub-tile
 * slide visual is client-side). */
static void PushWall(int checkx, int checky, int dir) {
    if (pwall_count >= MAXPWALLS) return;
    int oldtile = tilemap[checkx][checky];
    if (!oldtile) return;
    int nx = checkx + pwdx[dir], ny = checky + pwdy[dir];
    if (ActorOnTile(nx, ny)) return;           /* NOWAY: blocked */
    tilemap[nx][ny] = oldtile;                 /* the wall extends into the destination */
    int i = pwall_count++;
    pw_startx[i] = pw_curx[i] = checkx;
    pw_starty[i] = pw_cury[i] = checky;
    pw_dir[i] = dir;
    pw_oldtile[i] = oldtile;
    pw_state[i] = 1;
    pushwallat[checkx][checky] = 0;            /* clear the P marker (no re-trigger) */
}

/* WL_ACT1.C MovePWalls — advance every active pushwall one tic. Each 128-unit block
 * crossing relocates a wall one tile (the trailing tile becomes floor in the player's
 * area); it stops once pw_state passes 256 (with tics=1 that's a 3-tile slide; id's
 * "two tiles" assumes tics>1) — pw_state 0 then, but the record persists. The mid-slide
 * actor block-check (id aborts) is dropped — scenarios keep the path clear. */
void MovePWalls(void) {
    for (int i = 0; i < pwall_count; i++) {
        if (!pw_state[i]) continue;            /* completed: relocation is permanent */
        int oldblock = pw_state[i] / 128;
        pw_state[i] += 1;                      /* tics = 1 */
        if (pw_state[i] / 128 != oldblock) {
            tilemap[pw_curx[i]][pw_cury[i]] = 0;           /* trailing tile -> floor */
            areamap[pw_curx[i]][pw_cury[i]] = player->areanumber;
            if (pw_state[i] > 256) { pw_state[i] = 0; continue; } /* slide complete */
            pw_curx[i] += pwdx[pw_dir[i]];
            pw_cury[i] += pwdy[pw_dir[i]];
            tilemap[pw_curx[i]][pw_cury[i]] = pw_oldtile[i];   /* leading tile */
            tilemap[pw_curx[i] + pwdx[pw_dir[i]]][pw_cury[i] + pwdy[pw_dir[i]]] = pw_oldtile[i]; /* +1 ahead */
        }
    }
}

/* WL_AGENT.C Cmd_Use — operate the door the player faces (edge-triggered via
 * useheld). Elevator + pushwall paths dropped (no exit/secret in this scope). */
void Cmd_Use(int buttons) {
    int checkx, checky, dir, doortile, elevatorok;

    if (!((buttons >> bt_use) & 1)) { useheld = 0; return; }

    /* elevatorok: only an east/west wall is a usable elevator switch (the switch faces
     * the player along the corridor); north/south facings can't trigger it. */
    if (player->angle < ANGLES / 8 || player->angle > 7 * ANGLES / 8) {
        checkx = player->tilex + 1; checky = player->tiley;     dir = di_east;  elevatorok = 1;
    } else if (player->angle < 3 * ANGLES / 8) {
        checkx = player->tilex;     checky = player->tiley - 1; dir = di_north; elevatorok = 0;
    } else if (player->angle < 5 * ANGLES / 8) {
        checkx = player->tilex - 1; checky = player->tiley;     dir = di_west;  elevatorok = 1;
    } else {
        checkx = player->tilex;     checky = player->tiley + 1; dir = di_south; elevatorok = 0;
    }
    /* pushwall: triggers regardless of the useheld latch (PushWall guards re-entry via
     * pwallstate + the cleared marker), exactly like id checking PUSHABLETILE first. */
    if (pushwallat[checkx][checky]) {
        PushWall(checkx, checky, dir);
        return;
    }
    if (useheld) return;
    doortile = tilemap[checkx][checky];
    /* elevator switch: end the level (WL_AGENT.C Cmd_Use). id flips the tile to the
     * activated switch texture (21->22) and sets playstate = ex_completed; we latch the
     * exit and freeze the sim (the main loop / Engine stop advancing once it's set). */
    if (doortile == ELEVATORTILE && elevatorok) {
        useheld = 1;
        tilemap[checkx][checky]++;   /* flip to the activated switch (render-only) */
        playstate = ex_completed;
        return;
    }
    if (doortile & 0x80) {
        useheld = 1;
        OperateDoor(doortile & ~0x80);
    }
}

/* =========================================================================
 * PICKUPS (WL_AGENT.C GetBonus). Effects are faithful; sounds, treasurecount,
 * lives (GiveExtraMan) and weapon switching are dropped (one weapon, modeled as
 * a fire cooldown — weapon pickups still grant their GiveAmmo(6)). The render-
 * coupled trigger (WL_DRAW.C TransformTile) becomes "player on the item tile",
 * applied identically in the oracle and Solidity.
 * ========================================================================= */

static void HealSelf(int points) { health += points; if (health > 100) health = 100; }
static void GiveAmmo(int n)      { ammo += n; if (ammo > 99) ammo = 99; }
static void GivePoints(long pts) { score += pts; }   /* extra-life thresholds dropped */

/* WL_AGENT.C GiveWeapon — a weapon pickup grants 6 ammo and, if it's better than what
 * you have, becomes the current + best weapon (ownership stays contiguous knife..best).
 * chosenweapon is dropped: the cooldown model switches instantly, so weapon==chosenweapon. */
static void GiveWeapon(int w) {
    GiveAmmo(6);
    if (bestweapon < w) bestweapon = weapon = w;
}

/* Apply one bonus to the player; return 1 if it was consumed (remove it). */
static int GetBonus(statobj_t *check) {
    switch (check->itemnumber) {
    case bo_firstaid:   if (health == 100) return 0; HealSelf(25); break;
    case bo_key1: case bo_key2: case bo_key3: case bo_key4:
        keys |= 1 << (check->itemnumber - bo_key1); break;
    case bo_cross:      GivePoints(100);  break;
    case bo_chalice:    GivePoints(500);  break;
    case bo_bible:      GivePoints(1000); break;
    case bo_crown:      GivePoints(5000); break;
    case bo_clip:       if (ammo == 99) return 0; GiveAmmo(8);  break;
    case bo_clip2:      if (ammo == 99) return 0; GiveAmmo(4);  break;
    case bo_25clip:     if (ammo == 99) return 0; GiveAmmo(25); break;
    case bo_machinegun: GiveWeapon(wp_machinegun); break;
    case bo_chaingun:   GiveWeapon(wp_chaingun);   break;
    case bo_fullheal:   HealSelf(99); GiveAmmo(25); break;
    case bo_food:       if (health == 100) return 0; HealSelf(10); break;
    case bo_alpo:       if (health == 100) return 0; HealSelf(4);  break;
    case bo_gibs:       if (health > 10)   return 0; HealSelf(1);  break;
    default:            return 0;             /* bo_spear / unknown: ignore */
    }
    return 1;
}

void GetBonuses(void) {
    int i;
    for (i = 0; i < numstats; i++) {
        statobj_t *s = &statobjlist[i];
        if (s->taken) continue;
        if (player->tilex == s->tilex && player->tiley == s->tiley)
            if (GetBonus(s)) s->taken = 1;
    }
}

void InitStaticList(void) { numstats = 0; keys = 0; score = 0; }

void SpawnStatic(int tilex, int tiley, int itemnumber) {
    statobj_t *s = &statobjlist[numstats++];
    s->tilex = tilex;
    s->tiley = tiley;
    s->itemnumber = itemnumber;
    s->taken = 0;
}

/* WL_STATE.C CheckLine — straight-line LOS over the tilemap; a door tile blocks
 * unless the ray crosses above its (sliding) leading edge doorposition. */
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

        if (US_RndT() < chance) {
            int shoot = S_GRDSHOOT1;
            if (ob->obclass == ssobj)           shoot = S_SSSHOOT1;
            else if (ob->obclass == officerobj) shoot = S_OFCSHOOT1;
            NewState(ob, shoot);
            return;
        }
        dodge = 1;
    }

    if (ob->dir == nodir) {
        if (dodge) SelectDodgeDir(ob); else SelectChaseDir(ob);
        if (ob->dir == nodir) return;
    }

    move = ob->speed * tics;
    while (move) {
        if (ob->distance < 0) {        /* waiting for a door to open */
            OpenDoor(-ob->distance - 1);
            if (doorobjlist[-ob->distance - 1].action != dr_open) return;
            ob->distance = TILEGLOBAL; /* door is now open, go ahead */
        }
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

/* WL_STATE.C FirstSighting: wake into the class's chase, with the class's speed
 * multiplier (guard 3x, SS 4x, dog 2x), and set the attack flags. */
void FirstSighting(objtype *ob) {
    switch (ob->obclass) {
    case ssobj:      NewState(ob, S_SSCHASE1);  ob->speed *= 4; break;
    case dogobj:     NewState(ob, S_DOGCHASE1); ob->speed *= 2; break;
    case officerobj: NewState(ob, S_OFCCHASE1); ob->speed *= 5; break;
    default:         NewState(ob, S_GRDCHASE1); ob->speed *= 3; break; /* guard */
    }
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
        switch (ob->obclass) {           /* class-specific reaction delay */
        case officerobj: ob->temp2 = 2;                 break; /* constant, no RNG */
        case ssobj:      ob->temp2 = 1 + US_RndT() / 6; break;
        case dogobj:     ob->temp2 = 1 + US_RndT() / 8; break;
        default:         ob->temp2 = 1 + US_RndT() / 4; break; /* guard */
        }
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
    int die = S_GRDDIE1;
    if (ob->obclass == ssobj)           die = S_SSDIE1;
    else if (ob->obclass == dogobj)     die = S_DOGDIE1;
    else if (ob->obclass == officerobj) die = S_OFCDIE1;
    ob->tilex = ob->x >> TILESHIFT;
    ob->tiley = ob->y >> TILESHIFT;
    NewState(ob, die);
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
    if (ob->obclass == dogobj)
        return;                          /* dogs have no pain state (1 HP) */
    if (ob->obclass == ssobj)
        NewState(ob, (ob->hitpoints & 1) ? S_SSPAIN : S_SSPAIN1);
    else if (ob->obclass == officerobj)
        NewState(ob, (ob->hitpoints & 1) ? S_OFCPAIN : S_OFCPAIN1);
    else
        NewState(ob, (ob->hitpoints & 1) ? S_GRDPAIN : S_GRDPAIN1);
}

/* WL_AGENT.C target selection, render-decoupled. The original picks the on-screen
 * target via viewx/FL_VISABLE (render-derived); here the aim is computed from sim state:
 * the closest shootable actor that is in front (depth nx >= MINDIST via the view
 * rotation) within `maxnx`, with a clear line of sight. The screen-pixel `shootdelta`
 * cone is dropped (render-config-specific). GunAttack passes no range cap; KnifeAttack
 * caps at melee reach (KNIFEDIST). */
static objtype *FindShotTarget(long maxnx) {
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
        if (nx < MINDIST || nx > maxnx) continue; /* behind / too close / out of reach */
        if (!CheckLine(e)) continue;              /* line of sight blocked */
        if (nx < bestnx) { bestnx = nx; closest = e; }
    }
    return closest;
}

/* WL_AGENT.C GunAttack — player hitscan. Damage/miss math is faithful (distance +
 * US_RndT); only the render-derived target pick is adapted (see FindShotTarget). */
static void GunAttack(void) {
    objtype *closest = FindShotTarget(0x7fffffffL);
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

/* WL_AGENT.C KnifeAttack — melee: hit the closest in-front actor within KNIFEDIST.
 * Silent (no madenoise) and free (no ammo), unlike the guns. */
static void KnifeAttack(void) {
    objtype *closest = FindShotTarget(KNIFEDIST);
    if (!closest) return;
    DamageActor(closest, US_RndT() >> 4);
}

/* WL_AGENT.C CheckWeaponChange — keys 1-4 (bt_readyknife..bt_readychaingun) select an
 * owned weapon (knife..bestweapon). With no ammo you're locked to the knife. */
static void CheckWeaponChange(int buttons) {
    if (!ammo) return;
    for (int i = wp_knife; i <= bestweapon; i++)
        if (buttons & (1 << (bt_readyknife + i - wp_knife))) { weapon = i; return; }
}

/* Player firing. The Cmd_Fire/T_Attack/attackinfo weapon animation is still modeled as a
 * per-tic cooldown, now PER WEAPON: the knife swings free + silent at melee range; the
 * guns spend a round and alert guards; the machinegun/chaingun fire faster (their lower
 * cooldowns stand in for id's attackframe loop-back). Out of ammo forces the knife
 * (T_Attack case -1). The pistol path is unchanged from the single-weapon model. */
static const int weaponrate[4] = { ATTACKRATE, ATTACKRATE, 8, 4 }; /* knife,pistol,MG,chaingun */
void PlayerAttack(int buttons) {
    CheckWeaponChange(buttons);
    if (attackcount > 0) attackcount--;
    if (!(buttons & 1) || attackcount != 0) return; /* bt_attack held + cooldown ready */
    if (weapon == wp_knife) {
        KnifeAttack();
        attackcount = weaponrate[wp_knife];
    } else if (ammo > 0) {
        ammo--;
        madenoise = 1;          /* firing alerts guards in the area */
        GunAttack();
        attackcount = weaponrate[weapon];
        if (ammo == 0) weapon = wp_knife; /* out of ammo -> knife */
    }
}

/* WL_ACT2.C T_DogChase: melee chase — no LOS, always SelectDodgeDir; when within
 * byte (MINACTORDIST) range it leaps into the bite (s_dogjump1). */
static void T_DogChase(objtype *ob) {
    long move, dx, dy;

    if (ob->dir == nodir) {
        SelectDodgeDir(ob);
        if (ob->dir == nodir) return; /* blocked in */
    }
    move = ob->speed * tics;
    while (move) {
        dx = player->x - ob->x; if (dx < 0) dx = -dx; dx -= move;
        if (dx <= MINACTORDIST) {
            dy = player->y - ob->y; if (dy < 0) dy = -dy; dy -= move;
            if (dy <= MINACTORDIST) { NewState(ob, S_DOGJUMP1); return; }
        }
        if (move < ob->distance) { MoveObj(ob, move); break; }
        ob->x = ((long)ob->tilex << TILESHIFT) + TILEGLOBAL / 2;
        ob->y = ((long)ob->tiley << TILESHIFT) + TILEGLOBAL / 2;
        move -= ob->distance;
        SelectDodgeDir(ob);
        if (ob->dir == nodir) return;
    }
}

/* WL_ACT2.C T_Bite: the dog's melee attack (sound dropped). */
static void T_Bite(objtype *ob) {
    long dx, dy;
    dx = player->x - ob->x; if (dx < 0) dx = -dx; dx -= TILEGLOBAL;
    if (dx <= MINACTORDIST) {
        dy = player->y - ob->y; if (dy < 0) dy = -dy; dy -= TILEGLOBAL;
        if (dy <= MINACTORDIST)
            if (US_RndT() < 180) { TakeDamage(US_RndT() >> 4, ob); return; }
    }
}

static void dispatch_think(int id, objtype *ob) {
    switch (id) {
    case TH_STAND:    T_Stand(ob); break;
    case TH_CHASE:    T_Chase(ob); break;
    case TH_DOGCHASE: T_DogChase(ob); break;
    default: break;
    }
}
static void dispatch_action(int id, objtype *ob) {
    switch (id) {
    case AC_SHOOT: T_Shoot(ob); break;
    case AC_BITE:  T_Bite(ob); break;
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
            else if (blockmap[x][y])
                actorat[x][y] = (void *)(uintptr_t)1; /* blocking static: solid (temp<128) */
    (void)i;
}

/* WL_ACT2.C SpawnStand(which): spawn a dormant guard or SS, standing and facing a
 * cardinal dir (dir*2), at patrol speed. It wakes via T_Stand -> SightPlayer (LOS or
 * noise), not at spawn. `active` stays ac_yes so the headless sim keeps thinking. */
void SpawnEnemy(int which, int tilex, int tiley, int dir) {
    objtype *ob = &enemies[numenemies++];
    memset(ob, 0, sizeof(*ob));

    /* SpawnNewObj(...&s_?stand): tictime 0 => ticcount 0, no RNG */
    ob->ticcount = 0;
    ob->tilex = tilex;
    ob->tiley = tiley;
    ob->x = ((long)tilex << TILESHIFT) + TILEGLOBAL / 2;
    ob->y = ((long)tiley << TILESHIFT) + TILEGLOBAL / 2;
    ob->areanumber = areamap[tilex][tiley];   /* area of the spawn tile */
    actorat[tilex][tiley] = ob;

    ob->dir = (dir & 3) * 2;          /* 4-way 0..3 -> dirtype east/north/west/south */
    ob->speed = SPDPATROL;
    ob->flags = FL_SHOOTABLE;
    ob->temp2 = 0;
    ob->active = ac_yes;
    if (which == en_ss) {
        ob->state = S_SSSTAND;
        ob->obclass = ssobj;
        ob->hitpoints = HP_SS;
    } else if (which == en_dog) {
        ob->state = S_DOGSTAND;
        ob->obclass = dogobj;
        ob->hitpoints = HP_DOG;
        ob->speed = SPDDOG;
    } else if (which == en_officer) {
        ob->state = S_OFCSTAND;
        ob->obclass = officerobj;
        ob->hitpoints = HP_OFFICER;
    } else {
        ob->state = S_GRDSTAND;
        ob->obclass = guardobj;
        ob->hitpoints = HP_GUARD;
    }
}
