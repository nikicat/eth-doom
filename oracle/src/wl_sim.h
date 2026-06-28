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
#define MINSIGHT      0x18000L        /* CheckSight auto-see radius */
#define PLAYERSIZE    MINDIST         /* player half-extent */
#define MINACTORDIST  0x10000L
#define ANGLES        360
#define ANGLEQUAD     (ANGLES / 4)    /* 90 */
#define FINEANGLES    3600
#define PI            3.141592657     /* id's exact value — do not "fix" */
#define MAPSIZE       64

/* --- doors (WL_ACT1.C / WL_DEF.H) --- */
#define MAXDOORS      64              /* a tilemap spot holds doornum in 6 bits */
#define OPENTICS      300             /* DoorOpen auto-close delay */
#define AREATILE      107             /* first floor/area tile (map semantics) */
#define NUMAREAS      37              /* WL_DEF.H: floor tiles AREATILE..AREATILE+36 */
#define ELEVATORTILE  21             /* WL_DEF.H: the elevator (level-exit) switch wall */

/* WL_DEF.H exit_t (subset). Cmd_Use on an elevator switch sets playstate = ex_completed,
 * which in id ends PlayLoop; headless we latch it and freeze the sim (the level is over). */
enum { ex_stillplaying, ex_completed };
enum { dr_open, dr_closed, dr_opening, dr_closing };   /* doorobj_t.action */
enum { dr_normal, dr_lock1, dr_lock2, dr_lock3, dr_lock4, dr_elevator }; /* lock */

/* --- pickups (WL_ACT1.C statics + WL_AGENT.C GetBonus) --- */
#define MAXSTATS 400
/* WL_DEF.H stat_t bonus item numbers (non-bonus dressing/block omitted). */
enum {
    bo_gibs = 3, bo_alpo, bo_firstaid, bo_key1, bo_key2, bo_key3, bo_key4,
    bo_cross, bo_chalice, bo_bible, bo_crown, bo_clip, bo_clip2,
    bo_machinegun, bo_chaingun, bo_food, bo_fullheal, bo_25clip, bo_spear
};

/* --- WL_AGENT.C movement scales --- */
#define MOVESCALE      150L
#define BACKMOVESCALE  100L
#define ANGLESCALE     20

/* buttons (WL_DEF.H enum). bt_strafe affects movement; bt_use operates doors. */
#define bt_attack 0
#define bt_strafe 1
#define bt_run    2
#define bt_use    3
/* weapon-select buttons (WL_DEF.H bt_readyknife..bt_readychaingun) — keys 1-4 */
#define bt_readyknife      4
#define bt_readypistol     5
#define bt_readymachinegun 6
#define bt_readychaingun   7
#define NUMBUTTONS 8

/* WL_DEF.H weapontype. Ownership is contiguous wp_knife..bestweapon (CheckWeaponChange). */
enum { wp_knife, wp_pistol, wp_machinegun, wp_chaingun };

/* WL_DEF.H controldir_t — the cardinal a pushwall slides toward (= the Use direction). */
enum { di_north, di_east, di_south, di_west };

/* --- enemy AI constants (WL_DEF.H / WL_STATE.C) --- */
#define UNSIGNEDSHIFT 8           /* 1/256-tile precision */
#define SPDPATROL     512L        /* guard patrol speed; chase = *3 */
#define MINSIGHT      0x18000L
#define RUNSPEED      6000        /* player thrustspeed for "running" (T_Shoot) */
#define FOCALLENGTH   0x5700L     /* view focal point offset (WL_MAIN.C) */
#define ACTORSIZE     0x4000L     /* TransformActor shape fudge (WL_DRAW.C) */
#define ATTACKRATE    14          /* PoC fire cooldown (replaces the weapon anim) */
#define KNIFEDIST     0x18000L    /* WL_AGENT.C KnifeAttack melee reach (transx) */
#define STARTAMMO     8
/* actor flags */
#define FL_SHOOTABLE   1
#define FL_NEVERMARK   4
#define FL_ATTACKMODE  16
#define FL_FIRSTATTACK 32
#define FL_AMBUSH      64
#define FL_NONMARK     128

/* WL_DEF.H dirtype — order matters (opposite[]/diagonal[][] indexing). */
typedef enum { east, northeast, north, northwest, west, southwest, south, southeast, nodir } dirtype;

/* WL_DEF.H classtype (subset we simulate). obclass = guardobj + enemy_t. */
typedef enum { nothing, playerobj, inertobj, guardobj, officerobj, ssobj, dogobj } classtype;

/* WL_DEF.H enemy_t spawn index (the byte stored per spawn in the Map). */
enum { en_guard, en_officer, en_ss, en_dog };

