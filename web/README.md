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
turn · hold **Shift** to strafe · **Space** to fire · **E** to open the door you face. Each step
sends one `submitInput`; the world only advances when you act, so the guard keeps closing in. Doors
slide open over the next several ticks (the on-chain `doorposition`) and you walk through once open. A
render loop animates the gun / flashes smoothly between ticks (independent of tx latency).

## Authentic Wolfenstein art (optional)

The client renders procedural placeholder art by default. To get the **real** Wolf3D walls and
guard sprites, one helper does the whole thing — download the freely-distributable **shareware**,
find its `VSWAP.WL1`, and extract:

```
scripts/fetch-shareware.sh         # download shareware + extract → web/public/wolf
# reload the page — the HUD shows  art: real id (VSWAP)
```

Already have a shareware archive (or your own registered copy)? Skip the download:

```
scripts/fetch-shareware.sh --zip /path/to/1wolf14.zip   # or any zip containing VSWAP.WL1
cargo run -p wl-extract -- --vswap /path/to/VSWAP.WL1 --out web/public/wolf   # or call the extractor directly
```

> The script only ever auto-downloads the **shareware** (episode 1, `.WL1`). The registered game's
> `.WL6` data is commercial and not redistributable — if you own it, pass it via `--zip` (the
> extractor reads `VSWAP.WL6` identically), but the script won't fetch it.

`wl-extract` decodes, to PNGs under `web/public/wolf/` (which the client lazy-loads at runtime):
- **VSWAP** → 64×64 column-major **wall textures** + compshape (RLE) **sprite frames** (guard, the
  player **pistol** viewmodel);
- **VGAGRAPH** (Huffman-compressed, VGA-planar) → the **HUD** pics: the status bar, the white digit
  font, and the animated **BJ face**.

The client then textures the walls (page 0/1), billboards real guards (frame by `state`+`dir` via
Wolf3D's `CalcRotate`), draws the real pistol, and composites the authentic status bar — with the
BJ face chosen by health and digits drawn in the HUD slots (LEVEL/SCORE/LIVES/HEALTH/AMMO). Floor and
ceiling use Wolf3D's flat colors (`0x19`/`0x1d`). **No id Software art is committed** — that directory
is `.gitignore`d, and the extractor reads only *your* data file. Every format (VSWAP page table,
compshape posts, the palette, the Huffman/planar VGAGRAPH layout, and all chunk numbers) comes from
id's GPL source in `reference/wolf3d`.

> Decoder note: `src/main.ts` unpacks the same bit layout as `Engine.sol`'s `_pack`
> (header · player word · one word per actor). Keep them in sync.
>
> Renderer note: the DDA wall march is adapted from 3DSage's raycaster (MIT). It works in
> "sage units" (1 tile = 64); our positions are 16.16 fixed-point, scaled on the way in. The angle
> convention (degrees, east=0, dir = (cos a, −sin a), screen-y south) already matches ours, so the
> trig carries over unchanged.
