//! audio.rs — decode Wolf3D's sound assets for the off-chain web client (M7):
//!   * **digitized SFX** from `VSWAP` (8-bit PCM → 16-bit WAV), and
//!   * **AdLib SFX** + **IMF music** from `AUDIOHED`/`AUDIOT` (raw OPL2 streams the
//!     client plays through a Nuked-OPL3 wasm emulator).
//!
//! Reads **user-provided** shareware data; **no id Software audio is committed** (the
//! output dir is .gitignored, like the textures). Every format/offset/table here is
//! taken straight from id's GPL source in `reference/wolf3d`:
//!   - digi info page + `DigiList` walk:  `ID_SD.C` `SDL_SetupDigi`/`SD_PlayDigitized`
//!   - digi soundname→index map:          `WL_MAIN.C` `wolfdigimap[]` / `InitDigiMap`
//!   - `AUDIOHED`/`AUDIOT` chunk layout:  `ID_CA.C` `CA_CacheAudioChunk` (WL1 = uncompressed)
//!   - audio-chunk block offsets:         `AUDIOWL1.H` (NUMSOUNDS=69 ⟹ AdLib@69, digi@138, music@207)
//!   - AdLib `AdLibSound` struct + music `MusicGroup`: `ID_SD.H`

use std::path::Path;

use anyhow::{bail, Context, Result};

/// Digitized sounds play back at ~7 kHz on the Sound Blaster (id's DMA time constant).
pub const DIGI_HZ: u32 = 7000;

/// `wolfdigimap[]` from `WL_MAIN.C` (the non-SPEAR table): digitized-sound **name** →
/// its index in the VSWAP digi list. We emit names (not the per-episode enum values, which
/// differ between `AUDIOWL1.H`/`AUDIOWL6.H`) so the client maps game events → file by name.
/// Indices past the shareware VSWAP's `NumDigi` simply have no file; the client falls back
/// to the AdLib version of that sound. Doubly-mapped DEATHSCREAM3SND→13 is faithful to id.
pub const WOLFDIGIMAP: &[(&str, usize)] = &[
    ("HALTSND", 0),
    ("DOGBARKSND", 1),
    ("CLOSEDOORSND", 2),
    ("OPENDOORSND", 3),
    ("ATKMACHINEGUNSND", 4),
    ("ATKPISTOLSND", 5),
    ("ATKGATLINGSND", 6),
    ("SCHUTZADSND", 7),
    ("GUTENTAGSND", 8),
    ("MUTTISND", 9),
    ("BOSSFIRESND", 10),
    ("SSFIRESND", 11),
    ("DEATHSCREAM1SND", 12),
    ("DEATHSCREAM2SND", 13),
    ("DEATHSCREAM3SND", 13),
    ("TAKEDAMAGESND", 14),
    ("PUSHWALLSND", 15),
    ("LEBENSND", 20),
    ("NAZIFIRESND", 21),
    ("SLURPIESND", 22),
    // registered-only (absent from the shareware VSWAP, harmless if their index ≥ NumDigi)
    ("DOGDEATHSND", 16),
    ("AHHHGSND", 17),
    ("DIESND", 18),
    ("EVASND", 19),
    ("TOT_HUNDSND", 23),
    ("MEINGOTTSND", 24),
    ("SCHABBSHASND", 25),
    ("HITLERHASND", 26),
    ("SPIONSND", 27),
    ("NEINSOVASSND", 28),
    ("DOGATTACKSND", 29),
    ("LEVELDONESND", 30),
    ("MECHSTEPSND", 31),
];

/// One digitized sound located in the VSWAP sound pages.
pub struct DigiEntry {
    /// Page index **relative to** `PMSoundStart` (the VSWAP `sound_start`).
    pub start_page_rel: usize,
    /// Total length in bytes (`DigiList[which*2+1]`).
    pub length: usize,
}

/// Walk the VSWAP digi **info page** (the last chunk) exactly as `ID_SD.C SDL_SetupDigi`
/// does: it's an array of `(startPageRel, lengthBytes)` u16 pairs, and `NumDigi` is the
/// count of pairs whose pages fit before the info page itself (`ChunksInFile-1`).
pub fn parse_digi_info(info_page: &[u8], sound_start: usize, total_chunks: usize) -> Vec<DigiEntry> {
    const PAGE: usize = 4096; // PMPageSize
    let mut out = Vec::new();
    let mut pg = sound_start; // id seeds the running page counter at PMSoundStart
    let max_pairs = info_page.len() / 4;
    for i in 0..max_pairs {
        if pg >= total_chunks - 1 {
            break; // ran into the info page → no more digi sounds
        }
        let start = u16::from_le_bytes([info_page[i * 4], info_page[i * 4 + 1]]) as usize;
        let len = u16::from_le_bytes([info_page[i * 4 + 2], info_page[i * 4 + 3]]) as usize;
        out.push(DigiEntry { start_page_rel: start, length: len });
        pg += (len + PAGE - 1) / PAGE; // advance by the number of pages this sound spans
    }
    out
}

