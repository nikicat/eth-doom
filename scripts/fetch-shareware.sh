#!/usr/bin/env bash
#
# fetch-shareware.sh — download the freely-distributable Wolfenstein 3D *shareware*
# (episode 1) and turn its art into the PNGs the web client loads.
#
# It downloads a shareware archive, finds the .WL1 data files (VSWAP.WL1 etc.),
# sanity-checks VSWAP, and runs `wl-extract` to produce web/public/wolf/*.png.
#
# Nothing id-owned is committed: the .WL1 files land in assets/wl1/ and the PNGs in
# web/public/wolf/ — both .gitignored. This only fetches data onto *your* machine.
#
# Usage:
#   scripts/fetch-shareware.sh                 # download + extract (default)
#   scripts/fetch-shareware.sh --zip FILE      # use a local shareware .zip you already have
#   scripts/fetch-shareware.sh --url URL       # download from a specific URL
#   scripts/fetch-shareware.sh --no-extract    # only fetch the .WL1 files, don't run wl-extract
#   OUT=path scripts/fetch-shareware.sh        # override where .WL1 files are placed
#
set -euo pipefail

# repo root = parent of this script's dir
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)"

# Candidate sources for the freely-distributable Wolfenstein 3D *shareware*
# (episode 1, ".WL1" data). These auto-download ONLY the shareware — never the
# registered/full game. The script then finds the .WL1 files inside the archive.
# Override with --url if these move; --zip to use an archive you already have.
#
# NOTE: the registered game ships ".WL6" data; that is commercial, NOT free to
# redistribute. If you legitimately own it, point --zip at your own copy — the
# extractor reads VSWAP.WL6 the same way — but this script will not fetch it.
CANDIDATE_URLS=(
  "https://archive.org/download/Wolfenstein3-DVersion1.1Shareware/Wolfenstein3D.zip"
)

OUT="${OUT:-$ROOT/assets/wl1}"
WOLF_OUT="$ROOT/web/public/wolf"
ZIP=""
URL=""
DO_EXTRACT=1

while [ $# -gt 0 ]; do
  case "$1" in
    --zip) ZIP="$2"; shift 2 ;;
    --url) URL="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --no-extract) DO_EXTRACT=0; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

for tool in unzip python3; do
  command -v "$tool" >/dev/null || { echo "error: '$tool' is required" >&2; exit 1; }
done

echo "eth-doom: fetching the freely-distributable Wolfenstein 3D *shareware* (episode 1)."
echo "          .WL1 data and the decoded PNGs are .gitignored — nothing id-owned is committed."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- obtain the archive --------------------------------------------------------
dl="$work/dl.zip"
if [ -n "$ZIP" ]; then
  echo "using local archive: $ZIP"
  cp "$ZIP" "$dl"
else
  command -v curl >/dev/null || { echo "error: 'curl' is required to download (or pass --zip)" >&2; exit 1; }
  urls=("$@"); [ -n "$URL" ] && urls=("$URL") || urls=("${CANDIDATE_URLS[@]}")
  ok=0
  for u in "${urls[@]}"; do
    echo "downloading: $u"
    if curl -fSL --retry 3 --connect-timeout 20 -o "$dl" "$u"; then ok=1; break; fi
    echo "  …failed, trying next source"
  done
  [ "$ok" = 1 ] || { echo "error: could not download the shareware. Pass --url or --zip." >&2; exit 1; }
fi

# must look like a zip ("PK\x03\x04")
if [ "$(head -c2 "$dl" 2>/dev/null)" != "PK" ]; then
  echo "error: downloaded file is not a zip (server error page?). Try --url or --zip." >&2
  exit 1
fi

# --- extract (recursively, in case the WL1 files sit inside a nested zip) -------
mkdir -p "$work/x"
unzip -oq "$dl" -d "$work/x" || true
# decompress any nested zips one level deep
while IFS= read -r z; do unzip -oq "$z" -d "$work/x" 2>/dev/null || true; done \
  < <(find "$work/x" -iname '*.zip')

