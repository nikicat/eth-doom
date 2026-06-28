#!/usr/bin/env bash
# Build wolfrender.c for headless Node — the T3 renderer pixel-match (renderer/
# verify_render.mjs). It's the SAME C as the web build (renderer/build.sh); only the
# Emscripten environment differs (node instead of web), so the bit-exact framebuffer
# the browser blits is reproduced headlessly, hashed, and compared to committed goldens.
#
# Output (gitignored, like the other build artifacts): renderer/build/wolfrender.mjs +
# renderer/build/wolfrender.wasm.
#
# Needs emcc (Emscripten). On Arch it's at /usr/lib/emscripten; we add it to PATH if
# `emcc` isn't already resolvable.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v emcc >/dev/null 2>&1 || export PATH="/usr/lib/emscripten:$PATH"

OUT=renderer/build
mkdir -p "$OUT"
emcc renderer/wolfrender.c -O3 \
    -sMODULARIZE=1 -sEXPORT_ES6=1 -sENVIRONMENT=node \
    -sEXPORTED_FUNCTIONS=_rinit,_render,_fb_ptr,_zb_ptr,_tiles_ptr,_pwoff_ptr,_doorf_ptr,_tex_ptr,_texok_ptr \
    -sEXPORTED_RUNTIME_METHODS=HEAPU8,HEAPF32,HEAP32 \
    -sALLOW_MEMORY_GROWTH=1 \
    -o "$OUT/wolfrender.mjs"

echo "built $OUT/wolfrender.mjs + wolfrender.wasm ($(wc -c < "$OUT/wolfrender.wasm") bytes)"
