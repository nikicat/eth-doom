/* wl_wasm.c — the carved Wolf3D sim compiled to a freestanding WebAssembly
 * "reactor" for in-browser CLIENT-SIDE PREDICTION.
 *
 * This is the SAME C that builds `sim_oracle` (the golden-vector ground truth),
 * compiled a second way (clang --target=wasm32). Because that C is differential-
 * proven equal to the Solidity Engine, this module predicts each tick locally and
 * its packed-state output is byte-identical to the chain's `Session.getState()` —
 * so the browser renders instantly and reconciles against the chain by a plain
 * byte compare. (See web/ for the prediction loop; web/scripts for the verifier.)
 *
 * Freestanding constraints (no libc/libm):
 *   - BuildTables() is SKIPPED — its `sin()` is the only libm call, and recomputing
 *     trig risks a 1-ULP divergence from the chain's baked Trig.sol. Instead reset()
 *     loads BAKED_SINTABLE (generated from the SAME `sim_oracle --dump-trig` that
 *     baked Trig.sol), guaranteeing an identical table.
 *   - memset/memcpy/memmove/abs are provided below (tiny, standard).
 *   - `long` is 32-bit on wasm32 (64-bit on the native oracle); the one place that
 *     needs 64 bits, FixedByFrac, already uses int64_t explicitly. The wasm-vs-golden
 *     verifier is the safety net for any other latent width assumption.
 */
#include "wl_sim.h"
#include "trigtable.h" /* generated: static const uint32_t BAKED_SINTABLE[] */

/* --- freestanding libc shims (the sim uses only these) --- */
void *memset(void *d, int c, __SIZE_TYPE__ n) {
    unsigned char *p = d;
    while (n--) *p++ = (unsigned char)c;
    return d;
}
void *memcpy(void *d, const void *s, __SIZE_TYPE__ n) {
    unsigned char *a = d;
    const unsigned char *b = s;
    while (n--) *a++ = *b++;
    return d;
}
void *memmove(void *d, const void *s, __SIZE_TYPE__ n) {
    unsigned char *a = d;
    const unsigned char *b = s;
    if (a < b) while (n--) *a++ = *b++;
    else { a += n; b += n; while (n--) *--a = *--b; }
    return d;
}
int abs(int x) { return x < 0 ? -x : x; }

#define EXPORT __attribute__((visibility("default"), used))

/* Engine-packed state blob (32-byte words). Sized for the largest level we run. */
static unsigned char g_state[32 * 256];

/* --- setup: drive the same spawn sequence as oracle.c (load_map + main) --- */

EXPORT void reset(void) {
    /* bake trig instead of BuildTables() (no libm sin); costable = sintable+90 */
    for (unsigned i = 0; i < sizeof BAKED_SINTABLE / sizeof BAKED_SINTABLE[0]; i++)
        sintable[i] = (fixed)BAKED_SINTABLE[i];
    costable = sintable + ANGLEQUAD;
    /* re-init the player game-state. Natively these are global initializers (fresh
     * per process); in a persistent wasm instance they must be reset each game, or
     * health/ammo leak from the previous one. (keys/score via InitStaticList,
     * useheld via InitDoorList, anglefrac via SpawnPlayer.) */
    health = 100;
    ammo = STARTAMMO;
    attackcount = 0;
    playerdead = 0;
    memset(tilemap, 0, sizeof tilemap);
    InitDoorList();
    InitStaticList();
}

EXPORT void set_wall(int x, int y) { tilemap[x][y] = 1; }
EXPORT void add_door(int x, int y, int vertical, int lock) { SpawnDoor(x, y, vertical, lock); }
EXPORT void add_item(int x, int y, int itemnumber) { SpawnStatic(x, y, itemnumber); }

/* Sugar for the headless verifier: mirror oracle.c load_map()'s char semantics so
 * the verifier can replay the text maps without duplicating the bo_/door mapping. */
EXPORT void setup_tile(int x, int y, int ch) {
    switch (ch) {
        case '#': tilemap[x][y] = 1; break;
        case 'D': SpawnDoor(x, y, 1, dr_normal); break;
        case 'd': SpawnDoor(x, y, 0, dr_normal); break;
        case 'a': SpawnStatic(x, y, bo_clip); break;
        case 'h': SpawnStatic(x, y, bo_firstaid); break;
        case 'k': SpawnStatic(x, y, bo_key1); break;
        case 't': SpawnStatic(x, y, bo_cross); break;
        default: break; /* floor */
    }
}

EXPORT void init_actors(void) {
    InitActors();
    US_InitRndT(0);
}
EXPORT void add_player(int x, int y, int dir) { SpawnPlayer(x, y, dir); }
EXPORT void add_enemy(int which, int x, int y, int dir) { SpawnEnemy(which, x, y, dir); }

