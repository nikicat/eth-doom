/* Minimal freestanding shim for the wasm32 OPL build. Nuked-OPL3 #includes <stdio.h>
 * but uses no stdio symbol in the default (non-debug, no-stereoext) build. */
#ifndef WASM_SHIM_STDIO_H
#define WASM_SHIM_STDIO_H
#ifndef NULL
#define NULL ((void *)0)
#endif
#endif
