import {
  createWalletClient,
  createPublicClient,
  http,
  bytesToHex,
  parseEther,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount, generatePrivateKey } from "viem/accounts";
import { foundry } from "viem/chains";

// forge artifacts (abi + creation bytecode)
import EngineA from "../../contracts/out/Engine.sol/Engine.json";
import MapA from "../../contracts/out/Map.sol/Map.json";
import SessionA from "../../contracts/out/Session.sol/Session.json";

// --- chain wiring (anvil dev account 0) ---
const account = privateKeyToAccount(
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
);
const transport = http("http://127.0.0.1:8545");
const wallet = createWalletClient({ account, chain: foundry, transport });
// low pollingInterval so waitForTransactionReceipt returns fast on anvil (instant mining)
const pub = createPublicClient({ chain: foundry, transport, pollingInterval: 20 });

// ---------------------------------------------------------------------------
// World / map  (positions are 16.16 fixed-point; 1 tile = TILEGLOBAL)
// ---------------------------------------------------------------------------
const TILEGLOBAL = 65536;
const MAX_GUARDS = 12; // cap spawned guards (nearest to the player) for gas/sanity

// The world is dynamic: a real Wolf3D level from /level.json (run map-extract via
// scripts/fetch-shareware.sh) if present, else a built-in test room. `tiles` holds
// the per-tile wall value (0 = floor; 1..89 = a wall texture); the engine only
// needs the 0/1 collision grid (tilesHex).
let W = 16, H = 16;
let tiles = new Uint16Array(W * H); // runtime tilemap: 1..89 wall, 0x80|n door, 0 floor
let spawnTile = { x: 8, y: 8, dir: 1 }; // engine dir: angle = (1-dir)*90 ; 1 = east
let guardTiles: number[][] = [[12, 8]];
let doorList: number[][] = []; // [tilex, tiley, vertical|lock<<1] in doornum order
let itemList: number[][] = []; // [tilex, tiley, itemnumber] bonus items
let areaMap: number[] = []; // per-tile area number (row-major); empty => single area
let levelName = "test room";

const isWall = (v: number) => v >= 1 && v < 90; // 1..89 = solid wall texture
const isDoor = (v: number) => (v & 0x80) !== 0; // 0x80|doornum
// item char -> stat_t bonus number (matches the oracle map loader)
const ITEM_CHARS: Record<string, number> = { a: 14, h: 5, k: 6, t: 10 };

function initTestRoom() {
  // a room split by a N–S wall with a door (7,8); spawn faces it, a guard waits
  // behind. Walk over the ammo (5,8), open the door (E), grab the treasure (9,8)
  // and gold key (10,8). Fire (Space) makes noise that also wakes the guard.
  const MAP = [
    "################", "#......#.......#", "#......#.......#", "#......#.......#",
    "#......#.......#", "#......#.......#", "#......#.......#", "#......#.......#",
    "#....a.D.tk....#", "#......#.......#", "#......#.......#", "#......#.......#",
    "#......#.......#", "#......#.......#", "#......#.......#", "################",
  ];
  W = 16; H = 16;
  tiles = new Uint16Array(W * H);
  doorList = [];
  itemList = [];
  let doornum = 0;
  for (let y = 0; y < H; y++)
    for (let x = 0; x < W; x++) {
      const c = MAP[y][x];
      if (c === "#") tiles[y * W + x] = 1;
      else if (c === "D" || c === "d") {
        tiles[y * W + x] = 0x80 | doornum;
        doorList.push([x, y, c === "D" ? 1 : 0]); // vertical|lock<<1, lock 0
        doornum++;
      } else if (ITEM_CHARS[c] !== undefined) {
        itemList.push([x, y, ITEM_CHARS[c]]);
      } // else floor (0)
    }
  spawnTile = { x: 4, y: 8, dir: 1 };
  guardTiles = [[11, 8, 2, 0], [11, 10, 2, 2], [10, 6, 2, 3], [12, 9, 2, 1]]; // guard/SS/dog/officer
  levelName = "test room (door + item demo)";
}
initTestRoom();

async function loadLevel(): Promise<boolean> {
  try {
    const r = await fetch("/level.json");
    if (!r.ok) return false;
    const L = await r.json();
    W = L.w; H = L.h;
    tiles = Uint16Array.from(L.tiles as number[]);
    spawnTile = { x: L.spawn.x, y: L.spawn.y, dir: L.spawn.dir };
    levelName = L.name ?? "level";
    doorList = (L.doors as number[][] | undefined) ?? [];
    itemList = (L.items as number[][] | undefined) ?? [];
    areaMap = (L.areas as number[] | undefined) ?? []; // per-tile area numbers (sound localization)
    guardTiles = (L.guards as number[][])
      .map(([x, y, dir, cls]) => ({ x, y, dir: dir ?? 0, cls: cls ?? 0, d: Math.hypot(x - L.spawn.x, y - L.spawn.y) }))
      .sort((a, b) => a.d - b.d)
      .slice(0, MAX_GUARDS)
      .map((g) => [g.x, g.y, g.dir, g.cls]);
    return true;
  } catch {
    return false;
  }
}

// runtime tilemap deployed to Map.sol (raw values: wall 1..89, door 0x80|n, floor 0)
function tilesHex(): Hex {
  const t = new Uint8Array(W * H);
  for (let i = 0; i < t.length; i++) t[i] = tiles[i] & 0xff;
  return bytesToHex(t);
}
// enemies blob: 4 bytes each (tilex, tiley, dir, class) — engine spawns them dormant
function guardsHex(): Hex {
  const b = new Uint8Array(guardTiles.length * 4);
  guardTiles.forEach(([x, y, dir, cls], i) => {
    b[i * 4] = x; b[i * 4 + 1] = y; b[i * 4 + 2] = (dir ?? 0) & 3; b[i * 4 + 3] = cls ?? 0;
  });
  return bytesToHex(b);
}
// doors blob: 3 bytes each (tilex, tiley, vertical|lock<<1), in doornum order
function doorsHex(): Hex {
  const b = new Uint8Array(doorList.length * 3);
  doorList.forEach(([x, y, pk], i) => { b[i * 3] = x; b[i * 3 + 1] = y; b[i * 3 + 2] = pk ?? 0; });
  return bytesToHex(b);
}
// items blob: 3 bytes each (tilex, tiley, itemnumber)
function itemsHex(): Hex {
  const b = new Uint8Array(itemList.length * 3);
  itemList.forEach(([x, y, n], i) => { b[i * 3] = x; b[i * 3 + 1] = y; b[i * 3 + 2] = n; });
  return bytesToHex(b);
}
// area-map blob: w*h area bytes (or empty for a single-area level)
function areasHex(): Hex {
  if (areaMap.length === 0) return "0x";
  return bytesToHex(Uint8Array.from(areaMap.map((a) => a & 0xff)));
}
// per-doornum open fraction (0 closed .. 1 open), refreshed each frame from state
const doorOpenFrac = new Float64Array(64);

async function deploy(art: any, args: any[]): Promise<Address> {
  const hash = await wallet.deployContract({
    abi: art.abi,
    bytecode: art.bytecode.object as Hex,
    args,
  });
  const r = await pub.waitForTransactionReceipt({ hash });
  return r.contractAddress!;
}

// --- client-side prediction (M4) -------------------------------------------------
// `oracle/build_wasm.sh` compiles the SAME carved C as sim_oracle to wasm. We drive
// it through the SAME spawn the Map/Engine got, then predict each tick locally for
// instant feedback while the burner submits to the chain in the background. Because
// that C is differential-proven equal to the Engine, the predictor's packed state is
// byte-identical to Session.getState() — reconciliation is a plain hex compare.
// Falls back to chain-only if /predict.wasm isn't built.
type Predictor = { step: (cx: number, cy: number, b: number) => void; read: () => Hex };

async function loadPredictor(): Promise<Predictor | null> {
  try {
    const r = await fetch("/predict.wasm");
    if (!r.ok) return null;
    const { instance } = await WebAssembly.instantiate(await r.arrayBuffer());
    const E = instance.exports as any;
    const mem = E.memory as WebAssembly.Memory;
    // setup: same order as the Map blobs → same doornum / item index / actor order
    E.reset();
    for (let i = 0; i < areaMap.length; i++) {
      if (areaMap[i]) E.set_area(i % W, (i / W) | 0, areaMap[i]); // areas before doors (SpawnDoor fixup)
    }
    for (let i = 0; i < W * H; i++) {
      const v = tiles[i] & 0xff;
      if (v && !(v & 0x80)) E.set_wall(i % W, (i / W) | 0); // wall (door tiles via add_door)
    }
    for (const [x, y, pk] of doorList) E.add_door(x, y, (pk ?? 0) & 1, (pk ?? 0) >> 1);
    for (const [x, y, n] of itemList) E.add_item(x, y, n);
    E.init_actors();
    E.add_player(spawnTile.x, spawnTile.y, spawnTile.dir);
    for (const [x, y, dir, cls] of guardTiles) E.add_enemy(cls ?? 0, x, y, dir ?? 0);
    const read = (): Hex => bytesToHex(new Uint8Array(mem.buffer, E.state_ptr(), E.read_state()));
    return { step: (cx, cy, b) => E.step(cx, cy, b), read };
  } catch (e) {
    console.warn("predictor unavailable:", e);
    return null;
  }
}

