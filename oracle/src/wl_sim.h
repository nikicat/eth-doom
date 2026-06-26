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

/* Minimal actor; expands for enemy AI in M2. */
typedef struct objstruct {
    fixed    x, y;          /* world position (16.16) */
    int      angle;         /* 0..ANGLES-1 */
    unsigned tilex, tiley;
} objtype;

/* --- globals (defined in wl_sim.c) --- */
/* sintable sized +1: id's BuildTables writes one past [ANGLES+ANGLES/4]; we
 * widen the array so the (harmless) extra write isn't UB. costable = sintable+90. */
extern fixed  sintable[ANGLES + ANGLES / 4 + 1];
extern fixed *costable;

extern int   anglefrac;                 /* persistent sub-degree turn accumulator */
extern long  playerxmove, playerymove;

extern objtype  playerobj;
extern objtype *player;

/* Walls: 1..63 = solid, 0 = passable (plane-0 tile semantics). */
extern unsigned char tilemap[MAPSIZE][MAPSIZE];

extern int controlx, controly;          /* per-tic input (already device-scaled) */
extern int buttonstate[NUMBUTTONS];

/* --- deterministic RNG (ID_US_A.ASM) --- */
extern int rndindex;
void US_InitRndT(int randomize);
int  US_RndT(void);

/* --- API --- */
void  BuildTables(void);                 /* WL_MAIN.C */
fixed FixedByFrac(fixed a, fixed b);     /* WL_DRAW.C asm, portable */
void  SpawnPlayer(int tilex, int tiley, int dir);
void  ControlMovement(objtype *ob);
void  Thrust(int angle, long speed);
void  ClipMove(objtype *ob, long xmove, long ymove);
int   TryMove(objtype *ob);              /* boolean */

#endif /* WL_SIM_H */
