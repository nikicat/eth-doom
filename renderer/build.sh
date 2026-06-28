#!/usr/bin/env bash
# Build the wasm wall raycaster (renderer/wolfrender.c) with Emscripten into an ES6
# module the Vite client loads at runtime. Output (gitignored, like the other build
# artifacts): web/public/wolfrender.mjs + web/public/wolfrender.wasm. The client falls
# back to its TS raycaster if these aren't present.
#
# Needs emcc (Emscripten). On Arch it's at /usr/lib/emscripten; we add it to PATH if
# `emcc` isn't already resolvable.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v emcc >/dev/null 2>&1 || export PATH="/usr/lib/emscripten:$PATH"

OUT=web/public
emcc renderer/wolfrender.c -O3 \
    -sMODULARIZE=1 -sEXPORT_ES6=1 -sENVIRONMENT=web \
    -sEXPORTED_FUNCTIONS=_rinit,_render,_fb_ptr,_zb_ptr,_tiles_ptr,_pwoff_ptr,_doorf_ptr,_tex_ptr,_texok_ptr \
    -sEXPORTED_RUNTIME_METHODS=HEAPU8,HEAPF32,HEAP32 \
    -sALLOW_MEMORY_GROWTH=1 \
    -o "$OUT/wolfrender.mjs"

echo "built $OUT/wolfrender.mjs + wolfrender.wasm ($(wc -c < "$OUT/wolfrender.wasm") bytes)"
