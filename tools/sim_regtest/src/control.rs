//! The faucet control socket: a unix-socket server that exposes the [`Regtest`] faucet over a
//! JSON line protocol, so the Dart `./simctl` layer can drive it (fund the app's wallet, mine,
//! query balance) — the same pattern as the device-input channel (`SimDeviceChannel`).
//!
//! Protocol: one JSON request object per line, one JSON reply object per line.
//! ```text
//!   {"cmd":"electrum_url"}                  -> {"ok":true,"url":"tcp://127.0.0.1:PORT"}
//!   {"cmd":"faucet_address"}                -> {"ok":true,"address":"bcrt1..."}
//!   {"cmd":"balance"}                       -> {"ok":true,"sat":N}
//!   {"cmd":"address_balance","address":"bcrt1.."} -> {"ok":true,"sat":N}  (electrs, confirmed)
//!   {"cmd":"height"}                         -> {"ok":true,"height":N}
//!   {"cmd":"fund","address":"bcrt1..","sats":N} -> {"ok":true,"txid":"<hex>"}   (UNCONFIRMED)
//!   {"cmd":"mine","blocks":N}               -> {"ok":true}
//!   {"cmd":"ping"}                          -> {"ok":true,"pid":PID}
//!   {"cmd":"down"}                          -> {"ok":true,"down":true}   (then serve returns)
//! ```
//! Anything malformed/unknown -> `{"ok":false,"error":"..."}`.
//!
//! Single-threaded + serial (one connection at a time): the faucet is low-throughput and its
//! ops mutate one chain, so there are no handler threads holding references — the caller keeps
//! sole ownership of [`Regtest`], which drops (and reaps bitcoind/electrs) the moment `serve`
//! returns. Clients (the `./simctl` forwarder, the tray) send a command and close, so serial
//! handling is not a bottleneck.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use anyhow::{anyhow, Context};
use serde_json::{json, Value};

use crate::Regtest;

/// How often the accept loop wakes to check `stop` while idle.
const ACCEPT_POLL: Duration = Duration::from_millis(20);

/// Bind the faucet control socket as a SINGLETON, refusing to clobber a backend already live at
/// `path`. The shared-node invariant is "one backend per well-known socket, attachable + cleanly
/// teardownable"; unconditionally unlinking the socket would orphan a running node (its
/// bitcoind/electrs stay alive but unreachable). So: if `bind` fails because the path exists, we
/// probe it — a successful `connect` means a live listener (the kernel accepts into the backlog
/// even before it calls `accept`, so this also catches a backend still in `Regtest::start`), and
/// we bail; only a stale file (connect refused) is removed and rebound. Call this BEFORE spawning
/// the node so two concurrent `regtest up` invocations can't both start one — the loser fails to
/// bind here and exits before touching bitcoind/electrs.
pub fn bind_control_socket(path: &str) -> anyhow::Result<UnixListener> {
    match UnixListener::bind(path) {
        Ok(listener) => Ok(listener),
        Err(_) => {
            if UnixStream::connect(path).is_ok() {
                anyhow::bail!(
                    "a regtest backend is already running at {path}; attach to it or shut it down first"
                );
            }
            std::fs::remove_file(path)
                .with_context(|| format!("remove stale control socket {path}"))?;
            UnixListener::bind(path).with_context(|| format!("bind control socket {path}"))
        }
    }
}

/// Serve the faucet control protocol on `listener` until `stop` is set (by a `down` command or
/// by the caller, e.g. on a signal). Runs on the calling thread; `regtest` stays owned by the
/// caller so it drops — reaping the child processes — right after this returns.
pub fn serve(regtest: &Regtest, listener: &UnixListener, stop: &AtomicBool) -> std::io::Result<()> {
    listener.set_nonblocking(true)?;
    while !stop.load(Ordering::Relaxed) {
        match listener.accept() {
            Ok((stream, _)) => handle_conn(stream, regtest, stop)?,
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => std::thread::sleep(ACCEPT_POLL),
            Err(_) => break,
        }
    }
    Ok(())
}

fn handle_conn(stream: UnixStream, regtest: &Regtest, stop: &AtomicBool) -> std::io::Result<()> {
    // The listener is non-blocking for accept-polling; the accepted stream must block so
    // `read_line` waits for the next command instead of spinning.
    stream.set_nonblocking(false)?;
    let read_half = stream.try_clone()?;
    let mut writer = stream;
    for line in BufReader::new(read_half).lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let (reply, shutdown) = dispatch(&line, regtest);
        if writeln!(writer, "{reply}").is_err() || writer.flush().is_err() {
            break;
        }
        if shutdown {
            stop.store(true, Ordering::Relaxed);
            break;
        }
    }
    Ok(())
}

