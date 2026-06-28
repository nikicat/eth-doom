# eth-doom — design

## Thesis

Wolfenstein 3D's original multiplayer was **deterministic peer-to-peer lockstep**: every node ran an
identical simulation and exchanged only inputs. That is exactly a blockchain — a Byzantine-fault-
tolerant agreement on an ordered input log, executed by a deterministic VM (the EVM). So the chain
*is* the netcode: it orders inputs and runs the authoritative world simulation; **rendering and audio
stay off-chain**. (On-chain rendering was ruled out early — the per-pixel write floor dominates.)

One input = one tick: `Session.submitInput(cmd)` advances the world exactly one tic.

## Architecture

```
on-chain (Solidity, anvil → MegaETH)     off-chain                         build-time
────────────────────────────────────     ─────────                         ──────────
Engine   stateless sim (the logic)        rust/harness  differential+gas    oracle/  C sim_oracle
Map      immutable level data + guards     web/         TS/viem first-person (ground truth) →
Session  per-game packed world state                    raycaster view       golden vectors
```

### Contract decomposition

- **`Engine`** (stateless) — `tick(bytes state, address map, Cmd) view → bytes`. The deterministic
  transition: decode the world, run movement + every actor's `DoActor`, re-encode. Pure function of
  `(state, map, cmd)`, so it's exactly what the differential test targets. Helper libs: `Fixed`
  (16.16 + `FixedByFrac`), `Trig` (baked sin/cos), `Rng` (baked `rndtable`).
- **`Map`** (immutable) — tilemap (door tiles encoded `doornum|0x80`) + guard spawn list + door list
  (`tilex,tiley,vertical,lock`) + item list (`tilex,tiley,itemnumber`). The tilemap is stored
  **SSTORE2-style** (a data contract's bytecode, read each tick via one `EXTCODECOPY`); guards/doors/
  items are in storage (moving doors/items to SSTORE2 is the next gas lever).
- **`Session`** (stateful) — the single source of truth for a live game: holds the packed world
  state + immutable `engine`/`map` addresses. `engine`/`map` are immutable so a live game's rules can
  never change underneath it. An immutable `owner` may `delegate(sessionKey, expiry)` a time-boxed
  ephemeral burner key (one signature) that then auto-signs every `submitInput` — popup-free play, no
  wallet prompt per tick. `owner == address(0)` is an **open** session (anyone may submit), which the
  differential harness and PoC use (one dev key both deploys and plays).
- **`SessionFactory`** — `createSession(engine, map)` deploys + records a `Session`, so many concurrent
  matches share one engine and one map deployment and clients/indexers discover live games from its
  events. Full deploys, not EIP-1167 clones: a clone can't use `immutable`, so it would read
  `engine`/`map` from storage every `submitInput` (two cold `SLOAD`s/tick) — over a real game's
  thousands of ticks that dwarfs the one-time clone saving, so immutable + full deploy wins overall.

### Packed world state

`Session.state` is `header · player word · one word per door · item-taken bitmask · one word per actor`
(replacing an `abi.encode` blob — ~40% gas cut). Bit layout (LSB first), kept in lockstep across
`Engine.sol`, the harness, and the web decoder:

- **header**: `rndindex:uint8@0 | numactors:uint8@8 | numactivedoors:uint8@16 | numitems:uint16@24 |
  numpushwalls:uint8@40 | exit:uint8@48` (exit_t — 0 still playing, 1 completed; once nonzero the
  Engine freezes, re-packing the world unchanged so further inputs are no-ops)
- **player**: `x:int32@0 | y:int32@32 | angle:uint16@64 | anglefrac:int32@80 | tilex:uint8@112 |
  tiley:uint8@120 | health:int16@128 | ammo:int16@144 | attackcount:int16@160 | useheld:bit@176 |
  keys:uint8@184 | score:uint32@192 | weapon:uint8@224 | bestweapon:uint8@232`
- **door** (sparse — only non-closed doors get a word): `action:uint8@0 | ticcount:int16@16 |
  position:uint16@32 | doornum:uint8@48`. A closed door is the all-zero default the engine
  reconstructs, so on a level of mostly-shut doors the blob carries almost none. Static tilex/tiley/
  vertical/lock come from the `Map`, indexed by doornum = scan order.
- **items**: `ceil(numitems/256)` words; bit *i* = item *i* taken (the static tilex/tiley/itemnumber
  come from the `Map`). The dynamic per-item state is one bit, so the whole list packs into ~one word.
- **actor**: `x:int32@0 | y:int32@32 | tilex:uint8@64 | tiley:uint8@72 | dir:uint8@80 | state:uint8@88
  | ticcount:int16@96 | distance:int32@112 | hitpoints:int16@144 | flags:uint8@160 | obclass:uint8@168
  | speed:int32@176 | active:uint8@208 | temp2:int16@216`
- **pushwalls** (`numpushwalls@40` trailing words after the actors, one per triggered secret wall):
  `startx:uint8@0 | starty:uint8@8 | dir:uint8@16 | pwstate:uint16@24 | tile:uint8@40`. Several walls
  may slide at once (E1L1 has 5); each record persists once triggered (the relocation is permanent).
  The `Map` tilemap is immutable, so the Engine reconstructs the effective tilemap each tick from these.
  (The Engine stores each record as exactly this packed word, so pack/unpack are plain copies.)

## Methodology: faithful transliteration, validated by a C oracle

The hard requirement is **bit-exact determinism** vs original Wolf3D. We make the original C the
oracle so faithfulness is mechanically verified, not hoped for:

1. **`oracle/`** — the simulation subsystem carved from id's source (movement, actor model, AI,
   combat), compiled headless. Its output is correct *by definition*.
