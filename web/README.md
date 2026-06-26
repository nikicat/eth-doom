# web — first-person client

A **TypeScript + Vite + viem** client that renders the on-chain world in first person.
It deploys `Engine`/`Map`/`Session` to a local anvil, drives the sim (one `submitInput` tx per
step), decodes the packed `getState()` words, and draws:

- a **first-person raycaster view** — walls via a DDA march transliterated from 3DSage's
  MIT-licensed raycaster (`reference/sage-raycaster`), guards as depth-buffered sprite columns
  (the faithful Wolf3D technique), a pistol viewmodel with recoil + muzzle flash, and a damage
  flash when you're hit;
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

> Decoder note: `src/main.ts` unpacks the same bit layout as `Engine.sol`'s `_pack`
> (header · player word · one word per actor). Keep them in sync.
>
> Renderer note: the DDA wall march is adapted from 3DSage's raycaster (MIT). It works in
> "sage units" (1 tile = 64); our positions are 16.16 fixed-point, scaled on the way in. The angle
> convention (degrees, east=0, dir = (cos a, −sin a), screen-y south) already matches ours, so the
> trig carries over unchanged.
