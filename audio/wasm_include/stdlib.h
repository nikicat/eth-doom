/* Minimal freestanding shim for the wasm32 OPL build (no libc). Nuked references no
 * stdlib symbol in the default build; this only satisfies the #include. */
#ifndef WASM_SHIM_STDLIB_H
#define WASM_SHIM_STDLIB_H
#ifndef NULL
#define NULL ((void *)0)
#endif
#endif