/* WL_ACT2.C starthitpoints[BABY] — our sim runs at difficulty 0 (guard=25). */
#define HP_GUARD   25
#define HP_SS      100
#define HP_DOG     1
#define HP_OFFICER 50
#define SPDDOG     1500L         /* dogs are faster than SPDPATROL (512) */

/* activetype */
enum { ac_no, ac_yes, ac_allways };

/* think / action dispatch ids (replaces C function pointers) */
enum { TH_NONE, TH_STAND, TH_CHASE, TH_PATH, TH_DOGCHASE };
enum { AC_NONE, AC_SHOOT, AC_DEATHSCREAM, AC_BITE };

/* WL_ACT2.C enemy state graphs, as one flat indexed table (shapenum dropped —
 * render-only). Guard and SS share the think/action functions (T_Chase/T_Shoot/
 * A_DeathScream); only the state transitions + sprites differ (the SS fires a
 * 4-shot burst). The shoot/die/pain target state is chosen by obclass. */
enum {
    S_GRDSTAND,
    S_GRDCHASE1, S_GRDCHASE1S, S_GRDCHASE2, S_GRDCHASE3, S_GRDCHASE3S, S_GRDCHASE4,
    S_GRDSHOOT1, S_GRDSHOOT2, S_GRDSHOOT3,
    S_GRDDIE1, S_GRDDIE2, S_GRDDIE3, S_GRDDIE4,
    S_GRDPAIN, S_GRDPAIN1,
    S_SSSTAND,
    S_SSCHASE1, S_SSCHASE1S, S_SSCHASE2, S_SSCHASE3, S_SSCHASE3S, S_SSCHASE4,
    S_SSSHOOT1, S_SSSHOOT2, S_SSSHOOT3, S_SSSHOOT4, S_SSSHOOT5,
    S_SSSHOOT6, S_SSSHOOT7, S_SSSHOOT8, S_SSSHOOT9,
    S_SSDIE1, S_SSDIE2, S_SSDIE3, S_SSDIE4,
    S_SSPAIN, S_SSPAIN1,
    /* dog: melee-only (T_DogChase, no LOS), jumps to bite at range, 1 HP, no pain.
     * S_DOGSTAND is synthetic — id spawns dogs patrolling, but our headless model
     * spawns every enemy dormant-standing (T_Stand) and wakes it via SightPlayer. */
    S_DOGSTAND,
    S_DOGCHASE1, S_DOGCHASE1S, S_DOGCHASE2, S_DOGCHASE3, S_DOGCHASE3S, S_DOGCHASE4,
    S_DOGJUMP1, S_DOGJUMP2, S_DOGJUMP3, S_DOGJUMP4, S_DOGJUMP5,
    S_DOGDIE1, S_DOGDIE2, S_DOGDIE3, S_DOGDEAD,
    /* officer: like the guard (T_Chase/T_Shoot) but speed x5, 50 HP, constant
     * reaction time, faster single shot, and 5 die frames. */
    S_OFCSTAND,
    S_OFCCHASE1, S_OFCCHASE1S, S_OFCCHASE2, S_OFCCHASE3, S_OFCCHASE3S, S_OFCCHASE4,
    S_OFCSHOOT1, S_OFCSHOOT2, S_OFCSHOOT3,
    S_OFCDIE1, S_OFCDIE2, S_OFCDIE3, S_OFCDIE4, S_OFCDIE5,
    S_OFCPAIN, S_OFCPAIN1,
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
    int      temp2;         /* sight reaction countdown (SightPlayer) */
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
extern int   playstate;                  /* exit_t: ex_stillplaying / ex_completed (elevator) */
extern int   ammo, attackcount;         /* gamestate.ammo; fire cooldown */
extern int   weapon, bestweapon;         /* gamestate.weapon/bestweapon (wp_*) */
/* pushwall (WL_ACT1.C): one secret wall slides at a time. pwallstate 1->384 (3 tiles at
 * tics=1), pwallpos = (pwallstate/2)&63 is the render slide. pwall_active stays set once
 * triggered (the relocation is permanent). pushwallat[][] marks which walls are pushable. */
extern int   pwallstate, pwallx, pwally, pwalldir, pwallpos;
extern int   pwall_active, pwall_startx, pwall_starty, pwall_oldtile;
extern unsigned char pushwallat[MAPSIZE][MAPSIZE];
void MovePWalls(void);
extern int   madenoise;                 /* player fired this tic (alerts guards) */

extern objtype  playerent;
extern objtype *player;

/* Walls: 1..63 = solid, 0 = passable (plane-0 tile semantics). */
extern unsigned char tilemap[MAPSIZE][MAPSIZE];

/* Blocking decorations (WL_ACT1.C statics with the `block` flag — barrels, tables,
 * pillars, lamps…): 1 = a static blocks movement on this floor tile, 0 = clear. id
 * marks these in `actorat`, so they block both the player (TryMove) and enemies
 * (TryWalk/CHECKSIDE) but not sight or bullets (CheckLine reads the tilemap). M6. */
extern unsigned char blockmap[MAPSIZE][MAPSIZE];

/* Per-tile area number (0..NUMAREAS-1), from plane-0 floor codes (tile - AREATILE).
 * Drives sound localization: gunfire alerts only guards in areas reachable from the
 * player's area through OPEN doors (WL_ACT1.C areaconnect/ConnectAreas). */
extern unsigned char areamap[MAPSIZE][MAPSIZE];

extern int controlx, controly;          /* per-tic input (already device-scaled) */
extern int buttonstate[NUMBUTTONS];

/* --- deterministic RNG (ID_US_A.ASM) --- */
extern int rndindex;
void US_InitRndT(int randomize);
int  US_RndT(void);

/* --- doors (wl_actor.c) — WL_ACT1.C doorobj_t (area connectivity dropped: the
 * single-area map keeps areabyplayer all-true, so doors block/slide and gate LOS
 * via CheckLine + doorposition, but sound still crosses them). --- */
typedef struct {
    unsigned char tilex, tiley, vertical, lock;
    int action;        /* dr_open / dr_closed / dr_opening / dr_closing */
    int ticcount;      /* open-time accumulator (DoorOpen) */
} doorobj_t;
extern doorobj_t doorobjlist[MAXDOORS];
extern int       doornum;                  /* number of doors spawned */
extern unsigned  doorposition[MAXDOORS];   /* leading edge 0=closed..0xffff=open */
extern int       useheld;                  /* buttonheld[bt_use] edge latch */

void InitDoorList(void);
void ConnectAreas(void);   /* WL_ACT1.C: flood areabyplayer from the player's area */
void SpawnDoor(int tilex, int tiley, int vertical, int lock);
void OpenDoor(int door);
void CloseDoor(int door);
void OperateDoor(int door);
void MoveDoors(void);
void Cmd_Use(int buttons);

/* --- pickups (wl_actor.c) — bonus statics; FL_BONUS only (dressing/blocking
 * decorations dropped). Pickup is render-coupled in id (WL_DRAW.C TransformTile);
 * the faithful headless equivalent is "player tile == item tile", applied
 * identically on both sides. --- */
typedef struct {
    unsigned char tilex, tiley, itemnumber, taken;
} statobj_t;
extern statobj_t statobjlist[MAXSTATS];
extern int  numstats;
extern int  keys;   /* gamestate.keys bitmask (bo_key1..4 -> bits 0..3) */
extern long score;  /* gamestate.score */

void InitStaticList(void);
void SpawnStatic(int tilex, int tiley, int itemnumber);
void GetBonuses(void);   /* per-tic: pick up any bonus on the player's tile */

/* --- enemy actors (wl_actor.c) --- */
#define MAXENEMIES 64
extern objtype  enemies[MAXENEMIES];
extern int      numenemies;
extern void    *actorat[MAPSIZE][MAPSIZE]; /* walls (tile value <256) or actor ptr */
extern int      tics;                      /* 1 in our 1-input-1-tick model */
extern int      plux, pluy;                /* player 1/256 coords (for CheckLine) */
extern const statedef gstates[NUMSTATES];

void InitActors(void);                     /* clear lists, seed actorat from walls */
void SpawnEnemy(int which, int tilex, int tiley, int dir); /* which = en_guard / en_ss */
void DoActor(objtype *ob);                 /* WL_PLAY.C state-machine advance */
void PlayerAttack(int buttons);            /* fire cooldown + GunAttack hitscan */
int  CheckSight(objtype *ob);              /* WL_STATE.C: FOV + LOS to player */
int  SightPlayer(objtype *ob);             /* WL_STATE.C: react + countdown */
void FirstSighting(objtype *ob);           /* WL_STATE.C: wake guard into chase */

/* --- API --- */
void  BuildTables(void);                 /* WL_MAIN.C */
fixed FixedByFrac(fixed a, fixed b);     /* WL_DRAW.C asm, portable */
void  SpawnPlayer(int tilex, int tiley, int dir);
void  ControlMovement(objtype *ob);
void  Thrust(int angle, long speed);
void  ClipMove(objtype *ob, long xmove, long ymove);
int   TryMove(objtype *ob);              /* boolean */

#endif /* WL_SIM_H */
