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
- **`Map`** (immutable) — tilemap + guard spawn list. (Tiles in storage today; SSTORE2/`CODECOPY`
  is the planned gas optimization.)
- **`Session`** (stateful) — the single source of truth for a live game: holds the packed world
  state + immutable `engine`/`map` addresses. `engine`/`map` are immutable so a live game's rules can
  never change underneath it.

### Packed world state

`Session.state` is `header · player word · one word per actor` (replacing an `abi.encode` blob —
~40% gas cut). Bit layout (LSB first), kept in lockstep across `Engine.sol`, the harness, and the
web decoder:

- **header**: `rndindex:uint8@0 | numactors:uint8@8`
- **player**: `x:int32@0 | y:int32@32 | angle:uint16@64 | anglefrac:int32@80 | tilex:uint8@112 |
  tiley:uint8@120 | health:int16@128 | ammo:int16@144 | attackcount:int16@160`
- **actor**: `x:int32@0 | y:int32@32 | tilex:uint8@64 | tiley:uint8@72 | dir:uint8@80 | state:uint8@88
  | ticcount:int16@96 | distance:int32@112 | hitpoints:int16@144 | flags:uint8@160 | obclass:uint8@168
  | speed:int32@176 | active:uint8@208`

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
- **Weapon animation → cooldown.** The `Cmd_Fire`/`T_Attack`/`attackinfo` weapon state machine is
  replaced by a simple per-tick fire cooldown (`ATTACKRATE`).
- **Single-area map, no doors (yet).** `areanumber`/`areabyplayer` connectivity is collapsed to a
  single area; `CheckLine`'s door branch is dead code until M3 adds doors.
- **No `actorat` grid for one guard.** With a single guard there's no actor-vs-actor collision, so
  `TryWalk` checks walls directly. Multiple guards (M3) reintroduce the grid.

## Tooling

| layer | language | tool |
|---|---|---|
| contracts (`Engine`/`Map`/`Session`) | Solidity | Foundry (`via_ir`) |
| sim oracle (ground truth) | C | cc/make |
| differential + gas harness | Rust | alloy + in-process anvil |
| client (first-person view + HUD) | TypeScript | Vite + viem; DDA raycaster adapted from 3DSage (MIT) |
| asset extractor (VSWAP → PNG textures/sprites) | Rust | `png`; reads user-provided shareware, nothing committed |

`reference/` (id's Wolf3D source) is **not committed** — it's under a restrictive license; clone
commands are in the root README. No id game assets are committed.

## Glossary

- **sim oracle / C-oracle** — the headless program built from id's original C; correct by definition.
- **(input) vector** — a scripted sequence of inputs, one `ticcmd` per tick.
- **golden vector** — an input vector paired with the oracle's per-tick snapshots; the reference.
- **differential test** — replay an input vector through the Solidity `Engine` and assert its
  snapshots equal the golden ones, tic-by-tic.
- **ticcmd / `Cmd`** — one tick's input: buttons bitmask + `controlx`/`controly`.
- **DoActor** — the per-tic state-machine advance for an actor (decrement `ticcount`, run
  `think`/`action`, follow `state.next`).
