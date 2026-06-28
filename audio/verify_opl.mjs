// verify_opl.mjs — headless smoke test for the OPL2 audio pipeline (M7), the audio analog
// of renderer/verify_render.mjs: it drives the REAL web/public/opl.wasm (Nuked-OPL3) the
// browser uses, and proves the AdLib-SFX and IMF-music *formats* turn into actual sound.
//
// Asset-free + deterministic (pure integer FM synth, synthetic inputs) — never flaky, so
// it runs in CI without any id data. It does NOT replace listening to the real game audio;
// it pins that (a) the chip exports + synthesises, (b) a key-on makes sound and silence is
// silent, and (c) the IMF (700Hz) and AdLib-SFX (140Hz) replay clocks drive the chip.
//
// Run:  node audio/verify_opl.mjs    (after  bash audio/build_opl.sh)
import { readFileSync } from "node:fs";

const RATE = 49716; // ~OPL3 native rate; the wasm resamples to whatever we pass
const wasm = readFileSync(new URL("../web/public/opl.wasm", import.meta.url));
const { instance } = await WebAssembly.instantiate(wasm);
const E = instance.exports;
const mem = E.memory;
const MAXF = E.opl_maxframes();

// pull `frames` stereo frames, mixed to a mono Float32Array in [-1,1].
function generate(frames) {
  const out = new Float32Array(frames);
  let done = 0;
  while (done < frames) {
    const n = Math.min(MAXF, frames - done);
    E.opl_generate(n);
    const buf = new Int16Array(mem.buffer, E.opl_buf(), n * 2);
    for (let i = 0; i < n; i++) out[done + i] = (buf[i * 2] + buf[i * 2 + 1]) / 2 / 32768;
    done += n;
  }
  return out;
}
const rms = (a) => Math.sqrt(a.reduce((s, x) => s + x * x, 0) / a.length);
const ops = [0, 3]; // OPL2 channel-0 operator register offsets (modulator, carrier)

// a plain audible FM patch on channel 0 (id's AdLib instruments write these same regs).
function patch() {
  E.opl_write(0x01, 0x20); // enable waveform select
  E.opl_write(0xbd, 0x00); // no rhythm
  for (const op of ops) {
    E.opl_write(0x20 + op, 0x01); // mult=1, no AM/VIB/sustain-EG
    E.opl_write(0x60 + op, 0xf0); // fast attack, slow decay
    E.opl_write(0x80 + op, 0x77); // sustain/release
    E.opl_write(0xe0 + op, 0x00); // sine
  }
  E.opl_write(0x40 + ops[0], 0x2a); // modulator: attenuated
  E.opl_write(0x43, 0x00); // carrier: full volume (reg 0x40 + op 3)
  E.opl_write(0xc0, 0x31); // feedback/FM + L/R enable (OPL3 panning bits)
}

let fail = 0;
const check = (name, cond, extra = "") => {
  console.log(`${cond ? "ok  " : "FAIL"}  ${name}${extra ? "  " + extra : ""}`);
  if (!cond) fail++;
};

// 1. fresh chip with no note: silence.
E.opl_reset(RATE);
const silence = generate(2048);
check("idle chip is silent", rms(silence) < 1e-4, `rms=${rms(silence).toExponential(2)}`);

// 2. instrument + key-on: audible.
E.opl_reset(RATE);
patch();
E.opl_write(0xa0, 0x98); // F-number low
E.opl_write(0xb0, 0x31); // key-on | block 4 | F-number high
const tone = generate(8192);
check("key-on produces sound", rms(tone) > 0.02, `rms=${rms(tone).toFixed(4)}`);

