/* wl_sim.h — carved Wolfenstein-3D simulation core (movement subset).
 *
 * Constants and function bodies are transliterated 1:1 from id Software's
 * WL_DEF.H / WL_AGENT.C / WL_MAIN.C (see reference/wolf3d/WOLFSRC). This is the
 * differential-test *ground truth*: its output defines correct behaviour, so
 * fidelity to the original — including its quirks — matters more than cleanliness.
 */
#ifndef WL_SIM_H
#define WL_SIM_H

#include <stdint.h>

typedef int32_t fixed; /* 16.16 fixed point (id's `typedef long fixed`) */

/* --- WL_DEF.H --- */
#define GLOBAL1       (1L << 16)      /* 0x10000 */
#define TILEGLOBAL    GLOBAL1         /* world units per tile */
#define TILESHIFT     16L
#define MINDIST       0x5800L         /* 22528 */
#define PLAYERSIZE    MINDIST         /* player half-extent */
#define MINACTORDIST  0x10000L
#define ANGLES        360
#define ANGLEQUAD     (ANGLES / 4)    /* 90 */
#define FINEANGLES    3600
#define PI            3.141592657     /* id's exact value — do not "fix" */
#define MAPSIZE       64

/* --- WL_AGENT.C movement scales --- */
#define MOVESCALE      150L
#define BACKMOVESCALE  100L
#define ANGLESCALE     20

/* buttons (WL_DEF.H enum). Only bt_strafe affects movement. */
#define bt_attack 0
#define bt_strafe 1
#define bt_run    2
#define bt_use    3
#define NUMBUTTONS 8

/* --- enemy AI constants (WL_DEF.H / WL_STATE.C) --- */
#define UNSIGNEDSHIFT 8           /* 1/256-tile precision */
#define SPDPATROL     512L        /* guard patrol speed; chase = *3 */
#define MINSIGHT      0x18000L
#define RUNSPEED      6000        /* player thrustspeed for "running" (T_Shoot) */
#define FOCALLENGTH   0x5700L     /* view focal point offset (WL_MAIN.C) */
#define ACTORSIZE     0x4000L     /* TransformActor shape fudge (WL_DRAW.C) */
#define ATTACKRATE    14          /* PoC fire cooldown (replaces the weapon anim) */
#define STARTAMMO     8
/* actor flags */
#define FL_SHOOTABLE   1
#define FL_NEVERMARK   4
#define FL_ATTACKMODE  16
#define FL_FIRSTATTACK 32
#define FL_NONMARK     128

/* WL_DEF.H dirtype — order matters (opposite[]/diagonal[][] indexing). */
typedef enum { east, northeast, north, northwest, west, southwest, south, southeast, nodir } dirtype;

/* WL_DEF.H classtype (subset we simulate). */
typedef enum { nothing, playerobj, inertobj, guardobj } classtype;

/* activetype */
enum { ac_no, ac_yes, ac_allways };

/* think / action dispatch ids (replaces C function pointers) */
enum { TH_NONE, TH_STAND, TH_CHASE, TH_PATH };
enum { AC_NONE, AC_SHOOT, AC_DEATHSCREAM };

/* WL_ACT2.C guard state graph, as a flat indexed table (shapenum dropped — render-only). */
enum {
    S_GRDSTAND,
    S_GRDCHASE1, S_GRDCHASE1S, S_GRDCHASE2, S_GRDCHASE3, S_GRDCHASE3S, S_GRDCHASE4,
    S_GRDSHOOT1, S_GRDSHOOT2, S_GRDSHOOT3,
    S_GRDDIE1, S_GRDDIE2, S_GRDDIE3, S_GRDDIE4,
    S_GRDPAIN, S_GRDPAIN1,
    NUMSTATES
};

/* WL_DEF.H statetype, minus the render shapenum. */
typedef struct { int tictime; int think; int action; int next; } statedef;

/* WL_DEF.H objtype (sim-relevant fields). Movement uses x,y,angle,tilex,tiley. */
typedef struct objstruct {
    int      active;        /* activetype */
    int      ticcount;
    int      obclass;       /* classtype */
    int      state;         /* index into gstates */
    unsigned char flags;
    long     distance;      /* to next tile, or -doornum-1 */
    int      dir;           /* dirtype */
    fixed    x, y;          /* world position (16.16) */
    unsigned tilex, tiley;
    unsigned char areanumber;
    int      angle;         /* 0..ANGLES-1 (player) */
    int      hitpoints;
    long     speed;
    int      temp1;
} objtype;

/* --- globals (defined in wl_sim.c) --- */
/* sintable sized +1: id's BuildTables writes one past [ANGLES+ANGLES/4]; we
 * widen the array so the (harmless) extra write isn't UB. costable = sintable+90. */
extern fixed  sintable[ANGLES + ANGLES / 4 + 1];
extern fixed *costable;

extern int   anglefrac;                 /* persistent sub-degree turn accumulator */
extern long  playerxmove, playerymove;
extern long  thrustspeed;               /* total player thrust this tic (T_Shoot) */
extern int   health, playerdead;        /* gamestate.health; ex_died flag */
extern int   ammo, attackcount;         /* gamestate.ammo; fire cooldown */

extern objtype  playerent;
extern objtype *player;

/* Walls: 1..63 = solid, 0 = passable (plane-0 tile semantics). */
extern unsigned char tilemap[MAPSIZE][MAPSIZE];

extern int controlx, controly;          /* per-tic input (already device-scaled) */
extern int buttonstate[NUMBUTTONS];

/* --- deterministic RNG (ID_US_A.ASM) --- */
extern int rndindex;
void US_InitRndT(int randomize);
int  US_RndT(void);

/* --- enemy actors (wl_actor.c) --- */
#define MAXENEMIES 64
extern objtype  enemies[MAXENEMIES];
extern int      numenemies;
extern void    *actorat[MAPSIZE][MAPSIZE]; /* walls (tile value <256) or actor ptr */
extern int      tics;                      /* 1 in our 1-input-1-tick model */
extern int      plux, pluy;                /* player 1/256 coords (for CheckLine) */
extern const statedef gstates[NUMSTATES];

void InitActors(void);                     /* clear lists, seed actorat from walls */
void SpawnGuard(int tilex, int tiley, int dir);
void DoActor(objtype *ob);                 /* WL_PLAY.C state-machine advance */
void PlayerAttack(int buttons);            /* fire cooldown + GunAttack hitscan */

/* --- API --- */
void  BuildTables(void);                 /* WL_MAIN.C */
fixed FixedByFrac(fixed a, fixed b);     /* WL_DRAW.C asm, portable */
void  SpawnPlayer(int tilex, int tiley, int dir);
void  ControlMovement(objtype *ob);
void  Thrust(int angle, long speed);
void  ClipMove(objtype *ob, long xmove, long ymove);
int   TryMove(objtype *ob);              /* boolean */

#endif /* WL_SIM_H */