// --- wasm wall renderer (M4, optional) -------------------------------------------
// `renderer/build.sh` compiles renderer/wolfrender.c (id's WL_DRAW.C wall math + a
// portable grid-DDA ray cast) to wasm via Emscripten. It renders the textured wall
// view + per-column depth into wasm memory each frame; we blit the framebuffer and
// read the depth buffer to occlude sprites. Sprites / gun / HUD stay in TS on top.
// Falls back to the TS raycaster if /wolfrender.mjs isn't built (or no id textures).
type WallRenderer = { render: (px: number, py: number, pa: number, doors: Door[]) => void };

async function loadWasmRenderer(): Promise<WallRenderer | null> {
  if (!assets) return null; // needs real VSWAP wall textures; procedural uses the TS path
  try {
    // Load the Emscripten ES6 module via a blob URL so Vite's dev transform pipeline
    // leaves it alone; locateFile points the .wasm fetch at /wolfrender.wasm (public).
    const r = await fetch("/wolfrender.mjs");
    if (!r.ok) return null;
    const blobUrl = URL.createObjectURL(new Blob([await r.text()], { type: "text/javascript" }));
    const mod: any = await import(/* @vite-ignore */ blobUrl);
    const M = await mod.default({ locateFile: (p: string) => "/" + p });
    const NPAGES = 220; // covers wall pages (≤ (89-1)*2+1) + the door page (98)
    M._rinit(W, H, VW, VH, NPAGES);
    // tiles (int32, once)
    const tp = M._tiles_ptr() >> 2;
    for (let i = 0; i < W * H; i++) M.HEAP32[tp + i] = tiles[i] & 0xff;
    // wall textures (RGBA 64x64 per page, once) from the decoded VSWAP canvases
    const texBase = M._tex_ptr(), okBase = M._texok_ptr();
    const tmp = document.createElement("canvas"); tmp.width = 64; tmp.height = 64;
    const tctx = tmp.getContext("2d", { willReadFrequently: true })!;
    for (const [page, canvas] of assets.walls) {
      if (page < 0 || page >= NPAGES) continue;
      tctx.clearRect(0, 0, 64, 64);
      tctx.drawImage(canvas, 0, 0, 64, 64);
      M.HEAPU8.set(tctx.getImageData(0, 0, 64, 64).data, texBase + page * 64 * 64 * 4);
      M.HEAPU8[okBase + page] = 1;
    }
    const fbBase = M._fb_ptr(), zbBase = M._zb_ptr() >> 2, dfBase = M._doorf_ptr() >> 2;
    const fbLen = VW * VH * 4;
    return {
      render(px, py, pa, doors) {
        for (let i = 0; i < doors.length; i++)
          M.HEAPF32[dfBase + i] = doors[i].action === 0 ? 1 : doors[i].position / 0xffff;
        M._render(px, py, pa);
        // blit the framebuffer (a view onto wasm memory — no growth after init)
        vctx.putImageData(new ImageData(new Uint8ClampedArray(M.HEAPU8.buffer, fbBase, fbLen), VW, VH), 0, 0);
        for (let c = 0; c < VW; c++) zbuf[c] = M.HEAPF32[zbBase + c]; // depth for sprites
      },
    };
  } catch (e) {
    console.warn("wasm renderer unavailable:", e);
    return null;
  }
}
let wall: WallRenderer | null = null;

// ---------------------------------------------------------------------------
// packed-state decoder  (must match Engine.sol _pack layout)
// ---------------------------------------------------------------------------
function words(hex: string): bigint[] {
  const h = hex.slice(2);
  const out: bigint[] = [];
  for (let i = 0; i < h.length / 64; i++)
    out.push(BigInt("0x" + h.slice(i * 64, (i + 1) * 64)));
  return out;
}
const fld = (w: bigint, sh: number, bits: number) =>
  Number((w >> BigInt(sh)) & ((1n << BigInt(bits)) - 1n));
function sfld(w: bigint, sh: number, bits: number): number {
  let v = (w >> BigInt(sh)) & ((1n << BigInt(bits)) - 1n);
  if (v & (1n << BigInt(bits - 1))) v -= 1n << BigInt(bits);
  return Number(v);
}

type Guard = { x: number; y: number; dir: number; state: number; hp: number; obclass: number };
type Door = { action: number; position: number };
type State = {
  rndindex: number;
  player: {
    x: number; y: number; angle: number; tilex: number; tiley: number;
    health: number; ammo: number; attackcount: number; keys: number; score: number;
  };
  doors: Door[];
  itemsTaken: boolean[];
  guards: Guard[];
};

function decode(hex: string): State {
  const w = words(hex);
  const header = w[0];
  const n = fld(header, 8, 8);
  const ad = fld(header, 16, 8); // active (non-closed) doors stored
  const ni = fld(header, 24, 16);
  const iw = ni === 0 ? 0 : Math.ceil(ni / 256);
  const pw = w[1];
  // every door defaults closed; apply the stored active words by their doornum
  const doors: Door[] = Array.from({ length: doorList.length }, () => ({ action: 1, position: 0 }));
  for (let i = 0; i < ad; i++) {
    const d = w[2 + i]; // door word: action@0, ticcount@16, position@32, doornum@48
    doors[fld(d, 48, 8)] = { action: fld(d, 0, 8), position: fld(d, 32, 16) };
  }
  const itemsTaken: boolean[] = []; // bitmask words after the active doors
  for (let i = 0; i < ni; i++) {
    const bits = w[2 + ad + Math.floor(i / 256)];
    itemsTaken.push(((bits >> BigInt(i % 256)) & 1n) === 1n);
  }
  const guards: Guard[] = [];
  for (let i = 0; i < n; i++) {
    const a = w[2 + ad + iw + i];
    guards.push({
      x: sfld(a, 0, 32),
      y: sfld(a, 32, 32),
      dir: fld(a, 80, 8),
      state: fld(a, 88, 8),
      hp: sfld(a, 144, 16),
      obclass: fld(a, 168, 8),
    });
  }
  return {
    rndindex: fld(header, 0, 8),
    player: {
      x: sfld(pw, 0, 32),
      y: sfld(pw, 32, 32),
      angle: fld(pw, 64, 16),
      tilex: fld(pw, 112, 8),
      tiley: fld(pw, 120, 8),
      health: sfld(pw, 128, 16),
      ammo: sfld(pw, 144, 16),
      attackcount: sfld(pw, 160, 16),
      keys: fld(pw, 184, 8),
      score: fld(pw, 192, 32),
    },
    doors,
    itemsTaken,
    guards,
  };
}

// guard state IDs (gstates[] order in wl_actor.c)
const S_STAND = 0, S_CHASE1 = 1, S_CHASE4 = 6, S_SHOOT1 = 7, S_SHOOT3 = 9;
const S_DIE1 = 10, S_DIE4 = 13, S_PAIN = 14, S_PAIN1 = 15;
const GUARDOBJ = 3, OFFICEROBJ = 4, SSOBJ = 5, DOGOBJ = 6; // obclass values (id's classtype enum)

// M5.3: per-class enemy sprite frame tables — absolute VSWAP sprite indices read from id's
// WL_DEF.H sprite enum. Shareware = non-SPEAR build (48 statics), so SPR_GRD_S_1 = 50. Each
// class: stand (8 rotations; the dog has no stand frames → reuses its walk frame), walk
// (4 frames × 8 rotations), shoot (the dog's is the JUMP/bite frames), pain 1/2, the die
// sequence (canonical DIE_1..), and the dead corpse. The officer and mutant aren't episode-1
// enemies, so their VSWAP pages are sparse in the shareware — officer frames fall back to the
// real guard sprite at draw time (registered .WL6 data carries them and they load on their own).
type EnemyFrames = { stand: number; walk: number; shoot: number; pain1: number; pain2: number; die: number[]; dead: number };
const NF = -1; // frame not present for this class
const ENEMY_FRAMES: Record<number, EnemyFrames> = {
  [GUARDOBJ]:   { stand: 50,  walk: 58,  shoot: 96,  pain1: 90,  pain2: 94,  die: [91, 92, 93],         dead: 95 },
  [DOGOBJ]:     { stand: NF,  walk: 99,  shoot: 135, pain1: NF,  pain2: NF,  die: [131, 132, 133],      dead: 134 },
  [SSOBJ]:      { stand: 138, walk: 146, shoot: 184, pain1: 178, pain2: 182, die: [179, 180, 181],      dead: 183 },
  [OFFICEROBJ]: { stand: 238, walk: 246, shoot: 285, pain1: 278, pain2: 282, die: [279, 280, 281, 283], dead: 284 },
};
// SS (16..37), dog (38..53) and officer (54..70) states mirror the guard graph;
// fold them onto the guard state ids for rendering/category checks.
function rs(s: number): number {
  if (s < 16) return s;
  if (s === 16) return S_STAND; // ssstand
  if (s <= 22) return s - 16; // sschase 17..22 -> chase 1..6
  if (s <= 31) return S_SHOOT1 + ((s - 23) % 3); // ssshoot 23..31 -> shoot 7..9
  if (s <= 35) return S_DIE1 + (s - 32); // ssdie 32..35 -> die 10..13
  if (s <= 37) return s === 36 ? S_PAIN : S_PAIN1; // sspain
  if (s === 38) return S_STAND; // dogstand
  if (s <= 44) return s - 38; // dogchase 39..44 -> chase 1..6
  if (s <= 49) return S_SHOOT1; // dogjump (bite) -> a firing frame
  if (s <= 52) return S_DIE1 + (s - 50); // dogdie 50..52 -> die 10..12
  if (s === 53) return S_DIE4; // dogdead
  if (s === 54) return S_STAND; // ofcstand
  if (s <= 60) return s - 54; // ofcchase 55..60 -> chase 1..6
  if (s <= 63) return S_SHOOT1 + (s - 61); // ofcshoot 61..63 -> shoot 7..9
  if (s <= 68) return Math.min(S_DIE4, S_DIE1 + (s - 64)); // ofcdie 64..68 -> die 10..13
  return s === 69 ? S_PAIN : S_PAIN1; // ofcpain
}
const isChasing = (s: number) => { const r = rs(s); return r >= S_CHASE1 && r <= S_CHASE4; };
const isFiring = (s: number) => { const r = rs(s); return r >= S_SHOOT1 && r <= S_SHOOT3; };
const isDead = (s: number) => { const r = rs(s); return r >= S_DIE1 && r <= S_DIE4; };
const isPain = (s: number) => { const r = rs(s); return r === S_PAIN || r === S_PAIN1; };
function stateName(s: number): string {
  if (rs(s) === S_STAND) return "stand";
  if (isChasing(s)) return "chasing";
  if (isFiring(s)) return "FIRING";
  if (isDead(s)) return "dead";
  if (isPain(s)) return "pain";
  return "?";
}

