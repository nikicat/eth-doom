//! M1 differential + gas harness.
//!
//! Deploys Map/Engine/Session on an in-process anvil, replays a recorded input
//! vector through `Session.submitInput`, and asserts the resulting state matches
//! the C-oracle golden vector tic-by-tic — while recording per-input gas.

use std::fs;
use std::path::PathBuf;

use alloy::primitives::{Bytes, I256, U256};
use alloy::providers::ProviderBuilder;
use alloy::sol_types::SolValue;
use anyhow::{anyhow, bail, Result};
use serde_json::Value;

// Isolate each binding: Session's ABI re-declares Engine/Cmd, which collides at
// crate root, so give each its own module.
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

/// One golden snapshot line.
#[derive(Debug)]
struct Snap {
    x: i64,
    y: i64,
    angle: i64,
    tilex: i64,
    tiley: i64,
    anglefrac: i64,
}

fn load_golden(path: &str) -> Result<Vec<Snap>> {
    let txt = fs::read_to_string(repo(path))?;
    let mut out = Vec::new();
    for line in txt.lines().filter(|l| !l.trim().is_empty()) {
        let v: Value = serde_json::from_str(line)?;
        let g = |k: &str| v[k].as_i64().ok_or_else(|| anyhow!("missing {k}"));
        out.push(Snap {
            x: g("x")?,
            y: g("y")?,
            angle: g("angle")?,
            tilex: g("tilex")?,
            tiley: g("tiley")?,
            anglefrac: g("anglefrac")?,
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

/// Decode abi.encode(int x,int y,int angle,uint tilex,uint tiley,int anglefrac).
fn decode_state(bytes: &[u8]) -> Result<(i64, i64, i64, i64, i64, i64)> {
    let (x, y, angle, tilex, tiley, anglefrac) =
        <(I256, I256, I256, U256, U256, I256)>::abi_decode(bytes)?;
    Ok((
        i128::try_from(x)? as i64,
        i128::try_from(y)? as i64,
        i128::try_from(angle)? as i64,
        tilex.to::<u64>() as i64,
        tiley.to::<u64>() as i64,
        i128::try_from(anglefrac)? as i64,
    ))
}

fn check(tick: i64, got: (i64, i64, i64, i64, i64, i64), want: &Snap) -> Result<()> {
    let exp = (want.x, want.y, want.angle, want.tilex, want.tiley, want.anglefrac);
    if got != exp {
        bail!("tic {tick} MISMATCH\n  got  {:?}\n  want {:?}", got, exp);
    }
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    let (w, h, tiles) = load_map("oracle/maps/test_room.txt")?;
    let inputs = load_inputs("vectors/move_basic.input.txt")?;
    let golden = load_golden("vectors/move_basic.golden.jsonl")?;
    let (sx, sy, sdir) = (8u64, 8u64, 1u64); // matches gen_vectors.sh

    let provider = ProviderBuilder::new().connect_anvil_with_wallet();

    let engine = eng::Engine::deploy(provider.clone()).await?;
    let map = mp::Map::deploy(
        provider.clone(),
        U256::from(w),
        U256::from(h),
        Bytes::from(tiles),
        U256::from(sx),
        U256::from(sy),
        U256::from(sdir),
    )
    .await?;
    let session =
        sess::Session::deploy(provider.clone(), *engine.address(), *map.address()).await?;

    println!("engine={} map={} session={}", engine.address(), map.address(), session.address());

    // tic 0: post-spawn state set in the Session constructor.
    let state0 = session.getState().call().await?;
    check(0, decode_state(state0.as_ref())?, &golden[0])?;
    println!("tic   0  ok  {:?}", decode_state(state0.as_ref())?);

    let mut gas_used = Vec::new();
    for (i, &(cx, cy, btns)) in inputs.iter().enumerate() {
        let tick = (i + 1) as i64;
        let cmd = sess::Engine::Cmd {
            controlx: I256::try_from(cx).unwrap(),
            controly: I256::try_from(cy).unwrap(),
            buttons: btns,
        };
        let receipt = session.submitInput(cmd).send().await?.get_receipt().await?;
        gas_used.push(receipt.gas_used);

        let state = session.getState().call().await?;
        let got = decode_state(state.as_ref())?;
        check(tick, got, &golden[tick as usize])?;
        println!("tic {:>3}  ok  gas {:>7}  {:?}", tick, receipt.gas_used, got);
    }

    let n = gas_used.len() as u64;
    let sum: u64 = gas_used.iter().sum();
    let min = *gas_used.iter().min().unwrap();
    let max = *gas_used.iter().max().unwrap();
    println!(
        "\nDIFFERENTIAL PASS ({} tics) — submitInput gas: min {} avg {} max {}",
        n + 1,
        min,
        sum / n,
        max
    );
    Ok(())
}