# find the per-episode data files (.WL1 shareware, or .WL6 if a user pointed --zip
# at their own registered copy). VSWAP is the one we actually need.
mapfile -t data < <(find "$work/x" -iname '*.WL1' -o -iname '*.WL6' | sort)
if [ "${#data[@]}" -eq 0 ]; then
  echo "error: no Wolf3D data files (*.WL1 / *.WL6) in this archive." >&2
  echo "It may use a DOS self-installer (a .SHR/LZH that must be run under DOSBox)." >&2
  echo "Files found:" >&2; find "$work/x" -type f -printf '  %p\n' 2>/dev/null | head -30 >&2
  echo "Install the shareware yourself, then: cargo run -p wl-extract -- --vswap /path/to/VSWAP.WL1 --out web/public/wolf" >&2
  exit 1
fi

mkdir -p "$OUT"
ext=""
for f in "${data[@]}"; do
  base="$(basename "$f" | tr '[:lower:]' '[:upper:]')"
  cp -f "$f" "$OUT/$base"
  [ "${base#VSWAP.}" != "$base" ] && ext="${base#VSWAP.}"
done
echo "placed ${#data[@]} data file(s) -> $OUT"

# --- validate VSWAP header -----------------------------------------------------
vswap="$OUT/VSWAP.${ext:-WL1}"
[ -f "$vswap" ] || { echo "error: no VSWAP.WL1/.WL6 among the extracted files (needed for textures/sprites)." >&2; exit 1; }
python3 - "$vswap" <<'PY'
import os, struct, sys
p = sys.argv[1]
name = os.path.basename(p)
d = open(p, "rb").read()
if len(d) < 6:
    sys.exit(f"{name} too small")
chunks, sprite_start, sound_start = struct.unpack("<HHH", d[:6])
if not (0 < sprite_start <= sound_start <= chunks):
    sys.exit(f"{name} header looks wrong (chunks={chunks} sprite={sprite_start} sound={sound_start})")
print(f"  {name} OK: {len(d):,} bytes, {chunks} chunks "
      f"({sprite_start} walls, {sound_start - sprite_start} sprites)")
PY

# --- run the extractor ---------------------------------------------------------
if [ "$DO_EXTRACT" = 1 ]; then
  if command -v cargo >/dev/null; then
    echo "running wl-extract -> $WOLF_OUT"
    # also pass VGAGRAPH (HUD: status bar, BJ face, digit font) when present
    vga=()
    for f in vgadict vgahead vgagraph; do
      p="$OUT/$(echo "$f" | tr '[:lower:]' '[:upper:]').${ext:-WL1}"
      [ -f "$p" ] && vga+=("--$f" "$p")
    done
    cargo run -q -p wl-extract --manifest-path "$ROOT/rust/Cargo.toml" -- \
      --vswap "$vswap" --out "$WOLF_OUT" ${vga[@]+"${vga[@]}"}
    # decode the first level (E1L1) → web/public/level.json
    mh="$OUT/MAPHEAD.${ext:-WL1}"; gm="$OUT/GAMEMAPS.${ext:-WL1}"
    if [ -f "$mh" ] && [ -f "$gm" ]; then
      cargo run -q -p map-extract --manifest-path "$ROOT/rust/Cargo.toml" -- \
        --maphead "$mh" --gamemaps "$gm" --out "$ROOT/web/public/level.json"
    fi
    echo "done — reload the web client; the HUD should read  art: real id (VSWAP)"
  else
    echo "cargo not found; skipping extraction. Run it yourself:" >&2
    echo "  cargo run -p wl-extract -- --vswap \"$vswap\" --out web/public/wolf" >&2
  fi
else
  echo "next: cargo run -p wl-extract -- --vswap \"$vswap\" --out web/public/wolf"
fi
