# web — client shell (placeholder)

TypeScript + Vite shell. Lands in M1+:

- one-time wallet connect (`join` / `delegate`) via viem
- mounts the Rust→WASM `client-core` (game loop, state decode, prediction, session-key signing)
- mounts the C-port→WASM renderer (Wolf3D port via Emscripten)

Requires Emscripten (`emcc`) for the renderer build — not yet installed in this environment.