/// Dispatch one request line. Returns the reply and whether to shut the server down (`down`).
fn dispatch(line: &str, regtest: &Regtest) -> (Value, bool) {
    let req: Value = match serde_json::from_str(line) {
        Ok(v) => v,
        Err(e) => return (err(format!("invalid json: {e}")), false),
    };

    let result: anyhow::Result<(Value, bool)> = (|| match req.get("cmd").and_then(Value::as_str) {
        // `pid` is the AUTHORITATIVE owner token: only the process that won `bind_control_socket`
        // serves, so its PID identifies the live backend. A Dart spawner compares this against the
        // child it started to decide whether it owns the node (and may tear it down) or merely
        // attached to a concurrent winner's.
        Some("ping") => Ok((json!({"ok": true, "pid": std::process::id()}), false)),
        Some("electrum_url") => Ok((json!({"ok": true, "url": regtest.electrum_url()}), false)),
        Some("faucet_address") => Ok((
            json!({"ok": true, "address": regtest.faucet_address()?}),
            false,
        )),
        Some("balance") => Ok((
            json!({"ok": true, "sat": regtest.faucet_balance_sat()?}),
            false,
        )),
        Some("address_balance") => {
            let address = req
                .get("address")
                .and_then(Value::as_str)
                .ok_or_else(|| anyhow!("missing/invalid string field `address`"))?;
            Ok((
                json!({"ok": true, "sat": regtest.electrs_address_balance_sat(address)?}),
                false,
            ))
        }
        Some("height") => Ok((json!({"ok": true, "height": regtest.block_height()}), false)),
        Some("mine") => {
            let blocks = req.get("blocks").and_then(Value::as_u64).unwrap_or(1) as usize;
            regtest.mine(blocks)?;
            Ok((json!({"ok": true}), false))
        }
        Some("fund") => {
            let address = req
                .get("address")
                .and_then(Value::as_str)
                .ok_or_else(|| anyhow!("missing/invalid string field `address`"))?;
            let sats = req
                .get("sats")
                .and_then(Value::as_u64)
                .ok_or_else(|| anyhow!("missing/invalid integer field `sats`"))?;
            let txid = regtest.fund(address, sats)?;
            Ok((json!({"ok": true, "txid": txid}), false))
        }
        Some("down") => Ok((json!({"ok": true, "down": true}), true)),
        Some(other) => Err(anyhow!("unknown cmd: {other}")),
        None => Err(anyhow!("missing `cmd`")),
    })();

    match result {
        Ok(reply) => reply,
        Err(e) => (err(e.to_string()), false),
    }
}

