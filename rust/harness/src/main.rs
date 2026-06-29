//! M1/M2 differential + gas harness.
//!
//! Deploys Map/Engine/Session on an in-process anvil, replays a recorded input
//! vector through `Session.submitInput`, and asserts the resulting state matches
//! the C-oracle golden vector tic-by-tic — while recording per-input gas.

use std::fs;
use std::path::PathBuf;

use alloy::primitives::{Address, Bytes, I256, U256};
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
    weapon: i64,
    bestweapon: i64,
    exit: i64,             // exit_t: 0 still playing, 1 completed (elevator used)
    pwalls: Vec<[i64; 5]>, // one per triggered secret wall: sx, sy, dir, state, tile
    drops: Vec<[i64; 4]>,  // one per enemy-death drop: tx, ty, item, taken
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
            weapon: v.get("weapon").and_then(|x| x.as_i64()).unwrap_or(1),
            bestweapon: v.get("bestweapon").and_then(|x| x.as_i64()).unwrap_or(1),
            exit: v.get("exit").and_then(|x| x.as_i64()).unwrap_or(0),
            pwalls: v.get("pwalls").and_then(|x| x.as_array()).map_or_else(Vec::new, |arr| {
                arr.iter().map(|p| {
                    let f = |k: &str| p[k].as_i64().unwrap();
                    [f("sx"), f("sy"), f("dir"), f("state"), f("tile")]
                }).collect()
            }),
            drops: v.get("drops").and_then(|x| x.as_array()).map_or_else(Vec::new, |arr| {
                arr.iter().map(|d| {
                    let f = |k: &str| d[k].as_i64().unwrap();
                    [f("tx"), f("ty"), f("item"), f("taken")]
                }).collect()
            }),
        });
    }
    Ok(out)
}

/// Parse "W H" + grid into the runtime tilemap: tile(x,y) = tiles[y*W + x], 1 =
/// wall, `doornum|0x80` = door, 0 = floor. Door chars match the oracle map loader
/// ('D' vertical, 'd' horizontal, lock 0), with doornum in y-major scan order, and
/// also returns the Map door bytes (3/door: tilex, tiley, vertical|lock<<1).
fn load_map(path: &str) -> Result<(u64, u64, Vec<u8>, Vec<u8>, Vec<u8>, Vec<u8>, Vec<u8>, Vec<u8>)> {
    let txt = fs::read_to_string(repo(path))?;
    let mut lines = txt.lines();
    let hdr = lines.next().ok_or_else(|| anyhow!("empty map"))?;
    let mut it = hdr.split_whitespace();
    let w: u64 = it.next().unwrap().parse()?;
    let h: u64 = it.next().unwrap().parse()?;
    let mut tiles = vec![0u8; (w * h) as usize];
    let mut areas = vec![0u8; (w * h) as usize]; // per-tile area (floor digit), door tiles fixed up by the Engine
    let mut doors = Vec::new();
    let mut items = Vec::new();
    let mut blockers = Vec::new(); // 'B' blocking decorations (2 bytes each: tilex, tiley)
    let mut pushwalls = Vec::new(); // 'P' pushable secret walls (2 bytes each: tilex, tiley)
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
                b'm' => items.extend_from_slice(&item(16)), // bo_machinegun
                b'g' => items.extend_from_slice(&item(17)), // bo_chaingun
                b'P' => { tiles[(y * w + x) as usize] = 1; pushwalls.extend_from_slice(&[x as u8, y as u8]); } // pushable secret wall
                b'E' => tiles[(y * w + x) as usize] = 21, // elevator (level-exit) switch wall (ELEVATORTILE)
                b'B' => blockers.extend_from_slice(&[x as u8, y as u8]), // blocking decoration
                b'0'..=b'9' => areas[(y * w + x) as usize] = c - b'0', // floor, explicit area
                _ => {}
            }
        }
    }
    // single-area map (no explicit area digits): send no area map (engine fast-paths it)
    if areas.iter().all(|&a| a == 0) {
        areas.clear();
    }
    Ok((w, h, tiles, doors, items, areas, blockers, pushwalls))
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
    let weapon = field(pw, 224, 8) as i64;
    let bestweapon = field(pw, 232, 8) as i64;
    if weapon != want.weapon || bestweapon != want.bestweapon {
        bail!("tic {tick} WEAPON mismatch: got weapon {weapon} best {bestweapon}, want {} {}", want.weapon, want.bestweapon);
    }
    if let Some(wr) = want.rng {
        if rnd != wr {
            bail!("tic {tick} RNG mismatch: got {} want {}", rnd, wr);
        }
    }
    let exit = field(header, 48, 8) as i64; // exit_t latch (level over once nonzero)
    if exit != want.exit {
        bail!("tic {tick} EXIT mismatch: got {} want {}", exit, want.exit);
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

    // pushwalls: numpushwalls@40 trailing words after the actors, one per triggered wall
    let np = field(header, 40, 8) as usize;
    let mut got_pwalls = Vec::with_capacity(np);
    for k in 0..np {
        let pw = word(state, 2 + ad + iw + n + k);
        got_pwalls.push([
            field(pw, 0, 8) as i64,   // sx
            field(pw, 8, 8) as i64,   // sy
            field(pw, 16, 8) as i64,  // dir
            field(pw, 24, 16) as i64, // state
            field(pw, 40, 8) as i64,  // tile
        ]);
    }
    if got_pwalls != want.pwalls {
        bail!("tic {tick} PUSHWALL mismatch\n  got  {:?}\n  want {:?}", got_pwalls, want.pwalls);
    }

    // enemy-death drops: numdrops@56 trailing words after the pushwalls, one per drop
    let nd_drop = field(header, 56, 8) as usize;
    let mut got_drops = Vec::with_capacity(nd_drop);
    for k in 0..nd_drop {
        let dw = word(state, 2 + ad + iw + n + np + k);
        got_drops.push([
            field(dw, 0, 8) as i64,  // tilex
            field(dw, 8, 8) as i64,  // tiley
            field(dw, 16, 8) as i64, // itemnumber
            field(dw, 24, 1) as i64, // taken
        ]);
    }
    if got_drops != want.drops {
        bail!("tic {tick} DROP mismatch\n  got  {:?}\n  want {:?}", got_drops, want.drops);
    }
    Ok(())
}

