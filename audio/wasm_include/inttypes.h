/* Minimal freestanding shim for the wasm32 OPL build: opl3.h #includes <inttypes.h>
 * (not part of freestanding clang) only for the int types — forward to <stdint.h>. */
#ifndef WASM_SHIM_INTTYPES_H
#define WASM_SHIM_INTTYPES_H
#include <stdint.h>
#endif
