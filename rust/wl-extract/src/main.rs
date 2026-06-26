//! wl-extract — decode Wolfenstein 3D's `VSWAP.WL1` into PNG wall textures and
//! sprite frames the web client loads at runtime.
//!
//! Reads a **user-provided** shareware data file; **no id Software art is committed**
//! to this repo (the output dir is .gitignored). The VSWAP layout and the sprite
//! (compshape) decode are taken straight from id's GPL source in `reference/wolf3d`
//! (`ID_PM.C` header, `WL_SCALE.C`/`OLDSCALE.C` post format). The palette is the
//! game's VGA color table (data, reproduced in every open-source port).
//!
//! VSWAP.WL1 layout (little-endian):
//!   u16 chunks_in_file
//!   u16 sprite_start      // first sprite page
//!   u16 sound_start       // first sound page
//!   u32 page_offset[chunks_in_file]   // byte offset of each page (0 = sparse)
//!   u16 page_length[chunks_in_file]
//!   pages [0, sprite_start)            : walls   — 64x64, column-major, 1 byte/pixel
//!   pages [sprite_start, sound_start)  : sprites — compshape (RLE columns, transparent)
//!   pages [sound_start, chunks_in_file): digitized sounds (ignored)

mod palette;
use palette::PALETTE;

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{anyhow, bail, Context, Result};
use clap::Parser;

const DIM: usize = 64; // every wall/sprite is 64x64

#[derive(Parser)]
#[command(about = "Extract Wolf3D VSWAP walls + sprites to PNGs (user-provided data; nothing committed)")]
struct Args {
    /// Path to VSWAP.WL1 (shareware data you provide).
    #[arg(long, default_value = "VSWAP.WL1")]
    vswap: PathBuf,
    /// Output directory (served by the web client; .gitignored).
    #[arg(long, default_value = "web/public/wolf")]
    out: PathBuf,
}

struct Vswap {
    sprite_start: usize,
    sound_start: usize,
    offsets: Vec<u32>,
    lengths: Vec<u16>,
    data: Vec<u8>,
}

fn rd_u16(d: &[u8], i: usize) -> u16 {
    u16::from_le_bytes([d[i], d[i + 1]])
}
fn rd_u32(d: &[u8], i: usize) -> u32 {
    u32::from_le_bytes([d[i], d[i + 1], d[i + 2], d[i + 3]])
}

fn parse(data: Vec<u8>) -> Result<Vswap> {
    if data.len() < 6 {
        bail!("VSWAP too small ({} bytes)", data.len());
    }
    let chunks = rd_u16(&data, 0) as usize;
    let sprite_start = rd_u16(&data, 2) as usize;
    let sound_start = rd_u16(&data, 4) as usize;
    if sprite_start > chunks || sound_start > chunks || sprite_start > sound_start {
        bail!("nonsensical header (chunks={chunks} sprite={sprite_start} sound={sound_start}) — not a VSWAP file?");
    }
    let mut offsets = Vec::with_capacity(chunks);
    for i in 0..chunks {
        offsets.push(rd_u32(&data, 6 + i * 4));
    }
    let lenbase = 6 + chunks * 4;
    let mut lengths = Vec::with_capacity(chunks);
    for i in 0..chunks {
        lengths.push(rd_u16(&data, lenbase + i * 2));
    }
    Ok(Vswap { sprite_start, sound_start, offsets, lengths, data })
}

impl Vswap {
    fn chunk(&self, page: usize) -> Option<&[u8]> {
        let off = self.offsets[page] as usize;
        let len = self.lengths[page] as usize;
        if off == 0 || off + len > self.data.len() {
            return None; // sparse / out of range
        }
        Some(&self.data[off..off + len])
    }
}

/// Wall: 64x64, column-major (`src[x*64 + y]`), one palette index per pixel.
fn decode_wall(chunk: &[u8]) -> Vec<u8> {
    let mut out = vec![0u8; DIM * DIM * 4];
    for x in 0..DIM {
        for y in 0..DIM {
            let idx = *chunk.get(x * DIM + y).unwrap_or(&0) as usize;
            let [r, g, b] = PALETTE[idx];
            let o = (y * DIM + x) * 4;
            out[o] = r;
            out[o + 1] = g;
            out[o + 2] = b;
            out[o + 3] = 255;
        }
    }
    out
}

