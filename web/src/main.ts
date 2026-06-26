import {
  createWalletClient,
  createPublicClient,
  http,
  bytesToHex,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
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
const pub = createPublicClient({ chain: foundry, transport });

const TILEGLOBAL = 65536;
const W = 16;
const H = 16;
const MAP = [
  "################",
  "#..............#",
  "#..............#",
  "#..............#",
  "#..............#",
  "#..............#",
  "#..............#",
  "#..............#",
  "#..............#",
  "#..............#",
  "#..............#",
  "#..............#",
  "#..............#",
  "#..............#",
  "#..............#",
  "################",
];

function tilesHex(): Hex {
  const t = new Uint8Array(W * H);
  for (let y = 0; y < H; y++)
    for (let x = 0; x < W; x++) t[y * W + x] = MAP[y][x] === "#" ? 1 : 0;
  return bytesToHex(t);
}

async function deploy(art: any, args: any[]): Promise<Address> {
  const hash = await wallet.deployContract({
    abi: art.abi,
    bytecode: art.bytecode.object as Hex,
    args,
  });
  const r = await pub.waitForTransactionReceipt({ hash });
  return r.contractAddress!;
}

// --- packed-state decoder (must match Engine.sol _pack layout) ---
function words(hex: string): bigint[] {
  const h = hex.slice(2);
  const out: bigint[] = [];
  for (let i = 0; i < h.length / 64; i++) out.push(BigInt("0x" + h.slice(i * 64, (i + 1) * 64)));
  return out;
}
const fld = (w: bigint, sh: number, bits: number) =>
  Number((w >> BigInt(sh)) & ((1n << BigInt(bits)) - 1n));
function sfld(w: bigint, sh: number, bits: number): number {
  let v = (w >> BigInt(sh)) & ((1n << BigInt(bits)) - 1n);
  if (v & (1n << BigInt(bits - 1))) v -= 1n << BigInt(bits);
  return Number(v);
}

type Guard = { x: number; y: number; dir: number; state: number; hp: number };
type State = {
  rndindex: number;
  player: { x: number; y: number; angle: number; tilex: number; tiley: number; health: number };
  guards: Guard[];
};

function decode(hex: string): State {
  const w = words(hex);
  const header = w[0];
  const n = fld(header, 8, 8);
  const pw = w[1];
  const guards: Guard[] = [];
  for (let i = 0; i < n; i++) {
    const a = w[2 + i];
    guards.push({
      x: sfld(a, 0, 32),
      y: sfld(a, 32, 32),
      dir: fld(a, 80, 8),
      state: fld(a, 88, 8),
      hp: sfld(a, 144, 16),
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
    },
    guards,
  };
}

// --- rendering (top-down) ---
const canvas = document.getElementById("view") as HTMLCanvasElement;
const ctx = canvas.getContext("2d")!;
const hud = document.getElementById("hud")!;
const SC = canvas.width / W;

function draw(s: State, tick: number) {
  ctx.fillStyle = "#000";
  ctx.fillRect(0, 0, canvas.width, canvas.height);
  // map
  for (let y = 0; y < H; y++)
    for (let x = 0; x < W; x++) {
      ctx.fillStyle = MAP[y][x] === "#" ? "#334" : "#0a0a12";
      ctx.fillRect(x * SC, y * SC, SC - 1, SC - 1);
    }
  // guards
  for (const g of s.guards) {
    const gx = (g.x / TILEGLOBAL) * SC;
    const gy = (g.y / TILEGLOBAL) * SC;
    const shooting = g.state >= 7 && g.state <= 9;
    ctx.fillStyle = shooting ? "#f33" : "#f93";
    ctx.beginPath();
    ctx.arc(gx, gy, SC * 0.32, 0, Math.PI * 2);
    ctx.fill();
  }
  // player + facing
  const px = (s.player.x / TILEGLOBAL) * SC;
  const py = (s.player.y / TILEGLOBAL) * SC;
  const a = (s.player.angle * Math.PI) / 180;
  ctx.strokeStyle = "#6cf";
  ctx.lineWidth = 2;
  ctx.beginPath();
  ctx.moveTo(px, py);
  ctx.lineTo(px + Math.cos(a) * SC * 0.7, py - Math.sin(a) * SC * 0.7);
  ctx.stroke();
  ctx.fillStyle = "#6cf";
  ctx.beginPath();
  ctx.arc(px, py, SC * 0.28, 0, Math.PI * 2);
  ctx.fill();

  const g0 = s.guards[0];
  hud.textContent =
    `tick      ${tick}\n` +
    `rndindex  ${s.rndindex}\n\n` +
    `player\n  health  ${s.player.health}\n  tile    (${s.player.tilex},${s.player.tiley})\n  angle   ${s.player.angle}\n\n` +
    (g0
      ? `guard\n  state   ${g0.state} ${stateName(g0.state)}\n  hp      ${g0.hp}\n  dir     ${g0.dir}`
      : "");
}

function stateName(s: number): string {
  if (s === 0) return "(stand)";
  if (s >= 1 && s <= 6) return "(chasing)";
  if (s >= 7 && s <= 9) return "FIRING";
  return "";
}

// --- input ---
const keys = new Set<string>();
addEventListener("keydown", (e) => keys.add(e.key.toLowerCase()));
addEventListener("keyup", (e) => keys.delete(e.key.toLowerCase()));

function cmd() {
  let controlx = 0,
    controly = 0,
    buttons = 0;
  if (keys.has("w")) controly = -35;
  if (keys.has("s")) controly = 35;
  if (keys.has("a")) controlx = 35;
  if (keys.has("d")) controlx = -35;
  if (keys.has("shift")) buttons |= 2; // strafe
  if (keys.has(" ")) buttons |= 1; // attack (no effect until M2c part 2)
  return { controlx: BigInt(controlx), controly: BigInt(controly), buttons };
}

async function main() {
  hud.textContent = "deploying Engine / Map / Session to anvil…";
  const engine = await deploy(EngineA, []);
  const map = await deploy(MapA, [
    BigInt(W), BigInt(H), tilesHex(), 8n, 8n, 1n, "0x0c0804" as Hex, // guard at tile (12,8) dir west
  ]);
  const session = await deploy(SessionA, [engine, map]);

  // drive the sim continuously so the guard chases even while you stand still
  let tick = 0;
  for (;;) {
    const hash = await wallet.writeContract({
      address: session,
      abi: SessionA.abi,
      functionName: "submitInput",
      args: [cmd()],
    });
    await pub.waitForTransactionReceipt({ hash });
    const state = (await pub.readContract({
      address: session,
      abi: SessionA.abi,
      functionName: "getState",
    })) as Hex;
    draw(decode(state), ++tick);
    await new Promise((r) => setTimeout(r, 90));
  }
}

main().catch((e) => (hud.textContent = "error: " + (e?.message ?? e)));