// 3. IMF music replay (700Hz): a synthetic track = patch writes, key-on, a delay, key-off.
//    IMF = [u16 len][ (reg u8, val u8, delay u16-LE) ... ] — id ID_SD.C SDL_ALService.
function buildImf() {
  const evs = [
    [0x01, 0x20, 0],
    [0x20 + ops[0], 0x01, 0], [0x60 + ops[0], 0xf0, 0], [0x80 + ops[0], 0x77, 0], [0xe0 + ops[0], 0x00, 0], [0x40 + ops[0], 0x2a, 0],
    [0x20 + ops[1], 0x01, 0], [0x60 + ops[1], 0xf0, 0], [0x80 + ops[1], 0x77, 0], [0xe0 + ops[1], 0x00, 0], [0x40 + ops[1], 0x00, 0],
    [0xc0, 0x31, 0], [0xa0, 0x98, 0], [0xb0, 0x31, 350], // hold ~0.5s (350/700)
    [0xb0, 0x11, 0], // key-off
  ];
  const body = new Uint8Array(evs.length * 4);
  evs.forEach(([r, v, d], i) => { body[i * 4] = r; body[i * 4 + 1] = v; body[i * 4 + 2] = d & 0xff; body[i * 4 + 3] = d >> 8; });
  const chunk = new Uint8Array(2 + body.length);
  chunk[0] = body.length & 0xff; chunk[1] = body.length >> 8; chunk.set(body, 2);
  return chunk;
}
function renderImf(bytes, rate) {
  const len = bytes[0] | (bytes[1] << 8);
  const dv = new DataView(bytes.buffer, bytes.byteOffset);
  E.opl_reset(rate);
  const ticks = rate / 700; // IMF delay unit = 1/700s
  const out = [];
  let p = 2;
  while (p + 4 <= 2 + len) {
    E.opl_write(dv.getUint8(p), dv.getUint8(p + 1));
    const delay = dv.getUint16(p + 2, true);
    p += 4;
    if (delay) out.push(generate(Math.max(1, Math.round(delay * ticks))));
  }
  const total = out.reduce((s, a) => s + a.length, 0);
  const pcm = new Float32Array(total);
  let o = 0; for (const a of out) { pcm.set(a, o); o += a.length; }
  return pcm;
}
const imf = renderImf(buildImf(), RATE);
check("IMF track renders ~0.5s", Math.abs(imf.length / RATE - 0.5) < 0.05, `${(imf.length / RATE).toFixed(3)}s`);
check("IMF track is audible", rms(imf) > 0.02, `rms=${rms(imf).toFixed(4)}`);

// 4. AdLib SFX replay (140Hz): AdLibSound = {len u32, prio u16, Instrument[16], block u8,
//    data[len]} — id ID_SD.C SDL_ALPlaySound + SDL_ALSoundService (a per-tic F-number stream).
function buildAdlib() {
  // Instrument: mChar,cChar,mScale,cScale,mAttack,cAttack,mSus,cSus,mWave,cWave,nConn,+5 unused
  const inst = [0x01, 0x01, 0x2a, 0x00, 0xf0, 0xf0, 0x77, 0x77, 0x00, 0x00, 0x00, 0, 0, 0, 0, 0];
  const data = new Array(40).fill(0x98); // 40 tics of F-number 0x98 → ~0.29s @140Hz
  const buf = new Uint8Array(4 + 2 + 16 + 1 + data.length);
  const dv = new DataView(buf.buffer);
  dv.setUint32(0, data.length, true); // common.length
  dv.setUint16(4, 1, true); // priority
  buf.set(inst, 6);
  buf[22] = 4; // block
  buf.set(data, 23);
  return buf;
}
function renderAdlib(bytes, rate) {
  const dv = new DataView(bytes.buffer, bytes.byteOffset);
  const len = dv.getUint32(0, true);
  const inst = 6, block = bytes[22], data = 23;
  E.opl_reset(rate);
  E.opl_write(0x01, 0x20);
  E.opl_write(0xbd, 0x00);
  // SDL_AlSetFXInst: write the instrument to channel-0 ops (m=0, c=3)
  const setInst = () => {
    for (let k = 0; k < 2; k++) {
      const op = ops[k];
      E.opl_write(0x20 + op, bytes[inst + 0 + k]);
      E.opl_write(0x40 + op, bytes[inst + 2 + k]);
      E.opl_write(0x60 + op, bytes[inst + 4 + k]);
      E.opl_write(0x80 + op, bytes[inst + 6 + k]);
      E.opl_write(0xe0 + op, bytes[inst + 8 + k]);
    }
    E.opl_write(0xc0, 0x30); // alFeedCon = 0 + L/R enable
  };
  setInst();
  const alBlock = ((block & 7) << 2) | 0x20;
  const ticks = rate / 140; // SFX service runs at 140Hz
  const out = [];
  for (let i = 0; i < len; i++) {
    const s = bytes[data + i];
    if (!s) E.opl_write(0xb0, 0);
    else { E.opl_write(0xa0, s); E.opl_write(0xb0, alBlock); }
    out.push(generate(Math.round(ticks)));
  }
  E.opl_write(0xb0, 0);
  const total = out.reduce((s, a) => s + a.length, 0);
  const pcm = new Float32Array(total);
  let o = 0; for (const a of out) { pcm.set(a, o); o += a.length; }
  return pcm;
}
const sfx = renderAdlib(buildAdlib(), RATE);
check("AdLib SFX renders ~0.29s", Math.abs(sfx.length / RATE - 40 / 140) < 0.03, `${(sfx.length / RATE).toFixed(3)}s`);
check("AdLib SFX is audible", rms(sfx) > 0.02, `rms=${rms(sfx).toFixed(4)}`);

console.log(fail ? `\n${fail} check(s) FAILED` : "\nall OPL audio checks passed");
process.exit(fail ? 1 : 0);