/// Write 8-bit **unsigned** PCM (as stored in the VSWAP) to a 16-bit **signed** mono WAV —
/// the universally `decodeAudioData`-friendly form. `s16 = (s8 - 128) << 8`.
pub fn write_wav_u8(path: &Path, pcm: &[u8], hz: u32) -> Result<()> {
    let n = pcm.len();
    let data_bytes = n * 2; // 16-bit samples
    let byte_rate = hz * 2; // mono, 2 bytes/sample
    let mut w = Vec::with_capacity(44 + data_bytes);
    w.extend_from_slice(b"RIFF");
    w.extend_from_slice(&((36 + data_bytes) as u32).to_le_bytes());
    w.extend_from_slice(b"WAVE");
    w.extend_from_slice(b"fmt ");
    w.extend_from_slice(&16u32.to_le_bytes()); // PCM fmt chunk size
    w.extend_from_slice(&1u16.to_le_bytes()); // PCM
    w.extend_from_slice(&1u16.to_le_bytes()); // mono
    w.extend_from_slice(&hz.to_le_bytes());
    w.extend_from_slice(&byte_rate.to_le_bytes());
    w.extend_from_slice(&2u16.to_le_bytes()); // block align
    w.extend_from_slice(&16u16.to_le_bytes()); // bits/sample
    w.extend_from_slice(b"data");
    w.extend_from_slice(&(data_bytes as u32).to_le_bytes());
    for &s in pcm {
        let v = ((s as i16) - 128) << 8;
        w.extend_from_slice(&v.to_le_bytes());
    }
    std::fs::write(path, &w).with_context(|| format!("write {}", path.display()))
}

/// Result of slicing `AUDIOT` into the client's per-sound / per-track files.
pub struct AudiotOut {
    /// soundname index (0..num_sounds) of each AdLib SFX written (non-empty chunks).
    pub adlib: Vec<usize>,
    /// music-track index (0..) of each IMF track written.
    pub music: Vec<usize>,
}

/// A music chunk is `[u16 len][len bytes of 4-byte IMF events][optional MUSE title tag]`
/// (id `MusicGroup` / `SDL_ALService`: it reads exactly `len` bytes and ignores any tail).
/// So a valid track has a 4-aligned, non-empty length prefix that fits inside the chunk.
fn looks_like_imf(c: &[u8]) -> bool {
    if c.len() < 6 {
        return false;
    }
    let prefix = u16::from_le_bytes([c[0], c[1]]) as usize;
    prefix >= 4 && prefix % 4 == 0 && prefix + 2 <= c.len()
}

