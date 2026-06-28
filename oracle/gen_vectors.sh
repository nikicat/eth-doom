#!/usr/bin/env bash
# Regenerate golden vectors from the C sim oracle. These are the differential-test
# ground truth: the Solidity Engine is replayed against them tic-by-tic.
#
# Scenarios are auto-discovered from scenarios/*.json — the single source of truth
# shared with rust/harness and oracle/verify_wasm.mjs (T1). Add a test by dropping a
# scenarios/<name>.json + vectors/<name>.input.txt and re-running this; no edits here.
set -euo pipefail
cd "$(dirname "$0")/.."

make -C oracle >/dev/null
ORACLE=oracle/build/sim_oracle

# enemy class name -> oracle enum (en_guard=0, en_officer=1, en_ss=2, en_dog=3)
class_num() {
    case "$1" in
        guard) echo 0;; officer) echo 1;; ss) echo 2;; dog) echo 3;;
        *) echo "unknown enemy class: $1" >&2; exit 1;;
    esac
}

shopt -s nullglob
for scen in scenarios/*.json; do
    name=$(basename "$scen" .json)
    map=$(jq -r '.map' "$scen")
    sx=$(jq -r '.player.x' "$scen")
    sy=$(jq -r '.player.y' "$scen")
    sdir=$(jq -r '.player.dir' "$scen")
    input=$(jq -r '.input // empty' "$scen"); input=${input:-$name.input.txt}

    # enemy oracle args, in order: gx gy gdir gclass per enemy
    enemy_args=()
    while read -r cls ex ey edir; do
        [ -z "$cls" ] && continue
        enemy_args+=("$ex" "$ey" "$edir" "$(class_num "$cls")")
    done < <(jq -r '.enemies[]? | "\(.class) \(.x) \(.y) \(.dir)"' "$scen")

    "$ORACLE" "oracle/maps/$map" "vectors/$input" "$sx" "$sy" "$sdir" "${enemy_args[@]}" \
        > "vectors/$name.golden.jsonl"
done

echo "regenerated:"
ls -l vectors/*.golden.jsonl
