# web — quick client view (top-down)

A minimal **TypeScript + Vite + viem** client (the M1 smoke-test view from the plan; the
faithful Wolf3D-port WASM renderer is the later target). It deploys `Engine`/`Map`/`Session`
to a local anvil, drives the sim (one `submitInput` tx per frame), decodes the packed
`getState()` words, and draws a top-down view. WASD moves; the guard chases and shoots you.

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

Open the page: it auto-deploys to anvil and starts ticking. The HUD shows tick / rndindex /
player health / guard state. WASD to move (each key sends `submitInput`); the world advances
every frame so the guard keeps chasing even when you stand still.

> Decoder note: `src/main.ts` unpacks the same bit layout as `Engine.sol`'s `_pack`
> (header · player word · one word per actor). Keep them in sync.
