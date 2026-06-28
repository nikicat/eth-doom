// audio.ts — off-chain sound for the on-chain world (M7).
//
// Wolf3D's audio, like its rendering, was render-coupled and stays OFF-CHAIN: the client
// watches the decoded packed state for deltas (a gun fired, a guard died, a door opened)
// and plays the matching sound, positioned relative to the player. Nothing here touches
// the sim — exactly the sim↔render split in docs/DESIGN.md.
//
// Three faithful sources, all decoded from the user's shareware by `wl-extract` (nothing
// id-owned committed):
//   * digitized SFX  — VSWAP PCM → digi_NNN.wav (decodeAudioData)
//   * AdLib SFX      — AUDIOT AdLibSound chunks → adlib_NNN.bin, synthesised via opl.wasm
//   * IMF music      — AUDIOT music chunks → music_NNN.imf, synthesised via opl.wasm
// id played the digitized version of a sound when present and the AdLib version otherwise
// (ID_SD.C `SD_PlaySound` → `DigiMap`); we do the same. opl.wasm is Nuked-OPL3 (the same
// YM3812 id drove); see audio/opl_wasm.c. SFX render inline (opl.ts); MUSIC is synthesised
// in real time by public/musicProcessor.js (an AudioWorklet) so it starts instantly and is
// never starved by the game's main-thread tx loop.
import { loadOpl, renderAdlib } from "./opl";

function toBuffer(ctx: AudioContext, pcm: Float32Array): AudioBuffer {
  const ab = ctx.createBuffer(1, Math.max(1, pcm.length), ctx.sampleRate);
  if (pcm.length) ab.getChannelData(0).set(pcm);
  return ab;
}

// --- AUDIOWL1.H soundnames → AdLib chunk index (adlib_NNN.bin name) --------------
// Only the events the client can detect from state deltas need entries.
const SND: Record<string, number> = {
  NOWAYSND: 6, PLAYERDEATHSND: 9, DOGDEATHSND: 10, ATKGATLINGSND: 11, GETKEYSND: 12,
  TAKEDAMAGESND: 16, OPENDOORSND: 18, CLOSEDOORSND: 19, HALTSND: 21, DEATHSCREAM2SND: 22,
  ATKKNIFESND: 23, ATKPISTOLSND: 24, DEATHSCREAM3SND: 25, ATKMACHINEGUNSND: 26,
  DEATHSCREAM1SND: 29, GETMACHINESND: 30, GETAMMOSND: 31, HEALTH1SND: 33, HEALTH2SND: 34,
  BONUS1SND: 35, BONUS2SND: 36, BONUS3SND: 37, GETGATLINGSND: 38, LEVELDONESND: 40,
  DOGBARKSND: 41, BONUS4SND: 45, PUSHWALLSND: 46, SCHUTZADSND: 51, NAZIFIRESND: 58,
  SSFIRESND: 60, SPIONSND: 66,
};

type AudioManifest = {
  digi_count: number;
  digi_hz: number;
  digimap: Record<string, number>; // soundname → digi-list index
  adlib: number[]; // soundname indices with an AdLib chunk
  music: number[]; // music-track indices present
};

export type AudioEngine = {
  unlocked: boolean;
  muted: boolean;
  hasMusic: boolean;
  label(): string;
  unlock(): Promise<void>; // resume the AudioContext + start music (first user gesture)
  toggleMute(): void;
  play(sound: string, pan: number, gain: number): void; // pan −1..1, gain 0..1
  startMusic(track: number): void;
};

// Wolf3D E1L1 plays "Get Them For Greater Justice!" (GETTHEM_MUS = music index 3 in
// AUDIOWL1.H musicnames). Render-side default; harmless if the track isn't present.
export const E1L1_MUSIC = 3;