// ---------------------------------------------------------------------------
// canvases
// ---------------------------------------------------------------------------
const view = document.getElementById("view") as HTMLCanvasElement;
const vctx = view.getContext("2d")!;
const VW = view.width, VH = view.height;

// M5: the Wolf3D play border — a beveled gray frame around the 3D viewport, painted
// over the outer BORDER px of the view each frame (DrawPlayBorder in WL_DRAW.C draws a
// raised outer + sunken inner bevel in the border gray). Drawn last so it stays crisp
// over sprites / flashes / the death fade.
const BORDER = 7;
function drawBorder() {
  const w = VW, h = VH, b = BORDER;
  vctx.fillStyle = "#a8a8a8"; // frame fill
  vctx.fillRect(0, 0, w, b); vctx.fillRect(0, h - b, w, b);
  vctx.fillRect(0, 0, b, h); vctx.fillRect(w - b, 0, b, h);
  // raised outer bevel (light top/left, dark bottom/right)
  vctx.fillStyle = "#e0e0e0"; vctx.fillRect(0, 0, w, 1); vctx.fillRect(0, 0, 1, h);
  vctx.fillStyle = "#585858"; vctx.fillRect(0, h - 1, w, 1); vctx.fillRect(w - 1, 0, 1, h);
  // sunken inner bevel around the viewport opening (dark top/left, light bottom/right)
  vctx.fillStyle = "#585858";
  vctx.fillRect(b - 1, b - 1, w - 2 * b + 1, 1); vctx.fillRect(b - 1, b - 1, 1, h - 2 * b + 1);
  vctx.fillStyle = "#e0e0e0";
  vctx.fillRect(b - 1, h - b, w - 2 * b + 1, 1); vctx.fillRect(w - b, b - 1, 1, h - 2 * b + 1);
}

const hudC = document.getElementById("hud") as HTMLCanvasElement;
const hctx = hudC.getContext("2d")!;

const mapC = document.getElementById("map") as HTMLCanvasElement;
const mctx = mapC.getContext("2d")!;

const dbg = document.getElementById("dbg")!;

// ---------------------------------------------------------------------------
// first-person raycaster
//
// DDA wall march transliterated from 3DSage's MIT-licensed raycaster
// (github.com/3DSage/OpenGL-Raycaster_v1, drawRays2D). It works in "sage units"
// where 1 tile = 64; our positions are 16.16 fixed-point, so we scale by U/TILEGLOBAL.
// The angle convention matches ours exactly: degrees, east=0, dir=(cos a, -sin a),
// screen-y points south — so the trig carries over unchanged.
// ---------------------------------------------------------------------------
const U = 64; // sage tile size
const DR = Math.PI / 180;
const FOV = 60;
const PROJ = VW / 2 / Math.tan((FOV / 2) * DR); // projection-plane distance (px)
const toU = (fp: number) => (fp / TILEGLOBAL) * U;
const fixAng = (a: number) => ((a % 360) + 360) % 360;
const normDeg = (a: number) => ((((a + 180) % 360) + 360) % 360) - 180;

const zbuf = new Float64Array(VW); // perpendicular wall distance per column (sage units)

/**
 * Cast one ray from (px,py) at world angle `ra` (deg). Returns the nearest wall hit:
 * its distance, whether it's a vertical (E/W-facing) grid line, and the texture
 * column 0..63 where the ray struck the wall (for texture mapping).
 */
// Does the tile at (mx,my) stop the ray here? Walls always do; a door's sliding
// panel covers fraction (1-open) of the cell face (`frac` 0..1 along that face),
// so the receded part is see-through — the ray passes into the room beyond.
function rayBlocked(v: number, frac: number): boolean {
  if (isWall(v)) return true;
  // door slides into a wall pocket: solid where frac >= open (panel shrinking from the
  // left), see-through before it; the texture rides the panel (offset by open below).
  if (isDoor(v)) return frac >= doorOpenFrac[v & 0x7f];
  return false;
}

function castRay(px: number, py: number, ra: number): { dist: number; vertical: boolean; tex: number; tile: number } {
  ra = fixAng(ra);
  const cs = Math.cos(ra * DR), sn = Math.sin(ra * DR);
  let rx: number, ry: number, xo: number, yo: number, dof: number;
  let disV = 1e9, disH = 1e9;
  let vy = py, hx = px; // wall-hit coords used for the texture column
  let vtile = 1, htile = 1; // wall value at the hit (for texture selection)
  // step across the whole map, not a tiny-map's 8 (8 dropped any wall >8 tiles away)
  const maxdof = Math.max(W, H) + 1;

  // --- vertical grid lines (x = k*U) ---
  let Tan = Math.tan(ra * DR);
  dof = 0;
  if (cs > 0.001) { rx = Math.floor(px / U) * U + U; ry = (px - rx) * Tan + py; xo = U; yo = -xo * Tan; }
  else if (cs < -0.001) { rx = Math.floor(px / U) * U - 0.0001; ry = (px - rx) * Tan + py; xo = -U; yo = -xo * Tan; }
  else { rx = px; ry = py; dof = maxdof; xo = 0; yo = 0; }
  while (dof < maxdof) {
    const mx = Math.floor(rx / U), my = Math.floor(ry / U), mp = my * W + mx;
    const frac = ry / U - Math.floor(ry / U); // door panel slides along Y for a vertical face
    if (mx >= 0 && mx < W && my >= 0 && my < H && rayBlocked(tiles[mp], frac)) { dof = maxdof; disV = cs * (rx - px) - sn * (ry - py); vy = ry; vtile = tiles[mp]; }
    else { rx += xo; ry += yo; dof++; }
  }

  // --- horizontal grid lines (y = k*U) ---
  dof = 0;
  Tan = 1 / Tan;
  if (sn > 0.001) { ry = Math.floor(py / U) * U - 0.0001; rx = (py - ry) * Tan + px; yo = -U; xo = -yo * Tan; }
  else if (sn < -0.001) { ry = Math.floor(py / U) * U + U; rx = (py - ry) * Tan + px; yo = U; xo = -yo * Tan; }
  else { rx = px; ry = py; dof = maxdof; xo = 0; yo = 0; }
  while (dof < maxdof) {
    const mx = Math.floor(rx / U), my = Math.floor(ry / U), mp = my * W + mx;
    const frac = rx / U - Math.floor(rx / U); // door panel slides along X for a horizontal face
    if (mx >= 0 && mx < W && my >= 0 && my < H && rayBlocked(tiles[mp], frac)) { dof = maxdof; disH = cs * (rx - px) - sn * (ry - py); hx = rx; htile = tiles[mp]; }
    else { rx += xo; ry += yo; dof++; }
  }

  if (disV < disH) {
    let f = vy / U; f -= Math.floor(f); // hit on a vertical face → texture runs along Y
    if (isDoor(vtile)) f -= doorOpenFrac[vtile & 0x7f]; // texture rides the sliding panel
    return { dist: disV, vertical: true, tex: f * 64, tile: vtile };
  }
  let f = hx / U; f -= Math.floor(f); // horizontal face → texture runs along X
  if (isDoor(htile)) f -= doorOpenFrac[htile & 0x7f];
  return { dist: disH, vertical: false, tex: f * 64, tile: htile };
}

