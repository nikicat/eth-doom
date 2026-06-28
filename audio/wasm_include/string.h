/* Minimal freestanding shim for the wasm32 OPL build (no libc). memset/memcpy are
 * defined in audio/opl_wasm.c. __SIZE_TYPE__ matches clang's builtin signatures. */
#ifndef WASM_SHIM_STRING_H
#define WASM_SHIM_STRING_H
void *memset(void *, int, __SIZE_TYPE__);
void *memcpy(void *, const void *, __SIZE_TYPE__);
#endif
