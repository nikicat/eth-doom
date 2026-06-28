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
- **The full weapon roster** — knife, pistol, machine gun, chaingun (`weapon`/`bestweapon`, ownership
  contiguous knife..best): keys 1-4 select an owned weapon (`CheckWeaponChange`), the MG/chaingun are
  picked up (`GiveWeapon` → +6 ammo + auto-switch), and each fires differently — the knife is melee
  (`KnifeAttack`), silent, and free; the guns spend a round and alert nearby guards; the MG/chaingun
  fire faster (per-weapon cooldown standing in for id's `attackframe` loop-back); running out of ammo
  forces the knife. The animation state machine stays a cooldown (the M2 deviation, now per-weapon).
- **Pushwalls (secret walls)** — a pushable wall slides when the player **Uses** it (`Cmd_Use` →
  `PushWall`/`MovePWalls`): the wall relocates over time, the tiles it vacates become walkable and join
  the player's area. The `Map` tilemap is immutable (SSTORE2), so the Engine **reconstructs the
  effective tilemap each tick** from a small packed pushwall record — differential-verified bit-for-bit
  against the C oracle (which mutates its tilemap directly) across the whole slide and completion. The
  client + the T3 pixel-match reconstruct the moved wall into `wolfrender`'s tilemap, so the sliding
  wall **renders** (tile-granular — it relocates tile-by-tile; the sub-tile slide is deferred). One
  pushwall per session for now (multi-pushwall is a follow-up).
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
- **An authentic Wolf3D look (M5)** — the first-person view renders **flat-lit** (no distance shading —
  id's VGA renderer has none; N/S faces darken only via the dark texture page) at a native **320×200 /
  4:3 chunky** resolution inside the beveled **play border**, with **real per-class enemy sprites**
  (guard/SS/dog each draw their own VSWAP frame tables; the officer — not an episode-1 enemy — falls
  back to the guard sprite), **decorative scenery** billboards (lamps, plants, tables, ceiling lights —
  73 statics on E1L1, extracted from plane 1 by `map-extract`), and the status bar's **weapon slot**
  showing the real pistol pic above the health-driven BJ face. All render-side — the on-chain sim is
  unchanged.

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
| **M5** authentic Wolf3D look | ✅ | **flat lighting** (no distance shading — N/S faces darkened only by the dark VSWAP page, as id's VGA renderer did); **320×200 / 4:3 chunky framed viewport** (native-res internal buffer + beveled play border); **real per-class enemy sprites + frame tables** (guard/SS/dog each draw their own VSWAP frames via per-`obclass` `ENEMY_FRAMES`; the officer — absent from the episode-1 shareware — falls back to the guard sprite, and loads its own from registered `.WL6`); **decorative scenery** (`map-extract` emits plane-1 statics → the client billboards lamps/plants/tables/ceiling-lights — 73 on E1L1; render-only, off-chain); **HUD weapon slot** (real pistol pic) above the already-animated BJ face + live counters |

### Roadmap (fresh milestone set)

| | status | scope |
|---|---|---|
| **M6** weapons & world completeness | 🟡 | **blocking-decoration collision** (slice 1) ✅; **weapon roster + switching** (slice 2) ✅ — knife/pistol/MG/chaingun: `weapon`/`bestweapon` packed, keys 1-4 select (`CheckWeaponChange`), `GiveWeapon` on MG/chaingun pickup, per-weapon fire (knife melee+silent+free, guns spend ammo, MG/chaingun faster, out-of-ammo→knife), differential-verified (`weapon_switch`); **pushwalls / secret walls** (slice 3) ✅ — `Cmd_Use` slides a pushable wall (`PushWall`/`MovePWalls`); the immutable-Map tilemap is **reconstructed each tick** from a packed pushwall record (the vacated tiles become walkable + join the player's area, the wall relocates), differential-verified across the full slide + completion (`push_secret`), and the sliding wall **renders** (client + T3 reconstruct the moved tilemap for `wolfrender`, tile-granular); one pushwall per session, multi-pushwall + sub-tile slide deferred; next: **elevator + level exit + level→level flow** |
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
**tic-by-tic** (player pose/health/ammo/weapon/bestweapon/keys/score, every guard field, every door's
position/action/ticcount, every item's taken bit, obclass, and the RNG index — over single-guard,
multi-guard, SS, dog, officer, area-localization, blocking-collision, weapon-switching, and
pushwall scenarios). All fourteen scenarios pass.

The **wasm predictor is held to the same bar**: `oracle/verify_wasm.mjs` replays every golden
scenario through `web/public/predict.wasm` and asserts its decoded packed state matches the golden
vectors tic-by-tic (all fourteen pass). So the same carved C is differential-verified compiled
two ways — natively (`sim_oracle`, the ground truth) and to wasm (the browser predictor) — and the
client additionally reconciles each predicted tick against `Session.getState()` live.

## Testing roadmap

Today's bar — the **differential test** (above) + `forge test` (on-chain plumbing: delegation,
ownership, access control) + live browser reconciliation — is strong for the *sim* but leans on
hand-authored scenarios and eyeballed screenshots for the *renderer*. These layers extend it.
**Inputs stay canonical** (the oracle regenerates the snapshots), so demos survive sim changes, and
the small targeted scenarios stay for *diagnosis* — the layers below add coverage, authoring
ergonomics, renderer regression, and oracle fidelity; they don't replace the focused differential.

| | status | scope |
|---|---|---|
| **T1** self-describing scenarios + auto-discovery | ✅ | one `scenarios/<name>.json` per scenario = `{note, map, player spawn, enemy spawns, checkpoints}`; `gen_vectors.sh` (jq) / `harness` (serde) / `verify_wasm.mjs` (JSON) all **auto-discover** `scenarios/*.json` — the config that was triplicated across the three (adding `block_static` meant editing all three, in three orderings — one even had the enemy tuple in a different field order) is now single-sourced with **named** fields. Adding a test = drop `scenarios/<name>.json` + `vectors/<name>.input.txt` and run `gen_vectors.sh`. Goldens regenerate **byte-identical** (zero regression); harness + `verify_wasm` pass 12/12. (Input `.input.txt` is referenced, not inlined, to keep its authored per-phase comments; `checkpoints` defaults `"all"` = every tic, with an explicit tic-list honored for the future T3/T4 renderer frames. `engine-commit` is deferred to T2, where the on-chain immutable `engine` is the natural pin.) |
| **T2** browser demo record → corpus | ⬜ | the client logs its per-tick `cmd()` stream (+ a periodic state hash) to a downloadable demo — playing the game authors tests; grow the corpus from real play. The on-chain `Session` history is itself a replayable demo corpus (immutable `engine` per session ⟹ a past game reproduces bit-for-bit). |
| **T3** renderer pixel-match — WASM framebuffer (bit-exact, headless) | ✅ | `renderer/verify_render.mjs` drives the SAME wall renderer (`wolfrender.c`) headless under Node (`build_headless.sh` → `-sENVIRONMENT=node`), feeding each committed golden vector's pose+doors as the camera (`px=(x/65536)·64`, `pa=angle`, `doorf=act?pos/0xffff:1`), and hashing the 320×160 RGBA framebuffer **+ the depth buffer** per tic — exact compare vs committed `vectors/<name>.render.json`. Procedural art (`npages=0` → the texture-free two-tone fallback) keeps it asset-free + deterministic; pure integer/double math, never flaky. Covers projection (`CalcHeight`), the fisheye fix, the grid-DDA cast, flat lighting, and the door slide. Proven to have teeth (FOV 60→61 fails all 12; revert restores). Texture sampling (the has-art branch) is out of scope — needs committed id art. Goldens regenerate on an intentional renderer **or** sim-trajectory change (same `--write` contract as the differential goldens). |
| **T4** renderer pixel-match — composited `#view` (tolerant, browser) | ⬜ | the 3D viewport only (walls + sprites + gun + scenery) — **rendered frame only; HUD / minimap / `fillText` / fonts out of scope**. Pinned headless Chromium, a **fixed render clock** (`renderView` is clock-parameterized → deterministic gun bob / muzzle / flash, and lets us skip death-overlay text frames), a **subset of stable checkpoint frames**, pixel-diff with a small per-channel tolerance + max-diff-% threshold. Procedural goldens committed; real-VSWAP goldens are local/gitignored (same licensing as the art). |
| **T5** id `DEMO0`–`DEMO3` vs reference (oracle fidelity) | ⬜ | replay id's original recorded demos through the oracle and diff against a per-tick reference dump (e.g. Chocolate-Wolfenstein-3D) — the one check the current differential can't make: it validates the oracle's **carving against real id**, not just Engine-vs-oracle. Gated on M6+ completeness and the documented render-coupled deviations. |

T3/T4 consume T1's demo format (a demo supplies the deterministic per-frame state the renderer
draws); T5 is the fidelity capstone. Tier split for pixel-matching is deliberate: the WASM
framebuffer (T3) is pure math → bit-exact and never flaky; the composited canvas (T4) adds
`drawImage` and must stay tolerant + pinned + cropped to the rendered frame.

## Run it

```
( cd contracts && forge build )           # build artifacts (harness + web import these)
( cd oracle && ./gen_vectors.sh )         # regenerate golden vectors from the C oracle
( cd rust && cargo run -p harness )        # differential + gas, all scenarios
bash oracle/build_wasm.sh                  # build the wasm predictor -> web/public/predict.wasm
node oracle/verify_wasm.mjs                # differential: wasm predictor == golden vectors
bash renderer/build.sh                     # build the wasm wall renderer (Emscripten) -> web/public
bash renderer/build_headless.sh            # build the wall renderer for headless Node (T3)
node renderer/verify_render.mjs            # T3: wall-view framebuffer == committed render goldens
#   (regenerate render goldens after an intentional renderer/sim change: --write)
# live view:
anvil --silent &
( cd web && pnpm install && pnpm dev )      # http://localhost:5173
# deploy the whole stack (Engine + SessionFactory + Map + owned Session) to any chain:
( cd contracts && forge script script/Deploy.s.sol --rpc-url $RPC --private-key $KEY --broadcast )
#   default: a self-contained test room. Real level: prepend MAP_JSON=../web/public/level.json
#   (regenerate it first with `cargo run -p map-extract`, which now also emits *Hex fields).
```

## Next

- **M5 ✅ done** — the authentic Wolf3D look (flat lighting · native 320×200/4:3 framed viewport ·
  real per-class enemy sprites · decorative scenery · HUD weapon slot), all render-side. Next is
  **M6** (weapons & world completeness): the weapon roster + switching, pushwalls, the elevator /
  level-exit / level→level flow, and **blocking-decoration collision** (M5's scenery is render-only
  until M6 gives the blocking statics their collision back).
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