// ---------------------------------------------------------------------------
// runtime assets — authentic Wolf3D textures/sprites decoded by `rust/wl-extract`
// from a user-provided VSWAP.WL1 into /wolf/*.png. Never committed; absent by
// default, in which case the renderer falls back to the procedural art below.
// ---------------------------------------------------------------------------
// player pistol viewmodel frames (sprite indices in this shareware's VSWAP, found
// empirically: 425 ready, 426 the muzzle-flash fire frame, 427/428 recoil).
const PISTOL_READY = 425;
const PISTOL_FIRE = [426, 427, 428];
// Wolf3D wall texture page for tile value v: vertical (N/S) face (v-1)*2, horizontal +1
const wallPage = (v: number, vertical: boolean) => (Math.max(1, v) - 1) * 2 + (vertical ? 0 : 1);
const DOOR_PAGE = 98; // VSWAP door wall texture (falls back to a color if absent)
type Assets = {
  walls: Map<number, HTMLCanvasElement>; // wall texture pages, keyed by VSWAP page index
  sprites: Map<number, HTMLCanvasElement>;
  pics: Map<number, HTMLCanvasElement>; // VGAGRAPH HUD pics (status bar, digits, faces)
};
let assets: Assets | null = null;
// VGAGRAPH pic indices (this shareware's set): status bar 92, white digits 105–114
// (N_0PIC…N_9PIC), BJ faces 115–138 (FACE1APIC + 3·level + look).
const PIC_STATUSBAR = 92, PIC_DIGIT0 = 105, PIC_FACE1A = 115;

const tmp = document.createElement("canvas");
tmp.width = tmp.height = 64;
const tmpCtx = tmp.getContext("2d")!;
tmpCtx.imageSmoothingEnabled = false;

function loadImg64(url: string): Promise<HTMLCanvasElement | null> {
  return new Promise((res) => {
    const img = new Image();
    img.onload = () => {
      const c = document.createElement("canvas");
      c.width = c.height = 64;
      const cx = c.getContext("2d")!;
      cx.imageSmoothingEnabled = false;
      cx.drawImage(img, 0, 0, 64, 64);
      res(c);
    };
    img.onerror = () => res(null);
    img.src = url;
  });
}

// load a pic at its native dimensions (VGAGRAPH pics vary in size)
function loadImgRaw(url: string): Promise<HTMLCanvasElement | null> {
  return new Promise((res) => {
    const img = new Image();
    img.onload = () => {
      const c = document.createElement("canvas");
      c.width = img.naturalWidth;
      c.height = img.naturalHeight;
      const cx = c.getContext("2d")!;
      cx.imageSmoothingEnabled = false;
      cx.drawImage(img, 0, 0);
      res(c);
    };
    img.onerror = () => res(null);
    img.src = url;
  });
}

async function loadAssets(): Promise<Assets | null> {
  let manifest: any;
  try {
    const r = await fetch("/wolf/manifest.json");
    if (!r.ok) return null;
    manifest = await r.json();
  } catch {
    return null;
  }
  if (!manifest?.sprites_written) return null;
  const p3 = (n: number) => String(n).padStart(3, "0");
  // load only the wall texture pages this level actually uses (both faces per tile)
  const walls = new Map<number, HTMLCanvasElement>();
  const pages = new Set<number>([0, 1]);
  for (const v of tiles) if (isWall(v)) { pages.add(wallPage(v, true)); pages.add(wallPage(v, false)); }
  if (doorList.length) pages.add(DOOR_PAGE);
  for (const p of pages) {
    const c = await loadImg64(`/wolf/wall_${p3(p)}.png`);
    if (c) walls.set(p, c);
  }
  if (walls.size === 0) return null;
  const sprites = new Map<number, HTMLCanvasElement>();
  const need = [PISTOL_READY, ...PISTOL_FIRE]; // player pistol
  // every enemy class's frames (guard/dog/SS/officer) derived from the per-class tables;
  // absent pages (officer/mutant aren't in shareware) 404 → skipped. Loaded in parallel.
  for (const f of Object.values(ENEMY_FRAMES)) {
    if (f.stand >= 0) for (let i = 0; i < 8; i++) need.push(f.stand + i);
    for (let i = 0; i < 32; i++) need.push(f.walk + i);
    for (let i = 0; i < 3; i++) need.push(f.shoot + i);
    if (f.pain1 >= 0) need.push(f.pain1);
    if (f.pain2 >= 0) need.push(f.pain2);
    for (const d of f.die) need.push(d);
    need.push(f.dead);
  }
  const uniq = [...new Set(need)];
  const loaded = await Promise.all(uniq.map((i) => loadImg64(`/wolf/sprite_${p3(i)}.png`)));
  uniq.forEach((i, k) => { if (loaded[k]) sprites.set(i, loaded[k]!); });
  // HUD pics: status bar + digits (105–114) + BJ faces (115–138)
  const pics = new Map<number, HTMLCanvasElement>();
  const picIds = [PIC_STATUSBAR];
  for (let i = PIC_DIGIT0; i <= 114; i++) picIds.push(i);
  for (let i = PIC_FACE1A; i <= 138; i++) picIds.push(i);
  for (const i of picIds) {
    const c = await loadImgRaw(`/wolf/pic_${p3(i)}.png`);
    if (c) pics.set(i, c);
  }
  return { walls, sprites, pics };
}

// our guard `state`+`dir` → Wolf3D sprite index (enum order; SPR_GRD_S_1 = 50).
// directional frames use CalcRotate (WL_DRAW.C): rot = ((angTo-180) - dir*45 + 22.5)/45.
function calcRotate(g: Guard, angTo: number): number {
  const dir = g.dir >= 0 && g.dir < 8 ? g.dir : 0;
  let a = angTo - 180 - dir * 45 + 22.5;
  a = ((a % 360) + 360) % 360;
  return Math.floor(a / 45) & 7;
}
function enemySprite(obclass: number, g: Guard, angTo: number): number {
  const f = ENEMY_FRAMES[obclass] ?? ENEMY_FRAMES[GUARDOBJ];
  const s = rs(g.state); // rs() folds each class's state graph onto the canonical guard ids
  if (isFiring(s)) return f.shoot + (s - S_SHOOT1); // SHOOT1..3 (dog: JUMP, rs folds bite→SHOOT1)
  if (isPain(s)) { const p = s === S_PAIN ? f.pain1 : f.pain2; return p >= 0 ? p : f.walk; }
  if (isDead(s)) { const k = s - S_DIE1; return k < f.die.length ? f.die[k] : f.dead; }
  const rot = calcRotate(g, angTo);
  if (s === S_STAND) return (f.stand >= 0 ? f.stand : f.walk) + rot; // dog has no stand → W1
  const wf = [0, 0, 1, 2, 2, 3][s - S_CHASE1] ?? 0; // chase1,1s,2,3,3s,4 → walk W1..W4
  return f.walk + wf * 8 + rot;
}

/** Draw a guard using a real Wolf3D sprite frame, depth-tested per column. */
function drawGuardSprite(px: number, py: number, pa: number, g: Guard, clock: number, A: Assets) {
  const dx = toU(g.x) - px, dy = toU(g.y) - py;
  const dist = Math.hypot(dx, dy);
  if (dist < 1) return;
  const angTo = Math.atan2(-dy, dx) / DR;
  const rel = normDeg(angTo - pa);
  if (Math.abs(rel) > FOV / 2 + 30) return;
  const perp = dist * Math.cos(rel * DR);
  if (perp < 1) return;
  // real per-class frame; if it's absent (officer art isn't in the shareware VSWAP) fall
  // back to the real guard sprite, then to procedural — so an officer still renders as a
  // Wolf3D soldier rather than a colored box.
  let img = A.sprites.get(enemySprite(g.obclass, g, angTo));
  if (!img && g.obclass !== GUARDOBJ) img = A.sprites.get(enemySprite(GUARDOBJ, g, angTo));
  if (!img) { drawGuard(px, py, pa, g, clock); return; } // still missing → procedural

  const cx = VW / 2 - (rel / (FOV / 2)) * (VW / 2);
  const wallH = (U / perp) * PROJ;
  const floorY = VH / 2 + wallH / 2;
  const sprH = wallH, sprW = wallH; // 64x64 sprite fills the tile cube
  const top = floorY - sprH;
  const left = cx - sprW / 2;

  // M5: flat-lit — Wolf3D doesn't distance-shade sprites; draw at full brightness.
  const src: HTMLCanvasElement = img;

  const x0 = Math.max(0, Math.floor(left)), x1 = Math.min(VW - 1, Math.ceil(left + sprW));
  for (let xs = x0; xs <= x1; xs++) {
    if (perp > zbuf[xs] + 0.5) continue; // occluded by a nearer wall
    const u = (xs - left) / sprW;
    if (u < 0 || u >= 1) continue;
    const sx = Math.min(63, Math.floor(u * 64));
    vctx.drawImage(src, sx, 0, 1, 64, xs, top, 1, sprH);
  }
}

// procedural guard sprite (16x24), sampled per column with the wall z-buffer.
// faithful to Wolf3D's scaled sprite columns; asset-free (no id artwork shipped).
const GUARD_ART = [
  "................",
  ".....oooo.......",
  "....ohhhho......",
  "....hhhhhh......",
  "...offffffo.....",
  "...ofeffefo.....",
  "...offffffo.....",
  "....offffo......",
  "....ouuuuo......",
  "..oouuuuuuoo....",
  ".ouuuuuuuuuuo...",
  ".gouuuuuuuuuo...",
  ".ggouuuuuuuuo...",
  "..ouuuuuuuuo....",
  "..ouuuuuuuuo....",
  "..ouuuuuuuuo....",
  "..obuuuuuubo....",
  "..ouuuuuuuuo....",
  "...ouuoouuo.....",
  "...ouuoouuo.....",
  "...ouuoouuo.....",
  "...obboobbo.....",
  "...obboobbo.....",
  "................",
];
const TEXW = 16, TEXH = 24;
type RGB = [number, number, number];

