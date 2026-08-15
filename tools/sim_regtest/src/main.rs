//! `sim_regtest` binary: the regtest faucet backend as a standalone, long-lived process
//! (spawned by `./fsim regtest up`, or auto-spawned by a sim session). It spawns
//! bitcoind+electrs, publishes the electrum URL to a file, and serves the faucet control
//! socket until told to stop — a `down` command or SIGINT/SIGTERM — then drops everything,
//! which reaps the bitcoind/electrs child processes (no orphans).
//!
//! Usage: `sim_regtest --control-socket <path> [--url-file <path>] [--reap-on-owner-exit]`
//!
//! `--reap-on-owner-exit` binds this backend's lifetime to its spawner: when stdin (a pipe the owner
//! holds) hits EOF — i.e. the owner died, even via a SIGKILL that skips its teardown — we stop and drop,
//! reaping the children. Isolated per-test sessions pass it; the shared daemon does not.

use std::io::Read;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use anyhow::Context;
use sim_regtest::Regtest;

fn main() -> anyhow::Result<()> {
    let mut control_socket: Option<String> = None;
    let mut url_file: Option<String> = None;
    let mut reap_on_owner_exit = false;
    let args: Vec<String> = std::env::args().collect();
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--control-socket" => {
                control_socket = args.get(i + 1).cloned();
                i += 2;
            }
            "--url-file" => {
                url_file = args.get(i + 1).cloned();
                i += 2;
            }
            "--reap-on-owner-exit" => {
                reap_on_owner_exit = true;
                i += 1;
            }
            other => anyhow::bail!("unknown arg: {other}"),
        }
    }
    let control_socket = control_socket.context("--control-socket <path> is required")?;

    // Reserve the control socket FIRST (singleton guard): refuse to clobber a live backend, and
    // ensure two concurrent `regtest up` invocations can't both spawn a node — the loser bails
    // here before touching bitcoind/electrs.
    let listener = sim_regtest::bind_control_socket(&control_socket)?;

    let regtest = match Regtest::start() {
        Ok(regtest) => regtest,
        Err(e) => {
            // Don't leave our just-bound socket file behind on a failed start.
            let _ = std::fs::remove_file(&control_socket);
            return Err(e).context("start regtest backend");
        }
    };
    let url = regtest.electrum_url();
    if let Some(file) = &url_file {
        std::fs::write(file, &url).with_context(|| format!("write url file {file}"))?;
    }

    // Catch SIGINT/SIGTERM so `serve` returns and `regtest` drops (reaping the children)
    // rather than the process being killed with the children orphaned.
    let stop = Arc::new(AtomicBool::new(false));
    {
        let stop = stop.clone();
        ctrlc::set_handler(move || stop.store(true, Ordering::SeqCst))
            .context("install signal handler")?;
    }

    // Bind the backend's lifetime to its owner. An isolated session spawns us with the owner holding
    // the write end of our stdin pipe, so when the owner dies ANY way — including a SIGKILL that skips
    // its Dart teardown — the kernel closes that end, this read hits EOF, and we flip the same stop flag
    // (serve returns → Regtest drops → bitcoind/electrs reaped). A finally-based reap cannot do this; it
    // never runs after SIGKILL. Gated because the shared daemon's stdin is /dev/null (instant EOF) and
    // must NOT self-reap. Detached thread, never joined: process exit terminates it even mid-read.
    if reap_on_owner_exit {
        let stop = stop.clone();
        std::thread::spawn(move || {
            let mut buf = [0u8; 64];
            loop {
                match std::io::stdin().read(&mut buf) {
                    Ok(0) | Err(_) => break, // EOF (owner's pipe closed) or error → owner is gone
                    Ok(_) => continue,       // owner shouldn't write; ignore stray bytes
                }
            }
            stop.store(true, Ordering::SeqCst);
        });
    }

    // A machine-readable readiness line for the Dart layer to parse (URL + ready marker).
    println!("REGTEST_READY {url}");
    sim_regtest::serve(&regtest, &listener, &stop).context("serve faucet control socket")?;

    // Best-effort cleanup of the well-known paths; `regtest` drops at end of main → reaps
    // bitcoind + electrs.
    let _ = std::fs::remove_file(&control_socket);
    if let Some(file) = &url_file {
        let _ = std::fs::remove_file(file);
    }
    Ok(())
}
