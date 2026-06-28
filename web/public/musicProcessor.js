// musicProcessor.js — an AudioWorklet that synthesises Wolfenstein 3D IMF music in REAL
// TIME on the audio rendering thread, via the Nuked-OPL3 wasm chip (passed in pre-compiled).
//
// Unlike a pre-render, this starts instantly, loops gaplessly, uses ~no memory, and can't be
// starved by the game's main-thread tx loop (the audio thread runs at real-time priority).
// It is the audio-thread twin of opl.ts's IMF replay (id ID_SD.C SDL_ALService @ 700Hz).
//
// Served as a plain classic worklet script (no imports). The main thread (web/src/audio.ts)
// fetches + compiles opl.wasm and hands the WebAssembly.Module + the raw IMF bytes in via
// processorOptions; we instantiate the module synchronously here.
class MusicProcessor extends AudioWorkletProcessor {
  constructor(options) {
    super();
    try {
      this._init(options.processorOptions);
    } catch (e) {
      this.port.postMessage({ err: String((e && e.stack) || e) });
      this.playing = false;
    }
  }

  _init({ module, imf }) {
    const E = new WebAssembly.Instance(module, {}).exports; // freestanding: no imports
    this.E = E;
    this.mem = E.memory;
    E.opl_reset(sampleRate); // the AudioContext's rate (a worklet global)

    // parse IMF: [u16 len][ reg u8, val u8, delay u16-LE ]… delay is in 1/700s ticks.
    const b = new Uint8Array(imf);
    const dv = new DataView(b.buffer, b.byteOffset, b.byteLength);
    const len = b[0] | (b[1] << 8);
    const spt = sampleRate / 700; // samples per IMF tick
    this.reg = []; this.val = []; this.at = []; // event i is applied at sample time at[i]
    let p = 2, t = 0;
    while (p + 4 <= 2 + len) {
      this.reg.push(dv.getUint8(p));
      this.val.push(dv.getUint8(p + 1));
      this.at.push(t);
      t += dv.getUint16(p + 2, true) * spt;
      p += 4;
    }
    this.loopLen = Math.max(1, t);
    this.pos = 0;   // sample position within the loop
    this.idx = 0;   // next event index
    this.playing = true;
    this.port.onmessage = (e) => { if (e.data === "stop") this.playing = false; };
  }

  // signature is process(inputs, outputs, parameters) — we have no inputs.
  process(_inputs, outputs) {
    if (!this.playing) return false; // tear down the node
    try {
      return this._render(outputs);
    } catch (e) {
      if (!this._reported) { this._reported = true; this.port.postMessage({ procErr: String(e && e.stack || e) }); }
      this.playing = false;
      return false;
    }
  }

  _render(outputs) {
    const out = outputs[0];
    const ch0 = out[0];
    const n = ch0.length; // render quantum (128)
    // apply every register write due by the end of this block (≤128-sample timing
    // quantization, ~2.7ms — inaudible), then synthesise the block.
    const blockEnd = this.pos + n;
    while (this.idx < this.reg.length && this.at[this.idx] <= blockEnd) {
      this.E.opl_write(this.reg[this.idx], this.val[this.idx]);
      this.idx++;
    }
    this.E.opl_generate(n);
    const buf = new Int16Array(this.mem.buffer, this.E.opl_buf(), n * 2);
    for (let i = 0; i < n; i++) {
      const s = (buf[i * 2] + buf[i * 2 + 1]) / 65536; // interleaved L/R → mono
      for (let c = 0; c < out.length; c++) out[c][i] = s;
    }
    this.pos = blockEnd;
    if (this.pos >= this.loopLen) { this.pos -= this.loopLen; this.idx = 0; } // loop (regs carry over, like id)
    return true;
  }
}
registerProcessor("music-processor", MusicProcessor);
