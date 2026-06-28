/* opl_wasm.c — a freestanding WebAssembly wrapper around Nuked-OPL3, the cycle-accurate
 * YM3812/OPL2 (a subset of the OPL3 it emulates) FM synth chip. The browser client uses
 * it to play Wolfenstein 3D's **AdLib sound effects** and **IMF music** (M7), which are
 * just streams of OPL register writes — exactly what id's hardware received.
 *
 * The chip emulator itself is third-party (nukeykt/Nuked-OPL3, LGPL-2.1) and is NOT
 * committed — `audio/build_opl.sh` fetches it into `audio/vendor/` (gitignored, the same
 * pattern as `reference/wolf3d`) and compiles it here into `web/public/opl.wasm`. Only
 * this thin wrapper (our code) lives in the repo.
 *
 * Built like the prediction wasm (clang --target=wasm32, freestanding, no libc/Emscripten):
 * Nuked needs only memset/memcpy, provided below. JS drives it by writing registers
 * (opl_write) and pulling interleaved-stereo int16 frames (opl_generate → opl_buf), at the
 * output sample rate passed to opl_reset (Nuked's built-in resampler handles 49716→rate).
 */
#include <stdint.h>

/* --- freestanding libc shims (Nuked uses only these) --- */
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

#include "vendor/opl3.c" /* fetched by build_opl.sh; not committed */

#define EXPORT __attribute__((visibility("default"), used))

static opl3_chip chip;

/* Render buffer (interleaved L/R int16). JS pulls in chunks of ≤ MAXFRAMES. */
#define MAXFRAMES 4096
static int16_t g_buf[MAXFRAMES * 2];

/* (re)initialise the chip for an output sample rate (e.g. the AudioContext's). */
EXPORT void opl_reset(uint32_t rate) { OPL3_Reset(&chip, rate); }

/* write one OPL register (reg 0x000-0x1ff, val 0-255) — the AdLib/IMF data stream. */
EXPORT void opl_write(uint32_t reg, uint32_t val) {
    OPL3_WriteReg(&chip, (uint16_t)reg, (uint8_t)val);
}

EXPORT int opl_buf(void) { return (int)(unsigned long)g_buf; }
EXPORT int opl_maxframes(void) { return MAXFRAMES; }

/* generate `nframes` stereo frames into g_buf (clamped to MAXFRAMES). */
EXPORT void opl_generate(uint32_t nframes) {
    if (nframes > MAXFRAMES) nframes = MAXFRAMES;
    OPL3_GenerateStream(&chip, g_buf, nframes);
}
