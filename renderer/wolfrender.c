/* wolfrender.c — the wall raycaster, compiled to WebAssembly via Emscripten.
 *
 * The first-person wall view is the perf-heavy, math-heavy half of the renderer, so
 * we move it off the JS main thread into wasm. It carries id's WL_DRAW.C rendering
 * math — the perspective height (CalcHeight: height = heightnumerator / depth) and the
 * texture-coordinate selection (HitVertWall/HitHorizWall: texture column from the ray's
 * grid intercept, N/S faces darkened) — paired with a portable grid-DDA ray cast (the
 * part that was hand asm in WL_DR_A.ASM, here the same DDA the TS client used, adapted
 * from 3DSage's MIT raycaster). It fills an RGBA framebuffer the client blits, plus a
 * per-column depth buffer the client reads to occlude sprites. Sprites / gun / HUD stay
 * in TS on top. Fed by the SAME on-chain/predicted sim state as everything else.
 *
 * Layout matches the TS renderer it replaces: "sage units" (1 tile = 64), FOV 60,
 * angle in degrees (east=0, dir=(cos,-sin), screen-y south), 64x64 wall textures.
 */
#include <math.h>
#include <stdlib.h>
#include <emscripten.h>

#define TEXSZ 64       /* wall textures are 64x64 */
#define DOOR_PAGE 98   /* VSWAP door wall texture page */
#define FOV 60.0
#define U 64.0         /* sage tile size */

static int W, H, VW, VH, NPAGES;
static unsigned char *FB;     /* VW*VH*4 RGBA framebuffer */
static float *ZB;             /* VW perpendicular wall distance per column */
static int *TILES;            /* W*H runtime tilemap (1..89 wall, 0x80|n door, 0 floor) */
static float *DOORF;          /* per-door open fraction 0..1 (index = doornum) */
static unsigned char *TEX;    /* NPAGES * 64 * 64 * 4 RGBA, row-major per page */
static unsigned char *TEXOK;  /* NPAGES: 1 if the page has real texture data */

EMSCRIPTEN_KEEPALIVE void rinit(int w, int h, int vw, int vh, int npages) {
    W = w; H = h; VW = vw; VH = vh; NPAGES = npages;
    FB = malloc((size_t)vw * vh * 4);
    ZB = malloc((size_t)vw * sizeof(float));
    TILES = malloc((size_t)w * h * sizeof(int));
    DOORF = calloc(256, sizeof(float));
    TEX = calloc((size_t)npages * TEXSZ * TEXSZ * 4, 1);
    TEXOK = calloc(npages, 1);
}

/* pointers into wasm memory; JS writes tiles/textures once, doorf each frame, and
 * reads FB (blit) + ZB (sprite occlusion) after render(). */
EMSCRIPTEN_KEEPALIVE unsigned char *fb_ptr(void) { return FB; }
EMSCRIPTEN_KEEPALIVE float *zb_ptr(void) { return ZB; }
EMSCRIPTEN_KEEPALIVE int *tiles_ptr(void) { return TILES; }
EMSCRIPTEN_KEEPALIVE float *doorf_ptr(void) { return DOORF; }
EMSCRIPTEN_KEEPALIVE unsigned char *tex_ptr(void) { return TEX; }
EMSCRIPTEN_KEEPALIVE unsigned char *texok_ptr(void) { return TEXOK; }

static int is_wall(int v) { return v && !(v & 0x80); }
static int is_door(int v) { return v & 0x80; }
/* Wolf3D wall texture page: vertical (E/W) face (v-1)*2, horizontal (N/S) face +1. */
static int wallpage(int v, int vertical) { return ((v < 1 ? 1 : v) - 1) * 2 + (vertical ? 0 : 1); }

/* Does the tile at a ray step stop the ray? Walls always; a door's sliding panel
 * covers fraction (1 - open) of the cell face (frac is 0..1 along that face). */
static int ray_blocked(int v, float frac) {
    if (is_wall(v)) return 1;
    if (is_door(v)) return frac < 1.0f - DOORF[v & 0x7f];
    return 0;
}

/* Cast one ray; fill *dist (perp-less raw), *vertical, *tex (0..63), *tile. The DDA
 * mirrors the TS castRay it replaces (3DSage, MIT) so the view is the same shape;
 * texture column follows id's HitVert/HitHorizWall (intercept fraction). Uses DOUBLE
 * precision to match JS's float64: the DDA's -0.0001 cell-boundary nudge is below
 * float32 ULP at E1L1's large (thousands) coordinates, which would land rays in the
 * wrong grid cell and skew walls. */
