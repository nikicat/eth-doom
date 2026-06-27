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

# chase: a dormant guard at (12,8) faces west (dir 2 -> dirtype west), sees the
# idle player at (8,8) via T_Stand/SightPlayer, then chases.
"$ORACLE" oracle/maps/test_room.txt vectors/chase_guard.input.txt 8 8 1 12 8 2 \
    > vectors/chase_guard.golden.jsonl

# kill: player at (4,8) faces east and fires (the noise wakes the guard); the
# guard at (12,8) approaches and dies.
"$ORACLE" oracle/maps/test_room.txt vectors/kill_guard.input.txt 4 8 1 12 8 2 \
    > vectors/kill_guard.golden.jsonl

# door_use: player walks up to the vertical door at (8,8), opens it with Use, and
# slides through (no guard) — exercises Cmd_Use/OperateDoor/MoveDoors + door collision.
run door_use door_room.txt 4 8 1

# door_guard: a guard across the closed door wakes on the player's gunfire (noise),
# chases, bumps the door (TryWalk->OpenDoor), waits for it (T_Chase), then comes through.
"$ORACLE" oracle/maps/door_room.txt vectors/door_guard.input.txt 4 8 1 12 8 2 \
    > vectors/door_guard.golden.jsonl

# item_pickup: player walks east over a clip / first-aid / key / treasure while a guard
# shoots — exercises GetBonus (ammo+keys+score, heal after damage, skip-if-full).
"$ORACLE" oracle/maps/item_room.txt vectors/item_pickup.input.txt 2 8 1 13 8 2 \
    > vectors/item_pickup.golden.jsonl

echo "regenerated:"
ls -l vectors/*.golden.jsonl
