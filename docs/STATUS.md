# eth-doom — status

A proof-of-concept that runs a faithful **Wolfenstein-3D world simulation as an EVM smart
contract** — the chain as the authoritative, deterministic multiplayer engine (Wolf3D's original
lockstep netcode shape). Rendering stays off-chain. Every ported simulation function is verified
**bit-for-bit against the original id Software C code** via a differential test.

## What runs today

A complete single-guard PvE loop, on the EVM, differential-verified:

- **Player movement** — turn/strafe/forward/back with tile collision (`ControlMovement`/`Thrust`/
  `ClipMove`/`TryMove`).
- **Guard AI** — a guard stands dormant until it **sees the player** (`T_Stand`/`SightPlayer`/
  `CheckSight`: cardinal-facing FOV + `CheckLine` LOS + `MINSIGHT` auto-close) or **hears gunfire**,
  reacts after a short delay (`FirstSighting`), then chases (`T_Chase`, `SelectChaseDir`/
  `SelectDodgeDir`, `MoveObj`, `TryWalk`) — all driven by Wolf3D's deterministic RNG.
- **Two-way combat** — the guard shoots the player (`T_Shoot` → `TakeDamage`, health drops); the
  player fires back (`GunAttack` → `DamageActor` → pain → `KillActor` death), with ammo + a fire
  cooldown.
- **Doors** — sliding doors (`SpawnDoor`/`OperateDoor`/`MoveDoors`/`DoorOpening`/`DoorClosing`): the
  player opens the one they face with **Use** (`Cmd_Use`), a chasing guard opens a door in its path
  (`TryWalk` → `OpenDoor`) and waits for it (`T_Chase`), doors auto-close after `OPENTICS`, block
  movement until fully open, and gate line-of-sight while sliding (`CheckLine` reads `doorposition`).
- **Pickups** — bonus items (`SpawnStatic`/`GetBonus`): walk onto a clip/first-aid/key/treasure to
  take it — ammo/health with id's clamps + "skip if full" guards, treasure → score, keys → the keyring
  (a **gold/silver key unlocks its locked door** in `OperateDoor`). Items vanish as they're consumed.
