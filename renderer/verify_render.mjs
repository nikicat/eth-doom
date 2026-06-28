// verify_render.mjs — T3 renderer pixel-match (bit-exact, headless).
//
// The wall raycaster (renderer/wolfrender.c) is the renderer's math-heavy half and was,
// until now, only ever eyeballed. This replays each committed golden vector through the
// SAME wasm renderer the browser blits — but headless under Node, with procedural art
// (npages=0 → the texture-free two-tone fallback) so it's asset-free and deterministic —
// renders the 320x160 wall view for every tic, and hashes the RGBA framebuffer + the
// per-column depth buffer. Pure integer/double math: bit-exact, never flaky.
//
// It covers projection (CalcHeight), the fisheye fix, the grid-DDA cast, flat lighting,
// and the door slide. Texture sampling (the has-art branch) needs committed id art, so
// it stays out of scope here (a local real-VSWAP variant is future work, like T4).
//
//   bash renderer/build_headless.sh          # build renderer/build/wolfrender.mjs
//   node renderer/verify_render.mjs --write   # (re)generate vectors/<name>.render.json
//   node renderer/verify_render.mjs           # assert every frame matches, tic-by-tic
//
// Goldens regenerate when the renderer math OR the canonical sim trajectory changes
// (the camera path is the committed golden-vector pose) — same contract as the
// differential goldens: an intentional change is a deliberate --write + commit.
import { readFileSync, writeFileSync, readdirSync } from "node:fs";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import makeRenderer from "./build/wolfrender.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const WRITE = process.argv.includes("--write");
const VW = 320, VH = 160; // the #view wall canvas (index.html); HUD bar is separate

// Parse "W H" + grid into the renderer's int tilemap, identical to rust/harness
// load_map: '#' = wall (1), 'D'/'d' = door (0x80|doornum, doornum in y-major scan
// order — must match the golden's door indexing), everything else = floor (0).
function loadTiles(mapFile) {
  const lines = readFileSync(join(ROOT, "oracle/maps", mapFile), "utf8").split("\n");
  const [w, h] = lines[0].trim().split(/\s+/).map(Number);
  const tiles = new Int32Array(w * h);
  let doornum = 0;
  for (let y = 0; y < h; y++) {
    const row = lines[1 + y] ?? "";
    for (let x = 0; x < w; x++) {
      const c = row[x] ?? ".";
      // 'P' is a (pushable) wall — rendered static here; the pushwall slide overlay is a
      // deferred client feature, so T3 pins wolfrender's output for the unmoved wall.
      if (c === "#" || c === "P") tiles[y * w + x] = 1;
      else if (c === "D" || c === "d") tiles[y * w + x] = 0x80 | doornum++;
    }
  }
  return { w, h, tiles };
}

const M = await makeRenderer();
const TILEGLOBAL = 65536, U = 64; // 16.16 world coords -> sage units (1 tile = 64)
const PWDX = [0, 1, 0, -1], PWDY = [-1, 0, 1, 0]; // di_north, di_east, di_south, di_west

// Reconstruct the moving pushwall into wolfrender's tile buffer (mirrors Engine
// _applyPushwall, tile-granular): the path resets to base, then crosses c=0..3 vacate
// start..start+(c-1) and place the wall at start+c (+ start+c+1 while sliding). The
// sub-tile slide (pwallpos) is not modeled here — the wall relocates tile-by-tile.
function applyPushwall(pw, base, w, tp) {
  if (!pw) return;
  const set = (k, v) => {
    const i = (pw.sy + PWDY[pw.dir] * k) * w + (pw.sx + PWDX[pw.dir] * k);
    if (i >= 0 && i < base.length) M.HEAP32[tp + i] = v;
  };
  for (let k = 0; k <= 4; k++) set(k, base[(pw.sy + PWDY[pw.dir] * k) * w + (pw.sx + PWDX[pw.dir] * k)]); // reset path
  const c = pw.state === 0 ? 3 : Math.floor(pw.state / 128);
  for (let k = 0; k < c; k++) set(k, 0); // vacated -> floor
  set(c, pw.tile); // leading wall
  if (c < 3) set(c + 1, pw.tile);
}

