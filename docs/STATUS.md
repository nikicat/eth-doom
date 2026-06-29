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
  client + the T3 pixel-match reconstruct the moved walls into `wolfrender`'s tilemap, so the sliding
  walls **render** — and glide **sub-tile** (smoothly, tic-by-tic) via a per-record near-face offset in
  the raycaster (id's `HitVert`/`HitHorizPWall`), not a tile-by-tile jump.
  **Several secret walls can slide at once** — the packed state holds a sparse list of records (like the
  active-door list), and `map-extract` reads the plane-1 `PUSHABLETILE` markers, so **E1L1's 5 real
  secret walls all work** (differential-verified two-pushwall scenario `multi_push`: two walls sliding
  concurrently, one completing while the other is mid-slide).
- **The elevator + level exit** — Using the elevator switch (`ELEVATORTILE`) on an east/west wall ends the
  level (`Cmd_Use` → `playstate = ex_completed`): id's `PlayLoop` would return, so headless the Engine
  **latches an `exit` byte and freezes the sim** — every later input re-packs the world unchanged (the
  Session is terminal), differential-verified bit-for-bit (`level_exit`) across the trigger and the frozen
  tail. Since `map-extract` keeps real wall tile values, **E1L1's actual exit elevator works unchanged**.
  This is a demo (one immutable Map per Session), so instead of loading a floor 2 the **client plays
  Wolf3D's level-complete intermission** when `exit` flips — the elevator doors slide shut over the frozen
  view, then "LEVEL COMPLETED" with the BJ face and the score counting up (render-only, off-chain).
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
- **Authentic Wolf3D audio (M7)** — sound is off-chain, like rendering: the client **diffs consecutive
  decoded states** and plays the matching id sound, **positioned** (stereo pan + distance attenuation)
  relative to the player — a gunshot on the ammo drop, `HALT!`/bark when a guard wakes, enemy fire and
  death screams, door open/close, the pushwall rumble, pickups, take-damage, the player death cry, and
  the level-done jingle. Three faithful sources, all decoded from the user's shareware by `wl-extract`
  (**no id audio committed**): **digitized SFX** (VSWAP PCM → 16-bit WAV @ 7 kHz), **AdLib SFX**
  (`AUDIOT` `AdLibSound` chunks), and **IMF music** (`AUDIOT` music chunks; E1L1 plays "Get Them For
  Greater Justice!"). The AdLib SFX and IMF music are synthesised in the browser by **Nuked-OPL3** —
  the same YM3812 FM chip id drove — compiled freestanding to `web/public/opl.wasm`. id played a
  sound's **digitized** version when present and its **AdLib** version otherwise (`SD_PlaySound`→
  `DigiMap`); the client does the same. Music loops; `M` mutes; the AudioContext starts on the first
  keypress (browser autoplay policy). No on-chain change.

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
| **M6** weapons & world completeness | ✅ | **blocking-decoration collision** (slice 1) ✅; **weapon roster + switching** (slice 2) ✅ — knife/pistol/MG/chaingun: `weapon`/`bestweapon` packed, keys 1-4 select (`CheckWeaponChange`), `GiveWeapon` on MG/chaingun pickup, per-weapon fire (knife melee+silent+free, guns spend ammo, MG/chaingun faster, out-of-ammo→knife), differential-verified (`weapon_switch`); **pushwalls / secret walls** (slice 3) ✅ — `Cmd_Use` slides a pushable wall (`PushWall`/`MovePWalls`); the immutable-Map tilemap is **reconstructed each tick** from a packed pushwall record (the vacated tiles become walkable + join the player's area, the wall relocates), differential-verified across the full slide + completion (`push_secret`), and the sliding wall **renders** (client + T3 reconstruct the moved tilemap for `wolfrender`); **multi-pushwall** ✅ — a sparse list of records (several walls slide at once), `map-extract` reads plane-1 `PUSHABLETILE` so E1L1's 5 real secret walls work, differential-verified (`multi_push`, two concurrent walls); the walls glide **sub-tile** (smooth slide, render-only — a near-face offset in `wolfrender`, id's `HitVert`/`HitHorizPWall`); **elevator + level exit** (slice 4) ✅ — `Cmd_Use` on an `ELEVATORTILE` (east/west wall) latches `exit = ex_completed` and **freezes the sim** (oracle + wasm + Engine short-circuit; the Session is terminal), differential-verified (`level_exit`); E1L1's real exit elevator works for free (`map-extract` keeps wall tile values); the **client plays Wolf3D's level-complete intermission** (doors close → "LEVEL COMPLETED" + BJ + score count-up, render-only). No floor 2 — a demo keeps one immutable Map per Session; `ex_secretlevel` + multi-level flow deferred |
| **M7** audio | ✅ | **digitized SFX** (VSWAP PCM → WAV) + **AdLib SFX** & **IMF music** (AUDIOT/AUDIOHED), all **client-side, triggered from state deltas** — the client diffs consecutive decoded states and plays the matching Wolf3D sound, positioned (stereo pan + distance gain) relative to the player. AdLib SFX + IMF music are synthesised in the browser by **Nuked-OPL3** (the YM3812 id drove) compiled to `web/public/opl.wasm` (`audio/build_opl.sh`, freestanding clang→wasm, source fetched not committed); digitized SFX play when present and AdLib otherwise (id's `DigiMap` behaviour). `wl-extract` decodes all three from the user's shareware (nothing id-owned committed); `audio/verify_opl.mjs` smoke-tests the chip + IMF/AdLib pipelines headlessly. No on-chain change — audio is render-side, like the view |
| **M8** demo shell | ⬜ | a thin **browser-demo onboarding** layer (not Wolf3D title chrome): a **thesis/start card** — "Wolf3D simulated by an EVM contract; the chain is the netcode" + the control list — shown before boot, doubling as the **audio-unlock** gesture the AudioContext already needs; a **restart-session** control (redeploy a fresh `Session` + reset client state, so a death / level-exit isn't a manual page reload); and on-screen **controls help**. **Descoped from the original "presentation shell"** (title / menu / "Get Psyched!" / episode flow): one immutable Map per Session ⟹ nothing to select and no level→level flow, the browser tab is already the title, and the **level-intermission tally already shipped** (M6 slice 4 — the level-complete sequence) |
| **M9** MegaETH deployment | ⛔ | deploy to MegaETH testnet; fire-and-forget session-key play at ~native rate; end-to-end latency + gas (needs an RPC + funded key) |
| **M10** multiplayer | ⬜ | N-player shared `Session` (players as actors) + join/identity + session keys; chain-as-lockstep tick model (input log + paced advance); PvP/co-op (public-state caveat) |

## Gas (per `submitInput`, packed state + SSTORE2 map, on anvil)

| scenario | what | min | avg | max |
|---|---|---|---|---|
| `move_basic` | movement only | 79.6k | 84.6k | 100.1k |
| `chase_guard` | guard chases + shoots you (151 tics) | 86.2k | 91.7k | 112.2k |
| `kill_guard` | you fire + kill the guard (81 tics) | 86.4k | 89.3k | 120.3k |
| `door_use` | walk up to a door, Use it, pass through (151 tics) | 85.7k | 92.3k | 132.4k |
| `door_guard` | guard wakes on noise, opens a door, comes through (342 tics) | 88.1k | 95.6k | 122.7k |
| `item_pickup` | grab clip/key/treasure, get shot, heal on a first-aid (151 tics) | 96.3k | 104.1k | 132.0k |
| `two_guards` | two guards chase; the rear can't walk through the front (141 tics) | 95.6k | 110.4k | 134.5k |
| `kill_ss` | an SS (100 HP, 4-shot burst) chases, fires, and dies (221 tics) | 86.3k | 92.2k | 120.6k |
| `dog_bite` | a dog (1 HP, fast, melee) rushes the player and leaps to bite (261 tics) | 87.0k | 89.6k | 116.1k |
| `kill_officer` | an officer (50 HP, speed ×5, constant reaction) chases, fires, dies (171 tics) | 87.0k | 94.8k | 121.2k |
| `level_exit` | walk into the elevator switch, end the level, sim freezes (41 tics) | 75.1k | 80.1k | 104.9k |
| `multi_push` | push two secret walls; both slide at once (one finishes mid-slide of the other) (431 tics) | 89.4k | 100.9k | 144.5k |

`submitInput` gas is the true per-input cost a player pays — ~75–135k with a live guard + door + items
on the 16×16 test map, a fraction of a cent on a cheap L2 (the level-end **freeze** makes a completed
session's ticks the cheapest of all — it short-circuits before any sim work). Map data is stored
**SSTORE2-style** (read each tick with one `EXTCODECOPY`), doors are **sparse** (only non-closed ones get
a state word), and items pack into a taken-bitmask. The `rust/harness` E1L1 probe splits the real
per-tick cost (it calls `engine.tick` as a view to isolate compute from the `Session` write):

```
E1L1 submitInput  ~275k  =  engine compute ~226k          +  Session/tx overhead ~49k (21k base + state I/O)
                            ├ tilemap 64x64 + trig/rng + codec  ~65k
                            ├ 22 doors + 48 items load/scan      ~62k
                            └ 12-guard AI (CheckLine etc.)       ~99k
```

The **engine compute dominates** (not the `Session` write — that's only ~28k beyond the base tx).
The biggest single lever was the per-tick rebuild of the item/door memory **struct arrays**: items
are now read as raw `Map` bytes + a taken-bitmask (no 48-element struct array, no per-bit pack loops),
which cut a full E1L1 tick **~25%** at the time (~329k → ~248k; the M6 world features — pushwall
reconstruction, area connectivity, the exit/pushwall codec — since brought it to the ~275k above).
**Next levers:** give doors the same raw-bytes treatment (the `Door[]` build is most of that 62k),
and cap/cull live actors.

## How it's verified

Per `DESIGN.md`: the C `sim_oracle` (carved from id's source) replays an input vector and emits
per-tick **golden vectors**; the Rust harness deploys the contracts on anvil, replays the same
inputs through `Session.submitInput`, and asserts the decoded state matches the golden vector
**tic-by-tic** (player pose/health/ammo/weapon/bestweapon/keys/score, every guard field, every door's
position/action/ticcount, every item's taken bit, obclass, the RNG index, the `exit` latch, and every
pushwall record — over single-guard, multi-guard, SS, dog, officer, area-localization, blocking-collision,
weapon-switching, single- and multi-pushwall, and level-exit scenarios). All sixteen scenarios pass.

The **wasm predictor is held to the same bar**: `oracle/verify_wasm.mjs` replays every golden
scenario through `web/public/predict.wasm` and asserts its decoded packed state matches the golden
vectors tic-by-tic (all sixteen pass). So the same carved C is differential-verified compiled
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
| **T1** self-describing scenarios + auto-discovery | ✅ | one `scenarios/<name>.json` per scenario = `{note, map, player spawn, enemy spawns, checkpoints}`; `gen_vectors.sh` (jq) / `harness` (serde) / `verify_wasm.mjs` (JSON) all **auto-discover** `scenarios/*.json` — the config that was triplicated across the three (adding `block_static` meant editing all three, in three orderings — one even had the enemy tuple in a different field order) is now single-sourced with **named** fields. Adding a test = drop `scenarios/<name>.json` + `vectors/<name>.input.txt` and run `gen_vectors.sh`. Goldens regenerate **byte-identical** (zero regression); harness + `verify_wasm` pass 16/16. (Input `.input.txt` is referenced, not inlined, to keep its authored per-phase comments; `checkpoints` defaults `"all"` = every tic, with an explicit tic-list honored for the future T3/T4 renderer frames. `engine-commit` is deferred to T2, where the on-chain immutable `engine` is the natural pin.) |
| **T2** browser demo record → corpus | ⬜ | the client logs its per-tick `cmd()` stream (+ a periodic state hash) to a downloadable demo — playing the game authors tests; grow the corpus from real play. The on-chain `Session` history is itself a replayable demo corpus (immutable `engine` per session ⟹ a past game reproduces bit-for-bit). |
| **T3** renderer pixel-match — WASM framebuffer (bit-exact, headless) | ✅ | `renderer/verify_render.mjs` drives the SAME wall renderer (`wolfrender.c`) headless under Node (`build_headless.sh` → `-sENVIRONMENT=node`), feeding each committed golden vector's pose+doors as the camera (`px=(x/65536)·64`, `pa=angle`, `doorf=act?pos/0xffff:1`), and hashing the 320×160 RGBA framebuffer **+ the depth buffer** per tic — exact compare vs committed `vectors/<name>.render.json`. Procedural art (`npages=0` → the texture-free two-tone fallback) keeps it asset-free + deterministic; pure integer/double math, never flaky. Covers projection (`CalcHeight`), the fisheye fix, the grid-DDA cast, flat lighting, and the door slide. Proven to have teeth (a 1° FOV change fails every scenario; revert restores). Texture sampling (the has-art branch) is out of scope — needs committed id art. Goldens regenerate on an intentional renderer **or** sim-trajectory change (same `--write` contract as the differential goldens). |
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
bash audio/build_opl.sh                     # M7: fetch Nuked-OPL3 + build the OPL synth -> web/public/opl.wasm
node audio/verify_opl.mjs                   # M7: smoke-test the OPL chip + IMF/AdLib pipelines (asset-free)
# authentic id art + sound (optional; nothing id-owned committed):
scripts/fetch-shareware.sh                  # download shareware → walls/sprites/HUD + digi/AdLib/IMF audio + opl.wasm
# live view:
anvil --silent &
( cd web && pnpm install && pnpm dev )      # http://localhost:5173
# deploy the whole stack (Engine + SessionFactory + Map + owned Session) to any chain:
( cd contracts && forge script script/Deploy.s.sol --rpc-url $RPC --private-key $KEY --broadcast )
#   default: a self-contained test room. Real level: prepend MAP_JSON=../web/public/level.json
#   (regenerate it first with `cargo run -p map-extract`, which now also emits *Hex fields).
```

## Next

- **M6 ✅ done** — weapons & world completeness: blocking-decoration collision (slice 1) · weapon roster
  + switching (slice 2) · pushwalls + **multi-pushwall** + the **sub-tile slide** (slice 3 — a sparse list
  of records, `map-extract` reads plane-1 `PUSHABLETILE` so E1L1's 5 secret walls all work, and they glide
  smoothly via a near-face raycaster offset) · **elevator + level exit** (slice 4 — the switch ends the
  level, the sim freezes, and the client plays Wolf3D's level-complete intermission). `ex_secretlevel` /
  actual level→level flow stay out of scope (a demo).
- **M7 ✅ done** — audio: digitized SFX (VSWAP) + AdLib SFX & IMF music (AUDIOT) via a Nuked-OPL3 wasm
  synth, all client-side and triggered from state deltas (positioned pan/gain), digi-preferred with an
  AdLib fallback (id's `DigiMap`). Asset-free headless smoke test (`audio/verify_opl.mjs`). The level→level
  music change is moot here (one Map per Session, by design); per-tic audio fidelity isn't differential-
  tested (it's render-side, off the consensus path — same status as the renderer).
- **M8** (demo shell) — a thin browser-demo onboarding layer: a thesis/start card (what this is +
  controls, doubling as the audio-unlock gesture), a restart-session button (redeploy + reset, so retry
  isn't a page reload), and on-screen controls help. The original "presentation shell" (title / menu /
  "Get Psyched!" / episode flow) is **descoped** — one immutable Map per Session ⟹ no menu/episode flow,
  the browser tab is already the title, and the level-intermission tally already shipped in M6.4.
- **M9** (MegaETH) — blocked on an RPC + funded key: deploy to testnet, fire-and-forget session-key play
  at ~native rate, end-to-end latency + gas.
- **Gas** — state re-pack ✅, SSTORE2 map/doors/items ✅, item raw-bytes ✅. Remaining levers: per-actor
  packing (re-encoding every actor each tick), culling dead actors (corpses linger), and giving doors the
  raw-bytes treatment. The Engine sits ~10 B under EIP-170's 24,576-byte limit (see `foundry.toml`).