function guardPalette(g: Guard): Record<string, RGB | null> {
  const ss = g.obclass === SSOBJ, dog = g.obclass === DOGOBJ, ofc = g.obclass === OFFICEROBJ;
  // SS blue, dog brown, officer white-tan, guard tan-gray
  let uni: RGB = dog ? [122, 78, 42] : ss ? [40, 58, 165] : ofc ? [205, 200, 185] : [96, 82, 58];
  if (isFiring(g.state)) uni = dog ? [150, 96, 52] : ss ? [60, 80, 205] : ofc ? [230, 226, 210] : [128, 112, 80];
  if (isPain(g.state)) uni = [200, 200, 210];
  return {
    ".": null,
    o: [20, 17, 13],
    h: dog ? [86, 54, 28] : ss ? [30, 42, 110] : ofc ? [150, 146, 130] : [70, 60, 44],
    f: dog ? [150, 100, 56] : [216, 168, 120],
    e: [26, 20, 16],
    u: uni,
    b: [32, 24, 16],
    g: [107, 107, 107],
  };
}

function drawGuard(px: number, py: number, pa: number, g: Guard, clock: number) {
  const dx = toU(g.x) - px, dy = toU(g.y) - py;
  const dist = Math.hypot(dx, dy);
  if (dist < 1) return;
  const angTo = Math.atan2(-dy, dx) / DR; // CCW from east, y-down corrected
  const rel = normDeg(angTo - pa);
  if (Math.abs(rel) > FOV / 2 + 25) return; // off-screen
  const perp = dist * Math.cos(rel * DR);
  if (perp < 1) return;

  const cx = VW / 2 - (rel / (FOV / 2)) * (VW / 2); // screen x of sprite center
  const wallH = (U / perp) * PROJ;
  const floorY = VH / 2 + wallH / 2; // where this depth meets the floor

  // dead guard: a flat corpse mark on the floor (no standing sprite)
  if (isDead(g.state)) {
    const w = wallH * 0.5;
    vctx.fillStyle = "rgba(90,20,22,0.85)";
    vctx.beginPath();
    vctx.ellipse(cx, floorY - wallH * 0.04, w, wallH * 0.09, 0, 0, Math.PI * 2);
    vctx.fill();
    return;
  }

  const spriteH = wallH * 0.86;
  const spriteW = spriteH * (TEXW / TEXH);
  const top = floorY - spriteH;
  const left = cx - spriteW / 2;
  const colW = spriteW / TEXW, rowH = spriteH / TEXH;
  const shade = 1; // M5: flat-lit (no distance shading), asset-free fallback
  const pal = guardPalette(g);

  for (let tx = 0; tx < TEXW; tx++) {
    const colX = left + tx * colW;
    const cc = Math.floor(colX + colW / 2);
    if (cc < 0 || cc >= VW) continue;
    if (perp > zbuf[cc] + 0.5) continue; // occluded by a nearer wall
    for (let ty = 0; ty < TEXH; ty++) {
      const c = pal[GUARD_ART[ty][tx]];
      if (!c) continue;
      vctx.fillStyle = `rgb(${(c[0] * shade) | 0},${(c[1] * shade) | 0},${(c[2] * shade) | 0})`;
      vctx.fillRect(Math.floor(colX), Math.floor(top + ty * rowH), Math.ceil(colW), Math.ceil(rowH));
    }
  }

  // muzzle flash while the guard is in its shoot frames
  if (isFiring(g.state) && (clock % 160 < 90)) {
    const mx = left + 1.5 * colW, my = top + 11.5 * rowH;
    vctx.fillStyle = "rgba(255,225,120,0.95)";
    vctx.beginPath();
    vctx.arc(mx, my, Math.max(2, spriteW * 0.12), 0, Math.PI * 2);
    vctx.fill();
  }
}

// bonus item billboard colour by stat_t category
function itemColor(n: number): string {
  if (n >= 6 && n <= 9) return "#f4d03f"; // key — gold
  if (n >= 10 && n <= 13) return "#48d1cc"; // treasure — cyan
  if (n === 3 || n === 4 || n === 5 || n === 18 || n === 19) return "#6cc6ff"; // health — blue
  return "#f1c40f"; // ammo — yellow
}

// draw not-yet-taken bonus items as small floor-standing markers, wall-occluded
function drawItems(px: number, py: number, pa: number, s: State) {
  for (let i = 0; i < itemList.length; i++) {
    if (s.itemsTaken[i]) continue;
    const [tx, ty, n] = itemList[i];
    const dx = (tx + 0.5) * U - px, dy = (ty + 0.5) * U - py;
    const dist = Math.hypot(dx, dy);
    if (dist < 1) continue;
    const rel = normDeg(Math.atan2(-dy, dx) / DR - pa);
    if (Math.abs(rel) > FOV / 2 + 10) continue;
    const perp = dist * Math.cos(rel * DR);
    if (perp < 1) continue;
    const cx = VW / 2 - (rel / (FOV / 2)) * (VW / 2);
    const col = Math.floor(cx);
    if (col < 0 || col >= VW || perp > zbuf[col] + 0.5) continue; // off-screen / behind a wall
    const wallH = (U / perp) * PROJ;
    const floorY = VH / 2 + wallH / 2;
    const sz = Math.max(2, wallH * 0.2);
    vctx.fillStyle = "rgba(0,0,0,0.35)";
    vctx.fillRect(cx - sz / 2, floorY - sz / 7, sz, sz / 7); // shadow
    vctx.fillStyle = itemColor(n);
    vctx.fillRect(cx - sz / 2, floorY - sz, sz, sz); // marker
    vctx.fillStyle = "rgba(255,255,255,0.5)";
    vctx.fillRect(cx - sz / 2, floorY - sz, sz, Math.max(1, sz / 6)); // glint
  }
}

function renderView(s: State, clock: number, fx: Fx) {
  const px = toU(s.player.x), py = toU(s.player.y), pa = s.player.angle;

  // refresh per-door open fractions (action 0 = DR_OPEN = fully open) for the raycaster
  for (let i = 0; i < s.doors.length; i++)
    doorOpenFrac[i] = s.doors[i].action === 0 ? 1 : s.doors[i].position / 0xffff;

  // walls: the wasm raycaster (fills the framebuffer + zbuf, then we blit) if built,
  // else the TS raycaster below.
  if (wall) {
    wall.render(px, py, pa, s.doors);
  } else renderWallsTS(px, py, pa);

  // bonus items (floor markers) then guards on top
  drawItems(px, py, pa, s);

  // guards (depth-sorted far→near so nearer overdraw wins)
  const order = s.guards
    .map((g) => ({ g, d: Math.hypot(toU(g.x) - px, toU(g.y) - py) }))
    .sort((a, b) => b.d - a.d);
  for (const { g } of order) {
    if (assets) drawGuardSprite(px, py, pa, g, clock, assets);
    else drawGuard(px, py, pa, g, clock);
  }

  if (assets) drawWeaponSprite(clock, fx, assets);
  else drawWeapon(clock, fx);

  // damage flash
  if (clock < fx.damageUntil) {
    const a = 0.45 * (1 - (fx.damageUntil - clock) / 380);
    vctx.fillStyle = `rgba(170,0,0,${Math.max(0, a)})`;
    vctx.fillRect(0, 0, VW, VH);
  }

  if (s.player.health <= 0) {
    // Wolf3D death sequence: the view sinks while the screen fades to red over ~1.1s,
    // then "YOU DIED". (Render-only; the sim just reports health <= 0.)
    if (deathAt === 0) deathAt = clock;
    const t = Math.min(1, (clock - deathAt) / 1100);
    const sink = Math.floor(t * VH * 0.55);
    if (sink > 0) {
      vctx.drawImage(view, 0, 0, VW, VH, 0, sink, VW, VH); // shift the composed scene down
      vctx.fillStyle = "#000";
      vctx.fillRect(0, 0, VW, sink); // black above the sinking view
    }
    vctx.fillStyle = `rgba(150,0,0,${0.72 * t})`; // screen reddens
    vctx.fillRect(0, 0, VW, VH);
    if (t >= 1) {
      vctx.fillStyle = "#f55";
      vctx.font = `bold ${Math.round(VW * 0.075)}px ui-monospace, monospace`;
      vctx.textAlign = "center";
      vctx.fillText("YOU DIED", VW / 2, VH / 2);
      vctx.textAlign = "left";
    }
  } else if (deathAt !== 0) {
    deathAt = 0; // revived (new game) — reset the sequence
  }

  drawBorder(); // M5: frame the viewport (over everything, incl. the death fade)
}