// Render one golden snapshot's wall view and return the sha1 of (framebuffer + depth).
function frameHash(snap, ndoors) {
  const dfBase = M._doorf_ptr() >> 2;
  for (let i = 0; i < ndoors; i++) {
    const d = snap.doors?.[i] ?? { act: 1, pos: 0 };
    M.HEAPF32[dfBase + i] = d.act === 0 ? 1 : d.pos / 0xffff; // act 0 = DR_OPEN
  }
  const px = (snap.x / TILEGLOBAL) * U, py = (snap.y / TILEGLOBAL) * U;
  M._render(px, py, snap.angle); // angle: integer degrees, east=0 (as the client passes)
  const fb = M._fb_ptr(), zb = M._zb_ptr();
  return createHash("sha1")
    .update(M.HEAPU8.subarray(fb, fb + VW * VH * 4))
    .update(M.HEAPU8.subarray(zb, zb + VW * 4))
    .digest("hex");
}

const scenarios = readdirSync(join(ROOT, "scenarios")).filter((f) => f.endsWith(".json")).sort();
let failed = 0;
for (const f of scenarios) {
  const name = f.replace(/\.json$/, "");
  const cfg = JSON.parse(readFileSync(join(ROOT, "scenarios", f), "utf8"));
  const cps = cfg.checkpoints ?? "all";
  const shouldCheck = (t) => cps === "all" || cps.includes(t);

  const { w, h, tiles } = loadTiles(cfg.map);
  const golden = readFileSync(join(ROOT, "vectors", `${name}.golden.jsonl`), "utf8")
    .split("\n").filter(Boolean).map((l) => JSON.parse(l));
  const ndoors = golden.find((g) => g.doors)?.doors.length ?? 0;

  M._rinit(w, h, VW, VH, 0); // npages 0 -> procedural fallback (asset-free, deterministic)
  const tp = M._tiles_ptr() >> 2;
  const base = Int32Array.from(tiles); // immutable base tilemap (pushwall overlays onto a copy)
  for (let i = 0; i < w * h; i++) M.HEAP32[tp + i] = base[i];

  const frames = golden.map((snap, t) => {
    if (!shouldCheck(t)) return null;
    applyPushwall(snap.pwall, base, w, tp); // reconstruct the moved wall into wolfrender's tiles
    return frameHash(snap, ndoors);
  });

  const goldFile = join(ROOT, "vectors", `${name}.render.json`);
  if (WRITE) {
    writeFileSync(goldFile, JSON.stringify({ vw: VW, vh: VH, frames }) + "\n");
    console.log(`✎ ${name.padEnd(13)} ${frames.filter(Boolean).length} frames written`);
    continue;
  }
  let want;
  try { want = JSON.parse(readFileSync(goldFile, "utf8")); }
  catch { failed++; console.log(`✘ ${name.padEnd(13)} no golden — run --write first`); continue; }

  if (want.vw !== VW || want.vh !== VH) { failed++; console.log(`✘ ${name.padEnd(13)} viewport ${want.vw}x${want.vh} != ${VW}x${VH}`); continue; }
  const bad = frames.findIndex((hsh, t) => hsh !== want.frames[t]);
  if (bad >= 0) { failed++; console.log(`✘ ${name.padEnd(13)} frame ${bad}: got ${frames[bad]?.slice(0, 10)} want ${want.frames[bad]?.slice(0, 10)}`); }
  else console.log(`✓ ${name.padEnd(13)} ${frames.filter(Boolean).length} frames match`);
}

if (WRITE) { console.log("\ngoldens written — review the diff, then commit"); process.exit(0); }
console.log(failed ? `\n${failed} scenario(s) FAILED` : `\nall ${scenarios.length} scenarios match — the wall renderer is pixel-stable`);
process.exit(failed ? 1 : 0);