/// Sprite (compshape): transparent 64x64. Per column `x` in [leftpix,rightpix] a
/// list of 3-word posts `[2*endY, corrected_pixel_offset, 2*startY]`, terminated by
/// a 0 word; pixel for row `y` is `chunk[word1 + y]` ("corrected top", per OLDSCALE.C).
fn decode_sprite(chunk: &[u8]) -> Result<Vec<u8>> {
    if chunk.len() < 4 {
        bail!("sprite chunk too small");
    }
    let leftpix = rd_u16(chunk, 0) as usize;
    let rightpix = rd_u16(chunk, 2) as usize;
    if rightpix < leftpix || rightpix >= DIM {
        bail!("bad sprite bounds left={leftpix} right={rightpix}");
    }
    let mut out = vec![0u8; DIM * DIM * 4]; // alpha 0 = transparent
    for (i, x) in (leftpix..=rightpix).enumerate() {
        let ofs_pos = 4 + i * 2;
        if ofs_pos + 2 > chunk.len() {
            break;
        }
        let mut p = rd_u16(chunk, ofs_pos) as usize;
        loop {
            if p + 6 > chunk.len() {
                break;
            }
            let word0 = rd_u16(chunk, p);
            if word0 == 0 {
                break; // end of column
            }
            let end_y = (word0 / 2) as usize;
            let pool = rd_u16(chunk, p + 2) as usize; // "corrected top": pix[y] = chunk[pool + y]
            let start_y = (rd_u16(chunk, p + 4) / 2) as usize;
            p += 6;
            for y in start_y..end_y.min(DIM) {
                let src = pool + y;
                if src >= chunk.len() {
                    continue;
                }
                let [r, g, b] = PALETTE[chunk[src] as usize];
                let o = (y * DIM + x) * 4;
                out[o] = r;
                out[o + 1] = g;
                out[o + 2] = b;
                out[o + 3] = 255;
            }
        }
    }
    Ok(out)
}

fn write_png(path: &Path, rgba: &[u8]) -> Result<()> {
    let file = fs::File::create(path).with_context(|| format!("create {}", path.display()))?;
    let mut enc = png::Encoder::new(std::io::BufWriter::new(file), DIM as u32, DIM as u32);
    enc.set_color(png::ColorType::Rgba);
    enc.set_depth(png::BitDepth::Eight);
    enc.write_header()?.write_image_data(rgba)?;
    Ok(())
}