export async function loadAudio(): Promise<AudioEngine | null> {
  let man: AudioManifest;
  try {
    const r = await fetch("/wolf/manifest.json");
    if (!r.ok) return null;
    const j = await r.json();
    if (!j.audio) return null;
    man = j.audio as AudioManifest;
  } catch {
    return null;
  }
  const hasDigi = (man.digi_count ?? 0) > 0;
  const hasOplData = (man.adlib?.length ?? 0) > 0 || (man.music?.length ?? 0) > 0;
  if (!hasDigi && !hasOplData) return null;

  const opl = hasOplData ? await loadOpl() : null;

  const AC = (window.AudioContext || (window as any).webkitAudioContext) as typeof AudioContext;
  const ctx = new AC();
  const master = ctx.createGain();
  master.connect(ctx.destination);
  const sfxBus = ctx.createGain();
  sfxBus.gain.value = 0.8;
  sfxBus.connect(master);
  const musicBus = ctx.createGain();
  musicBus.gain.value = 0.45;
  musicBus.connect(master);

  // per-soundname resolved AudioBuffer (digi preferred, AdLib fallback), loaded once.
  const cache = new Map<string, Promise<AudioBuffer | null>>();
  const adlibSet = new Set(man.adlib ?? []);

  async function fetchBytes(url: string): Promise<Uint8Array | null> {
    const r = await fetch(url);
    return r.ok ? new Uint8Array(await r.arrayBuffer()) : null;
  }

  function resolve(sound: string): Promise<AudioBuffer | null> {
    let p = cache.get(sound);
    if (p) return p;
    p = (async () => {
      // 1. digitized version (VSWAP) if mapped + extracted
      const di = man.digimap?.[sound];
      if (di !== undefined && di < man.digi_count) {
        const r = await fetch(`/wolf/digi_${String(di).padStart(3, "0")}.wav`);
        if (r.ok) return await ctx.decodeAudioData(await r.arrayBuffer());
      }
      // 2. AdLib version (synthesised) otherwise
      const si = SND[sound];
      if (opl && si !== undefined && adlibSet.has(si)) {
        const b = await fetchBytes(`/wolf/adlib_${String(si).padStart(3, "0")}.bin`);
        if (b) return toBuffer(ctx, renderAdlib(opl, ctx.sampleRate, b)); // SFX are short → render inline
      }
      return null;
    })().catch((e) => (console.warn("sound load failed", sound, e), null));
    cache.set(sound, p);
    return p;
  }

  // MUSIC via an AudioWorklet (public/musicProcessor.js): the OPL chip runs on the audio
  // thread and synthesises in real time, so music starts instantly, loops gaplessly, and is
  // never starved by the main-thread tx loop. We pre-compile opl.wasm to a Module + register
  // the worklet during the deploy phase so it's ready by the first keypress.
  let musicNode: AudioWorkletNode | null = null;
  let musicGen = 0; // bumped on every startMusic; a stale async start is dropped
  let oplModule: WebAssembly.Module | null = null;
  let workletReady: Promise<boolean> | null = null;
  if (opl && (man.music?.length ?? 0) > 0 && (ctx as any).audioWorklet) {
    workletReady = (async () => {
      try {
        oplModule = await WebAssembly.compile(await (await fetch("/opl.wasm")).arrayBuffer());
        await ctx.audioWorklet.addModule("/musicProcessor.js");
        return true;
      } catch (e) {
        return (console.warn("music worklet unavailable:", e), false);
      }
    })();
  }
  const engine: AudioEngine = {
    unlocked: false,
    muted: false,
    hasMusic: !!workletReady,
    label() {
      if (this.muted) return "muted (M)";
      if (!this.unlocked) return "press a key to enable";
      const parts = [`${man.digi_count} digi`];
      if (opl) parts.push(`${man.adlib.length} adlib`, `${man.music.length} music`);
      return `on · ${parts.join(" · ")}`;
    },
    async unlock() {
      if (this.unlocked) return;
      this.unlocked = true; // set synchronously so rapid re-entrant keydowns don't double-start
      try { await ctx.resume(); } catch {}
      if (this.hasMusic && !this.muted) this.startMusic(E1L1_MUSIC);
      // prewarm the common sounds so the first shot/door isn't late
      for (const s of ["ATKPISTOLSND", "OPENDOORSND", "CLOSEDOORSND", "TAKEDAMAGESND"]) resolve(s);
    },
    toggleMute() {
      this.muted = !this.muted;
      master.gain.value = this.muted ? 0 : 1;
      if (this.muted) this.startMusic(-1); // stop
      else if (this.unlocked && this.hasMusic) this.startMusic(E1L1_MUSIC);
    },
    play(sound, pan, gain) {
      if (!this.unlocked || this.muted || gain <= 0) return;
      resolve(sound).then((buf) => {
        if (!buf) return;
        const src = ctx.createBufferSource();
        src.buffer = buf;
        const g = ctx.createGain();
        g.gain.value = Math.min(1, gain);
        const pan_ = ctx.createStereoPanner();
        pan_.pan.value = Math.max(-1, Math.min(1, pan));
        src.connect(g).connect(pan_).connect(sfxBus);
        src.start();
      });
    },
    startMusic(track) {
      const gen = ++musicGen; // invalidate any in-flight start from a previous call
      if (musicNode) { try { musicNode.port.postMessage("stop"); musicNode.disconnect(); } catch {} musicNode = null; }
      if (track < 0 || !workletReady || !(man.music ?? []).includes(track)) return;
      (async () => {
        const ok = await workletReady;
        if (!ok || !oplModule || gen !== musicGen) return;
        const b = await fetchBytes(`/wolf/music_${String(track).padStart(3, "0")}.imf`);
        if (!b || this.muted || gen !== musicGen) return; // superseded / muted meanwhile
        const node = new AudioWorkletNode(ctx, "music-processor", {
          numberOfInputs: 0,
          outputChannelCount: [2],
          processorOptions: { module: oplModule, imf: b.buffer },
        });
        node.port.onmessage = (ev) => { // the processor only messages on failure
          const m = ev.data?.err ?? ev.data?.procErr;
          if (m) console.warn("[music worklet]", m);
        };
        node.onprocessorerror = (ev) => console.error("[music worklet] processorerror", ev);
        node.connect(musicBus);
        musicNode = node;
      })();
    },
  };
  return engine;
}