fn err(message: String) -> Value {
    json!({"ok": false, "error": message})
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::sync::Arc;
    use std::thread;

    fn temp_socket(name: &str) -> PathBuf {
        std::env::temp_dir().join(name)
    }

    // The control socket is a SINGLETON: bind_control_socket refuses to clobber a LIVE backend
    // (so a second `regtest up` can't orphan the first's node), but reclaims a stale socket file.
    // Light — no node spawned.
    #[test]
    fn bind_control_socket_is_a_singleton() {
        let path = temp_socket("sim_regtest_singleton_test.sock");
        let _ = std::fs::remove_file(&path);
        let path = path.to_str().unwrap();

        // Fresh path: binds.
        let live = bind_control_socket(path).expect("first bind");
        // A second bind while the first is live: refused (don't clobber the running backend).
        assert!(
            bind_control_socket(path).is_err(),
            "must refuse a live socket"
        );

        // Drop the listener -> the socket FILE is now stale (no listener); bind reclaims it.
        drop(live);
        let reclaimed = bind_control_socket(path).expect("rebind over a stale socket");
        drop(reclaimed);
        let _ = std::fs::remove_file(path);
    }

    // Spawns a REAL regtest bitcoind + electrs and proves BOTH the lib faucet API (matured
    // balance, electrs synced to the tip, fund a regtest address — the require_network guard)
    // AND the control socket (round-trips every command, including `down` to stop the server).
    // Heavy (spawns processes); only runs under `cargo test -p sim_regtest` (the crate is not
    // in the workspace default-members).
    #[test]
    fn faucet_lib_and_control_socket() {
        let regtest = Regtest::start().expect("spawn regtest node");

        // ---- direct lib API (guards the regtest-network + electrs-sync invariants) ----
        assert!(
            regtest.faucet_balance_sat().expect("balance") > 0,
            "faucet should have matured coins"
        );
        assert!(
            regtest.electrs_tip_height().expect("tip") >= 101,
            "electrs should be synced to the mined tip"
        );
        let target = regtest.faucet_address().expect("regtest address");
        // fund broadcasts an UNCONFIRMED tx: it returns a txid but must NOT advance the chain, and
        // (since fund waits for indexing) electrs must already see it as unconfirmed before mine.
        let height_before = regtest.block_height();
        let funded = regtest.fund(&target, 100_000).expect("fund");
        assert_eq!(funded.len(), 64, "fund returns a hex txid");
        assert_eq!(
            regtest.block_height(),
            height_before,
            "fund must not mine — the receive stays unconfirmed until mine"
        );
        let unconfirmed = regtest
            .electrs_tx_height(&target, &funded)
            .expect("electrs query")
            .expect("funded tx must be visible to electrs before any mine");
        assert!(
            unconfirmed <= 0,
            "funded tx must be unconfirmed in electrs, got height {unconfirmed}"
        );
        regtest.mine(1).expect("mine");
        assert_eq!(
            regtest.block_height(),
            height_before + 1,
            "mine advances the chain height"
        );
        // electrs can advance its header tip before its per-script index reflects the new block,
        // so poll until the tx reads confirmed (height > 0) rather than checking once.
        let mut confirmed = 0;
        for _ in 0..50 {
            confirmed = regtest
                .electrs_tx_height(&target, &funded)
                .expect("electrs query")
                .unwrap_or(0);
            if confirmed > 0 {
                break;
            }
            std::thread::sleep(Duration::from_millis(200));
        }
        assert!(
            confirmed > 0,
            "after mine the tx should confirm in electrs within ~10s, got height {confirmed}"
        );
        // The per-address (electrs) balance is scoped to `target` and so reflects exactly the
        // funded amount — coinbase to the faucet's OWN address does not pollute it.
        assert_eq!(
            regtest
                .electrs_address_balance_sat(&target)
                .expect("address balance"),
            100_000,
            "electrs address balance must be exactly the confirmed amount funded to it"
        );
        assert!(regtest.electrum_url().starts_with("tcp://127.0.0.1:"));

        // ---- control socket round-trip ----
        let sock = temp_socket("sim_regtest_control_test.sock");
        let _ = std::fs::remove_file(&sock);
        let listener = UnixListener::bind(&sock).expect("bind control socket");
        let stop = Arc::new(AtomicBool::new(false));

        // The client runs on its own thread (only socket I/O, no Regtest access); `serve` runs
        // on this thread and returns once the client sends `down`.
        let client = {
            let sock = sock.clone();
            let target = target.clone();
            thread::spawn(move || -> Vec<Value> {
                let stream = UnixStream::connect(&sock).expect("connect control socket");
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut writer = stream;
                let mut call = |line: &str| -> Value {
                    writeln!(writer, "{line}").unwrap();
                    writer.flush().unwrap();
                    let mut reply = String::new();
                    reader.read_line(&mut reply).unwrap();
                    serde_json::from_str(&reply).unwrap()
                };
                vec![
                    call(r#"{"cmd":"ping"}"#),
                    call(r#"{"cmd":"electrum_url"}"#),
                    call(r#"{"cmd":"balance"}"#),
                    call(r#"{"cmd":"height"}"#),
                    call(&format!(
                        r#"{{"cmd":"fund","address":"{target}","sats":50000}}"#
                    )),
                    call(r#"{"cmd":"mine","blocks":2}"#),
                    call(&format!(
                        r#"{{"cmd":"address_balance","address":"{target}"}}"#
                    )),
                    call(r#"{"cmd":"nope"}"#),
                    call(r#"{"cmd":"down"}"#),
                ]
            })
        };

        serve(&regtest, &listener, &stop).expect("serve");
        let replies = client.join().expect("client thread");

        assert_eq!(replies[0]["ok"], json!(true), "ping");
        assert_eq!(
            replies[0]["pid"].as_u64(),
            Some(std::process::id() as u64),
            "ping reports the serving process's pid (the owner token)"
        );
        assert!(
            replies[1]["url"]
                .as_str()
                .unwrap()
                .starts_with("tcp://127.0.0.1:"),
            "electrum_url: {:?}",
            replies[1]
        );
        assert!(replies[2]["sat"].as_u64().unwrap() > 0, "balance");
        assert!(
            replies[3]["height"].as_u64().unwrap() >= 101,
            "height: {:?}",
            replies[3]
        );
        assert_eq!(replies[4]["txid"].as_str().unwrap().len(), 64, "fund txid");
        assert_eq!(replies[5]["ok"], json!(true), "mine");
        // 100_000 (lib section) + 50_000 (just funded) confirmed to `target`, coinbase-free.
        assert_eq!(
            replies[6]["sat"].as_u64(),
            Some(150_000),
            "address_balance: {:?}",
            replies[6]
        );
        assert_eq!(
            replies[7]["ok"],
            json!(false),
            "unknown cmd is a clean error"
        );
        assert_eq!(replies[8]["down"], json!(true), "down");

        let _ = std::fs::remove_file(&sock);
    }
}
