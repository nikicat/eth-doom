/* Minimal freestanding shim for the wasm32 build (no libc). abs() is defined in
 * wl_wasm.c. See oracle/build_wasm.sh. */
#ifndef WASM_SHIM_STDLIB_H
#define WASM_SHIM_STDLIB_H
#ifndef NULL
#define NULL ((void *)0)
#endif
int abs(int);
#endif
