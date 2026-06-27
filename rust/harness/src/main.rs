//! M1/M2 differential + gas harness.
//!
//! Deploys Map/Engine/Session on an in-process anvil, replays a recorded input
//! vector through `Session.submitInput`, and asserts the resulting state matches
//! the C-oracle golden vector tic-by-tic — while recording per-input gas.

use std::fs;
use std::path::PathBuf;

use alloy::primitives::{Bytes, I256, U256};
use alloy::providers::ProviderBuilder;
use anyhow::{anyhow, bail, Result};
use serde_json::Value;

mod eng {
    alloy::sol!(#[sol(rpc)] Engine, "../../contracts/out/Engine.sol/Engine.json");
}
mod mp {
    alloy::sol!(#[sol(rpc)] Map, "../../contracts/out/Map.sol/Map.json");
}
mod sess {
    alloy::sol!(#[sol(rpc)] Session, "../../contracts/out/Session.sol/Session.json");
}

fn repo(path: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..").join(path)
}

// --- packed state readers (must match Engine.sol's _pack layout) ---
fn word(state: &[u8], i: usize) -> U256 {
    U256::from_be_slice(&state[i * 32..(i + 1) * 32])
}
fn field(w: U256, shift: usize, bits: usize) -> u64 {
    let mask = (U256::from(1u64) << bits) - U256::from(1u64);
    ((w >> shift) & mask).to::<u64>()
}
fn s32(w: U256, shift: usize) -> i64 {
    field(w, shift, 32) as u32 as i32 as i64
}
fn s16(w: U256, shift: usize) -> i64 {
    field(w, shift, 16) as u16 as i16 as i64
}

/// One golden snapshot line.
struct Snap {
    player: [i64; 9], // x,y,angle,tilex,tiley,anglefrac,health,ammo,acount
    rng: Option<i64>,
    guards: Vec<[i64; 8]>, // x,y,dir,st,hp,tc,dist,cls
    doors: Vec<[i64; 3]>,  // pos,act,tc
    items: Vec<i64>,       // taken (0/1) per item
    keys: i64,
    score: i64,
}

fn load_golden(path: &str) -> Result<Vec<Snap>> {
    let txt = fs::read_to_string(repo(path))?;
    let mut out = Vec::new();
    for line in txt.lines().filter(|l| !l.trim().is_empty()) {
        let v: Value = serde_json::from_str(line)?;
        let g = |k: &str| v[k].as_i64().ok_or_else(|| anyhow!("missing {k}"));
        let mut guards = Vec::new();
        if let Some(arr) = v.get("guards").and_then(|x| x.as_array()) {
            for gd in arr {
                let f = |k: &str| gd[k].as_i64().unwrap();
                guards.push([f("x"), f("y"), f("dir"), f("st"), f("hp"), f("tc"), f("dist"), f("cls")]);
            }
        }
        let mut doors = Vec::new();
        if let Some(arr) = v.get("doors").and_then(|x| x.as_array()) {
            for dr in arr {
                let f = |k: &str| dr[k].as_i64().unwrap();
                doors.push([f("pos"), f("act"), f("tc")]);
            }
        }
        let mut items = Vec::new();
        if let Some(arr) = v.get("items").and_then(|x| x.as_array()) {
            for it in arr {
                items.push(it.as_i64().unwrap());
            }
        }
        out.push(Snap {
            player: [g("x")?, g("y")?, g("angle")?, g("tilex")?, g("tiley")?, g("anglefrac")?, g("health")?, g("ammo")?, g("acount")?],
            rng: v.get("rng").and_then(|x| x.as_i64()),
            guards,
            doors,
            items,
            keys: v.get("keys").and_then(|x| x.as_i64()).unwrap_or(0),
            score: v.get("score").and_then(|x| x.as_i64()).unwrap_or(0),
        });
    }
    Ok(out)
}

/// Parse "W H" + grid into the runtime tilemap: tile(x,y) = tiles[y*W + x], 1 =
/// wall, `doornum|0x80` = door, 0 = floor. Door chars match the oracle map loader
/// ('D' vertical, 'd' horizontal, lock 0), with doornum in y-major scan order, and
/// also returns the Map door bytes (3/door: tilex, tiley, vertical|lock<<1).
fn load_map(path: &str) -> Result<(u64, u64, Vec<u8>, Vec<u8>, Vec<u8>)> {
    let txt = fs::read_to_string(repo(path))?;
    let mut lines = txt.lines();
    let hdr = lines.next().ok_or_else(|| anyhow!("empty map"))?;
    let mut it = hdr.split_whitespace();
    let w: u64 = it.next().unwrap().parse()?;
    let h: u64 = it.next().unwrap().parse()?;
    let mut tiles = vec![0u8; (w * h) as usize];
    let mut doors = Vec::new();
    let mut items = Vec::new();
    let mut doornum: u8 = 0;
    for y in 0..h {
        let row = lines.next().ok_or_else(|| anyhow!("map too short"))?;
        let bytes = row.as_bytes();
        for x in 0..w {
            let c = *bytes.get(x as usize).unwrap_or(&b'.');
            // item chars match the oracle map loader (bo_clip/firstaid/key1/cross)
            let item = |b: u8| [x as u8, y as u8, b];
            match c {
                b'#' => tiles[(y * w + x) as usize] = 1,
                b'D' | b'd' => {
                    let vertical: u8 = if c == b'D' { 1 } else { 0 };
                    tiles[(y * w + x) as usize] = 0x80 | doornum;
                    doors.extend_from_slice(&[x as u8, y as u8, vertical]); // lock 0
                    doornum += 1;
                }
                b'a' => items.extend_from_slice(&item(14)), // bo_clip
                b'h' => items.extend_from_slice(&item(5)),  // bo_firstaid
                b'k' => items.extend_from_slice(&item(6)),  // bo_key1
                b't' => items.extend_from_slice(&item(10)), // bo_cross
                _ => {}
            }
        }
    }
    Ok((w, h, tiles, doors, items))
}

/// Parse "cx cy buttons" lines (skip blank / '#').
fn load_inputs(path: &str) -> Result<Vec<(i64, i64, u8)>> {
    let txt = fs::read_to_string(repo(path))?;
    let mut out = Vec::new();
    for line in txt.lines() {
        let l = line.trim();
        if l.is_empty() || l.starts_with('#') {
            continue;
        }
        let mut it = l.split_whitespace();
        let cx: i64 = it.next().unwrap().parse()?;
        let cy: i64 = it.next().unwrap().parse()?;
        let b: i64 = it.next().unwrap().parse()?;
        out.push((cx, cy, b as u8));
    }
    Ok(out)
}

fn decode_and_check(state: &[u8], want: &Snap, tick: i64) -> Result<()> {
    let header = word(state, 0);
    let rnd = field(header, 0, 8) as i64;
    let n = field(header, 8, 8) as usize;
    let ad = field(header, 16, 8) as usize; // active (non-closed) doors stored
    let ni = field(header, 24, 16) as usize;
    let iw = if ni == 0 { 0 } else { (ni + 255) / 256 };

    let pw = word(state, 1);
    let player = [
        s32(pw, 0),               // x
        s32(pw, 32),              // y
        field(pw, 64, 16) as i64, // angle
        field(pw, 112, 8) as i64, // tilex
        field(pw, 120, 8) as i64, // tiley
        s32(pw, 80),              // anglefrac
        s16(pw, 128),             // health
        s16(pw, 144),             // ammo
        s16(pw, 160),             // attackcount
    ];
    if player != want.player {
        bail!("tic {tick} PLAYER mismatch\n  got  {:?}\n  want {:?}", player, want.player);
    }
    let keys = field(pw, 184, 8) as i64;
    let score = field(pw, 192, 32) as i64;
    if keys != want.keys || score != want.score {
        bail!("tic {tick} KEYS/SCORE mismatch: got keys {keys} score {score}, want {} {}", want.keys, want.score);
    }
    if let Some(wr) = want.rng {
        if rnd != wr {
            bail!("tic {tick} RNG mismatch: got {} want {}", rnd, wr);
        }
    }
    // doors: only the `ad` non-closed doors are stored (each carries its doornum).
    // Reconstruct the full set: default every door closed [pos 0, act 1, tc 0], apply
    // the active words by doornum, then check against the golden (which has all doors).
    let total_doors = want.doors.len();
    let mut doors = vec![[0i64, 1, 0]; total_doors]; // DR_CLOSED = 1
    for k in 0..ad {
        let dw = word(state, 2 + k);
        // door word: action@0, ticcount@16, position@32, doornum@48 -> golden [pos, act, tc]
        let doornum = field(dw, 48, 8) as usize;
        doors[doornum] = [field(dw, 32, 16) as i64, field(dw, 0, 8) as i64, s16(dw, 16)];
    }
    for k in 0..total_doors {
        if doors[k] != want.doors[k] {
            bail!("tic {tick} DOOR{k} mismatch\n  got  {:?}\n  want {:?}", doors[k], want.doors[k]);
        }
    }
    // items: iw bitmask words after the active doors; bit i = item i taken
    if ni != want.items.len() {
        bail!("tic {tick} item count: got {} want {}", ni, want.items.len());
    }
    for k in 0..ni {
        let bits = word(state, 2 + ad + k / 256);
        let taken = field(bits, k % 256, 1) as i64;
        if taken != want.items[k] {
            bail!("tic {tick} ITEM{k} taken: got {} want {}", taken, want.items[k]);
        }
    }

    if n != want.guards.len() {
        bail!("tic {tick} guard count: got {} want {}", n, want.guards.len());
    }
    for k in 0..n {
        let aw = word(state, 2 + ad + iw + k);
        // golden guard order: x, y, dir, state, hp, ticcount, distance, obclass
        let got = [
            s32(aw, 0),
            s32(aw, 32),
            field(aw, 80, 8) as i64,
            field(aw, 88, 8) as i64,
            s16(aw, 144),
            s16(aw, 96),
            s32(aw, 112),
            field(aw, 168, 8) as i64,
        ];
        if got != want.guards[k] {
            bail!("tic {tick} GUARD{k} mismatch\n  got  {:?}\n  want {:?}", got, want.guards[k]);
        }
    }
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    let provider = ProviderBuilder::new().connect_anvil_with_wallet();
    let engine = eng::Engine::deploy(provider.clone()).await?;

    // (name, map, input, golden, spawn, guards bytes)
    let scenarios: &[(&str, &str, &str, &str, (u64, u64, u64), Vec<u8>)] = &[
        // guard spawn bytes: tilex, tiley, dir, class (0 = en_guard, 2 = en_ss)
        ("move_basic", "oracle/maps/test_room.txt", "vectors/move_basic.input.txt",
         "vectors/move_basic.golden.jsonl", (8, 8, 1), vec![]),
        ("chase_guard", "oracle/maps/test_room.txt", "vectors/chase_guard.input.txt",
         "vectors/chase_guard.golden.jsonl", (8, 8, 1), vec![12, 8, 2, 0]),
        ("kill_guard", "oracle/maps/test_room.txt", "vectors/kill_guard.input.txt",
         "vectors/kill_guard.golden.jsonl", (4, 8, 1), vec![12, 8, 2, 0]),
        ("door_use", "oracle/maps/door_room.txt", "vectors/door_use.input.txt",
         "vectors/door_use.golden.jsonl", (4, 8, 1), vec![]),
        ("door_guard", "oracle/maps/door_room.txt", "vectors/door_guard.input.txt",
         "vectors/door_guard.golden.jsonl", (4, 8, 1), vec![12, 8, 2, 0]),
        ("item_pickup", "oracle/maps/item_room.txt", "vectors/item_pickup.input.txt",
         "vectors/item_pickup.golden.jsonl", (2, 8, 1), vec![13, 8, 2, 0]),
        ("two_guards", "oracle/maps/test_room.txt", "vectors/two_guards.input.txt",
         "vectors/two_guards.golden.jsonl", (2, 8, 1), vec![10, 8, 2, 0, 11, 8, 2, 0]),
        ("kill_ss", "oracle/maps/test_room.txt", "vectors/kill_ss.input.txt",
         "vectors/kill_ss.golden.jsonl", (4, 8, 1), vec![12, 8, 2, 2]),
        ("dog_bite", "oracle/maps/test_room.txt", "vectors/dog_bite.input.txt",
         "vectors/dog_bite.golden.jsonl", (4, 8, 1), vec![12, 8, 2, 3]),
        ("kill_officer", "oracle/maps/test_room.txt", "vectors/kill_officer.input.txt",
         "vectors/kill_officer.golden.jsonl", (4, 8, 1), vec![12, 8, 2, 1]),
    ];

    for (name, mapf, inf, goldf, (sx, sy, sdir), guards) in scenarios {
        let (w, h, tiles, doors, items) = load_map(mapf)?;
        let inputs = load_inputs(inf)?;
        let golden = load_golden(goldf)?;

        let map = mp::Map::deploy(
            provider.clone(),
            U256::from(w), U256::from(h), Bytes::from(tiles),
            U256::from(*sx), U256::from(*sy), U256::from(*sdir),
            Bytes::from(guards.clone()),
            Bytes::from(doors),
            Bytes::from(items),
        ).await?;
        let session = sess::Session::deploy(provider.clone(), *engine.address(), *map.address()).await?;

        decode_and_check(&session.getState().call().await?, &golden[0], 0)?;

        let mut gas = Vec::new();
        for (idx, &(cx, cy, btns)) in inputs.iter().enumerate() {
            let cmd = sess::Engine::Cmd {
                controlx: I256::try_from(cx).unwrap(),
                controly: I256::try_from(cy).unwrap(),
                buttons: btns,
            };
            let receipt = session.submitInput(cmd).send().await?.get_receipt().await?;
            gas.push(receipt.gas_used);
            decode_and_check(&session.getState().call().await?, &golden[idx + 1], (idx + 1) as i64)?;
        }

        let n = gas.len() as u64;
        let (sum, min, max) = (gas.iter().sum::<u64>(), *gas.iter().min().unwrap(), *gas.iter().max().unwrap());
        println!(
            "{:<12} PASS ({} tics) — submitInput gas: min {} avg {} max {}",
            name, golden.len(), min, sum / n, max
        );
    }
    Ok(())
}
