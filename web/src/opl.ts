// opl.ts — the OPL2/OPL3 chip (Nuked-OPL3, audio/build_opl.sh → /opl.wasm) plus the pure
// Wolf3D AdLib-SFX (140Hz) replay clock. Produces raw mono PCM (Float32Array) and touches
// NO Web Audio API. SFX are short, so audio.ts renders them inline on the main thread;
// MUSIC is synthesised in real time by public/musicProcessor.js (an AudioWorklet) instead,
// so it starts instantly and can't be starved by the game's tx loop. See audio.ts.

export type Opl = {
  reset(rate: number): void;
  write(reg: number, val: number): void;
  generate(nframes: number): Int16Array; // interleaved L/R view into wasm memory (len 2*n)
  maxframes: number;
};

export async function loadOpl(url = "/opl.wasm"): Promise<Opl | null> {
  try {
    const r = await fetch(url);
    if (!r.ok) return null;
    const { instance } = await WebAssembly.instantiate(await r.arrayBuffer());
    const E = instance.exports as any;
    const mem = E.memory as WebAssembly.Memory;
    const maxframes = E.opl_maxframes() as number;
    return {
      reset: (rate) => E.opl_reset(rate),
      write: (reg, val) => E.opl_write(reg, val),
      // a fresh view each call; opl.wasm never grows memory, so the buffer stays valid
      generate: (n) => (E.opl_generate(n), new Int16Array(mem.buffer, E.opl_buf(), n * 2)),
      maxframes,
    };
  } catch (e) {
    console.warn("opl.wasm unavailable:", e);
    return null;
  }
}

// channel-0 operator register offsets (modulator, carrier) — ID_SD.C carriers/modifiers.
const C0 = [0, 3];

// pull `frames` from the chip, appending mono samples (L/R averaged) to `chunks`.
function pull(opl: Opl, frames: number, chunks: Float32Array[]) {
  let done = 0;
  while (done < frames) {
    const n = Math.min(opl.maxframes, frames - done);
    const buf = opl.generate(n);
    const out = new Float32Array(n);
    for (let i = 0; i < n; i++) out[i] = (buf[i * 2] + buf[i * 2 + 1]) / 65536;
    chunks.push(out);
    done += n;
  }
}
function concat(chunks: Float32Array[]): Float32Array {
  let total = 0;
  for (const c of chunks) total += c.length;
  const out = new Float32Array(Math.max(1, total));
  let o = 0;
  for (const c of chunks) { out.set(c, o); o += c.length; }
  return out;
}

// AdLib SFX (id ID_SD.C SDL_ALPlaySound + SDL_ALSoundService, 140Hz): AdLibSound =
// {len u32, prio u16, Instrument[16], block u8, data[len]} — data is a per-tic F-number.
export function renderAdlib(opl: Opl, rate: number, bytes: Uint8Array): Float32Array {
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const len = dv.getUint32(0, true);
  const inst = 6, block = bytes[22], data = 23;
  if (len === 0 || data + len > bytes.length) return new Float32Array(1);
  opl.reset(rate);
  opl.write(0x01, 0x20); // waveform select on
  opl.write(0xbd, 0x00); // no rhythm
  for (let k = 0; k < 2; k++) {
    const op = C0[k]; // SDL_AlSetFXInst: instrument bytes are interleaved m,c per field
    opl.write(0x20 + op, bytes[inst + 0 + k]);
    opl.write(0x40 + op, bytes[inst + 2 + k]);
    opl.write(0x60 + op, bytes[inst + 4 + k]);
    opl.write(0x80 + op, bytes[inst + 6 + k]);
    opl.write(0xe0 + op, bytes[inst + 8 + k]);
  }
  opl.write(0xc0, 0x30); // alFeedCon=0 + OPL3 L/R enable
  const alBlock = ((block & 7) << 2) | 0x20;
  const f = Math.max(1, Math.round(rate / 140));
  const chunks: Float32Array[] = [];
  for (let i = 0; i < len; i++) {
    const s = bytes[data + i];
    if (!s) opl.write(0xb0, 0);
    else { opl.write(0xa0, s); opl.write(0xb0, alBlock); }
    pull(opl, f, chunks);
  }
  opl.write(0xb0, 0);
  return concat(chunks);
}
