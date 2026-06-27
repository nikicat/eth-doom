//! VGAGRAPH decoder — the Wolf3D menu/HUD graphics (status bar, BJ face, fonts).
//! Unlike VSWAP, these are Huffman-compressed (ID_CA.C) and stored in VGA planar
//! format (ID_VL.C VL_MemToScreen). Decodes the pic chunks to PNGs.
//!
//! Layout (all from id's GPL source):
//!   VGADICT.WL1  : 255 huffnodes (each = u16 bit0, u16 bit1); head node = 254.
//!   VGAHEAD.WL1  : (NUMCHUNKS+1) × 3-byte little-endian offsets into VGAGRAPH.
//!   VGAGRAPH.WL1 : each chunk = u32 expanded-length, then Huffman data.
//!   chunk 0 (STRUCTPIC) decompresses to the pic table: NUMPICS × (u16 w, u16 h).
//!   pic chunk = STARTPICS + pic_index; its bytes are 4-plane VGA-planar.

use anyhow::{bail, Result};

use crate::palette::PALETTE;

/// Huffman-expand `src` to exactly `explen` bytes. `dict[i] = (bit0, bit1)`;
/// a value < 256 is a leaf byte, else the next node is `value - 256`. Head = 254.
fn huff_expand(src: &[u8], dict: &[(u16, u16)], explen: usize) -> Vec<u8> {
    let mut out = Vec::with_capacity(explen);
    let mut node = 254usize; // head node
    let mut cur = src.first().copied().unwrap_or(0);
    let mut bi = 1usize; // next source byte
    let mut mask = 1u16;
    while out.len() < explen {
        let bit = (cur as u16) & mask;
        let val = if bit != 0 { dict[node].1 } else { dict[node].0 };
        mask <<= 1;
        if mask == 256 {
            cur = src.get(bi).copied().unwrap_or(0);
            bi += 1;
            mask = 1;
        }
        if val < 256 {
            out.push(val as u8);
            node = 254;
        } else {
            node = (val - 256) as usize;
        }
    }
    out
}

fn rd_u16(d: &[u8], i: usize) -> u16 {
    u16::from_le_bytes([d[i], d[i + 1]])
}
fn rd_u32(d: &[u8], i: usize) -> u32 {
    u32::from_le_bytes([d[i], d[i + 1], d[i + 2], d[i + 3]])
}

/// VGAHEAD: 3-byte little-endian file offsets, one per chunk (+1 sentinel).
fn parse_head(head: &[u8]) -> Vec<u32> {
    (0..head.len() / 3)
        .map(|c| {
            let o = c * 3;
            u32::from_le_bytes([head[o], head[o + 1], head[o + 2], 0])
        })
        .collect()
}

fn parse_dict(dict_bytes: &[u8]) -> Vec<(u16, u16)> {
    let n = (dict_bytes.len() / 4).max(255);
    (0..n)
        .map(|i| {
            let o = i * 4;
            if o + 4 <= dict_bytes.len() {
                (rd_u16(dict_bytes, o), rd_u16(dict_bytes, o + 2))
            } else {
                (0, 0)
            }
        })
        .collect()
}

/// decompress chunk `c` (skipping its 4-byte expanded-length prefix).
fn decompress_chunk(graph: &[u8], offsets: &[u32], dict: &[(u16, u16)], c: usize) -> Option<Vec<u8>> {
    let pos = offsets[c] as usize;
    let next = offsets[c + 1] as usize;
    // sparse chunks are marked 0xFFFFFF; offset 0 is valid (chunk 0 starts the file)
    if pos >= 0xFFFFFF || next <= pos + 4 || next > graph.len() {
        return None;
    }
    let explen = rd_u32(graph, pos) as usize;
    let comp = &graph[pos + 4..next];
    Some(huff_expand(comp, dict, explen))
}

/// un-planarize a `w`×`h` VGA-planar pic (plane p owns pixels where x%4==p,
/// planes stored sequentially) into RGBA.
fn planar_to_rgba(data: &[u8], w: usize, h: usize) -> Vec<u8> {
    let mut out = vec![0u8; w * h * 4];
    let bpp = w / 4; // bytes per plane row
    let mut idx = 0usize;
    for plane in 0..4 {
        for y in 0..h {
            for col in 0..bpp {
                let x = col * 4 + plane;
                if x < w && idx < data.len() {
                    let [r, g, b] = PALETTE[data[idx] as usize];
                    let o = (y * w + x) * 4;
                    out[o] = r;
                    out[o + 1] = g;
                    out[o + 2] = b;
                    out[o + 3] = 255;
                }
                idx += 1;
            }
        }
    }
    out
}

pub struct Pic {
    pub index: usize, // pic index (chunk - start_pics)
    pub w: usize,
    pub h: usize,
    pub rgba: Vec<u8>,
}

/// Decode all pic chunks. `start_pics` is the chunk index where pics begin
/// (STARTPICS = 3 for WL1). Returns one Pic per non-sparse pic chunk.
pub fn decode_pics(
    dict_bytes: &[u8],
    head_bytes: &[u8],
    graph: &[u8],
    start_pics: usize,
) -> Result<Vec<Pic>> {
    let dict = parse_dict(dict_bytes);
    let offsets = parse_head(head_bytes);
    if offsets.len() < 2 {
        bail!("VGAHEAD too small");
    }
    // chunk 0 = pic table: NUMPICS × (u16 width, u16 height)
    let table = decompress_chunk(graph, &offsets, &dict, 0)
        .ok_or_else(|| anyhow::anyhow!("could not decompress STRUCTPIC (pic table)"))?;
    let numpics = table.len() / 4;
    let mut pics = Vec::new();
    for pi in 0..numpics {
        let w = rd_u16(&table, pi * 4) as usize;
        let h = rd_u16(&table, pi * 4 + 2) as usize;
        if w == 0 || h == 0 || w % 4 != 0 || w > 1024 || h > 1024 {
            continue;
        }
        let c = start_pics + pi;
        if c + 1 >= offsets.len() {
            break;
        }
        let Some(data) = decompress_chunk(graph, &offsets, &dict, c) else { continue };
        if data.len() < w * h {
            continue; // not a straight pic (masked/font/etc.)
        }
        pics.push(Pic { index: pi, w, h, rgba: planar_to_rgba(&data, w, h) });
    }
    Ok(pics)
}
