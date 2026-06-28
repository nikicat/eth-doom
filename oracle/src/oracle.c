/* sim_oracle — headless Wolfenstein-3D world simulation (movement subset).
 *
 * Usage:  sim_oracle <map.txt> <input.txt> <spawnx> <spawny> <spawndir>
 *
 *   map.txt    line 1 "W H", then H rows of W chars ('#' = wall, else floor)
 *   input.txt  one tic per line: "controlx controly buttons" ('#' comment / blank ok)
 *
 * Emits JSONL to stdout: one snapshot for tic 0 (post-spawn) then one per input
 * tic. These are the golden vectors the Solidity Engine is diffed against.
 */
#include "wl_sim.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void emit(long tick)
{
    printf("{\"tick\":%ld,\"x\":%ld,\"y\":%ld,\"angle\":%d,"
           "\"tilex\":%u,\"tiley\":%u,\"anglefrac\":%d,\"health\":%d,\"ammo\":%d,\"acount\":%d,"
           "\"weapon\":%d,\"bestweapon\":%d",
           tick, (long)player->x, (long)player->y, player->angle,
           player->tilex, player->tiley, anglefrac, health, ammo, attackcount,
           weapon, bestweapon);
    if (numenemies > 0) {
        printf(",\"rng\":%d,\"guards\":[", rndindex);
        for (int i = 0; i < numenemies; i++) {
            objtype *g = &enemies[i];
            printf("%s{\"x\":%ld,\"y\":%ld,\"dir\":%d,\"st\":%d,\"hp\":%d,\"tc\":%d,\"dist\":%ld,\"cls\":%d}",
                   i ? "," : "", (long)g->x, (long)g->y, g->dir, g->state,
                   g->hitpoints, g->ticcount, (long)g->distance, g->obclass);
        }
        printf("]");
    }
    if (doornum > 0) {
        printf(",\"doors\":[");
        for (int i = 0; i < doornum; i++)
            printf("%s{\"pos\":%u,\"act\":%d,\"tc\":%d}", i ? "," : "",
                   doorposition[i], doorobjlist[i].action, doorobjlist[i].ticcount);
        printf("]");
    }
    if (numstats > 0) {
        printf(",\"items\":[");
        for (int i = 0; i < numstats; i++)
            printf("%s%d", i ? "," : "", statobjlist[i].taken);
        printf("]");
    }
    printf(",\"keys\":%d,\"score\":%ld", keys, score);
    printf("}\n");
}

static void load_map(const char *path)
{
    FILE *f = fopen(path, "r");
    int w, h, x, y;
    char line[256];

    if (!f) { perror(path); exit(1); }
    if (fscanf(f, "%d %d\n", &w, &h) != 2 || w > MAPSIZE || h > MAPSIZE) {
        fprintf(stderr, "bad map header\n"); exit(1);
    }
    InitDoorList();
    InitStaticList();
    for (y = 0; y < h; y++) {
        if (!fgets(line, sizeof line, f)) { fprintf(stderr, "map too short\n"); exit(1); }
        for (x = 0; x < w; x++) {
            char c = line[x];
            tilemap[x][y] = 0;                                 /* floor by default */
            areamap[x][y] = 0;                                 /* area 0 by default */
            blockmap[x][y] = 0;                                /* no blocker by default */
            if (c == '#')      tilemap[x][y] = 1;              /* wall */
            else if (c == 'D') SpawnDoor(x, y, 1, dr_normal);  /* vertical door */
            else if (c == 'd') SpawnDoor(x, y, 0, dr_normal);  /* horizontal door */
            else if (c == 'a') SpawnStatic(x, y, bo_clip);     /* ammo clip */
            else if (c == 'h') SpawnStatic(x, y, bo_firstaid); /* first-aid */
            else if (c == 'k') SpawnStatic(x, y, bo_key1);     /* gold key */
            else if (c == 't') SpawnStatic(x, y, bo_cross);    /* treasure */
            else if (c == 'm') SpawnStatic(x, y, bo_machinegun); /* machine gun pickup */
            else if (c == 'g') SpawnStatic(x, y, bo_chaingun);   /* chaingun pickup */
            else if (c == 'B') blockmap[x][y] = 1;             /* blocking decoration (barrel/table/…) */
            else if (c >= '0' && c <= '9') areamap[x][y] = c - '0'; /* floor, explicit area */
            /* else: floor, area 0 ('.', ' ') */
        }
    }
    fclose(f);
}

int main(int argc, char **argv)
{
    FILE *f;
    char  line[256];
    long  tick = 0;

    /* dump the sin/cos table (450 big-endian uint32) for baking into Trig.sol */
    if (argc == 2 && strcmp(argv[1], "--dump-trig") == 0) {
        BuildTables();
        for (int i = 0; i < 450; i++)
            printf("%08x", (uint32_t)sintable[i]);
        printf("\n");
        return 0;
    }

    /* validate the RNG: print the first N values from a deterministic start */
    if (argc == 3 && strcmp(argv[1], "--dump-rng") == 0) {
        US_InitRndT(0);
        int n = atoi(argv[2]);
        for (int i = 0; i < n; i++)
            printf("%d ", US_RndT());
        printf("\n");
        return 0;
    }

    if (argc < 6 || (argc - 6) % 4 != 0) {
        fprintf(stderr, "usage: %s <map> <input> <spawnx> <spawny> <spawndir> [gx gy gdir gclass]...\n", argv[0]);
        return 1;
    }

    BuildTables();
    load_map(argv[1]);
    InitActors();
    US_InitRndT(0);
    SpawnPlayer(atoi(argv[3]), atoi(argv[4]), atoi(argv[5]));
    for (int g = 6; g + 3 < argc; g += 4) /* gx gy gdir gclass (en_guard=0, en_ss=2) */
        SpawnEnemy(atoi(argv[g + 3]), atoi(argv[g]), atoi(argv[g + 1]), atoi(argv[g + 2]));
    emit(tick); /* tic 0: initial state */

    f = fopen(argv[2], "r");
    if (!f) { perror(argv[2]); return 1; }
    while (fgets(line, sizeof line, f)) {
        int cx, cy, btns;
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '#' || *p == '\n' || *p == '\0') continue;
        if (sscanf(p, "%d %d %d", &cx, &cy, &btns) != 3) continue;

        controlx = cx;
        controly = cy;
        memset(buttonstate, 0, sizeof buttonstate);
        for (int b = 0; b < NUMBUTTONS; b++)
            buttonstate[b] = (btns >> b) & 1;

        /* WL_PLAY.C PlayLoop order: MoveDoors, then the player's T_Player
         * (ControlMovement + Cmd_Use + weapon), then every actor's DoActor. */
        MoveDoors();
        ControlMovement(player);
        plux = player->x >> UNSIGNEDSHIFT;
        pluy = player->y >> UNSIGNEDSHIFT;
        Cmd_Use(btns);
        madenoise = 0;
        PlayerAttack(btns);
        for (int e = 0; e < numenemies; e++)
            DoActor(&enemies[e]);
        GetBonuses();   /* WL_DRAW.C ThreeDRefresh: pick up bonuses on the player tile */
        emit(++tick);
    }
    fclose(f);
    return 0;
}
