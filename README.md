# eth-doom

Wolfenstein-3D **world simulation** running as an EVM smart contract — the chain as the
authoritative, deterministic multiplayer consensus engine (the same shape as Wolf3D's original
lockstep netcode). Rendering and audio stay off-chain.

See the design plan: `~/.claude-personal/plans/megaeth-looks-promising-but-hazy-crane.md`.

## Layout

```
reference/   cloned wolf3d + sage-raycaster (read-only reference)
oracle/      carved C sim → headless `sim_oracle` (ground truth for differential tests)
contracts/   Foundry: Engine / Map / Session / SessionFactory (Solidity)
rust/        cargo workspace: map-extract · harness (revm gate) · client-core (→ wasm)
web/         TypeScript + Vite shell (wallet connect, mounts wasm modules)
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
