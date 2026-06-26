# eth-doom — status

A proof-of-concept that runs a faithful **Wolfenstein-3D world simulation as an EVM smart
contract** — the chain as the authoritative, deterministic multiplayer engine (Wolf3D's original
lockstep netcode shape). Rendering stays off-chain. Every ported simulation function is verified
**bit-for-bit against the original id Software C code** via a differential test.

## What runs today

A complete single-guard PvE loop, on the EVM, differential-verified:

- **Player movement** — turn/strafe/forward/back with tile collision (`ControlMovement`/`Thrust`/
  `ClipMove`/`TryMove`).
- **Guard AI** — a guard chases the player (`T_Chase`, `SelectChaseDir`/`SelectDodgeDir`,
  `MoveObj`, `TryWalk`, `CheckLine` line-of-sight) driven by Wolf3D's deterministic RNG.
- **Two-way combat** — the guard shoots the player (`T_Shoot` → `TakeDamage`, health drops); the
  player fires back (`GunAttack` → `DamageActor` → pain → `KillActor` death), with ammo + a fire
  cooldown.
- **A live first-person browser view** — a TypeScript/viem client that deploys to anvil, drives the
  sim one `submitInput` tx per step, and renders the decoded on-chain state: a raycaster wall view
  (DDA adapted from 3DSage's MIT raycaster), guards as depth-buffered sprite columns, a pistol
  viewmodel + muzzle/damage flashes, a Wolfenstein-style HUD (health/ammo/face + live gas/input),
  and a minimap. WASD/arrows move, Shift strafes, Space fires. No game logic client-side; no id art.

## Milestones

| | status | delivered |
|---|---|---|
| **M0** scaffold + oracle | ✅ | Foundry/Rust/C scaffold; C `sim_oracle` (movement) — the differential ground truth |
| **M1** Solidity movement + gas | ✅ | `Engine`/`Map`/`Session`; movement port; Rust+anvil differential harness; first gas number; state packed into one word |
| **M2a** RNG + actor model | ✅ | deterministic `rndtable`/`US_RndT`; `objtype`/`DoActor` state machine; multi-actor packed state |
| **M2b** guard chase AI | ✅ | chase/dodge/move/LOS, oracle + Solidity, differential PASS |
| **M2c** hitscan combat | ✅ | guard shoots player + player kills guard; pain/death; ammo |
| **M3** world completeness | ⬜ | doors, pickups, multiple enemies, real WL1 level via `map-extract`, `SessionFactory` |
| **M4** MegaETH + UX | ⬜ | deploy to MegaETH; session-key delegation + auto-signing; WASM Wolf3D-port renderer; client prediction |

## Gas (per `submitInput`, packed state, on anvil)

| scenario | what | min | avg | max |
|---|---|---|---|---|
| `move_basic` | movement only | 74.4k | 78.8k | 94.4k |
| `chase_guard` | guard chases + shoots you (151 tics) | 81.0k | 86.2k | 110.9k |
| `kill_guard` | you fire + kill the guard (81 tics) | 83.9k | 93.6k | 126.3k |

`submitInput` gas is the true per-input cost a player pays. ~80–126k/input with a live guard —
well inside the original ~120–250k estimate, and a fraction of a cent on a cheap L2.

## How it's verified

Per `DESIGN.md`: the C `sim_oracle` (carved from id's source) replays an input vector and emits
per-tick **golden vectors**; the Rust harness deploys the contracts on anvil, replays the same
inputs through `Session.submitInput`, and asserts the decoded state matches the golden vector
**tic-by-tic** (player pose/health/ammo, every guard field, and the RNG index). All three
scenarios pass.

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

- **Re-pack opt** is done for the multi-actor state; the obvious remaining gas lever is reading
  the map via SSTORE2/`CODECOPY` instead of an `IMap.tiles()` staticcall each tic.
- **M3**: doors + `CheckLine` door logic, pickups, multiple guards (then actor-vs-actor `actorat`
  collision matters), real WL1 geometry.
- **M4**: MegaETH deploy (plain redeploy), popup-free play via session keys, first-person renderer.