/// A differential scenario, auto-discovered from a `scenarios/<name>.json` file —
/// the single source of truth shared with `oracle/gen_vectors.sh` and
/// `oracle/verify_wasm.mjs` (T1). Adding a test is "drop a file", no edits here.
struct Scenario {
    name: String,
    map: String,    // repo-relative, e.g. "oracle/maps/test_room.txt"
    input: String,  // repo-relative, e.g. "vectors/move_basic.input.txt"
    golden: String, // repo-relative, e.g. "vectors/move_basic.golden.jsonl"
    spawn: (u64, u64, u64),        // player tilex, tiley, dir
    guards: Vec<u8>,               // tilex, tiley, dir, class — 4 bytes per enemy
    checkpoints: Option<Vec<i64>>, // None = assert every tic; Some = only these tics
}

/// Enemy class name -> spawn byte (must match the oracle enum en_guard/officer/ss/dog).
fn class_byte(name: &str) -> Result<u8> {
    Ok(match name {
        "guard" => 0,
        "officer" => 1,
        "ss" => 2,
        "dog" => 3,
        other => bail!("unknown enemy class: {other}"),
    })
}

/// Discover and parse every `scenarios/*.json` (sorted by name for stable output).
fn discover_scenarios() -> Result<Vec<Scenario>> {
    let mut paths: Vec<PathBuf> = fs::read_dir(repo("scenarios"))?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().and_then(|x| x.to_str()) == Some("json"))
        .collect();
    paths.sort();
    let mut out = Vec::new();
    for path in paths {
        let name = path.file_stem().unwrap().to_string_lossy().into_owned();
        let cfg: Value = serde_json::from_str(&fs::read_to_string(&path)?)?;
        let req = |v: &Value, k: &str| v[k].as_u64().ok_or_else(|| anyhow!("{name}: missing {k}"));
        let map = format!("oracle/maps/{}", cfg["map"].as_str().ok_or_else(|| anyhow!("{name}: missing map"))?);
        let input = cfg["input"].as_str().map(String::from).unwrap_or_else(|| format!("vectors/{name}.input.txt"));
        let golden = format!("vectors/{name}.golden.jsonl");
        let p = &cfg["player"];
        let spawn = (req(p, "x")?, req(p, "y")?, req(p, "dir")?);
        let mut guards = Vec::new();
        if let Some(es) = cfg["enemies"].as_array() {
            for e in es {
                guards.push(req(e, "x")? as u8);
                guards.push(req(e, "y")? as u8);
                guards.push(req(e, "dir")? as u8);
                guards.push(class_byte(e["class"].as_str().ok_or_else(|| anyhow!("{name}: enemy.class"))?)?);
            }
        }
        // "all" (or absent) -> every tic; an explicit array -> only those tics.
        let checkpoints = cfg["checkpoints"].as_array().map(|a| a.iter().filter_map(|v| v.as_i64()).collect());
        out.push(Scenario { name, map, input, golden, spawn, guards, checkpoints });
    }
    Ok(out)
}