// the original TS wall raycaster (ceiling/floor fill + one ray per column), used when
// the wasm renderer isn't built or there are no real textures.
function renderWallsTS(px: number, py: number, pa: number) {
  // ceiling + floor — Wolf3D draws these as flat colors, not textures:
  // floor is palette 0x19 (gray); E1 ceiling is palette 0x1d (dark gray), per vgaCeiling[].
  vctx.fillStyle = "#383838"; // ceiling (0x1d)
  vctx.fillRect(0, 0, VW, VH / 2);
  vctx.fillStyle = "#717171"; // floor (0x19)
  vctx.fillRect(0, VH / 2, VW, VH / 2);

  // walls (one ray per column)
  for (let c = 0; c < VW; c++) {
    const ra = pa + FOV / 2 - ((c + 0.5) / VW) * FOV;
    const hit = castRay(px, py, ra);
    const perp = Math.max(0.0001, hit.dist * Math.cos((pa - ra) * DR)); // fisheye fix
    zbuf[c] = perp;
    let lineH = (U / perp) * PROJ;
    if (lineH > VH * 3) lineH = VH * 3;
    const top = VH / 2 - lineH / 2;
    // M5: flat lighting — no distance shading (Wolf3D's VGA renderer has none). N/S
    // faces are darkened by the dark VSWAP page (wallPage +1), or a constant two-tone
    // side factor in the procedural fallback. See renderer/wolfrender.c.
    const door = isDoor(hit.tile);
    if (assets) {
      // real Wolf3D texture for this tile's value + face; blit a 1px source column
      const page = door ? DOOR_PAGE : wallPage(hit.tile, hit.vertical);
      const tex = assets.walls.get(page) ?? assets.walls.get(0)!;
      const sx = Math.min(63, Math.max(0, Math.floor(hit.tex)));
      vctx.drawImage(tex, sx, 0, 1, 64, c, top, 1, lineH);
    } else if (door) {
      const side = hit.vertical ? 1 : 0.7;
      const r = (74 * side) | 0, gg = (96 * side) | 0, b = (132 * side) | 0; // steel door
      vctx.fillStyle = `rgb(${r},${gg},${b})`;
      vctx.fillRect(c, top, 1, lineH);
    } else {
      const side = hit.vertical ? 1 : 0.7; // darken N/S faces for depth cue
      const r = (150 * side) | 0, gg = (132 * side) | 0, b = (108 * side) | 0;
      vctx.fillStyle = `rgb(${r},${gg},${b})`;
      vctx.fillRect(c, top, 1, lineH);
    }
  }
}

// real Wolf3D pistol viewmodel: the sprite is drawn scaled to the view height and
// centered (as Wolf3D's SimpleScaleShape does), so the gun sits bottom-center; the
// transparent upper part shows the world. Swaps to the fire frames on recoil.
function drawWeaponSprite(clock: number, fx: Fx, A: Assets) {
  let idx = PISTOL_READY;
  if (clock < fx.recoilUntil) {
    const prog = 1 - (fx.recoilUntil - clock) / 120; // 0→1 across the fire window
    idx = PISTOL_FIRE[Math.min(PISTOL_FIRE.length - 1, Math.floor(prog * PISTOL_FIRE.length))];
  }
  const img = A.sprites.get(idx) ?? A.sprites.get(PISTOL_READY);
  if (!img) { drawWeapon(clock, fx); return } // frame missing → procedural fallback
  const h = VH * 1.3, w = h; // square sprite, a touch larger than view height, centered
  const bob = Math.sin(clock / 350) * (VH * 0.012); // subtle idle sway
  vctx.drawImage(img, 0, 0, 64, 64, (VW - w) / 2, VH - h + bob, w, h); // bottom-anchored
}

// procedural weapon viewmodel (fallback when no VSWAP assets): a pistol held in the
// lower-right, barrel up, viewed from behind. Recoil kicks it up; muzzle flash on fire.
function drawWeapon(clock: number, fx: Fx) {
  const recoil = clock < fx.recoilUntil ? 20 * ((fx.recoilUntil - clock) / 120) : 0;
  const cx = VW / 2 + 40; // right of center (right hand)
  const b = VH - recoil; // base at bottom of view (kicks up on fire)
  const o = "#0e0e12"; // outline
  const box = (x: number, y: number, w: number, h: number, fill: string) => {
    vctx.fillStyle = o;
    vctx.fillRect(x - 2, y - 2, w + 4, h + 4);
    vctx.fillStyle = fill;
    vctx.fillRect(x, y, w, h);
  };

  // fist gripping (skin), runs off the bottom edge
  box(cx - 30, b - 58, 76, 70, "#c89868");
  vctx.fillStyle = "#a87a48"; // knuckle shading
  for (let i = 0; i < 4; i++) vctx.fillRect(cx - 24 + i * 18, b - 58, 10, 24);
  // grip / body of the gun (tapering tower)
  box(cx - 22, b - 104, 60, 50, "#3a3a44");
  box(cx - 16, b - 150, 44, 48, "#4c4c58"); // slide
  vctx.fillStyle = "#6a6a78"; // slide highlight
  vctx.fillRect(cx - 16, b - 150, 44, 6);
  box(cx - 4, b - 188, 20, 40, "#2e2e38"); // barrel
  vctx.fillStyle = "#14141a"; // muzzle hole
  vctx.fillRect(cx, b - 188, 12, 8);

  if (clock < fx.muzzleUntil) {
    const tipX = cx + 6, tipY = b - 188;
    vctx.fillStyle = "rgba(255,232,150,0.96)";
    vctx.beginPath();
    for (let i = 0; i < 10; i++) {
      const ang = (i / 10) * Math.PI * 2;
      const rr = i % 2 ? 14 : 40;
      vctx.lineTo(tipX + Math.cos(ang) * rr, tipY + Math.sin(ang) * rr * 0.85);
    }
    vctx.closePath();
    vctx.fill();
    vctx.fillStyle = "rgba(255,220,120,0.10)"; // muzzle light wash
    vctx.fillRect(0, 0, VW, VH);
  }
}

// ---------------------------------------------------------------------------
// HUD (Wolfenstein-style status bar)
// ---------------------------------------------------------------------------
function cell(x: number, w: number, label: string, value: string, color: string) {
  hctx.fillStyle = "#000";
  hctx.fillRect(x + 4, 26, w - 8, 44);
  hctx.fillStyle = "#7a7a82";
  hctx.font = "10px ui-monospace, monospace";
  hctx.textAlign = "center";
  hctx.fillText(label, x + w / 2, 22);
  hctx.fillStyle = color;
  hctx.font = "bold 26px ui-monospace, monospace";
  hctx.fillText(value, x + w / 2, 58);
}

function drawFace(cx: number, cy: number, health: number, hurt: boolean) {
  const r = 22;
  hctx.fillStyle = "#000";
  hctx.fillRect(cx - r - 4, cy - r - 2, r * 2 + 8, r * 2 + 8);
  hctx.fillStyle = health <= 0 ? "#777" : "#d8a878";
  hctx.beginPath();
  hctx.arc(cx, cy, r, 0, Math.PI * 2);
  hctx.fill();
  hctx.fillStyle = "#3a2a1a"; // hair
  hctx.fillRect(cx - r, cy - r, r * 2, 8);
  hctx.fillStyle = "#111"; // eyes
  const eo = hurt ? 1 : 0;
  hctx.fillRect(cx - 11, cy - 4 + eo, 6, 5);
  hctx.fillRect(cx + 5, cy - 4 + eo, 6, 5);
  // mouth by health
  hctx.strokeStyle = "#5a1010";
  hctx.lineWidth = 2;
  hctx.beginPath();
  if (health <= 0) { hctx.moveTo(cx - 8, cy + 12); hctx.lineTo(cx + 8, cy + 12); } // flat dead
  else if (health < 35) { hctx.arc(cx, cy + 16, 6, Math.PI, 0); } // frown
  else if (health < 75) { hctx.moveTo(cx - 7, cy + 11); hctx.lineTo(cx + 7, cy + 11); }
  else { hctx.arc(cx, cy + 8, 6, 0, Math.PI); } // smile
  hctx.stroke();
}

function renderHud(s: State, gas: number | null, clock: number, fx: Fx) {
  // this procedural bar was authored in a 640x80 design space; the canvas is now native
  // 320x40, so map design coords onto it (then CSS scales the canvas up to 640x96).
  hctx.save();
  hctx.setTransform(hudC.width / 640, 0, 0, hudC.height / 80, 0, 0);
  hctx.fillStyle = "#3c3c42";
  hctx.fillRect(0, 0, 640, 80);
  hctx.fillStyle = "#2a2a30";
  hctx.fillRect(0, 0, 640, 6);

  const hp = Math.max(0, s.player.health);
  const hpColor = hp <= 0 ? "#f33" : hp < 35 ? "#f73" : hp < 75 ? "#fd6" : "#6f6";
  cell(0, 120, "FLOOR", "1", "#9cf");
  cell(120, 130, "HEALTH", hp + "%", hpColor);
  drawFace(295, 42, hp, clock < fx.damageUntil);
  cell(330, 110, "AMMO", String(Math.max(0, s.player.ammo)), s.player.ammo > 0 ? "#fd6" : "#f55");
  const keyTag = (s.player.keys & 1 ? " G" : "") + (s.player.keys & 2 ? " S" : ""); // gold/silver
  cell(440, 95, "SCORE", String(s.player.score) + keyTag, "#fd6");
  cell(535, 105, "GAS", gas != null ? (gas / 1000).toFixed(0) + "k" : "—", "#6cf");
  hctx.restore();
}

