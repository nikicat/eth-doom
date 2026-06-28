#!/usr/bin/env bash
# Build the in-browser OPL2/OPL3 FM synth (audio/opl_wasm.c around Nuked-OPL3) into a
# freestanding WebAssembly module the client uses to play Wolf3D's AdLib SFX + IMF music.
#
# The chip emulator is third-party (nukeykt/Nuked-OPL3, LGPL-2.1) and is NOT committed:
# this script fetches opl3.c/opl3.h into audio/vendor/ (gitignored, like reference/wolf3d),
# then compiles them with our wrapper. Same toolchain as oracle/build_wasm.sh — clang's
# wasm32 backend + wasm-ld + binaryen (wasm-opt). No Emscripten / wasi-sdk needed.
#
# Output (committed, like web/public/wolfrender.wasm + predict.wasm): web/public/opl.wasm
set -euo pipefail
cd "$(dirname "$0")/.."

VENDOR=audio/vendor
BUILD=audio/build
OUT=web/public/opl.wasm
REV="${OPL_REV:-master}" # override to pin a specific Nuked-OPL3 commit/tag
BASE="https://raw.githubusercontent.com/nukeykt/Nuked-OPL3/$REV"
mkdir -p "$VENDOR" "$BUILD" "$(dirname "$OUT")"

# 1. fetch the emulator source (cached; delete audio/vendor to refetch)
for f in opl3.c opl3.h; do
    if [ ! -f "$VENDOR/$f" ]; then
        echo "fetching Nuked-OPL3 $f ($REV)…"
        command -v curl >/dev/null || { echo "error: 'curl' required to fetch Nuked-OPL3" >&2; exit 1; }
        curl -fSL --retry 3 --connect-timeout 20 "$BASE/$f" -o "$VENDOR/$f"
    fi
done

# 2. compile freestanding to a wasm reactor, exporting only the opl_* wrapper API.
#    -mbulk-memory lowers Nuked's memset (chip reset) to memory.fill; --gc-sections drops
#    unused code. -I audio/wasm_include supplies the freestanding libc <stdio/stdlib/string>
#    shims (Nuked only actually calls memset, defined in opl_wasm.c).
clang --target=wasm32 -O2 -ffreestanding -nostdlib -mbulk-memory -fvisibility=hidden \
    -Wl,--no-entry -Wl,--export-dynamic -Wl,--gc-sections \
    -Wl,-z,stack-size=131072 \
    -I audio/wasm_include \
    audio/opl_wasm.c -o "$BUILD/opl.raw.wasm"

# 3. optimize + shrink with binaryen
wasm-opt -O3 --enable-bulk-memory "$BUILD/opl.raw.wasm" -o "$OUT"

echo "built $OUT ($(wc -c < "$OUT") bytes) from Nuked-OPL3@$REV"