- **A live first-person browser view** — a TypeScript/viem client that deploys to anvil, drives the
  sim one `submitInput` tx per step, and renders the decoded on-chain state: a raycaster wall view
  (DDA adapted from 3DSage's MIT raycaster), guards as depth-buffered sprite columns, a pistol
  viewmodel + muzzle/damage flashes, a Wolfenstein-style HUD (health/ammo/face + live gas/input),
  and a minimap. WASD/arrows move, Shift strafes, Space fires. No game logic client-side.
- **Authentic id art + the real first level, runtime-loaded** — `scripts/fetch-shareware.sh` downloads
  the freely-distributable Wolf3D shareware and the Rust extractors decode it: `wl-extract` does
  **VSWAP** → wall textures + guard sprites + the player pistol and **VGAGRAPH** (Huffman + VGA-planar)
  → the **HUD** (status bar, BJ face, digit font); `map-extract` does **MAPHEAD/GAMEMAPS** (Carmack +
  RLEW) → **E1L1's real geometry + guard spawns**. The client deploys the real level as the `Map` and
  renders it in first person — per-tile textured walls, billboarded guards (frame by `state`+`dir` via
  `CalcRotate`), the real pistol, Wolf3D's flat floor/ceiling colors, and the authentic status bar with
  the health-driven BJ face — all from on-chain state. **No id art/level is committed**; the client
  falls back to procedural art + a test room when no data is present. Every format/palette/chunk-number
  comes from id's GPL source in `reference/`.

## Milestones

| | status | delivered |
|---|---|---|
| **M0** scaffold + oracle | ✅ | Foundry/Rust/C scaffold; C `sim_oracle` (movement) — the differential ground truth |
| **M1** Solidity movement + gas | ✅ | `Engine`/`Map`/`Session`; movement port; Rust+anvil differential harness; first gas number; state packed into one word |
| **M2a** RNG + actor model | ✅ | deterministic `rndtable`/`US_RndT`; `objtype`/`DoActor` state machine; multi-actor packed state |
| **M2b** guard chase AI | ✅ | chase/dodge/move/LOS, oracle + Solidity, differential PASS |
| **M2c** hitscan combat | ✅ | guard shoots player + player kills guard; pain/death; ammo |
| **M3** world completeness | 🟡 | **real WL1 level (E1L1) via `map-extract`** + multiple guards ✅; **dormant guards + line-of-sight** ✅; **doors** (`OperateDoor`/`MoveDoors`/`Cmd_Use`, guard-opens-door + LOS gating) ✅; **pickups** (`GetBonus`: ammo/health/keys/treasure, keys unlock doors) ✅; other enemy types + actor-vs-actor collision + `SessionFactory` ⬜ |
| **M4** MegaETH + UX | ⬜ | deploy to MegaETH; session-key delegation + auto-signing; WASM Wolf3D-port renderer; client prediction |

## Gas (per `submitInput`, packed state + SSTORE2 map, on anvil)

| scenario | what | min | avg | max |
|---|---|---|---|---|
| `move_basic` | movement only | 60.3k | 65.1k | 80.6k |
| `chase_guard` | guard chases + shoots you (151 tics) | 66.9k | 72.3k | 92.3k |
| `kill_guard` | you fire + kill the guard (81 tics) | 67.1k | 70.0k | 100.4k |
| `door_use` | walk up to a door, Use it, pass through (151 tics) | 71.4k | 77.6k | 118.0k |
| `door_guard` | guard wakes on noise, opens a door, comes through (342 tics) | 74.3k | 81.6k | 108.8k |
| `item_pickup` | grab clip/key/treasure, get shot, heal on a first-aid (151 tics) | 89.7k | 97.0k | 124.2k |

`submitInput` gas is the true per-input cost a player pays — ~65–125k with a live guard + door + items
on the 16×16 test map, a fraction of a cent on a cheap L2. Map data is stored **SSTORE2-style** (a data
contract's bytecode, read each tick with one `EXTCODECOPY`): the tilemap (removing ~128 cold
`SLOAD`s/tick, ~270k on the 64×64 level) and the door/item lists. The dominant remaining cost is the
`Session` rewriting its full packed state every tick (≈3–5k/word: a cold `SLOAD` + a warm `SSTORE` per
32-byte word), so **state size is the gas driver**. Two wins keep it down: doors are **sparse** (only
the non-closed ones get a word — a closed door is the all-zero default the engine reconstructs), and
items pack their taken bits into ~one word. A full idle E1L1 tick (12 guards, 22 doors, 48 items) is
**~324k** (was ~397k before these); each *open* door adds ~5k back. **Next levers:** cap/cull live
actors (corpses linger) and a tighter actor word.

## How it's verified

Per `DESIGN.md`: the C `sim_oracle` (carved from id's source) replays an input vector and emits
per-tick **golden vectors**; the Rust harness deploys the contracts on anvil, replays the same
inputs through `Session.submitInput`, and asserts the decoded state matches the golden vector
**tic-by-tic** (player pose/health/ammo/keys/score, every guard field, every door's
position/action/ticcount, every item's taken bit, and the RNG index). All six scenarios pass.

## Run it

```
( cd contracts && forge build )           # build artifacts (harness + web import these)
( cd oracle && ./gen_vectors.sh )         # regenerate golden vectors from the C oracle
( cd rust && cargo run -p harness )        # differential + gas, all scenarios
# live view:
anvil --silent &
( cd web && pnpm install && pnpm dev )      # http://localhost:5173
```

## Next

- **Gas**: state re-pack ✅ and SSTORE2 map ✅ are done; the remaining levers are per-actor
  packing (re-encoding every actor each tick) and capping live-actor count.
- **M3**: dormant guards + line-of-sight ✅, doors ✅, pickups ✅ (ammo/health/keys/treasure, keys
  unlock doors; differential-verified `item_pickup`); next: other enemy types (dog/SS/officer),
  actor-vs-actor `actorat` collision, `SessionFactory`.
- **Gas**: doors/items now SSTORE2-stored, door state is sparse (closed doors cost nothing) →
  E1L1 ~397k → ~324k. Remaining levers: cull dead actors (corpses linger in the state) + a tighter
  actor word.
- **M4**: MegaETH deploy (plain redeploy), popup-free play via session keys, first-person renderer.
