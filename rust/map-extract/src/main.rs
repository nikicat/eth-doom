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

/// WL_GAME.C ScanInfoPlane enemy codes: each (enemy, difficulty-band) is 8 codes
/// (4 stand + 4 patrol), dir = (code - base) & 3. Returns (enemy_t class, dir).
/// class: 0 guard, 1 officer, 2 SS, 3 dog (the engine spawns guard/SS, others fall
/// back to guard until implemented).
fn enemy_spawn(t: u16) -> Option<(u8, u8)> {
    const BANDS: &[(u16, u8)] = &[
        (108, 0), (144, 0), (180, 0), // guard
        (116, 1), (152, 1), (188, 1), // officer
        (126, 2), (162, 2), (198, 2), // SS
        (134, 3), (170, 3), (206, 3), // dog
    ];
    for &(base, cls) in BANDS {
        if (base..base + 8).contains(&t) {
            return Some((cls, ((t - base) & 3) as u8));
        }
    }
    None
}

/// WL1 statinfo[] type per index (WL_ACT1.C): 0 = non-bonus (dressing/block);
/// else the stat_t bonus number. Plane-1 info code `t` indexes statinfo at t-23
/// (WL_GAME.C ScanInfoPlane: `case 23..` -> SpawnStatic(x,y,tile-23)).
const STATINFO_BO: [u8; 49] = [
    0, 0, 0, 0, 0, 0, 4, 0, // 0..7   (idx6 bo_alpo)
    0, 0, 0, 0, 0, 0, 0, 0, // 8..15
    0, 0, 0, 0, 6, 7, 0, 0, // 16..23 (idx20 bo_key1, idx21 bo_key2)
    18, 5, 14, 16, 17, 10, 11, 12, // 24..31 (food,firstaid,clip,mg,cg,cross,chalice,bible)
    13, 19, 3, 0, 0, 0, 3, 0, // 32..39 (crown,fullheal,gibs,…,gibs)
    0, 0, 0, 0, 0, 0, 0, 0, // 40..47
    15, // 48 bo_clip2
];

fn bonus_item(t: u16) -> Option<u8> {
    if t < 23 {
        return None;
    }
    let idx = (t - 23) as usize;
    STATINFO_BO.get(idx).copied().filter(|&bo| bo != 0)
}

const AREATILE: u16 = 107;
const AMBUSHTILE: u16 = 106;

