//! map-extract — decode one Wolfenstein 3D level from MAPHEAD.WL1 / GAMEMAPS.WL1
//! into the geometry + spawns the client deploys as a `Map`.
//!
//! Reads **user-provided** shareware data; the extracted level (id's design) is
//! written to a `.gitignore`d JSON, never committed. Map planes are stored
//! Carmack-compressed wrapping an RLEW-compressed plane (ID_CA.C); plane 0 is the
//! tilemap, plane 1 holds spawns (ScanInfoPlane in WL_GAME.C).
//!
//! Layout (little-endian):
//!   MAPHEAD.WL1  : u16 rlewtag, then i32 offset[NUMMAPS] into GAMEMAPS (0 = none).
//!   GAMEMAPS.WL1 : at offset, maptype { i32 planestart[3]; u16 planelength[3];
//!                  u16 width, height; char name[16] }.
//!   each plane   : u16 carmack_explen, Carmack(data) → [u16 rlew_explen, RLEW(plane)].

use std::fs;
use std::path::PathBuf;

use anyhow::{anyhow, bail, Context, Result};
use clap::Parser;

#[derive(Parser)]
#[command(about = "Decode a Wolf3D level (MAPHEAD/GAMEMAPS) → level.json (user data; nothing committed)")]
struct Args {
    #[arg(long, default_value = "assets/wl1/MAPHEAD.WL1")]
    maphead: PathBuf,
    #[arg(long, default_value = "assets/wl1/GAMEMAPS.WL1")]
    gamemaps: PathBuf,
    /// level index (0 = E1L1).
    #[arg(long, default_value_t = 0)]
    map: usize,
    /// output JSON (consumed by the web client; .gitignored).
    #[arg(long, default_value = "web/public/level.json")]
    out: PathBuf,
    /// also print the decoded map as ASCII for a sanity check.
    #[arg(long)]
    ascii: bool,
}

fn u16le(d: &[u8], i: usize) -> u16 {
    u16::from_le_bytes([d[i], d[i + 1]])
}
fn i32le(d: &[u8], i: usize) -> i32 {
    i32::from_le_bytes([d[i], d[i + 1], d[i + 2], d[i + 3]])
}

/// Carmack expansion (near-tag 0xA7 = relative back-ref, far-tag 0xA8 = absolute).
fn carmack_expand(src: &[u8], explen_bytes: usize) -> Vec<u16> {
    const NEAR: u8 = 0xA7;
    const FAR: u8 = 0xA8;
    let words = explen_bytes / 2;
    let mut out: Vec<u16> = Vec::with_capacity(words);
    let mut i = 0usize;
    while out.len() < words {
        let ch = u16le(src, i);
        i += 2;
        let high = (ch >> 8) as u8;
        let count = (ch & 0xff) as usize;
        if high == NEAR && count != 0 {
            let offset = src[i] as usize;
            i += 1;
            let start = out.len() - offset;
            for k in 0..count {
                out.push(out[start + k]);
            }
        } else if high == FAR && count != 0 {
            let off = u16le(src, i) as usize;
            i += 2;
            for k in 0..count {
                out.push(out[off + k]);
            }
        } else if (high == NEAR || high == FAR) && count == 0 {
            // exception: a literal word whose high byte was a tag; real low byte follows
            let b = src[i];
            i += 1;
            out.push(((high as u16) << 8) | b as u16);
        } else {
            out.push(ch);
        }
    }
    out
}

/// RLEW expansion: words, with `tag` introducing a (count, value) run.
fn rlew_expand(src: &[u16], explen_words: usize, tag: u16) -> Vec<u16> {
    let mut out = Vec::with_capacity(explen_words);
    let mut i = 0usize;
    while out.len() < explen_words && i < src.len() {
        let v = src[i];
        i += 1;
        if v != tag {
            out.push(v);
        } else {
            let count = src[i] as usize;
            let value = src[i + 1];
            i += 2;
            for _ in 0..count {
                out.push(value);
            }
        }
    }
    out
}