// authentic Wolf3D status bar: the real STATUSBARPIC + white digit font + the BJ
// face (chosen by health). Wolf3D's StatusDrawPic(x,y,pic) places x in 8px tiles,
// y in pixels from the bar top; LatchNumber right-aligns digits in a field. 2x scale.
function renderHudReal(s: State, A: Assets, clock: number) {
  const S = 1; // native 320x40 bar; the canvas is CSS-scaled to 640x96 (4:3 stretch)
  hctx.imageSmoothingEnabled = false;
  hctx.clearRect(0, 0, hudC.width, hudC.height);
  hctx.drawImage(A.pics.get(PIC_STATUSBAR)!, 0, 0, 320, 40, 0, 0, 320 * S, 40 * S);

  const num = (value: number, xTile: number, width: number) => {
    const str = Math.max(0, Math.floor(value)).toString();
    const shown = str.length <= width ? str : str.slice(str.length - width);
    let x = xTile + (width - shown.length); // right-align (leading blanks show bar bg)
    for (const ch of shown) {
      const d = A.pics.get(PIC_DIGIT0 + (ch.charCodeAt(0) - 48));
      if (d) hctx.drawImage(d, 0, 0, 8, 16, x * 8 * S, 16 * S, 8 * S, 16 * S);
      x++;
    }
  };
  num(1, 2, 2);                              // LEVEL (floor 1)
  num(s.player.score, 6, 6);                 // SCORE (on-chain: treasure pickups)
  num(1, 14, 1);                             // LIVES
  num(s.player.health, 21, 3);               // HEALTH
  num(s.player.ammo, 27, 2);                 // AMMO

  // gold/silver key indicators when held (the real bar has empty key slots)
  for (let k = 0; k < 2; k++)
    if (s.player.keys & (1 << k)) {
      hctx.fillStyle = k === 0 ? "#f4d03f" : "#cfd8dc";
      hctx.fillRect(30 * 8 * S, (4 + k * 16) * S, 6 * S, 12 * S);
    }

  // BJ face: FACE1APIC + 3*level + look; level by health, FACE8 (level 7) when dead
  const hp = s.player.health;
  const level = hp <= 0 ? 7 : Math.min(6, Math.floor((100 - hp) / 16));
  const look = hp <= 0 ? 0 : Math.floor(clock / 600) % 3;
  const face = A.pics.get(PIC_FACE1A + level * 3 + look) ?? A.pics.get(PIC_FACE1A);
  if (face) hctx.drawImage(face, 0, 0, 24, 32, 17 * 8 * S, 4 * S, 24 * S, 32 * S);
}

// ---------------------------------------------------------------------------
// minimap (top-down)
// ---------------------------------------------------------------------------
function renderMap(s: State) {
  const SC = mapC.width / W;
  mctx.fillStyle = "#000";
  mctx.fillRect(0, 0, mapC.width, mapC.height);
  const px0 = SC > 4 ? 1 : 0; // gridlines only when tiles are big enough
  for (let y = 0; y < H; y++)
    for (let x = 0; x < W; x++) {
      const v = tiles[y * W + x];
      // doors: brighter when closed, dim as they open
      mctx.fillStyle = isDoor(v)
        ? (doorOpenFrac[v & 0x7f] > 0.5 ? "#1d3a2a" : "#3aa06a")
        : isWall(v) ? "#3a3a4a" : "#0c0c14";
      mctx.fillRect(x * SC, y * SC, SC - px0, SC - px0);
    }
  const px = (s.player.x / TILEGLOBAL) * SC, py = (s.player.y / TILEGLOBAL) * SC;
  // fov cone
  const pa = s.player.angle;
  mctx.fillStyle = "rgba(110,200,255,0.12)";
  mctx.beginPath();
  mctx.moveTo(px, py);
  for (let d = -FOV / 2; d <= FOV / 2; d += 6) {
    const a = (pa + d) * DR;
    mctx.lineTo(px + Math.cos(a) * SC * 6, py - Math.sin(a) * SC * 6);
  }
  mctx.closePath();
  mctx.fill();
  for (const g of s.guards) {
    const gx = (g.x / TILEGLOBAL) * SC, gy = (g.y / TILEGLOBAL) * SC;
    mctx.fillStyle = isDead(g.state) ? "#633" : isFiring(g.state) ? "#f33" : "#f93";
    mctx.beginPath();
    mctx.arc(gx, gy, SC * 0.32, 0, Math.PI * 2);
    mctx.fill();
  }
  mctx.fillStyle = "#6cf";
  mctx.beginPath();
  mctx.arc(px, py, SC * 0.3, 0, Math.PI * 2);
  mctx.fill();
}

