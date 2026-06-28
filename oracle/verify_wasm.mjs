// verify_wasm.mjs — prove the WebAssembly predictor (web/public/predict.wasm) is
// faithful: drive it through every golden scenario and assert its packed-state output
// decodes to the SAME fields the C oracle dumped, tic-by-tic. Since the oracle's golden
// vectors are what the Solidity Engine is diffed against, wasm == golden ⟹ wasm == chain.
//
//   node oracle/verify_wasm.mjs        (build first: bash oracle/build_wasm.sh)
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

// Scenarios are auto-discovered from scenarios/*.json — the single source of truth
// shared with oracle/gen_vectors.sh + rust/harness (T1). enemy class -> en_* enum.
const CLASS = { guard: 0, officer: 1, ss: 2, dog: 3 };
const SCENARIOS = readdirSync(join(ROOT, "scenarios"))
  .filter((f) => f.endsWith(".json"))
  .sort()
  .map((f) => {
    const name = f.replace(/\.json$/, "");
    const cfg = JSON.parse(readFileSync(join(ROOT, "scenarios", f), "utf8"));
    return {
      name,
      map: cfg.map,
      sx: cfg.player.x, sy: cfg.player.y, sdir: cfg.player.dir,
      // [which, tilex, tiley, dir] — the order the wasm add_enemy / setup() expects.
      enemies: (cfg.enemies ?? []).map((e) => [CLASS[e.class], e.x, e.y, e.dir]),
      input: cfg.input ?? `${name}.input.txt`,
      checkpoints: cfg.checkpoints ?? "all", // "all" = every tic; array = only those tics
    };
  });

const DR_CLOSED = 1;

// --- packed-state decoder (mirrors Engine._unpack; words are 32-byte big-endian) ---
function words(bytes) {
  const out = [];
  for (let o = 0; o < bytes.length; o += 32) {
    let w = 0n;
    for (let i = 0; i < 32; i++) w = (w << 8n) | BigInt(bytes[o + i]);
    out.push(w);
  }
  return out;
}
const u = (w, off, bits) => Number((w >> BigInt(off)) & ((1n << BigInt(bits)) - 1n));
const s = (w, off, bits) => {
  const v = (w >> BigInt(off)) & ((1n << BigInt(bits)) - 1n);
  const m = 1n << BigInt(bits - 1);
  return Number((v ^ m) - m);
};

function decode(bytes, ndoorsTotal) {
  const ws = words(bytes);
  const h = ws[0];
  const rng = u(h, 0, 8), na = u(h, 8, 8), ad = u(h, 16, 8), ni = u(h, 24, 16);
  const iw = ni === 0 ? 0 : Math.ceil(ni / 256);
  const p = ws[1];
  const st = {
    rng,
    x: s(p, 0, 32), y: s(p, 32, 32), angle: s(p, 64, 16), anglefrac: s(p, 80, 32),
    tilex: u(p, 112, 8), tiley: u(p, 120, 8), health: s(p, 128, 16), ammo: s(p, 144, 16),
    acount: s(p, 160, 16), keys: u(p, 184, 8), score: s(p, 192, 32),
    weapon: u(p, 224, 8), bestweapon: u(p, 232, 8), exit: u(h, 48, 8),
  };
  // doors: default all closed, fill from the sparse active-door words (by doornum)
  const doors = Array.from({ length: ndoorsTotal }, () => ({ pos: 0, act: DR_CLOSED, tc: 0 }));
  for (let i = 0; i < ad; i++) {
    const dw = ws[2 + i];
    const dn = u(dw, 48, 8);
    doors[dn] = { act: u(dw, 0, 8), tc: s(dw, 16, 16), pos: u(dw, 32, 16) };
  }
  // items: taken bitmask
  const items = [];
  for (let i = 0; i < ni; i++) {
    const word = ws[2 + ad + ((i / 256) | 0)];
    items.push(Number((word >> BigInt(i % 256)) & 1n));
  }
  // actors
  const guards = [];
  for (let i = 0; i < na; i++) {
    const a = ws[2 + ad + iw + i];
    guards.push({
      x: s(a, 0, 32), y: s(a, 32, 32), dir: u(a, 80, 8), st: u(a, 88, 8),
      tc: s(a, 96, 16), dist: s(a, 112, 32), hp: s(a, 144, 16), cls: u(a, 168, 8),
    });
  }
  // pushwalls: numpushwalls@40 trailing words after the actors, one per triggered wall
  const np = u(h, 40, 8);
  const pwalls = [];
  for (let i = 0; i < np; i++) {
    const pw = ws[2 + ad + iw + na + i];
    pwalls.push({ sx: u(pw, 0, 8), sy: u(pw, 8, 8), dir: u(pw, 16, 8), state: u(pw, 24, 16), tile: u(pw, 40, 8) });
  }
  return { ...st, doors, items, guards, pwalls };
}

