# web — first-person client

A **TypeScript + Vite + viem** client that renders the on-chain world in first person.
It deploys `Engine`/`Map`/`Session` to a local anvil, drives the sim (one `submitInput` tx per
step), decodes the packed `getState()` words, and draws:

- a **first-person raycaster view** — walls via a DDA march transliterated from 3DSage's
  MIT-licensed raycaster (`reference/sage-raycaster`), guards as depth-buffered sprite columns
  (the faithful Wolf3D technique), a pistol viewmodel with recoil + muzzle flash, and a damage
  flash when you're hit. With **authentic id textures/sprites** when present (see below), else
  procedural placeholder art;
- a **Wolfenstein-style HUD** — floor, health (with a face that reacts to damage), ammo, and the
  live `gas/input` of the last `submitInput` tx;
- a **top-down minimap** with the FOV cone and live guard positions, plus a debug readout.

Everything on screen is decoded from contract state — no client-side game logic. No id artwork
is shipped: the guard sprite and weapon are drawn procedurally.

## Run

```
# 1. build the contracts (the client imports ../contracts/out artifacts)
( cd ../contracts && forge build )

# 2. start a local chain
anvil --silent &

# 3. serve the client
pnpm install
pnpm dev          # http://localhost:5173
```

Open the page: it auto-deploys to anvil and starts ticking. **WASD** move · **←/→** (or **A/D**)
turn · hold **Shift** to strafe · **Space** to fire. Each step sends one `submitInput`; the world
only advances when you act, so the guard keeps closing in. A render loop animates the gun / flashes
smoothly between ticks (independent of tx latency).

## Authentic Wolfenstein art (optional)

The client renders procedural placeholder art by default. To get the **real** Wolf3D walls and
guard sprites, point `rust/wl-extract` at a Wolfenstein 3D **shareware** `VSWAP.WL1` you provide:

```
# get the freely-distributable WL1 shareware (e.g. from archive.org / 3D Realms) and
# copy its VSWAP.WL1 somewhere, then:
cargo run -p wl-extract -- --vswap /path/to/VSWAP.WL1 --out web/public/wolf
# reload the page — the HUD shows  art: real id (VSWAP)
```

`wl-extract` decodes VSWAP's 64×64 column-major wall textures and its compshape (RLE) sprite frames
to PNGs under `web/public/wolf/` (which the client lazy-loads at runtime). **No id Software art is
committed** — that directory is `.gitignore`d, and the extractor reads only *your* data file. The
VSWAP layout, the sprite post format, and the game palette were taken from id's GPL source in
`reference/wolf3d` (`ID_PM.C`, `OLDSCALE.C`, `GAMEPAL`). Wall page `0`/`1` texture our 0/1 map;
guard sprite frames are picked by the guard's `state` + `dir` via Wolf3D's `CalcRotate`.

> Decoder note: `src/main.ts` unpacks the same bit layout as `Engine.sol`'s `_pack`
> (header · player word · one word per actor). Keep them in sync.
>
> Renderer note: the DDA wall march is adapted from 3DSage's raycaster (MIT). It works in
> "sage units" (1 tile = 64); our positions are 16.16 fixed-point, scaled on the way in. The angle
> convention (degrees, east=0, dir = (cos a, −sin a), screen-y south) already matches ours, so the
> trig carries over unchanged.