// short "owner → burner" label for the HUD; set once the session key is delegated
let sessionKeyLabel = "—";
let predictLabel = "off (chain-only)"; // client-side prediction status
let renderLabel = "ts raycaster"; // wall renderer: wasm vs TS raycaster
let tps = 0; // confirmed ticks/sec (rolling 1s window)
const TICK_HZ = 70; // fixed-timestep target — Wolf3D's native time base; we sustain more
let deathAt = 0; // clock (ms) when the player's health first hit 0, for the death sequence
const shortAddr = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`;

function renderDbg(s: State, tick: number, gas: number | null) {
  const g0 = s.guards[0];
  dbg.textContent =
    `level     ${levelName} ${W}x${H}\n` +
    `tick      ${tick}\n` +
    `tickrate  ${tps.toFixed(0)} / ${TICK_HZ} tics/s\n` +
    `gas/tick  ${gas != null ? `${(gas / 1000).toFixed(0)}k (${gas.toLocaleString("en-US")})` : "—"}\n` +
    `signer    ${sessionKeyLabel}\n` +
    `predict   ${predictLabel}\n` +
    `walls     ${renderLabel}\n` +
    `art       ${assets ? "real id (VSWAP)" : "procedural"}\n` +
    `guards    ${s.guards.length}\n` +
    `rndindex  ${s.rndindex}\n\n` +
    `player\n` +
    `  health  ${s.player.health}\n` +
    `  ammo    ${s.player.ammo}\n` +
    `  tile    (${s.player.tilex},${s.player.tiley})\n` +
    `  angle   ${s.player.angle}\n\n` +
    (g0
      ? `guard\n  state   ${g0.state} ${stateName(g0.state)}\n  hp      ${g0.hp}\n  dir     ${g0.dir}`
      : "no guards");
}

// ---------------------------------------------------------------------------
// fx timers (driven on the render clock, independent of tx latency)
// ---------------------------------------------------------------------------
type Fx = { muzzleUntil: number; recoilUntil: number; damageUntil: number };
const fx: Fx = { muzzleUntil: 0, recoilUntil: 0, damageUntil: 0 };

// ---------------------------------------------------------------------------
// input
// ---------------------------------------------------------------------------
const keys = new Set<string>();
addEventListener("keydown", (e) => {
  keys.add(e.key.toLowerCase());
  if ([" ", "arrowleft", "arrowright", "arrowup", "arrowdown"].includes(e.key.toLowerCase()))
    e.preventDefault();
});
addEventListener("keyup", (e) => keys.delete(e.key.toLowerCase()));

const MOVE = 35; // forward/back/strafe input (≈ max thrust after MOVESCALE)
// turn input. The engine turns controlx/ANGLESCALE(20) degrees per tic, so degrees/sec =
// TURN/20 * TICK_HZ. Derive TURN for a comfortable ~140°/s at whatever TICK_HZ is set to
// (was a fixed 200 = 700°/s once the tickrate was pinned at 70 — far too fast).
const TURN = Math.round((140 / TICK_HZ) * 20);
// Controls: W/S or ↑/↓ = forward/back; A/D = strafe; ←/→ = turn. (controlx is reused by
// the engine for either turn or strafe per tic, so strafe takes precedence when both.)
function cmd() {
  let controlx = 0, controly = 0, buttons = 0;
  if (keys.has("w") || keys.has("arrowup")) controly = -MOVE;
  if (keys.has("s") || keys.has("arrowdown")) controly = MOVE;
  const strafeL = keys.has("a"), strafeR = keys.has("d");
  const turnL = keys.has("arrowleft"), turnR = keys.has("arrowright");
  if (strafeL || strafeR) {
    // strafe: +controlx → right (engine thrusts toward angle-90), -controlx → left
    if (strafeL) controlx = -MOVE;
    if (strafeR) controlx = MOVE;
    buttons |= 2; // BT_STRAFE
  } else {
    // turn: engine does angle -= controlx/ANGLESCALE, so +controlx = right, - = left
    if (turnL) controlx = -TURN;
    if (turnR) controlx = TURN;
  }
  if (keys.has(" ")) buttons |= 1; // BT_ATTACK
  if (keys.has("e")) buttons |= 8; // BT_USE (open/close the door you face)
  return { controlx: BigInt(controlx), controly: BigInt(controly), buttons };
}

// ---------------------------------------------------------------------------
// main: deploy, then a render loop (rAF) + a tx loop (drives the sim)
// ---------------------------------------------------------------------------
let latest: State | null = null;
let tick = 0;
let lastGas: number | null = null;

async function main() {
  vctx.imageSmoothingEnabled = false; // crisp texels
  dbg.textContent = "loading level + assets / deploying to anvil…";
  await loadLevel(); // real Wolf3D level from /level.json if present, else the test room
  assets = await loadAssets(); // authentic id art if /wolf/*.png present, else procedural
  wall = await loadWasmRenderer(); // wasm wall raycaster if built, else the TS one
  renderLabel = wall ? "wasm (Emscripten raycaster)" : "ts raycaster";
  if (wall) console.log("[render] wasm wall renderer active");
  const engine = await deploy(EngineA, []);
  const map = await deploy(MapA, [
    BigInt(W), BigInt(H), tilesHex(),
    BigInt(spawnTile.x), BigInt(spawnTile.y), BigInt(spawnTile.dir),
    guardsHex(), doorsHex(), itemsHex(), areasHex(),
  ]);
  // owner = our dev account (the "main wallet"). It signs exactly once below to
  // delegate a session key; from then on the burner signs every tick.
  const session = await deploy(SessionA, [engine, map, account.address]);

  // --- session key (M4): popup-free play ---------------------------------------
  // Generate an ephemeral burner keypair in the browser, fund it for gas, and have
  // the owner authorize it once via delegate(). The burner then auto-signs every
  // submitInput with no further wallet touches — the standard FOCG pattern. On a real
  // chain the funding is a dust pre-fund (or an ERC-4337 paymaster) and delegate() is
  // the one MetaMask popup; here both keys are local anvil accounts.
  const burner = privateKeyToAccount(generatePrivateKey());
  const burnerWallet = createWalletClient({ account: burner, chain: foundry, transport });
  const expiry = BigInt(Math.floor(Date.now() / 1000) + 3600); // 1 hour, time-boxed
  // fund the burner so it can pay its own gas
  await pub.waitForTransactionReceipt({
    hash: await wallet.sendTransaction({ to: burner.address, value: parseEther("10") }),
  });
  // the single owner signature that authorizes the burner for this Session
  await pub.waitForTransactionReceipt({
    hash: await wallet.writeContract({
      address: session, abi: SessionA.abi, functionName: "delegate",
      args: [burner.address, expiry],
    }),
  });
  sessionKeyLabel = `${shortAddr(account.address)} → ${shortAddr(burner.address)} (key)`;
  console.log(`[session key] owner ${account.address} delegated burner ${burner.address} until ${expiry}`);

  const getStateHex = async (): Promise<Hex> =>
    (await pub.readContract({ address: session, abi: SessionA.abi, functionName: "getState" })) as Hex;

  const initHex = await getStateHex();
  latest = decode(initHex);

  // load the wasm predictor and verify its spawn is byte-identical to the chain's
  const predictor = await loadPredictor();
  let predictEnabled = false;
  if (predictor) {
    const predHex = predictor.read();
    predictEnabled = predHex.toLowerCase() === initHex.toLowerCase();
    predictLabel = predictEnabled ? "wasm ✓ verified vs chain spawn" : "off (spawn mismatch)";
    console.log(
      predictEnabled
        ? "[predict] wasm predictor verified against chain spawn — predicting locally"
        : "[predict] spawn mismatch, disabling prediction",
      predictEnabled ? "" : { predHex, initHex },
    );
  }
  let predOk = 0, predTotal = 0, confTick = 0;

  // render loop — smooth fx (gun/muzzle/flash) regardless of tx cadence
  function frame() {
    const clock = performance.now();
    if (latest) {
      renderView(latest, clock, fx);
      if (assets?.pics.get(PIC_STATUSBAR)) renderHudReal(latest, assets, clock);
      else renderHud(latest, lastGas, clock, fx);
      renderMap(latest);
      renderDbg(latest, tick, lastGas);
    }
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);

  // rolling tickrate: count confirmations in the last second
  const confTimes: number[] = [];
  const markTick = () => {
    const now = performance.now();
    confTimes.push(now);
    while (confTimes.length && confTimes[0] < now - 1000) confTimes.shift();
    tps = confTimes.length;
  };

  // a damage/muzzle flash when health/ammo drop between two states
  const applyFx = (before: State, after: State) => {
    const now = performance.now();
    if (after.player.ammo < before.player.ammo) { fx.muzzleUntil = now + 90; fx.recoilUntil = now + 110; }
    if (after.player.health < before.player.health) fx.damageUntil = now + 380;
  };

  // tx loop — one submitInput per step, signed by the BURNER (session key), no popup.
  //
  // Fast path (predictor on): the predictor is differential-proven equal to the chain,
  // so the chain read is OFF the hot path. We render the predicted state immediately and
  // submit FIRE-AND-FORGET — local nonce + fixed gas/gasPrice collapse writeContract to a
  // single sendRawTransaction (no per-tick estimateGas / nonce fetch / fee history), and
  // we don't await each receipt or re-read state. Every SYNC_EVERY ticks we let the chain
  // catch up and verify the prediction byte-for-byte (resyncing on the should-never-happen
  // mismatch). Chain-only fallback (no predictor) still awaits + reads each tick.
  let nonce = await pub.getTransactionCount({ address: burner.address });
  const gasPrice = await pub.getGasPrice();
  const GAS = 600000n; // generous fixed limit (an E1L1 tick is ~245k) — skips estimateGas
  const submit = (c: ReturnType<typeof cmd>): Promise<Hex | undefined> =>
    burnerWallet.writeContract({
      address: session, abi: SessionA.abi, functionName: "submitInput", args: [c],
      nonce: nonce++, gas: GAS, gasPrice,
    }).catch((e) => (console.warn("submit failed @", tick, e), undefined));

  // pipeline: keep up to MAXINFLIGHT sends outstanding (don't block on each round-trip);
  // await the oldest only when the window is full. The predictor renders instantly so the
  // tx loop never gates the view.
  const MAXINFLIGHT = 24;
  const inflight: Promise<Hex | undefined>[] = [];
  const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

  // predicted-state history (tick -> packed hex). The reconciler compares the chain's
  // confirmed state to what we predicted AT THAT tick, so it never has to stall the loop
  // waiting for the chain to catch up to the (ahead) prediction.
  const predHist = new Map<number, string>();
  let lastHash: Hex | undefined;

  // reconciler: runs IN PARALLEL with the tick loop (not inline), so verification never
  // perturbs the cadence. Each second it reads the chain's confirmed tick + state at a
  // pinned block and checks them against our prediction for that tick; refreshes gas;
  // resyncs on the (differential-proven-impossible) mismatch.
  (async function reconcile() {
    for (;;) {
      await sleep(1000);
      if (!predictEnabled) continue;
      try {
        const bn = await pub.getBlockNumber();
        const T = Number(await pub.readContract({ address: session, abi: SessionA.abi, functionName: "tickCount", blockNumber: bn }));
        const chainHex = ((await pub.readContract({ address: session, abi: SessionA.abi, functionName: "getState", blockNumber: bn })) as Hex).toLowerCase();
        confTick = T;
        if (lastHash) {
          const r = await pub.getTransactionReceipt({ hash: lastHash }).catch(() => null);
          if (r) lastGas = Number(r.gasUsed);
        }
        const want = predHist.get(T);
        if (want === undefined) continue; // outside our history window — skip this round
        predTotal++;
        if (want === chainHex) predOk++;
        else {
          console.warn(`[predict] reconcile mismatch @ ${T}; falling back to chain`);
          predictEnabled = false;
          latest = decode(chainHex as Hex);
        }
      } catch (e) { console.warn("[reconcile]", e); }
    }
  })();

  // fixed-timestep pacing: pin the world to a stable TICK_HZ instead of free-running
  // (which ramped 120->145 and jittered with load). The accumulator keeps the average
  // exact even when setTimeout overshoots; the catch-up cap avoids a spiral after the tab
  // is backgrounded (throttled timers). Rendering stays at 60fps via rAF, independent.
  const DT = 1000 / TICK_HZ;
  let nextAt = performance.now();

  for (;;) {
    const wait = nextAt - performance.now();
    if (wait > 0) await sleep(wait);
    nextAt += DT;
    if (performance.now() - nextAt > 250) nextAt = performance.now(); // stall/background reset

    const before = latest!;
    const c = cmd();

    if (predictEnabled && predictor) {
      // predict locally (instant render) + submit fire-and-forget into the pipeline
      predictor.step(Number(c.controlx), Number(c.controly), c.buttons);
      const predHex = predictor.read();
      const pred = decode(predHex);
      applyFx(before, pred);
      latest = pred;
      tick++;
      predHist.set(tick, predHex.toLowerCase()); // for the parallel reconciler
      if (predHist.size > 256) predHist.delete(tick - 256);
      const p = submit(c);
      p.then((h) => { if (h) lastHash = h; });
      inflight.push(p);
      markTick();
      if (inflight.length > MAXINFLIGHT) await inflight.shift(); // bound the window (+ yield)
      predictLabel = predictEnabled
        ? `wasm ✓ ${predOk}/${predTotal} syncs · pred ${tick} / conf ${confTick}`
        : `off (diverged @ ${confTick})`;
    } else {
      // chain-only: must read state each tick, so await the receipt
      const hash = await submit(c);
      if (hash) lastGas = Number((await pub.waitForTransactionReceipt({ hash })).gasUsed);
      confTick++;
      markTick();
      const after = decode(await getStateHex());
      applyFx(before, after);
      latest = after;
      tick++;
    }
  }
}

main().catch((e) => (dbg.textContent = "error: " + (e?.message ?? e)));
