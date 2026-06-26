//! M1/M2 differential + gas harness.
//!
//! Deploys Map/Engine/Session on an in-process anvil, replays a recorded input
//! vector through `Session.submitInput`, and asserts the resulting state matches
//! the C-oracle golden vector tic-by-tic — while recording per-input gas.

use std::fs;
use std::path::PathBuf;

use alloy::dyn_abi::{DynSolType, DynSolValue};
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

/// DynSolType for the engine's `abi.encode(Player, Actor[], rndindex)`.
fn world_type() -> DynSolType {
    let player = DynSolType::Tuple(vec![
        DynSolType::Int(256), DynSolType::Int(256), DynSolType::Int(256),
        DynSolType::Uint(256), DynSolType::Uint(256), DynSolType::Int(256),
    ]);
    let actor = DynSolType::Tuple(vec![
        DynSolType::Int(256), DynSolType::Int(256), DynSolType::Uint(256), DynSolType::Uint(256),
        DynSolType::Int(256), DynSolType::Uint(256), DynSolType::Int(256), DynSolType::Int(256),
        DynSolType::Int(256), DynSolType::Uint(8), DynSolType::Uint(8), DynSolType::Int(256),
        DynSolType::Uint(8),
    ]);
    DynSolType::Tuple(vec![player, DynSolType::Array(Box::new(actor)), DynSolType::Uint(256)])
}

fn as_i(v: &DynSolValue) -> i64 {
    match v {
        DynSolValue::Int(x, _) => i128::try_from(*x).unwrap() as i64,
        DynSolValue::Uint(x, _) => x.to::<u64>() as i64,
        _ => panic!("not a number: {v:?}"),
    }
}
fn tup(v: &DynSolValue) -> &Vec<DynSolValue> {
    match v { DynSolValue::Tuple(t) => t, _ => panic!("not a tuple") }
}
fn arr(v: &DynSolValue) -> &Vec<DynSolValue> {
    match v { DynSolValue::Array(t) => t, _ => panic!("not an array") }
}

/// One golden snapshot line.
struct Snap {
    player: [i64; 6], // x,y,angle,tilex,tiley,anglefrac
    rng: Option<i64>,
    guards: Vec<[i64; 7]>, // x,y,dir,st,hp,tc,dist
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
                guards.push([f("x"), f("y"), f("dir"), f("st"), f("hp"), f("tc"), f("dist")]);
            }
        }
        out.push(Snap {
            player: [g("x")?, g("y")?, g("angle")?, g("tilex")?, g("tiley")?, g("anglefrac")?],
            rng: v.get("rng").and_then(|x| x.as_i64()),
            guards,
        });
    }
    Ok(out)
}

/// Parse "W H" + grid into row-major tiles: tile(x,y) = tiles[y*W + x], 1 = wall.
fn load_map(path: &str) -> Result<(u64, u64, Vec<u8>)> {
    let txt = fs::read_to_string(repo(path))?;
    let mut lines = txt.lines();
    let hdr = lines.next().ok_or_else(|| anyhow!("empty map"))?;
    let mut it = hdr.split_whitespace();
    let w: u64 = it.next().unwrap().parse()?;
    let h: u64 = it.next().unwrap().parse()?;
    let mut tiles = vec![0u8; (w * h) as usize];
    for y in 0..h {
        let row = lines.next().ok_or_else(|| anyhow!("map too short"))?;
        let bytes = row.as_bytes();
        for x in 0..w {
            let c = *bytes.get(x as usize).unwrap_or(&b'.');
            tiles[(y * w + x) as usize] = if c == b'#' { 1 } else { 0 };
        }
    }
    Ok((w, h, tiles))
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
    let decoded = world_type().abi_decode_params(state)?;
    let top = tup(&decoded);
    let p = tup(&top[0]);
    let pl = [as_i(&p[0]), as_i(&p[1]), as_i(&p[2]), as_i(&p[3]), as_i(&p[4]), as_i(&p[5])];
    if pl != want.player {
        bail!("tic {tick} PLAYER mismatch\n  got  {:?}\n  want {:?}", pl, want.player);
    }
    let actors = arr(&top[1]);
    let rnd = as_i(&top[2]);
    if let Some(wr) = want.rng {
        if rnd != wr {
            bail!("tic {tick} RNG mismatch: got {} want {}", rnd, wr);
        }
    }
    if actors.len() != want.guards.len() {
        bail!("tic {tick} guard count: got {} want {}", actors.len(), want.guards.len());
    }
    for (k, av) in actors.iter().enumerate() {
        let a = tup(av);
        // golden guard order: x, y, dir, state, hp, ticcount, distance
        let got = [as_i(&a[0]), as_i(&a[1]), as_i(&a[4]), as_i(&a[5]), as_i(&a[8]), as_i(&a[6]), as_i(&a[7])];
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
        ("move_basic", "oracle/maps/test_room.txt", "vectors/move_basic.input.txt",
         "vectors/move_basic.golden.jsonl", (8, 8, 1), vec![]),
        ("chase_guard", "oracle/maps/test_room.txt", "vectors/chase_guard.input.txt",
         "vectors/chase_guard.golden.jsonl", (8, 8, 1), vec![12, 8, 4]),
    ];

    for (name, mapf, inf, goldf, (sx, sy, sdir), guards) in scenarios {
        let (w, h, tiles) = load_map(mapf)?;
        let inputs = load_inputs(inf)?;
        let golden = load_golden(goldf)?;

        let map = mp::Map::deploy(
            provider.clone(),
            U256::from(w), U256::from(h), Bytes::from(tiles),
            U256::from(*sx), U256::from(*sy), U256::from(*sdir),
            Bytes::from(guards.clone()),
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