fn main() -> Result<()> {
    let args = Args::parse();
    let data = fs::read(&args.vswap).with_context(|| {
        format!(
            "reading {} — provide your own Wolf3D shareware VSWAP.WL1 (see web/README.md)",
            args.vswap.display()
        )
    })?;
    let v = parse(data)?;
    fs::create_dir_all(&args.out)?;

    let mut walls = 0usize;
    for page in 0..v.sprite_start {
        let Some(chunk) = v.chunk(page) else { continue };
        write_png(&args.out.join(format!("wall_{page:03}.png")), &decode_wall(chunk))?;
        walls += 1;
    }

    let mut sprites = 0usize;
    for page in v.sprite_start..v.sound_start {
        let Some(chunk) = v.chunk(page) else { continue };
        let idx = page - v.sprite_start; // 0-based sprite index (SPR_DEMO = 0)
        match decode_sprite(chunk) {
            Ok(rgba) => {
                write_png(&args.out.join(format!("sprite_{idx:03}.png")), &rgba)?;
                sprites += 1;
            }
            Err(e) => eprintln!("skip sprite {idx}: {e}"),
        }
    }

    let manifest = serde_json::json!({
        "wall_count": v.sprite_start,
        "sprite_count": v.sound_start - v.sprite_start,
        "walls_written": walls,
        "sprites_written": sprites,
        "dim": DIM,
    });
    fs::write(args.out.join("manifest.json"), serde_json::to_vec_pretty(&manifest)?)?;

    println!(
        "wl-extract: {walls} walls + {sprites} sprites -> {} (manifest.json written)",
        args.out.display()
    );
    if walls == 0 && sprites == 0 {
        return Err(anyhow!("nothing extracted — is {} a real VSWAP.WL1?", args.vswap.display()));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a tiny synthetic VSWAP in memory (1 wall, 1 sprite) and round-trip it
    /// through the parser + decoders. Validates the format handling with zero id data.
    #[test]
    fn roundtrip_synthetic() {
        // wall page: column-major, pixel(x,y) = palette index (x+y) & 0xff
        let mut wall = vec![0u8; DIM * DIM];
        for x in 0..DIM {
            for y in 0..DIM {
                wall[x * DIM + y] = ((x + y) & 0xff) as u8;
            }
        }
        // sprite page: leftpix=1, rightpix=1, one column with a single post painting
        // rows 2..5 from a 3-byte pixel pool of palette indices [10,20,30].
        // post words: [2*end(=5), pool_offset, 2*start(=2)], then 0 terminator.
        // "corrected top": pix[y]=chunk[pool+y] for y in 2..5, so pool = pool_byte_base - 2.
        let header_words = 2 + 1; // leftpix, rightpix, one dataofs
        let header_bytes = header_words * 2;
        let post_at = header_bytes; // posts start right after the offset table
        let pool_base = post_at + 8; // 3 words post (6) + 2-byte terminator
        let pool = pool_base - 2; // corrected so chunk[pool+2..pool+5] are the pixels
        let mut sp = vec![0u8; pool_base + 5];
        sp[0..2].copy_from_slice(&1u16.to_le_bytes()); // leftpix
        sp[2..4].copy_from_slice(&1u16.to_le_bytes()); // rightpix
        sp[4..6].copy_from_slice(&(post_at as u16).to_le_bytes()); // dataofs[0]
        sp[post_at..post_at + 2].copy_from_slice(&10u16.to_le_bytes()); // 2*endY (endY=5)
        sp[post_at + 2..post_at + 4].copy_from_slice(&(pool as u16).to_le_bytes());
        sp[post_at + 4..post_at + 6].copy_from_slice(&4u16.to_le_bytes()); // 2*startY (startY=2)
        // terminator word at post_at+6 already 0
        sp[pool_base..pool_base + 3].copy_from_slice(&[10, 20, 30]); // pixel pool (rows 2,3,4)

        // assemble VSWAP: chunks=2, sprite_start=1, sound_start=2
        let chunks = 2usize;
        let mut data = Vec::new();
        data.extend_from_slice(&2u16.to_le_bytes());
        data.extend_from_slice(&1u16.to_le_bytes());
        data.extend_from_slice(&2u16.to_le_bytes());
        let table = 6 + chunks * 4 + chunks * 2;
        let wall_off = table;
        let sp_off = table + wall.len();
        for off in [wall_off as u32, sp_off as u32] {
            data.extend_from_slice(&off.to_le_bytes());
        }
        for len in [wall.len() as u16, sp.len() as u16] {
            data.extend_from_slice(&len.to_le_bytes());
        }
        data.extend_from_slice(&wall);
        data.extend_from_slice(&sp);

        let v = parse(data).unwrap();
        assert_eq!(v.sprite_start, 1);
        assert_eq!(v.sound_start, 2);

        let w = decode_wall(v.chunk(0).unwrap());
        // wall pixel(3,4): palette[(3+4)] with full alpha
        let o = (4 * DIM + 3) * 4;
        assert_eq!(&w[o..o + 4], &[PALETTE[7][0], PALETTE[7][1], PALETTE[7][2], 255]);

        let s = decode_sprite(v.chunk(1).unwrap()).unwrap();
        // column 1, row 3 should be palette[20] opaque; row 0 transparent
        let drawn = (3 * DIM + 1) * 4;
        assert_eq!(&s[drawn..drawn + 4], &[PALETTE[20][0], PALETTE[20][1], PALETTE[20][2], 255]);
        let empty = (0 * DIM + 1) * 4;
        assert_eq!(s[empty + 3], 0, "untouched pixel must be transparent");
    }
}
