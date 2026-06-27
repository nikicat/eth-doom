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
- **Doors + area connectivity** — sliding doors (`SpawnDoor`/`OperateDoor`/`MoveDoors`/`DoorOpening`/
  `DoorClosing`): the player opens the one they face with **Use** (`Cmd_Use`), a chasing guard opens a
  door in its path (`TryWalk` → `OpenDoor`) and waits for it (`T_Chase`), doors auto-close after
  `OPENTICS`, block movement until fully open, and gate line-of-sight while sliding (`CheckLine` reads
  `doorposition`). Sound is **localized by id's area graph** (`ConnectAreas`/`areabyplayer`): gunfire
  only alerts guards in the player's area + rooms reachable through OPEN doors — a closed door keeps a
  room's guards asleep, exactly like the original.
- **Pickups** — bonus items (`SpawnStatic`/`GetBonus`): walk onto a clip/first-aid/key/treasure to
  take it — ammo/health with id's clamps + "skip if full" guards, treasure → score, keys → the keyring
  (a **gold/silver key unlocks its locked door** in `OperateDoor`). Items vanish as they're consumed.
- **The full E1 enemy roster** — guard, **SS** (100 HP, 4-shot burst), **officer** (50 HP, speed ×5,
  fast single shot), and the melee **dog** (`T_DogChase`/`T_Bite`: rushes and leaps to bite, 1 HP,
  can't open doors). Guard/SS/officer share `T_Chase`/`T_Shoot`; all four live in one state table with
  obclass-dispatched shoot/die/pain plus class-specific `FirstSighting` (chase state + speed
  ×3/×4/×5/×2) and sight-reaction time. Guards no longer walk through each other (`actorat` occupancy).
- **A live first-person browser view** — a TypeScript/viem client that deploys to anvil, drives the
  sim one `submitInput` tx per step, and renders the decoded on-chain state: a raycaster wall view
  (DDA adapted from 3DSage's MIT raycaster), guards as depth-buffered sprite columns, a pistol
  viewmodel + muzzle/damage flashes, a Wolfenstein-style HUD (health/ammo/face + live gas/input),
  and a minimap. WASD/arrows move, Shift strafes, Space fires. No game logic client-side. The
  client **owns the session and delegates an ephemeral burner key once**, then auto-signs every
  `submitInput` with it — popup-free play, no wallet prompt per tick (the HUD shows `owner → key`).
  It also runs **client-side prediction**: the same carved C sim compiled to WebAssembly
  (`oracle/build_wasm.sh`) advances each tick locally for instant feedback, while the burner submits
  to the chain in the background; the predicted state is reconciled byte-for-byte against
  `Session.getState()` (the HUD shows the live match count) — a continuous in-browser differential.
  The textured **wall view is rendered in WebAssembly** too (`renderer/build.sh`, Emscripten): id's
  `WL_DRAW.C` wall math + a portable ray cast fill an RGBA framebuffer + per-column depth that the
  client blits, with sprites/gun/HUD drawn in TS on top (falls back to the TS raycaster if unbuilt).
  Because prediction takes the chain read off the hot path, the burner submits **fire-and-forget**
  (local nonce + fixed gas, a pipelined in-flight window) and a **parallel reconciler** verifies the
  chain against a small predicted-state history without ever stalling the loop. The world runs on a
  **fixed-timestep loop pinned to a stable 70 tics/s** — Wolf3D's native time base — with anvil
  sustaining ~145 ticks/s of headroom underneath (the live tickrate is shown in the HUD).
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
| **M3** world completeness | ✅ | **real WL1 level (E1L1) via `map-extract`** + multiple guards ✅; **dormant guards + line-of-sight** ✅; **doors** ✅; **pickups** (ammo/health/keys/treasure, keys unlock doors) ✅; **actor-vs-actor collision** ✅; **SS trooper** (4-shot burst, 100 HP) ✅; **dog** (melee, 1 HP) ✅; **officer** (speed ×5, 50 HP) ✅ — full E1 roster; **`SessionFactory`** (many games, one engine/map) ✅ |
| **M4** on-chain UX + client engine | ✅ | **session-key delegation** (owner + `delegate`/`revoke`, time-boxed burner keys, popup-free `submitInput`); **`Deploy.s.sol`** one-command stack deploy (test room or a real level via `MAP_JSON`); **web burner/auto-sign UX**; **client-side prediction** — the carved C sim compiled to wasm (clang `--target=wasm32`) predicts locally, reconciled byte-for-byte vs the chain by a parallel reconciler; **wasm wall renderer** (Emscripten, id's `WL_DRAW.C` math) + the player **death sequence**; **fixed-timestep 70-tics/s** via fire-and-forget pipelined submission; **area connectivity** — faithful sound localization (`ConnectAreas`/`areabyplayer`) |

### Roadmap (fresh milestone set)

| | status | scope |
|---|---|---|
| **M5** authentic Wolf3D look | ⬜ | flat lighting (no distance shading); decorative scenery sprites; real per-class enemy sprites + frame tables; 320×200 / 4:3 chunky view + framed viewport; HUD polish (weapon slot, animated BJ face, counters) |
| **M6** weapons & world completeness | ⬜ | weapon roster + switching (knife/pistol/MG/chaingun); pushwalls (secret walls); elevator + level exit + level→level flow; blocking-decoration collision |
| **M7** audio | ⬜ | digitized SFX (VSWAP) + AdLib/IMF music, client-side, triggered from state deltas |
| **M8** presentation shell | ⬜ | title / menu / "Get Psyched!" / level-intermission tally / episode flow |
| **M9** MegaETH deployment | ⛔ | deploy to MegaETH testnet; fire-and-forget session-key play at ~native rate; end-to-end latency + gas (needs an RPC + funded key) |
| **M10** multiplayer | ⬜ | N-player shared `Session` (players as actors) + join/identity + session keys; chain-as-lockstep tick model (input log + paced advance); PvP/co-op (public-state caveat) |

## Gas (per `submitInput`, packed state + SSTORE2 map, on anvil)

| scenario | what | min | avg | max |
|---|---|---|---|---|
| `move_basic` | movement only | 66.0k | 70.7k | 86.2k |
| `chase_guard` | guard chases + shoots you (151 tics) | 72.6k | 78.0k | 98.1k |
| `kill_guard` | you fire + kill the guard (81 tics) | 72.8k | 75.7k | 106.3k |
| `door_use` | walk up to a door, Use it, pass through (151 tics) | 71.7k | 77.8k | 118.2k |
| `door_guard` | guard wakes on noise, opens a door, comes through (342 tics) | 74.5k | 81.8k | 109.1k |
| `item_pickup` | grab clip/key/treasure, get shot, heal on a first-aid (151 tics) | 82.5k | 90.1k | 117.9k |
| `two_guards` | two guards chase; the rear can't walk through the front (141 tics) | 82.0k | 96.5k | 120.1k |
| `kill_ss` | an SS (100 HP, 4-shot burst) chases, fires, and dies (221 tics) | 70.4k | 77.4k | 106.6k |
| `dog_bite` | a dog (1 HP, fast, melee) rushes the player and leaps to bite (261 tics) | 73.4k | 75.8k | 102.0k |
| `kill_officer` | an officer (50 HP, speed ×5, constant reaction) chases, fires, dies (171 tics) | 71.1k | 80.4k | 107.2k |

`submitInput` gas is the true per-input cost a player pays — ~65–125k with a live guard + door + items
on the 16×16 test map, a fraction of a cent on a cheap L2. Map data is stored **SSTORE2-style** (read
each tick with one `EXTCODECOPY`), doors are **sparse** (only non-closed ones get a state word), and
items pack into a taken-bitmask. The `rust/harness` E1L1 probe splits the real per-tick cost (it calls
`engine.tick` as a view to isolate compute from the `Session` write):

```
E1L1 submitInput  ~248k  =  engine compute ~199k          +  Session/tx overhead ~49k (21k base + state I/O)
                            ├ tilemap 64x64 + trig/rng + codec  ~51k
                            ├ 22 doors + 48 items load/scan      ~62k
                            └ 12-guard AI (CheckLine etc.)       ~86k
```

The **engine compute dominates** (not the `Session` write — that's only ~28k beyond the base tx).
The biggest single lever was the per-tick rebuild of the item/door memory **struct arrays**: items
are now read as raw `Map` bytes + a taken-bitmask (no 48-element struct array, no per-bit pack loops),
which cut a full E1L1 tick **~329k → ~248k (−25%)**. **Next levers:** give doors the same raw-bytes
treatment (the `Door[]` build is most of that 62k), and cap/cull live actors.

## How it's verified

Per `DESIGN.md`: the C `sim_oracle` (carved from id's source) replays an input vector and emits
per-tick **golden vectors**; the Rust harness deploys the contracts on anvil, replays the same
inputs through `Session.submitInput`, and asserts the decoded state matches the golden vector
**tic-by-tic** (player pose/health/ammo/keys/score, every guard field, every door's
position/action/ticcount, every item's taken bit, obclass, and the RNG index — over single-guard,
multi-guard, SS, dog, officer, and area-localization scenarios). All eleven scenarios pass.

The **wasm predictor is held to the same bar**: `oracle/verify_wasm.mjs` replays every golden
scenario through `web/public/predict.wasm` and asserts its decoded packed state matches the golden
vectors tic-by-tic (all eleven pass). So the same carved C is differential-verified compiled
two ways — natively (`sim_oracle`, the ground truth) and to wasm (the browser predictor) — and the
client additionally reconciles each predicted tick against `Session.getState()` live.

## Run it

```
( cd contracts && forge build )           # build artifacts (harness + web import these)
( cd oracle && ./gen_vectors.sh )         # regenerate golden vectors from the C oracle
( cd rust && cargo run -p harness )        # differential + gas, all scenarios
bash oracle/build_wasm.sh                  # build the wasm predictor -> web/public/predict.wasm
node oracle/verify_wasm.mjs                # differential: wasm predictor == golden vectors
bash renderer/build.sh                     # build the wasm wall renderer (Emscripten) -> web/public
# live view:
anvil --silent &
( cd web && pnpm install && pnpm dev )      # http://localhost:5173
# deploy the whole stack (Engine + SessionFactory + Map + owned Session) to any chain:
( cd contracts && forge script script/Deploy.s.sol --rpc-url $RPC --private-key $KEY --broadcast )
#   default: a self-contained test room. Real level: prepend MAP_JSON=../web/public/level.json
#   (regenerate it first with `cargo run -p map-extract`, which now also emits *Hex fields).
```

## Next

- **Gas**: state re-pack ✅ and SSTORE2 map ✅ are done; the remaining levers are per-actor
  packing (re-encoding every actor each tick) and capping live-actor count.
- **M3**: dormant guards + line-of-sight ✅, doors ✅, pickups ✅ (ammo/health/keys/treasure, keys
  unlock doors; differential-verified `item_pickup`), actor-vs-actor collision ✅ (`two_guards`),
  the SS ✅, dog ✅, and officer ✅ — the **full E1 enemy roster**; next: `SessionFactory`. (M3 also
  fixed latent class-specific unfaithfulness — `FirstSighting`, sight-reaction time — caught while
  porting the dog/officer.)
- **M4**: deploy to MegaETH; session-key delegation + auto-signing for popup-free play; WASM renderer.
- **Gas**: doors/items now SSTORE2-stored, door state is sparse (closed doors cost nothing) →
  E1L1 ~397k → ~324k. Remaining levers: cull dead actors (corpses linger in the state) + a tighter
  actor word.
- **M4**: MegaETH deploy (plain redeploy), popup-free play via session keys, first-person renderer.
