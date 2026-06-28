# eth-doom

Wolfenstein-3D **world simulation** running as an EVM smart contract — the chain as the
authoritative, deterministic multiplayer consensus engine (the same shape as Wolf3D's original
lockstep netcode). Rendering and audio stay off-chain.

**Working today:** the full E1 enemy cast — guards, SS troopers, officers, and melee dogs — wakes
when they see or hear you, chases, shoots/bites you, and you can shoot them dead, and they no longer
walk through each other; doors slide open
when you Use them (or a guard bumps one) and block sight until they do; you pick up ammo / health /
keys / treasure by walking over them (keys unlock their doors); and Using the **elevator switch ends
the level** (the sim freezes; the client plays Wolf3D's level-complete intermission); and you slide **secret pushwalls** (several at once — E1L1's are all
real) — a PvE loop simulated entirely in a Solidity contract, **verified bit-for-bit against the
original id C code**, at ~75–145k gas per input, with a live **first-person** browser view (raycaster +
HUD + minimap), all decoded from on-chain state — now **with sound**: authentic digitized SFX, AdLib
SFX, and OPL/IMF music, synthesised off-chain in the browser and triggered from state deltas.

- **[docs/STATUS.md](docs/STATUS.md)** — milestones, what runs, gas numbers, how to run it.
- **[docs/DESIGN.md](docs/DESIGN.md)** — architecture, the differential-testing method, state
  layout, and the sim↔render faithfulness adaptations.

## Layout

```
docs/        STATUS.md · DESIGN.md
reference/   cloned wolf3d + sage-raycaster (read-only; not committed — see below;
             the client's DDA wall march is adapted from sage-raycaster, MIT)
oracle/      carved C sim → headless sim_oracle (differential ground truth)
contracts/   Foundry: Engine / Map / Session + Fixed/Trig/Rng libs (Solidity)
rust/        cargo workspace: harness (differential + gas) · wl-extract (VSWAP→PNG textures/
             sprites + digi/AdLib/IMF audio) · map-extract · client-core (stubs)
audio/       OPL2 FM synth: opl_wasm.c wraps Nuked-OPL3 (fetched, not committed) → opl.wasm
             (build_opl.sh) for AdLib SFX + IMF music · verify_opl.mjs (headless smoke test)
web/         TypeScript + Vite + viem first-person client (raycaster + HUD + Web Audio sound)
scenarios/   one self-describing <name>.json per differential scenario (map · spawns ·
             checkpoints) — auto-discovered by the oracle / harness / verify_wasm (single source)
vectors/     per-scenario golden input (<name>.input.txt) + oracle snapshots (committed)
```

## Build

```
make -C oracle          # sim_oracle (C)
cargo build             # in rust/  (map-extract, harness, client-core)
forge build             # in contracts/
```

## Reference sources

`reference/` is **not** committed (id Software's Wolf3D source is under a restrictive, non-free
license). Re-create it for development:

```
mkdir -p reference && cd reference
git clone --depth 1 https://github.com/id-Software/wolf3d.git
git clone --depth 1 https://github.com/3DSage/OpenGL-Raycaster_v1.git sage-raycaster
```

The browser OPL2 synth (M7 audio) wraps **Nuked-OPL3** (nukeykt, LGPL-2.1), which is also **not**
committed — `audio/build_opl.sh` fetches `opl3.c`/`opl3.h` into `audio/vendor/` (gitignored) and
compiles them with our wrapper. The DDA wall march in the web client is adapted from sage-raycaster (MIT).

## Licensing & assets

- The simulation in `oracle/` (and the future Solidity `Engine`) is a **derivative** of id Software's
  Wolfenstein 3D source, carried under id's original license terms.
- This repo contains **no** id shareware data. `map-extract` reads `MAPHEAD`/`GAMEMAPS` from a
  user-provided WL1 directory; only the transformed `Map` blob is committed.
