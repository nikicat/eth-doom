/* Minimal freestanding shim for the wasm32 build (no libm). Only sin() is
 * referenced — by BuildTables(), which the wasm build bypasses (trig is baked) and
 * --gc-sections drops, so this declaration is never linked. See oracle/build_wasm.sh. */
#ifndef WASM_SHIM_MATH_H
#define WASM_SHIM_MATH_H
double sin(double);
#endif