static void cast_ray(double px, double py, double ra,
                     double *dist, int *vertical, double *tex, int *tile) {
    const double DR = M_PI / 180.0;
    double r = fmod(fmod(ra, 360.0) + 360.0, 360.0);
    double cs = cos(r * DR), sn = sin(r * DR);
    double rx, ry, xo, yo;
    double disV = 1e9, disH = 1e9, vy = py, hx = px;
    int vtile = 1, htile = 1, dof;

    /* vertical grid lines (x = k*U) */
    double Tan = tan(r * DR);
    dof = 0;
    if (cs > 0.001)       { rx = floor(px / U) * U + U;       ry = (px - rx) * Tan + py; xo = U;  yo = -xo * Tan; }
    else if (cs < -0.001) { rx = floor(px / U) * U - 0.0001;  ry = (px - rx) * Tan + py; xo = -U; yo = -xo * Tan; }
    else                  { rx = px; ry = py; dof = 8; xo = yo = 0; }
    while (dof < 8) {
        int mx = (int)floor(rx / U), my = (int)floor(ry / U), mp = my * W + mx;
        double frac = ry / U - floor(ry / U);
        if (mx >= 0 && mx < W && my >= 0 && my < H && ray_blocked(TILES[mp], (float)frac)) {
            dof = 8; disV = cs * (rx - px) - sn * (ry - py); vy = ry; vtile = TILES[mp];
        } else { rx += xo; ry += yo; dof++; }
    }

    /* horizontal grid lines (y = k*U) */
    dof = 0;
    Tan = 1.0 / Tan;
    if (sn > 0.001)       { ry = floor(py / U) * U - 0.0001;  rx = (py - ry) * Tan + px; yo = -U; xo = -yo * Tan; }
    else if (sn < -0.001) { ry = floor(py / U) * U + U;       rx = (py - ry) * Tan + px; yo = U;  xo = -yo * Tan; }
    else                  { rx = px; ry = py; dof = 8; xo = yo = 0; }
    while (dof < 8) {
        int mx = (int)floor(rx / U), my = (int)floor(ry / U), mp = my * W + mx;
        double frac = rx / U - floor(rx / U);
        if (mx >= 0 && mx < W && my >= 0 && my < H && ray_blocked(TILES[mp], (float)frac)) {
            dof = 8; disH = cs * (rx - px) - sn * (ry - py); hx = rx; htile = TILES[mp];
        } else { rx += xo; ry += yo; dof++; }
    }

    if (disV < disH) {
        double t = vy / U;
        *dist = disV; *vertical = 1; *tex = (t - floor(t)) * 64.0; *tile = vtile;
    } else {
        double t = hx / U;
        *dist = disH; *vertical = 0; *tex = (t - floor(t)) * 64.0; *tile = htile;
    }
}

EMSCRIPTEN_KEEPALIVE void render(double px, double py, double pa) {
    const double DR = M_PI / 180.0;
    double PROJ = VW / 2.0 / tan((FOV / 2.0) * DR);

    /* ceiling 0x383838 (top) / floor 0x717171 (bottom) — Wolf3D flat colors */
    for (int y = 0; y < VH; y++) {
        unsigned char g = y < VH / 2 ? 0x38 : 0x71;
        for (int x = 0; x < VW; x++) {
            int o = (y * VW + x) * 4;
            FB[o] = g; FB[o + 1] = g; FB[o + 2] = g; FB[o + 3] = 255;
        }
    }

    for (int c = 0; c < VW; c++) {
        double ra = pa + FOV / 2.0 - ((c + 0.5) / VW) * FOV;
        double dist, texf; int vertical, tile;
        cast_ray(px, py, ra, &dist, &vertical, &texf, &tile);

        double perp = fmax(0.0001, dist * cos((pa - ra) * DR)); /* fisheye fix */
        ZB[c] = (float)perp;
        double lineH = (U / perp) * PROJ;
        if (lineH > VH * 3) lineH = VH * 3;
        double topf = VH / 2.0 - lineH / 2.0;
        double shade = fmax(0.16, fmin(1.0, 1.25 - perp / 760.0));
        double bright = vertical ? shade : fmax(0.1, shade - 0.22); /* darken N/S faces */
        int door = is_door(tile);
        int page = door ? DOOR_PAGE : wallpage(tile, vertical);
        int has = page < NPAGES && TEXOK[page];
        int sx = (int)texf; if (sx < 0) sx = 0; if (sx > 63) sx = 63;

        int y0 = (int)floor(topf), y1 = (int)floor(topf + lineH);
        for (int y = y0; y < y1; y++) {
            if (y < 0 || y >= VH) continue;
            unsigned char r, g, b;
            if (has) {
                int row = (int)(((y - topf) / lineH) * 64.0);
                if (row < 0) row = 0; if (row > 63) row = 63;
                unsigned char *t = &TEX[(((size_t)page * 64 + row) * 64 + sx) * 4];
                r = (unsigned char)(t[0] * bright); g = (unsigned char)(t[1] * bright); b = (unsigned char)(t[2] * bright);
            } else {
                float side = vertical ? 1.0f : 0.74f;
                if (door) { r = (unsigned char)(74 * shade * side); g = (unsigned char)(96 * shade * side); b = (unsigned char)(132 * shade * side); }
                else      { r = (unsigned char)(150 * shade * side); g = (unsigned char)(132 * shade * side); b = (unsigned char)(108 * shade * side); }
            }
            int o = (y * VW + c) * 4;
            FB[o] = r; FB[o + 1] = g; FB[o + 2] = b; FB[o + 3] = 255;
        }
    }
}
