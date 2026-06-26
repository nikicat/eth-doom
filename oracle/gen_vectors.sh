#!/usr/bin/env bash
# Regenerate golden vectors from the C sim oracle. These are the differential-test
# ground truth: the Solidity Engine is replayed against them tic-by-tic.
set -euo pipefail
cd "$(dirname "$0")/.."

make -C oracle >/dev/null
ORACLE=oracle/build/sim_oracle

# name : map : spawnx spawny spawndir  (input is vectors/<name>.input.txt)
run() { # <name> <map> <sx> <sy> <dir>
    "$ORACLE" "oracle/maps/$2" "vectors/$1.input.txt" "$3" "$4" "$5" \
        > "vectors/$1.golden.jsonl"
}

run move_basic test_room.txt 8 8 1

echo "regenerated:"
ls -l vectors/*.golden.jsonl
