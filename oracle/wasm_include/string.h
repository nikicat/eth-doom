/* Minimal freestanding shim for the wasm32 build (no libc). memset/memcpy/memmove
 * are defined in wl_wasm.c. __SIZE_TYPE__ matches clang's builtin signatures. See
 * oracle/build_wasm.sh. */
#ifndef WASM_SHIM_STRING_H
#define WASM_SHIM_STRING_H
void *memset(void *, int, __SIZE_TYPE__);
void *memcpy(void *, const void *, __SIZE_TYPE__);
void *memmove(void *, const void *, __SIZE_TYPE__);
#endif
