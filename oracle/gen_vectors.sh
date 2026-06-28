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
"$ORACLE" oracle/maps/test_room.txt vectors/chase_guard.input.txt 8 8 1 12 8 2 0 \
    > vectors/chase_guard.golden.jsonl

# kill: player at (4,8) faces east and fires (the noise wakes the guard); the
# guard at (12,8) approaches and dies.
"$ORACLE" oracle/maps/test_room.txt vectors/kill_guard.input.txt 4 8 1 12 8 2 0 \
    > vectors/kill_guard.golden.jsonl

# door_use: player walks up to the vertical door at (8,8), opens it with Use, and
# slides through (no guard) — exercises Cmd_Use/OperateDoor/MoveDoors + door collision.
run door_use door_room.txt 4 8 1

# door_guard: a guard across the closed door wakes on the player's gunfire (noise),
# chases, bumps the door (TryWalk->OpenDoor), waits for it (T_Chase), then comes through.
"$ORACLE" oracle/maps/door_room.txt vectors/door_guard.input.txt 4 8 1 12 8 2 0 \
    > vectors/door_guard.golden.jsonl

# item_pickup: player walks east over a clip / first-aid / key / treasure while a guard
# shoots — exercises GetBonus (ammo+keys+score, heal after damage, skip-if-full).
"$ORACLE" oracle/maps/item_room.txt vectors/item_pickup.input.txt 2 8 1 13 8 2 0 \
    > vectors/item_pickup.golden.jsonl

# two_guards: two adjacent guards chase the player; the rear can't walk through the
# front (actorat occupancy — actor-vs-actor collision).
"$ORACLE" oracle/maps/test_room.txt vectors/two_guards.input.txt 2 8 1 10 8 2 0 11 8 2 0 \
    > vectors/two_guards.golden.jsonl

# kill_ss: an SS (100 HP, 4-shot burst) instead of a guard — player fires until it dies.
"$ORACLE" oracle/maps/test_room.txt vectors/kill_ss.input.txt 4 8 1 12 8 2 2 \
    > vectors/kill_ss.golden.jsonl

# dog_bite: a dog (1 HP, fast, melee) rushes the player and bites (T_DogChase/T_Bite).
"$ORACLE" oracle/maps/test_room.txt vectors/dog_bite.input.txt 4 8 1 12 8 2 3 \
    > vectors/dog_bite.golden.jsonl

# kill_officer: an officer (50 HP, speed x5, constant reaction) chases, fires, and dies.
"$ORACLE" oracle/maps/test_room.txt vectors/kill_officer.input.txt 4 8 1 12 8 2 1 \
    > vectors/kill_officer.golden.jsonl

# area_sound: a guard at (12,3) in area 1, player in area 0, one door between. Firing with
# the door CLOSED must NOT wake the guard (areas disconnected); opening the door connects
# the areas and the guard then hears the gunfire and wakes (area connectivity).
"$ORACLE" oracle/maps/area_room.txt vectors/area_sound.input.txt 4 8 1 12 3 2 0 \
    > vectors/area_sound.golden.jsonl

# block_static: player walks east into a blocking decoration (barrel at tile (8,8)) and is
# stopped (TryMove); a guard at (12,8) wakes on gunfire, chases west, and must route around
# the same barrel (TryWalk/CHECKSIDE) — exercises blocking-decoration collision (M6).
"$ORACLE" oracle/maps/block_room.txt vectors/block_static.input.txt 4 8 1 12 8 2 0 \
    > vectors/block_static.golden.jsonl

echo "regenerated:"
ls -l vectors/*.golden.jsonl