/// WL_GAME.C SetupGameLevel: turn raw plane-0 codes into the runtime tilemap the
/// engine/client consume, and collect the door list (scan order = doornum).
///   - 90..=101 door  -> tile = doornum|0x80 ; door = (x, y, vertical|lock<<1)
///   - 1..<AREATILE   -> solid wall (keep the value; AMBUSHTILE clears to floor)
///   - else (areas/0) -> floor (0)
/// vertical/lock follow id's even=vertical/odd=horizontal door encoding.
/// 0x-prefixed lowercase hex of `bytes` (for the JSON fields Deploy.s.sol reads).
fn to_hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(2 + bytes.len() * 2);
    s.push_str("0x");
    for b in bytes {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

fn build_tilemap(plane0: &[u16], w: usize, h: usize) -> (Vec<u8>, Vec<[u8; 3]>) {
    let mut tiles = vec![0u8; w * h];
    let mut doors = Vec::new();
    let mut doornum: u8 = 0;
    for y in 0..h {
        for x in 0..w {
            let t = plane0[y * w + x];
            if (90..=101).contains(&t) {
                let vertical: u8 = if t % 2 == 0 { 1 } else { 0 };
                let lock: u8 = if t % 2 == 0 { ((t - 90) / 2) as u8 } else { ((t - 91) / 2) as u8 };
                tiles[y * w + x] = 0x80 | doornum;
                doors.push([x as u8, y as u8, vertical | (lock << 1)]);
                doornum += 1;
            } else if t >= 1 && t < AREATILE && t != AMBUSHTILE {
                tiles[y * w + x] = t as u8; // solid wall (texture = (t-1)*2)
            }
        }
    }
    (tiles, doors)
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

    // scan plane 1 for the player start + enemies + bonus items; plane 0 holds geometry
    let mut spawn = None;
    let mut guards: Vec<[u8; 4]> = Vec::new();
    let mut items: Vec<[u8; 3]> = Vec::new();
    for y in 0..h {
        for x in 0..w {
            let t = plane1[y * w + x];
            if (19..=22).contains(&t) {
                spawn = Some((x, y, (t - 19) as u8)); // dir: N=0 E=1 S=2 W=3
            } else if let Some((cls, dir)) = enemy_spawn(t) {
                guards.push([x as u8, y as u8, dir, cls]); // tilex, tiley, dir, class
            } else if let Some(bo) = bonus_item(t) {
                items.push([x as u8, y as u8, bo]); // tilex, tiley, itemnumber
            }
        }
    }
    let (sx, sy, sdir) = spawn.ok_or_else(|| anyhow!("no player start (tiles 19-22) in plane 1"))?;

    let (tiles, doors) = build_tilemap(&plane0, w, h);

    if args.ascii {
        for y in 0..h {
            let mut row = String::new();
            for x in 0..w {
                let t = plane0[y * w + x];
                let p1 = plane1[y * w + x];
                row.push(if (x, y) == (sx, sy) {
                    '@'
                } else if enemy_spawn(p1).is_some() {
                    'G'
                } else if (90..=101).contains(&t) {
                    'D'
                } else if (1..90).contains(&t) {
                    '#'
                } else {
                    ' '
                });
            }
            println!("{row}");
        }
    }

    // Flat 0x-hex of the exact bytes each Map constructor arg wants, so the Foundry
    // Deploy.s.sol reads them with one vm.parseBytes each (no nested-array JSON parsing).
    let flat = |rows: &[Vec<u8>]| -> Vec<u8> { rows.iter().flatten().copied().collect() };
    let guards_flat = flat(&guards.iter().map(|g| g.to_vec()).collect::<Vec<_>>());
    let doors_flat = flat(&doors.iter().map(|d| d.to_vec()).collect::<Vec<_>>());
    let items_flat = flat(&items.iter().map(|i| i.to_vec()).collect::<Vec<_>>());

    // per-tile area number for sound localization: plane-0 floor codes >= AREATILE encode
    // the area (tile - AREATILE); walls/doors get 0 (the engine fixes up door tiles).
    const AREATILE: u16 = 107;
    let areas: Vec<u8> = plane0.iter().map(|&t| if t >= AREATILE { (t - AREATILE) as u8 } else { 0 }).collect();

    let level = serde_json::json!({
        "name": name,
        "w": w, "h": h,
        "spawn": { "x": sx, "y": sy, "dir": sdir },
        "tiles": tiles,             // runtime tilemap: 1..=89 wall (texture (v-1)*2), 0x80|n door, 0 floor
        "guards": guards,           // [tilex, tiley, dir, class] per enemy (0 guard, 2 SS, 1/3 -> guard)
        "doors": doors,             // [tilex, tiley, vertical|lock<<1] per door, in doornum order
        "items": items,             // [tilex, tiley, itemnumber] per bonus item
        "areas": areas,             // per-tile area number (sound localization via ConnectAreas)
        // flat-bytes mirror of the arrays above, for script/Deploy.s.sol:
        "tilesHex": to_hex(&tiles),
        "guardsHex": to_hex(&guards_flat),
        "doorsHex": to_hex(&doors_flat),
        "itemsHex": to_hex(&items_flat),
        "areasHex": to_hex(&areas),
    });
    if let Some(dir) = args.out.parent() {
        fs::create_dir_all(dir)?;
    }
    fs::write(&args.out, serde_json::to_vec_pretty(&level)?)?;
    println!(
        "map-extract: \"{name}\" {w}x{h} — player @({sx},{sy}) dir {sdir}, {} guards, {} doors, {} items -> {}",
        guards.len(),
        doors.len(),
        items.len(),
        args.out.display()
    );
    Ok(())
}