/// Slice `AUDIOT` using `AUDIOHED`'s u32 offset table (WL1: chunks are **uncompressed**,
/// per `ID_CA.C` with `AUDIOHEADERLINKED` undefined). Block layout (`AUDIOWL1.H`):
/// `[0,N)` PC speaker (ignored), `[N,2N)` AdLib SFX, `[2N,3N)` digi headers (the PCM is in
/// VSWAP), `[3N, end)` IMF music — where `N = NUMSOUNDS`. `num_sounds = None` **auto-detects**
/// `N` (the shareware data ships with the 87-sound registered header, not `AUDIOWL1.H`'s 69),
/// by checking which stride puts a valid IMF chunk at `STARTMUSIC = 3N`.
pub fn extract_audiot(
    audiohead: &[u8],
    audiot: &[u8],
    num_sounds: Option<usize>,
    out: &Path,
) -> Result<AudiotOut> {
    if audiohead.len() < 8 {
        bail!("AUDIOHED too small ({} bytes)", audiohead.len());
    }
    let starts: Vec<usize> = audiohead
        .chunks_exact(4)
        .map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]) as usize)
        .collect();
    let num_chunks = starts.len() - 1; // last entry is the end-of-file marker
    let chunk = |c: usize| -> Option<&[u8]> {
        if c + 1 >= starts.len() {
            return None;
        }
        let (a, b) = (starts[c], starts[c + 1]);
        if b <= a || b > audiot.len() {
            return None; // empty / out of range
        }
        Some(&audiot[a..b])
    };

    // resolve the block stride: explicit, else the first of the two real Wolf3D values
    // (69 = AUDIOWL1.H, 87 = registered/SOD) whose 3N chunk is valid IMF music.
    let num_sounds = match num_sounds {
        Some(n) => n,
        None => [69usize, 87]
            .into_iter()
            .find(|&n| 3 * n < num_chunks && chunk(3 * n).map(looks_like_imf).unwrap_or(false))
            .ok_or_else(|| anyhow::anyhow!("could not auto-detect NUMSOUNDS (no valid IMF at 3·69 or 3·87) — pass --num-sounds"))?,
    };
    let start_adlib = num_sounds; // STARTADLIBSOUNDS
    let start_music = 3 * num_sounds; // STARTMUSIC
    if start_music >= num_chunks {
        bail!(
            "AUDIOT has {num_chunks} chunks but STARTMUSIC={start_music} (wrong --num-sounds for this episode?)"
        );
    }

    let mut adlib = Vec::new();
    for s in 0..num_sounds {
        if let Some(data) = chunk(start_adlib + s) {
            std::fs::write(out.join(format!("adlib_{s:03}.bin")), data)?;
            adlib.push(s);
        }
    }

    // index music by its position in the block (= musicnames enum order, so E1L1's
    // GETTHEM_MUS is always music_003) and keep only real IMF chunks.
    let mut music = Vec::new();
    for c in start_music..num_chunks {
        if let Some(data) = chunk(c) {
            if !looks_like_imf(data) {
                continue;
            }
            let m = c - start_music;
            std::fs::write(out.join(format!("music_{m:03}.imf")), data)?;
            music.push(m);
        }
    }

    Ok(AudiotOut { adlib, music })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn digi_info_walk() {
        // sound_start=10, total_chunks=14 → info page is chunk 13, digi pages [10,13) =
        // three 1-page sounds. id checks `pg` at the TOP of each iteration, so all three fit
        // (pg goes 10→11→12, each < 13); the 4th iteration sees pg==13 and stops.
        let mut info = vec![0u8; 4096];
        let put = |info: &mut [u8], i: usize, sp: u16, ln: u16| {
            info[i * 4..i * 4 + 2].copy_from_slice(&sp.to_le_bytes());
            info[i * 4 + 2..i * 4 + 4].copy_from_slice(&ln.to_le_bytes());
        };
        put(&mut info, 0, 0, 4096);
        put(&mut info, 1, 1, 4000);
        put(&mut info, 2, 2, 10);
        put(&mut info, 3, 3, 99); // beyond the available pages → not returned
        let d = parse_digi_info(&info, 10, 14);
        assert_eq!(d.len(), 3);
        assert_eq!((d[0].start_page_rel, d[0].length), (0, 4096));
        assert_eq!((d[1].start_page_rel, d[1].length), (1, 4000));
        assert_eq!((d[2].start_page_rel, d[2].length), (2, 10));
    }

    #[test]
    fn wav_roundtrip_header() {
        let dir = std::env::temp_dir().join("wlx_audio_test");
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("t.wav");
        write_wav_u8(&p, &[128, 0, 255], 7000).unwrap();
        let b = std::fs::read(&p).unwrap();
        assert_eq!(&b[0..4], b"RIFF");
        assert_eq!(&b[8..12], b"WAVE");
        assert_eq!(u32::from_le_bytes([b[24], b[25], b[26], b[27]]), 7000); // sample rate
        // first sample (128 unsigned) → 0 signed
        assert_eq!(i16::from_le_bytes([b[44], b[45]]), 0);
        // 0 unsigned → -32768; 255 → 127<<8
        assert_eq!(i16::from_le_bytes([b[46], b[47]]), -32768);
    }

    #[test]
    fn audiot_slice() {
        // num_sounds=1 → AdLib@1, digi@2, music@3. 5 chunks + EOF marker.
        // chunk0 PC(skip), chunk1 AdLib, chunk2 digi-hdr(skip), chunk3 music, chunk4 music.
        // music chunks must be valid IMF ([u16 len=4][one 4-byte event]) to be kept.
        let imf0: &[u8] = &[4, 0, 0xa0, 0x98, 1, 0];
        let imf1: &[u8] = &[4, 0, 0xb0, 0x31, 2, 0];
        let bodies: [&[u8]; 5] = [b"PC__", b"ADLB", b"DIGI", imf0, imf1];
        let mut audiot = Vec::new();
        let mut starts = Vec::new();
        for body in bodies {
            starts.push(audiot.len() as u32);
            audiot.extend_from_slice(body);
        }
        starts.push(audiot.len() as u32); // EOF marker
        let mut head = Vec::new();
        for s in &starts {
            head.extend_from_slice(&s.to_le_bytes());
        }
        let dir = std::env::temp_dir().join("wlx_audiot_test");
        std::fs::create_dir_all(&dir).unwrap();
        let r = extract_audiot(&head, &audiot, Some(1), &dir).unwrap();
        assert_eq!(r.adlib, vec![0]);
        assert_eq!(r.music, vec![0, 1]);
        assert_eq!(std::fs::read(dir.join("adlib_000.bin")).unwrap(), b"ADLB");
        assert_eq!(std::fs::read(dir.join("music_000.imf")).unwrap(), imf0);
        assert_eq!(std::fs::read(dir.join("music_001.imf")).unwrap(), imf1);
    }
}
