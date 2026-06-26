# eth-doom

Wolfenstein-3D **world simulation** running as an EVM smart contract — the chain as the
authoritative, deterministic multiplayer consensus engine (the same shape as Wolf3D's original
lockstep netcode). Rendering and audio stay off-chain.

**Working today:** a guard chases you, shoots you, and you can shoot it dead — a full PvE loop
simulated entirely in a Solidity contract, **verified bit-for-bit against the original id C code**,
at ~80–126k gas per input, with a live top-down browser view.

- **[docs/STATUS.md](docs/STATUS.md)** — milestones, what runs, gas numbers, how to run it.
- **[docs/DESIGN.md](docs/DESIGN.md)** — architecture, the differential-testing method, state
  layout, and the sim↔render faithfulness adaptations.

## Layout

```
docs/        STATUS.md · DESIGN.md
reference/   cloned wolf3d + sage-raycaster (read-only; not committed — see below)
oracle/      carved C sim → headless sim_oracle (differential ground truth)
contracts/   Foundry: Engine / Map / Session + Fixed/Trig/Rng libs (Solidity)
rust/        cargo workspace: harness (differential + gas) · map-extract · client-core (stubs)
web/         TypeScript + Vite + viem top-down client
vectors/     golden input + per-tick snapshot files (committed)
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

## Licensing & assets

- The simulation in `oracle/` (and the future Solidity `Engine`) is a **derivative** of id Software's
  Wolfenstein 3D source, carried under id's original license terms.
- This repo contains **no** id shareware data. `map-extract` reads `MAPHEAD`/`GAMEMAPS` from a
  user-provided WL1 directory; only the transformed `Map` blob is committed.