// --- wasm driver ---
const wasm = new WebAssembly.Instance(
  new WebAssembly.Module(readFileSync(join(ROOT, "web/public/predict.wasm"))),
);
const E = wasm.exports;
function readState() {
  const len = E.read_state();
  const ptr = E.state_ptr();
  return new Uint8Array(E.memory.buffer, ptr, len).slice();
}

function setup(sc) {
  E.reset();
  const text = readFileSync(join(ROOT, "oracle/maps", sc.map), "utf8").split("\n");
  const [w, h] = text[0].trim().split(/\s+/).map(Number);
  for (let y = 0; y < h; y++) {
    const row = text[1 + y] ?? "";
    for (let x = 0; x < w; x++) E.setup_tile(x, y, (row[x] ?? " ").charCodeAt(0));
  }
  E.init_actors();
  E.add_player(sc.sx, sc.sy, sc.sdir);
  for (const [which, x, y, dir] of sc.enemies) E.add_enemy(which, x, y, dir);
}

function parseInputs(file) {
  return readFileSync(join(ROOT, "vectors", file), "utf8")
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l && !l.startsWith("#"))
    .map((l) => l.split(/\s+/).map(Number)); // [cx, cy, btns]
}

// compare decoded state to a golden snapshot; return a mismatch string or null
function diff(got, want) {
  const eq = (k, a, b) => (a === b ? null : `${k}: wasm=${a} golden=${b}`);
  const checks = [
    eq("x", got.x, want.x), eq("y", got.y, want.y), eq("angle", got.angle, want.angle),
    eq("tilex", got.tilex, want.tilex), eq("tiley", got.tiley, want.tiley),
    eq("anglefrac", got.anglefrac, want.anglefrac), eq("health", got.health, want.health),
    eq("ammo", got.ammo, want.ammo), eq("acount", got.acount, want.acount),
    eq("keys", got.keys, want.keys), eq("score", got.score, want.score),
    eq("weapon", got.weapon, want.weapon), eq("bestweapon", got.bestweapon, want.bestweapon),
    eq("exit", got.exit, want.exit ?? 0), // golden omits exit when 0 (still playing)
  ];
  if (want.rng !== undefined) {
    checks.push(eq("rng", got.rng, want.rng));
    (want.guards ?? []).forEach((g, i) => {
      const a = got.guards[i] ?? {};
      for (const k of ["x", "y", "dir", "st", "hp", "tc", "dist", "cls"])
        checks.push(eq(`guard[${i}].${k}`, a[k], g[k]));
    });
  }
  if (want.doors) want.doors.forEach((d, i) => {
    const a = got.doors[i] ?? {};
    for (const k of ["pos", "act", "tc"]) checks.push(eq(`door[${i}].${k}`, a[k], d[k]));
  });
  if (want.items) want.items.forEach((t, i) => checks.push(eq(`item[${i}]`, got.items[i], t)));
  // pushwalls: the golden omits the array when none triggered; compare count + each record
  const wantPw = want.pwalls ?? [];
  checks.push(eq("pwalls.len", got.pwalls.length, wantPw.length));
  wantPw.forEach((w, i) => {
    const a = got.pwalls[i] ?? {};
    for (const k of ["sx", "sy", "dir", "state", "tile"]) checks.push(eq(`pwalls[${i}].${k}`, a[k], w[k]));
  });
  return checks.filter(Boolean)[0] ?? null;
}

let failed = 0;
for (const sc of SCENARIOS) {
  const golden = readFileSync(join(ROOT, "vectors", `${sc.name}.golden.jsonl`), "utf8")
    .split("\n").filter(Boolean).map((l) => JSON.parse(l));
  const inputs = parseInputs(sc.input);
  const ndoors = golden[0].doors?.length ?? golden.find((g) => g.doors)?.doors.length ?? 0;
  const shouldCheck = (t) => sc.checkpoints === "all" || sc.checkpoints.includes(t);

  setup(sc);
  let bad = null, badTick = -1;
  const check = (tick, want) => {
    if (bad || !shouldCheck(tick)) return;
    const m = diff(decode(readState(), ndoors), want);
    if (m) { bad = m; badTick = tick; }
  };
  check(0, golden[0]); // tic 0: post-spawn
  for (let i = 0; i < inputs.length; i++) {
    const [cx, cy, btns] = inputs[i];
    E.step(cx, cy, btns);
    check(i + 1, golden[i + 1]);
  }

  if (bad) { failed++; console.log(`✘ ${sc.name.padEnd(13)} tic ${badTick}: ${bad}`); }
  else console.log(`✓ ${sc.name.padEnd(13)} ${golden.length} tics match the golden vector`);
}

console.log(failed ? `\n${failed} scenario(s) FAILED` : `\nall ${SCENARIOS.length} scenarios match — the wasm predictor is faithful`);
process.exit(failed ? 1 : 0);