/* --- one tick: the exact WL_PLAY.C PlayLoop order from oracle.c --- */
EXPORT void step(int cx, int cy, int btns) {
    controlx = cx;
    controly = cy;
    for (int b = 0; b < NUMBUTTONS; b++) buttonstate[b] = (btns >> b) & 1;
    MoveDoors();
    ControlMovement(player);
    plux = player->x >> UNSIGNEDSHIFT;
    pluy = player->y >> UNSIGNEDSHIFT;
    Cmd_Use(btns);
    madenoise = 0;
    PlayerAttack(btns);
    for (int e = 0; e < numenemies; e++) DoActor(&enemies[e]);
    GetBonuses();
}

/* --- pack: byte-identical to Engine._pack (see contracts/src/Engine.sol) ---
 * Each 256-bit word is stored big-endian (EVM mstore); field at LSB-bit `off`. */
static void put(unsigned char *w, int off, int width, unsigned int val) {
    for (int i = 0; i < width; i++)
        if ((val >> i) & 1u) {
            int bit = off + i;
            w[31 - bit / 8] |= (unsigned char)(1u << (bit % 8));
        }
}

EXPORT int read_state(void) {
    int nd = doornum, ni = numstats, na = numenemies;
    int iw = ni == 0 ? 0 : (ni + 255) / 256;
    int ad = 0;
    for (int i = 0; i < nd; i++)
        if (doorobjlist[i].action != dr_closed) ad++;
    int nwords = 2 + ad + iw + na;
    unsigned char *out = g_state;
    memset(out, 0, 32 * nwords);

    /* header: rndindex@0 | numactors@8 | numactivedoors@16 | numitems@24 */
    put(out, 0, 8, rndindex & 0xff);
    put(out, 8, 8, na & 0xff);
    put(out, 16, 8, ad & 0xff);
    put(out, 24, 16, ni & 0xffff);

    /* player word */
    unsigned char *pw = out + 32;
    put(pw, 0, 32, (unsigned int)player->x);
    put(pw, 32, 32, (unsigned int)player->y);
    put(pw, 64, 16, (unsigned int)player->angle);
    put(pw, 80, 32, (unsigned int)anglefrac);
    put(pw, 112, 8, player->tilex);
    put(pw, 120, 8, player->tiley);
    put(pw, 128, 16, (unsigned int)health);
    put(pw, 144, 16, (unsigned int)ammo);
    put(pw, 160, 16, (unsigned int)attackcount);
    put(pw, 176, 1, useheld & 1);
    put(pw, 184, 8, keys & 0xff);
    put(pw, 192, 32, (unsigned int)score);

    /* active (non-closed) doors, in doornum order, each carrying doornum@48 */
    int slot = 0;
    for (int i = 0; i < nd; i++) {
        if (doorobjlist[i].action == dr_closed) continue;
        unsigned char *dw = out + 32 * (2 + slot);
        put(dw, 0, 8, doorobjlist[i].action & 0xff);
        put(dw, 16, 16, (unsigned int)doorobjlist[i].ticcount);
        put(dw, 32, 16, doorposition[i] & 0xffff);
        put(dw, 48, 8, i & 0xff);
        slot++;
    }

    /* item taken-bitmask words: bit (i%256) of word (i/256) */
    for (int i = 0; i < ni; i++)
        if (statobjlist[i].taken) {
            int j = i % 256;
            unsigned char *iwp = out + 32 * (2 + ad + i / 256);
            iwp[31 - j / 8] |= (unsigned char)(1u << (j % 8));
        }

    /* actor words */
    for (int i = 0; i < na; i++) {
        objtype *a = &enemies[i];
        unsigned char *aw = out + 32 * (2 + ad + iw + i);
        put(aw, 0, 32, (unsigned int)a->x);
        put(aw, 32, 32, (unsigned int)a->y);
        put(aw, 64, 8, a->tilex);
        put(aw, 72, 8, a->tiley);
        put(aw, 80, 8, a->dir & 0xff);
        put(aw, 88, 8, a->state & 0xff);
        put(aw, 96, 16, (unsigned int)a->ticcount);
        put(aw, 112, 32, (unsigned int)a->distance);
        put(aw, 144, 16, (unsigned int)a->hitpoints);
        put(aw, 160, 8, a->flags);
        put(aw, 168, 8, a->obclass);
        put(aw, 176, 32, (unsigned int)a->speed);
        put(aw, 208, 8, a->active);
        put(aw, 216, 16, (unsigned int)a->temp2);
    }
    return 32 * nwords;
}

EXPORT int state_ptr(void) { return (int)(unsigned long)g_state; }
