//! `sim_regtest` binary: the regtest faucet backend as a standalone, long-lived process
//! (spawned by `./simctl regtest up`, or auto-spawned by a sim session). It spawns
//! bitcoind+electrs, publishes the electrum URL to a file, and serves the faucet control
//! socket until told to stop — a `down` command or SIGINT/SIGTERM — then drops everything,
//! which reaps the bitcoind/electrs child processes (no orphans).
//!
//! Usage: `sim_regtest --control-socket <path> [--url-file <path>]`

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use anyhow::Context;
use sim_regtest::Regtest;

fn main() -> anyhow::Result<()> {
    let mut control_socket: Option<String> = None;
    let mut url_file: Option<String> = None;
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