2. **golden vectors** — feed a scripted input vector to the oracle; it dumps a per-tick snapshot
   (player pose/health/ammo, every actor's pos/dir/state/hp/ticcount, the RNG index). Committed to
   `vectors/`.
3. **Solidity port** — the same functions transliterated 1:1 (names, constants, control flow).
4. **`rust/harness`** — deploys `Map`/`Engine`/`Session` on an in-process **anvil**, replays the
   input vector through `Session.submitInput`, and asserts the decoded state == the golden vector
   **tic-by-tic**, recording `submitInput` gas. (Anvil runs on revm; the plan's pure-revm "no node"
   path is a later optimization.)

Determinism mechanics, all faithful: **fixed-point only** (`FixedByFrac`, sign-magnitude, rounds
toward zero — matches id's asm); a **baked sin/cos table** generated from the oracle (mirrors id's
float truncation, so `cos[0]==0xFFFF`); the **deterministic `rndtable`** (`US_RndT` advances a
wrapping index). The EVM provides cross-node determinism for free.

## The sim ↔ render boundary (faithfulness adaptations)

Wolf3D was one program; we split simulation (on-chain, consensus) from rendering (off-chain). A few
behaviours were *render-coupled* in the original and had to be reconstructed from sim state. These
are applied **identically in the oracle and Solidity**, so the differential test still holds — they
are deviations from id's *render-coupled* code, not between our two implementations.

- **`FL_VISABLE` is always false.** It's set by the renderer when an actor is drawn. In a headless
  consensus sim there is no renderer, so it's false on both sides — only the non-visible branches of
  `T_Shoot`'s hit-chance apply.
- **Player aim (`GunAttack`).** The original targets whatever is centered on screen (`viewx`,
  `FL_VISABLE`). We instead pick the closest shootable actor that is **in front** (depth `nx ≥ MINDIST`
  via the same view rotation the renderer uses) with **clear line-of-sight**. Damage/miss math is
  faithful; only the screen-pixel `shootdelta` cone (render-config-specific) is dropped.
- **Weapon animation → per-weapon cooldown.** The `Cmd_Fire`/`T_Attack`/`attackinfo` weapon state
  machine is replaced by a per-tick fire cooldown — now PER WEAPON: the knife/pistol use `ATTACKRATE`,
  the machine gun/chaingun fire faster (their lower cooldowns stand in for id's `attackframe` loop-back
  that auto-repeats while the trigger is held). `weapon`/`bestweapon` are packed (ownership is
  contiguous `wp_knife..bestweapon`, per `CheckWeaponChange`); keys 1-4 select a weapon, `GiveWeapon`
  (MG/chaingun pickup) grants +6 ammo and auto-switches, and out-of-ammo forces the knife (`T_Attack`
  case -1). The knife (`KnifeAttack`) is melee + silent + free; the guns spend a round and `madenoise`.
  Both share the render-decoupled target pick of `GunAttack` (closest shootable in front with LOS), the
  knife capped at melee reach `KNIFEDIST` (id's `transx ≤ 0x18000`). One artifact: that depth `nx`
  (offset by `FOCALLENGTH`, as id's `transx` is) puts a tile-adjacent enemy just beyond `KNIFEDIST`, so
  a connecting knife hit needs sub-tile range — the differential exercises `KnifeAttack` via the
  out-of-ammo→knife tail of `kill_ss`/`kill_officer`.
- **Pickups trigger on the player's tile.** id picks up a bonus during the 3D refresh, when its tile
  transforms onto the player (`WL_DRAW.C` `TransformTile`). Headless there's no refresh, so a bonus is
  taken when `player tile == item tile` — an identical-on-both-sides choice, like `FL_VISABLE`. The
  effects (`GetBonus`: ammo/health clamps, "skip if full", keys, score) are faithful; only render/audio
  bits (bonus flash, `treasurecount`, lives/`GiveExtraMan`, weapon switching) are dropped — weapon
  pickups still grant their `GiveAmmo(6)`, and kill-points are not awarded (score is treasure only).
- **All actors think every tic.** Wolf3D gates an actor's processing on `ob->active`, which the
  renderer flips on when the actor is drawn. Headless, there's no renderer, so we process every
  actor every tic (like `FL_VISABLE`, an identical-on-both-sides choice). This is what lets a
  dormant guard run `T_Stand`/`SightPlayer` and wake on line-of-sight without screen activation.
- **Doors + area connectivity.** Doors are faithful (open/close/slide/auto-close, block until fully
  open, open on player Use / guard bump, gate LOS via `CheckLine`+`doorposition`), and so is id's
  **area graph**: each map tile carries an `areanumber` (plane-0 floor code − `AREATILE`), a door joins
  its two perpendicular neighbours' areas while it isn't fully closed, and `ConnectAreas`/
  `RecursiveConnect` flood `areabyplayer` from the player's area. So gunfire (`madenoise`) and sight
  only reach guards in areas reachable from the player through OPEN doors — a closed door localizes
  sound, exactly like the original (`SightPlayer`/`CheckSight` gate on `areabyplayer`). The Engine
  rebuilds the connectivity bitmask each tick from the (stateless) door states, so `areanumber`/
  `areabyplayer` need no extra packed state. Only `PlaySoundLocTile` audio, door-jamb side textures
  (`|0x40`), and the `actorat` adjacency checks in `CloseDoor`/`DoorClosing` (no actor grid) remain
  dropped. Applied identically in the oracle and Solidity (differential scenario `area_sound`).
- **Pushwalls reconstruct the immutable tilemap.** A secret wall slides when Used (`Cmd_Use` →
  `PushWall`/`MovePWalls`), permanently relocating tiles. The C oracle mutates its `tilemap[][]`
  directly, as id does; but the Solidity `Map` tilemap is **immutable** (SSTORE2), so the Engine
  carries a small packed pushwall record (`startx,starty,dir,pwstate,tile`) and **reconstructs the
  effective tilemap each tick** — the vacated tiles become floor (joining the player's area), the wall
  appears at its slid position — so collision, sight, and the renderer all read the moved geometry with
  no per-tile state. The two reach the same observable result (differential scenario `push_secret`),
  though the tilemap *representation* differs (the oracle's grid vs the Engine's reconstruction). id's
  `0xc0` "moving" tile-flag is dropped — a relocated wall is a plain solid tile (the sim cares only
  solid-vs-floor; the sub-tile slide is a render value). With the fixed `tics=1` a wall slides 3 tiles
  (id's "two" assumes `tics>1`). The client and the T3 pixel-match reconstruct the moved walls into
  `wolfrender`'s tilemap, so the slide renders — and it glides **sub-tile**: the renderer derives each
  record's slide fraction from `pwstate` and offsets the moving wall's near face into its tile (id
  WL_DRAW.C `HitVert`/`HitHorizPWall`), so the wall moves smoothly tic-by-tic instead of jumping a whole
  tile at each block boundary (the offset is render-only — the on-chain sim stays tile-granular for
  collision/sight). **Several secret walls can slide at once** — the state holds a sparse list of records
  (numpushwalls + one word each, like the active-door list), and `map-extract` reads the plane-1
  `PUSHABLETILE` markers, so E1L1's 5 real secret walls all work. Re-triggering a wall already sliding is
  a no-op (the oracle clears that tile's `pushwallat` marker; the Engine scans the active list). Remaining
  simplification: no mid-slide actor block-check (the trigger still checks the first destination).
- **The elevator ends the level; the sim then freezes.** id's `Cmd_Use` ends the level when the player
  Uses an `ELEVATORTILE` (21) on an east/west wall (`elevatorok`): it sets `playstate = ex_completed`
  and `PlayLoop` returns. Headless there's no loop to return from, so the same trigger latches an `exit`
  byte (header `@48`) and **freezes the sim** — the oracle main loop, the wasm `step()`, and the Engine
  `tick()` all short-circuit once `exit` is set, re-emitting the unchanged world so any further input is a
  no-op (the Session is terminal). Applied identically on all three, so the differential still holds
  (scenario `level_exit`). id's switch-texture flip (`tilemap[checkx][checky]++`, 21→22) stays oracle-only
  — the Engine's tilemap is immutable and the freeze already prevents re-trigger. `map-extract` keeps real
  wall tile values, so E1L1's actual exit elevator works unchanged. **No level→level flow**: this is a
  demo (one immutable Map per Session by design), so on completion the *client* plays Wolf3D's
  level-complete intermission (render-only) rather than loading a floor 2; `ex_secretlevel` (the
  `ALTELEVATORTILE` variant) is likewise out of scope.
- **Enemy classes share one state table + AI.** The full E1 roster lives in one flat `gstates[]` graph
  (0–15 guard, 16–37 SS, 38–53 dog, 54–70 officer). Guard/SS/officer reuse `T_Chase`/`T_Shoot`; the dog
  has its own `T_DogChase` (no LOS — rushes via `SelectDodgeDir` and leaps to `T_Bite` at melee range)
  and uses CHECKDIAG on cardinals (it can't open doors). Stats and the shoot/die/pain target state are
  by `obclass`, and `FirstSighting` (chase state + speed ×3/×4/×5/×2) and the sight-reaction delay
  (random for guard/SS/dog, a constant `2` with NO RNG draw for the officer) are class-specific — a
  faithfulness detail that was hardcoded to the guard until the dog/officer forced it out (the
  consistent-but-wrong oracle+Engine had hidden it from the differential). Spawns carry a class byte
  (`tilex,tiley,dir,class`).
- **Actor-vs-actor collision** is modeled by scanning the actor list for a shootable actor on the
  target tile, rather than id's `actorat` grid — equivalent here because each actor's `(tilex,tiley)`
  is its grid mark (id's clear-at-start/mark-at-end falls out of reading live positions in actor
  order) and `TryWalk` only tests tiles adjacent to the mover, never its own. So guards no longer walk
  through each other. The `actorat`-based straddle checks in `CloseDoor`/`DoorClosing` stay player-only
  (a closing door can still pinch a guard standing in it — an accepted simplification).
- **Audio is off-chain, reconstructed from state deltas (M7).** id called `SD_PlaySound` inline from the
  sim (e.g. `GunAttack`, `KillActor`, `OperateDoor`, `GetBonus`). On-chain there is no audio device and
  emitting a per-tic sound *log* would cost gas for a consensus-irrelevant value, so — exactly like the
  renderer — the **client** derives sound from the public state: it diffs two consecutive decoded states
  and plays the matching sound (ammo drop → the weapon's gunshot; a guard's `T_Stand`→chase → its sight
  cry; shoot/die frames → fire/death; door `action` → open/close; a new pushwall record → the rumble; a
  taken-bit flip → the pickup; `health`↓ → take-damage; `exit` latch → level-done). This is a *view* of
  state, never a cause — no sim logic client-side. Three faithful sources, decoded from the user's
  shareware by `wl-extract` (no id audio committed): **digitized SFX** (VSWAP PCM, the `SDL_SetupDigi`
  info-page walk + `wolfdigimap` name→index, 8-bit→16-bit WAV @ 7 kHz), **AdLib SFX** (`AUDIOT`
  `AdLibSound` = instrument + a 140 Hz F-number stream, `SDL_ALPlaySound`/`SDL_ALSoundService`), and
  **IMF music** (`AUDIOT` music = a 700 Hz OPL register stream, `SD_StartMusic`/`SDL_ALService`). AdLib
  SFX and IMF music are synthesised by **Nuked-OPL3** (the YM3812 id drove) compiled to wasm. Faithful
  choices/deviations, all render-side: id plays a sound's **digitized** version when one is mapped and
  its **AdLib** version otherwise (`SD_PlaySound`→`DigiMap`) — the client does the same; the **PC-speaker**
  source is dropped (a third rendering of the same effects); id's `SetSoundLoc` per-ear attenuation tables
  are approximated by a Web Audio `StereoPanner` + linear distance gain in the same view frame; the
  digitized-sound **sample rate** (~7 kHz, id's DMA time constant) and the **block layout** of `AUDIOT`
  (`NUMSOUNDS` stride) are auto-detected (the shareware data ships with the registered 87-sound header,
  not `AUDIOWL1.H`'s 69); and there is no level→level **music change** (one Map per Session, by design —
  E1L1 simply loops "Get Them For Greater Justice!"). Because audio is off the consensus path, it is not
  part of the differential test — the same status as the renderer; `audio/verify_opl.mjs` instead
  asset-free smoke-tests that the OPL chip + the IMF/AdLib replay clocks actually synthesise sound.

## Tooling

| layer | language | tool |
|---|---|---|
| contracts (`Engine`/`Map`/`Session`) | Solidity | Foundry (`via_ir`) |
| sim oracle (ground truth) | C | cc/make |
| client-side predictor | C → WebAssembly | clang `--target=wasm32` (freestanding, no Emscripten) + binaryen `wasm-opt`; the SAME carved C as the oracle, trig baked from `--dump-trig` |
| wall renderer | C → WebAssembly | Emscripten; id's `WL_DRAW.C` wall math + a portable grid-DDA ray cast → framebuffer + depth |
| differential + gas harness | Rust | alloy + in-process anvil |
| client (first-person view + HUD + audio) | TypeScript | Vite + viem; DDA raycaster adapted from 3DSage (MIT); Web Audio sound from state deltas |
| OPL2 FM synth (AdLib SFX + IMF music) | C → WebAssembly | clang `--target=wasm32` (freestanding, no Emscripten) + binaryen; wraps **Nuked-OPL3** (LGPL-2.1, fetched not committed) |
| asset extractor (VSWAP textures/sprites + VGAGRAPH HUD pics + digi/AdLib/IMF audio) | Rust | `png`; reads user-provided shareware, nothing committed |

`reference/` (id's Wolf3D source) is **not committed** — it's under a restrictive license; clone
commands are in the root README. The **Nuked-OPL3** emulator source (`audio/vendor/`, LGPL-2.1) is
likewise not committed — `audio/build_opl.sh` fetches it. No id game assets are committed.

## Glossary

- **sim oracle / C-oracle** — the headless program built from id's original C; correct by definition.
- **(input) vector** — a scripted sequence of inputs, one `ticcmd` per tick.
- **golden vector** — an input vector paired with the oracle's per-tick snapshots; the reference.
- **differential test** — replay an input vector through the Solidity `Engine` and assert its
  snapshots equal the golden ones, tic-by-tic.
- **ticcmd / `Cmd`** — one tick's input: buttons bitmask + `controlx`/`controly`.
- **DoActor** — the per-tic state-machine advance for an actor (decrement `ticcount`, run
  `think`/`action`, follow `state.next`).
