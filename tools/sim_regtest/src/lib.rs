//! sim_regtest — a Bitcoin regtest `bitcoind` + `electrs` + faucet for the simulator
//! (regtest-bitcoin-receiving). Spawns a real regtest node via the `electrsd` crate, mines
//! coins to bitcoind's own wallet (the faucet), and lets the sim fund the app's receive
//! addresses so "receive bitcoin" works on the real electrum sync path.
//!
//! The node is spawned ABOVE the app (never by `load_sim`); the app's regtest wallet is
//! pointed at [`Regtest::electrum_url`]. `electrsd` binds electrs to a DYNAMIC port, so the
//! URL is seeded into the app (it can't be a fixed default) — see the plan's decision 5.

use std::str::FromStr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use anyhow::Context;
use bitcoin::{Address, Amount, Network};
use electrsd::bitcoind::{self, BitcoinD};
use electrsd::electrum_client::ElectrumApi;
use electrsd::ElectrsD;

mod control;
pub use control::{bind_control_socket, serve};

/// Mine this many blocks on startup so the faucet has spendable coins (a coinbase matures
/// after 100 confirmations on regtest, so 101 leaves one matured ~50 BTC output).
const FAUCET_MATURITY_BLOCKS: usize = 101;

/// A running regtest node: `bitcoind` + `electrs`, with bitcoind's own wallet as the faucet.
/// Dropping it stops and reaps both child processes (via `electrsd`/`bitcoind` `Drop`).
pub struct Regtest {
    bitcoind: BitcoinD,
    electrsd: ElectrsD,
    /// A faucet address mined to; reused as the coinbase sink for [`Regtest::mine`].
    faucet: Address,
    /// Cumulative blocks we've mined = the chain height (regtest starts at genesis height 0,
    /// and we only ever advance the chain via [`Regtest::mine`]). Used to wait for electrs.
    tip: AtomicUsize,
}

impl Regtest {
    /// Spawn bitcoind (regtest) + electrs and mine the faucet to maturity. Uses the
    /// `electrsd`-downloaded binaries, or `BITCOIND_EXE` / `ELECTRS_EXE` if set.
    pub fn start() -> anyhow::Result<Self> {
        let bitcoind_exe = match std::env::var("BITCOIND_EXE") {
            Ok(path) => path,
            Err(_) => bitcoind::downloaded_exe_path().context(
                "no bitcoind: set BITCOIND_EXE or build with the electrsd download features",
            )?,
        };
        let bitcoind = BitcoinD::with_conf(bitcoind_exe, &bitcoind::Conf::default())
            .context("spawn bitcoind")?;

        let electrs_exe = match std::env::var("ELECTRS_EXE") {
            Ok(path) => path,
            Err(_) => electrsd::downloaded_exe_path().context(
                "no electrs: set ELECTRS_EXE or build with the electrsd download features",
            )?,
        };
        let electrsd = ElectrsD::with_conf(electrs_exe, &bitcoind, &electrsd::Conf::default())
            .context("spawn electrs")?;

        // The faucet is bitcoind's OWN wallet (no bdk): mine to it so a coinbase matures.
        let faucet = bitcoind.client.new_address().context("faucet address")?;
        let regtest = Self {
            bitcoind,
            electrsd,
            faucet,
            tip: AtomicUsize::new(0),
        };
        regtest.mine(FAUCET_MATURITY_BLOCKS)?;
        Ok(regtest)
    }

    /// Block until ELECTRS has indexed up to our chain tip. electrs polls bitcoind on its own
    /// schedule, so after mining we nudge it (`trigger`) and wait — otherwise the app's chain
    /// sync (and our queries) would race ahead of electrs's index.
    fn sync_electrs(&self) -> anyhow::Result<()> {
        let target = self.tip.load(Ordering::SeqCst);
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            self.electrsd.trigger().context("trigger electrs")?;
            if self.electrs_tip_height()? >= target {
                return Ok(());
            }
            if Instant::now() >= deadline {
                anyhow::bail!("electrs did not reach height {target} within 30s");
            }
            std::thread::sleep(Duration::from_millis(200));
        }
    }

    /// The electrum URL to point the app's REGTEST wallet at. `electrsd` publishes
    /// `0.0.0.0:<dynamic-port>`; the app wants a `tcp://` URL on loopback, so this is seeded
    /// into the app rather than relied on as a fixed default.
    pub fn electrum_url(&self) -> String {
        let port = self.electrsd.electrum_url.rsplit(':').next().unwrap_or("");
        format!("tcp://127.0.0.1:{port}")
    }

    /// A fresh faucet (bitcoind-wallet) address — e.g. to send change back to in a demo.
    pub fn faucet_address(&self) -> anyhow::Result<String> {
        Ok(self.bitcoind.client.new_address()?.to_string())
    }

    /// The faucet's spendable balance, in satoshis.
    pub fn faucet_balance_sat(&self) -> anyhow::Result<u64> {
        Ok(self.bitcoind.client.get_balance()?.into_model()?.0.to_sat())
    }

    /// Send `sats` to `address` (a regtest address string from the app's wallet) and confirm
    /// it with one mined block so the wallet sees a confirmed receive. Returns the txid.
    pub fn fund(&self, address: &str, sats: u64) -> anyhow::Result<String> {
        let address = Address::from_str(address)
            .context("invalid bitcoin address")?
            .require_network(Network::Regtest)
            .context("not a regtest address")?;
        let txid = self
            .bitcoind
            .client
            .send_to_address(&address, Amount::from_sat(sats))
            .context("send to address")?
            .txid()?;
        self.mine(1)?;
        Ok(txid.to_string())
    }

    /// Mine `blocks` blocks (coinbase to the faucet), advancing the chain, then wait for
    /// electrs to index up to the new tip so the wallet sees the result promptly.
    pub fn mine(&self, blocks: usize) -> anyhow::Result<()> {
        self.bitcoind
            .client
            .generate_to_address(blocks as _, &self.faucet)
            .context("mine blocks")?
            .into_model()?;
        self.tip.fetch_add(blocks, Ordering::SeqCst);
        self.sync_electrs()
    }

    /// The chain-tip height as seen by ELECTRS (not just bitcoind) — proves electrs is synced.
    pub fn electrs_tip_height(&self) -> anyhow::Result<usize> {
        Ok(self.electrsd.client.block_headers_subscribe()?.height)
    }
}