#[tokio::main]
async fn main() -> Result<()> {
    let provider = ProviderBuilder::new().connect_anvil_with_wallet();
    let engine = eng::Engine::deploy(provider.clone()).await?;

    for sc in &discover_scenarios()? {
        let (w, h, tiles, doors, items, areas, blockers, pushwalls) = load_map(&sc.map)?;
        let inputs = load_inputs(&sc.input)?;
        let golden = load_golden(&sc.golden)?;
        let (sx, sy, sdir) = sc.spawn;

        let map = mp::Map::deploy(
            provider.clone(),
            U256::from(w), U256::from(h), Bytes::from(tiles),
            U256::from(sx), U256::from(sy), U256::from(sdir),
            Bytes::from(sc.guards.clone()),
            Bytes::from(doors),
            Bytes::from(items),
            Bytes::from(areas),
            Bytes::from(blockers),
            Bytes::from(pushwalls),
        ).await?;
        let session = sess::Session::deploy(provider.clone(), *engine.address(), *map.address(), Address::ZERO).await?;

        // None = assert every tic; Some(list) = only those tics (default is every tic).
        let want_check = |t: i64| sc.checkpoints.as_ref().map_or(true, |cps| cps.contains(&t));

        if want_check(0) {
            decode_and_check(&session.getState().call().await?, &golden[0], 0)?;
        }

        let mut gas = Vec::new();
        for (idx, &(cx, cy, btns)) in inputs.iter().enumerate() {
            let cmd = sess::Engine::Cmd {
                controlx: I256::try_from(cx).unwrap(),
                controly: I256::try_from(cy).unwrap(),
                buttons: btns,
            };
            let receipt = session.submitInput(cmd).send().await?.get_receipt().await?;
            gas.push(receipt.gas_used);
            let tick = (idx + 1) as i64;
            if want_check(tick) {
                decode_and_check(&session.getState().call().await?, &golden[tick as usize], tick)?;
            }
        }

        let n = gas.len() as u64;
        let (sum, min, max) = (gas.iter().sum::<u64>(), *gas.iter().min().unwrap(), *gas.iter().max().unwrap());
        println!(
            "{:<12} PASS ({} tics) — submitInput gas: min {} avg {} max {}",
            sc.name, golden.len(), min, sum / n, max
        );
    }

    // --- E1L1 gas probe (no golden): split the full submitInput cost into the
    // Engine compute (a view eth_call) vs the Session state read/write overhead. ---
    let lvl_path = repo("web/public/level.json");
    if lvl_path.exists() {
        let level: Value = serde_json::from_str(&fs::read_to_string(&lvl_path)?)?;
        let w = level["w"].as_u64().unwrap();
        let h = level["h"].as_u64().unwrap();
        let tiles: Vec<u8> = level["tiles"].as_array().unwrap().iter().map(|v| v.as_u64().unwrap() as u8).collect();
        let (sx, sy, sdir) = (level["spawn"]["x"].as_u64().unwrap(), level["spawn"]["y"].as_u64().unwrap(), level["spawn"]["dir"].as_u64().unwrap());
        let triplet = |key: &str, fields: usize| -> Vec<u8> {
            level[key].as_array().map(|a| a.iter().flat_map(|e| {
                let r = e.as_array().unwrap();
                (0..fields).map(|k| r[k].as_u64().unwrap() as u8).collect::<Vec<_>>()
            }).collect()).unwrap_or_default()
        };
        let mut guards = triplet("guards", 4);
        guards.truncate(12 * 4); // match the client's MAX_GUARDS cap
        let (doors, items) = (triplet("doors", 3), triplet("items", 3));
        let blockers = triplet("blockers", 2); // blocking decorations (2 bytes each) — M6
        let pushwalls = triplet("pushwalls", 2); // pushable secret walls (2 bytes each) — M6 (empty until map-extract emits them)
        let areas: Vec<u8> = level["areas"].as_array()
            .map(|a| a.iter().map(|v| v.as_u64().unwrap() as u8).collect()).unwrap_or_default();
        let (ng, nd, ni) = (guards.len() / 4, doors.len() / 3, items.len() / 3);

        let map = mp::Map::deploy(
            provider.clone(), U256::from(w), U256::from(h), Bytes::from(tiles),
            U256::from(sx), U256::from(sy), U256::from(sdir),
            Bytes::from(guards), Bytes::from(doors), Bytes::from(items),
            Bytes::from(areas), Bytes::from(blockers), Bytes::from(pushwalls),
        ).await?;
        let session = sess::Session::deploy(provider.clone(), *engine.address(), *map.address(), Address::ZERO).await?;

        let mut full = Vec::new();
        let mut compute = Vec::new();
        for _ in 0..8 {
            let state = session.getState().call().await?;
            let cmd_c = eng::Engine::Cmd { controlx: I256::ZERO, controly: I256::try_from(-35).unwrap(), buttons: 0 };
            // Engine compute only (a view call — no Session storage write):
            compute.push(engine.tick(state, *map.address(), cmd_c).estimate_gas().await?);
            // Full per-input cost (the tx the player pays):
            let cmd_s = sess::Engine::Cmd { controlx: I256::ZERO, controly: I256::try_from(-35).unwrap(), buttons: 0 };
            full.push(session.submitInput(cmd_s).send().await?.get_receipt().await?.gas_used);
        }
        let avg = |v: &[u64]| v.iter().sum::<u64>() / v.len() as u64;
        let (f, c) = (avg(&full), avg(&compute));

        // attribute the compute: same map/doors/items but ZERO guards, on a freshly
        // spawned session, isolates the fixed per-tick map-data load from the guard AI.
        let map0 = mp::Map::deploy(
            provider.clone(), U256::from(w), U256::from(h),
            Bytes::from(level["tiles"].as_array().unwrap().iter().map(|v| v.as_u64().unwrap() as u8).collect::<Vec<u8>>()),
            U256::from(sx), U256::from(sy), U256::from(sdir),
            Bytes::new(), Bytes::from(triplet("doors", 3)), Bytes::from(triplet("items", 3)), Bytes::new(), Bytes::new(), Bytes::new(),
        ).await?;
        let s0 = sess::Session::deploy(provider.clone(), *engine.address(), *map0.address(), Address::ZERO).await?;
        let st0 = s0.getState().call().await?;
        let cmd0 = eng::Engine::Cmd { controlx: I256::ZERO, controly: I256::try_from(-35).unwrap(), buttons: 0 };
        let c0 = engine.tick(st0, *map0.address(), cmd0).estimate_gas().await?;

        // bare map: tilemap only (no guards/doors/items) — isolates the tilemap +
        // trig/rng load + codec from the per-door/item processing.
        let mapb = mp::Map::deploy(
            provider.clone(), U256::from(w), U256::from(h),
            Bytes::from(level["tiles"].as_array().unwrap().iter().map(|v| v.as_u64().unwrap() as u8).collect::<Vec<u8>>()),
            U256::from(sx), U256::from(sy), U256::from(sdir), Bytes::new(), Bytes::new(), Bytes::new(), Bytes::new(), Bytes::new(), Bytes::new(),
        ).await?;
        let sb = sess::Session::deploy(provider.clone(), *engine.address(), *mapb.address(), Address::ZERO).await?;
        let stb = sb.getState().call().await?;
        let cmdb = eng::Engine::Cmd { controlx: I256::ZERO, controly: I256::try_from(-35).unwrap(), buttons: 0 };
        let cb = engine.tick(stb, *mapb.address(), cmdb).estimate_gas().await?;

        println!(
            "\nE1L1 gas probe ({ng} guards, {nd} doors, {ni} items):\n  \
             submitInput   {f}  (the per-input tx the player pays)\n  \
             engine compute {c}\n    tilemap({w}x{h})+trig/rng+codec  {cb}\n    \
             {nd} doors + {ni} items load/scan  {}\n    {ng}-guard AI  {}\n  \
             Session/tx overhead  {}  (21k base tx + state read/write)",
            c0.saturating_sub(cb), c.saturating_sub(c0), f.saturating_sub(c)
        );
    }
    Ok(())
}