fn decode_plane(maps: &[u8], start: usize, len: usize, tiles: usize, tag: u16) -> Result<Vec<u16>> {
    if start + len > maps.len() || len < 2 {
        bail!("plane out of range");
    }
    let comp = &maps[start..start + len];
    let carmack_explen = u16le(comp, 0) as usize; // bytes after Carmack expand
    let carmack = carmack_expand(&comp[2..], carmack_explen);
    // carmack[0] = the RLEW-expanded length word; the RLEW stream starts at [1]
    Ok(rlew_expand(&carmack[1..], tiles, tag))
}

const fn is_guard(t: u16) -> bool {
    // stand+patrol guards across the three difficulty bands (WL_GAME.C ScanInfoPlane)
    matches!(t, 108..=115 | 144..=151 | 180..=187)
}

fn main() -> Result<()> {
    let args = Args::parse();
    let head = fs::read(&args.maphead)
        .with_context(|| format!("reading {} (run scripts/fetch-shareware.sh)", args.maphead.display()))?;
    let maps = fs::read(&args.gamemaps).with_context(|| format!("reading {}", args.gamemaps.display()))?;

    let rlewtag = u16le(&head, 0);
    let num = (head.len() - 2) / 4;
    let offset = (0..num)
        .map(|i| i32le(&head, 2 + i * 4))
        .nth(args.map)
        .ok_or_else(|| anyhow!("map index {} out of range (0..{num})", args.map))?;
    if offset <= 0 {
        bail!("map {} is empty", args.map);
    }
    let o = offset as usize;

    let planestart = [i32le(&maps, o) as usize, i32le(&maps, o + 4) as usize];
    let planelen = [u16le(&maps, o + 12) as usize, u16le(&maps, o + 14) as usize];
    let w = u16le(&maps, o + 18) as usize;
    let h = u16le(&maps, o + 20) as usize;
    let name = String::from_utf8_lossy(&maps[o + 22..o + 38]).trim_end_matches('\0').trim().to_string();
    if w == 0 || h == 0 || w > 128 || h > 128 {
        bail!("nonsensical map dims {w}x{h}");
    }

    let plane0 = decode_plane(&maps, planestart[0], planelen[0], w * h, rlewtag)?; // tilemap
    let plane1 = decode_plane(&maps, planestart[1], planelen[1], w * h, rlewtag)?; // spawns

    // scan plane 1 for the player start + guards; plane 0 holds wall textures
    let mut spawn = None;
    let mut guards = Vec::new();
    for y in 0..h {
        for x in 0..w {
            let t = plane1[y * w + x];
            if (19..=22).contains(&t) {
                spawn = Some((x, y, (t - 19) as u8)); // dir: N=0 E=1 S=2 W=3
            } else if is_guard(t) {
                guards.push([x, y, (t & 3) as usize]); // facing 0..3 (each 4-code group)
            }
        }
    }
    let (sx, sy, sdir) = spawn.ok_or_else(|| anyhow!("no player start (tiles 19-22) in plane 1"))?;

    if args.ascii {
        for y in 0..h {
            let mut row = String::new();
            for x in 0..w {
                let t = plane0[y * w + x];
                let p1 = plane1[y * w + x];
                row.push(if (x, y) == (sx, sy) {
                    '@'
                } else if is_guard(p1) {
                    'G'
                } else if (1..90).contains(&t) {
                    '#'
                } else {
                    ' '
                });
            }
            println!("{row}");
        }
    }

    let level = serde_json::json!({
        "name": name,
        "w": w, "h": h,
        "spawn": { "x": sx, "y": sy, "dir": sdir },
        "tiles": plane0,            // plane-0 values: wall if 1..=89, else floor (texture = (v-1)*2)
        "guards": guards,           // [tilex, tiley] per guard
    });
    if let Some(dir) = args.out.parent() {
        fs::create_dir_all(dir)?;
    }
    fs::write(&args.out, serde_json::to_vec_pretty(&level)?)?;
    println!(
        "map-extract: \"{name}\" {w}x{h} — player @({sx},{sy}) dir {sdir}, {} guards -> {}",
        guards.len(),
        args.out.display()
    );
    Ok(())
}
