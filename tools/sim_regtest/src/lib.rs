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
use std::sync::Mutex;
use std::time::{Duration, Instant};

use anyhow::Context;
use bitcoin::{Address, Amount, Network};
use electrsd::bitcoind::{self, BitcoinD, Client};
use electrsd::corepc_client::client_sync::Auth;
use electrsd::electrum_client::ElectrumApi;
use electrsd::ElectrsD;
use miniscript::{Descriptor, DescriptorPublicKey};
use serde_json::{json, Value};

mod control;
pub use control::{bind_control_socket, serve};

/// Mine this many blocks on startup so the faucet has spendable coins (a coinbase matures
/// after 100 confirmations on regtest, so 101 leaves one matured ~50 BTC output).
const FAUCET_MATURITY_BLOCKS: usize = 101;

/// The node-side wallet [`Regtest::watch_descriptor`] imports the app's descriptor into. Separate
/// from bitcoind's own (faucet) wallet so the faucet's coins can never fund a PSBT that is supposed
/// to spend the APP's coins.
const WATCH_WALLET: &str = "frostsnap_watch";

/// How many addresses of each keychain the watch-only wallet derives. The sim only ever reveals a
/// handful, and a wide range makes `importdescriptors`'s rescan slower for nothing.
const WATCH_RANGE: u32 = 100;

/// Feerate (sat/vB) for [`Regtest::create_psbt`]. Fixed rather than estimated: regtest has no fee
/// history, so `estimatesmartfee` fails and the funding call would depend on `-fallbackfee`.
const PSBT_FEERATE_SAT_VB: u64 = 2;

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
    /// RPC client bound to the watch-only wallet [`watch_descriptor`] creates, once it exists.
    watch: Mutex<Option<Client>>,
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
            watch: Mutex::new(None),
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

    /// Broadcast `sats` to `address` (a regtest address string from the app's wallet) as an
    /// UNCONFIRMED mempool tx — [`mine`](Self::mine) is the only thing that confirms it — and block
    /// until electrs has actually indexed it, so the app's electrum sync can see the pending
    /// receive the moment this returns. Returns the txid.
    pub fn fund(&self, address: &str, sats: u64) -> anyhow::Result<String> {
        let addr = Address::from_str(address)
            .context("invalid bitcoin address")?
            .require_network(Network::Regtest)
            .context("not a regtest address")?;
        let txid = self
            .bitcoind
            .client
            .send_to_address(&addr, Amount::from_sat(sats))
            .context("send to address")?
            .txid()?
            .to_string();
        // Broadcast only — leave it UNCONFIRMED in the mempool; `mine` is the only thing that
        // confirms it. `electrsd.trigger()` merely signals electrs (non-blocking), so poll its
        // electrum history until the tx is actually indexed — otherwise fund could return before
        // the app's electrum sync can see the pending receive (racey).
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            self.electrsd.trigger().context("trigger electrs")?;
            if self.electrs_tx_height(address, &txid)?.is_some() {
                return Ok(txid);
            }
            if Instant::now() >= deadline {
                anyhow::bail!("electrs did not index the funded tx {txid} within 30s");
            }
            std::thread::sleep(Duration::from_millis(200));
        }
    }

    /// Forward a raw JSON-RPC `method`/`params` to bitcoind and return its result verbatim —
    /// the control channel's escape hatch. One-off test questions (`deriveaddresses`,
    /// `getdescriptorinfo`, `decodepsbt`, …) compose over this instead of each growing a
    /// dedicated verb, a backend helper, and a Dart wrapper.
    pub fn rpc(&self, method: &str, params: &[Value]) -> anyhow::Result<Value> {
        self.bitcoind
            .client
            .call(method, params)
            .with_context(|| format!("bitcoind rpc `{method}`"))
    }

    /// electrs's view of `txid` against `address`: `Some(height)` once electrs has indexed it
    /// (height `0` is an UNCONFIRMED mempool entry; `> 0` is confirmed at that block), or `None`
    /// if electrs hasn't picked it up yet. [`fund`](Self::fund) polls this to wait for a broadcast
    /// to become visible to the app's electrum sync.
    pub fn electrs_tx_height(&self, address: &str, txid: &str) -> anyhow::Result<Option<i32>> {
        let spk = Address::from_str(address)
            .context("invalid bitcoin address")?
            .require_network(Network::Regtest)
            .context("not a regtest address")?
            .script_pubkey();
        let history = self
            .electrsd
            .client
            .script_get_history(&spk)
            .context("electrs script history")?;
        Ok(history
            .iter()
            .find(|h| h.tx_hash.to_string() == txid)
            .map(|h| h.height))
    }

    /// The CONFIRMED balance electrs reports for `address`, in satoshis. Unlike
    /// [`faucet_balance_sat`](Self::faucet_balance_sat) (the node wallet's balance, which is
    /// dominated by maturing coinbase and so useless for isolating a single payment), this is
    /// scoped to one script — a freshly-vended faucet address used purely as a send destination
    /// shows exactly the received amount once the send confirms. The cross-check for a wallet→node
    /// send.
    pub fn electrs_address_balance_sat(&self, address: &str) -> anyhow::Result<u64> {
        let spk = Address::from_str(address)
            .context("invalid bitcoin address")?
            .require_network(Network::Regtest)
            .context("not a regtest address")?
            .script_pubkey();
        Ok(self
            .electrsd
            .client
            .script_get_balance(&spk)
            .context("electrs script balance")?
            .confirmed)
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

    /// Current chain height (blocks mined; regtest starts at genesis 0 and only advances via
    /// [`mine`](Self::mine)).
    pub fn block_height(&self) -> usize {
        self.tip.load(Ordering::SeqCst)
    }

    /// Track the app wallet's output `descriptor` in a node-side WATCH-ONLY wallet, so bitcoind can
    /// see the app's coins and build spends of them. This is the Sparrow/Core half of the real
    /// "some other wallet builds the PSBT, Frostsnap signs it" flow: nothing about the transaction
    /// then comes from the app's own tx builder.
    ///
    /// The app hands out its MULTIPATH (`<0;1>`) descriptor and Core rejects that form outright
    /// (`tr(): Key path value '<0;1>' is not a valid uint32`), so it is expanded into the
    /// receive/change pair Core wants and each half imported with its `internal` flag — Core needs
    /// that flag to know which keychain to draw change from. `timestamp: 0` forces a rescan, so the
    /// import is correct whether the app has been funded yet or not.
    pub fn watch_descriptor(&self, descriptor: &str) -> anyhow::Result<()> {
        let multi = Descriptor::<DescriptorPublicKey>::from_str(descriptor)
            .context("parse the app wallet descriptor")?;
        let singles = multi
            .into_single_descriptors()
            .context("expand the multipath descriptor")?;
        let [receive, change] = <[_; 2]>::try_from(singles).map_err(|got| {
            anyhow::anyhow!(
                "expected a receive/change descriptor pair, got {} path(s)",
                got.len()
            )
        })?;

        let mut watch = self.watch.lock().unwrap();
        let client = match &*watch {
            Some(client) => client,
            None => {
                // createwallet <name> <disable_private_keys> <blank> <passphrase> <avoid_reuse> <descriptors>
                self.bitcoind
                    .client
                    .call::<Value>(
                        "createwallet",
                        &[
                            json!(WATCH_WALLET),
                            json!(true),
                            json!(true),
                            json!(""),
                            json!(false),
                            json!(true),
                        ],
                    )
                    .context("create the watch-only wallet")?;
                watch.insert(
                    Client::new_with_auth(
                        &self.bitcoind.rpc_url_with_wallet(WATCH_WALLET),
                        Auth::CookieFile(self.bitcoind.params.cookie_file.clone()),
                    )
                    .context("connect to the watch-only wallet")?,
                )
            }
        };

        let requests: Vec<Value> = [(receive, false), (change, true)]
            .into_iter()
            .map(|(descriptor, internal)| {
                json!({
                    "desc": descriptor.to_string(),
                    "active": true,
                    "internal": internal,
                    "timestamp": 0,
                    "range": [0, WATCH_RANGE],
                })
            })
            .collect();
        let results: Vec<Value> = client
            .call("importdescriptors", &[json!(requests)])
            .context("importdescriptors")?;
        for result in results {
            if result["success"] != json!(true) {
                anyhow::bail!("importdescriptors rejected a descriptor: {result}");
            }
        }
        Ok(())
    }

    /// Build an unsigned PSBT paying `sats` to `address` out of the coins of the wallet last passed
    /// to [`watch_descriptor`](Self::watch_descriptor). Returns it base64-encoded.
    ///
    /// `bip32derivs` is on so the PSBT carries the taproot key origins the app checks a PSBT input
    /// against before it will sign it. The feerate is fixed rather than estimated because regtest
    /// has no fee history for `estimatesmartfee` to work from.
    pub fn create_psbt(&self, address: &str, sats: u64) -> anyhow::Result<String> {
        let addr = Address::from_str(address)
            .context("invalid bitcoin address")?
            .require_network(Network::Regtest)
            .context("not a regtest address")?;
        let watch = self.watch.lock().unwrap();
        let client = watch.as_ref().ok_or_else(|| {
            anyhow::anyhow!("no descriptor is being watched — call watch_descriptor first")
        })?;
        let funded: Value = client
            .call(
                "walletcreatefundedpsbt",
                &[
                    json!([]),
                    json!([{ addr.to_string(): Amount::from_sat(sats).to_btc() }]),
                    json!(0),
                    json!({"fee_rate": PSBT_FEERATE_SAT_VB}),
                    json!(true),
                ],
            )
            .context("walletcreatefundedpsbt")?;
        funded["psbt"]
            .as_str()
            .map(str::to_owned)
            .ok_or_else(|| anyhow::anyhow!("walletcreatefundedpsbt returned no psbt: {funded}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A frostsnap app wallet descriptor (`multi_x_descriptor_for_account`, Segwitv1 account 0,
    /// test network kind) — the exact string the app hands out over its `wallet-descriptor` channel.
    const APP_DESCRIPTOR: &str = "tr([e128fc9d/0/0]tpubD6NzVbkrYhZ4WetKhbx7a2uGmADGhmBsX2MnXnW9SLs3qB5HdbnLdX3niZZU6Kev91RQsB1cZ3BdtNyJxBTDFkUh3rqUa94toyzAZEEm3k5/<0;1>/*)#7c2sjwgq";

    /// bitcoind can watch a frostsnap wallet and fund a spend of it, and the PSBT it produces
    /// carries everything `psbt_to_tx_template` demands before the app will sign an input:
    /// a `witness_utxo`, a `tap_internal_key`, and a `tap_key_origin` for that key whose
    /// fingerprint is the wallet's bitcoin appkey and whose path is the 4-segment
    /// account/keychain/index form `BitcoinBip32Path::from_u32_slice` accepts.
    ///
    /// Heavy (spawns bitcoind + electrs); `sim_regtest` is not in the workspace default-members.
    #[test]
    fn watched_descriptor_funds_a_signable_psbt() {
        let regtest = Regtest::start().expect("spawn regtest node");
        regtest
            .watch_descriptor(APP_DESCRIPTOR)
            .expect("watch the app descriptor");

        // Fund the app wallet's FIRST receive address, derived here the same way the app derives
        // the address it displays.
        let receive = Descriptor::<DescriptorPublicKey>::from_str(APP_DESCRIPTOR)
            .unwrap()
            .into_single_descriptors()
            .unwrap()
            .remove(0)
            .at_derivation_index(0)
            .unwrap()
            .address(Network::Regtest)
            .unwrap()
            .to_string();
        assert!(receive.starts_with("bcrt1p"), "taproot receive: {receive}");
        regtest
            .fund(&receive, 100_000_000)
            .expect("fund the wallet");
        regtest.mine(1).expect("confirm the funding");

        let destination = regtest.faucet_address().expect("destination address");
        let psbt_base64 = regtest
            .create_psbt(&destination, 25_000_000)
            .expect("build a PSBT spending the watched wallet");

        use base64::Engine;
        let raw = base64::engine::general_purpose::STANDARD
            .decode(&psbt_base64)
            .expect("PSBT is base64");
        let psbt = bitcoin::Psbt::deserialize(&raw).expect("PSBT parses");

        assert!(!psbt.inputs.is_empty(), "the PSBT must spend something");
        for (i, input) in psbt.inputs.iter().enumerate() {
            assert!(
                input.witness_utxo.is_some(),
                "input {i} has no witness_utxo"
            );
            let internal_key = input
                .tap_internal_key
                .unwrap_or_else(|| panic!("input {i} has no tap_internal_key"));
            let (_, (fingerprint, path)) = input
                .tap_key_origins
                .get(&internal_key)
                .unwrap_or_else(|| panic!("input {i} has no origin for its tap_internal_key"));
            assert_eq!(
                fingerprint.to_string(),
                "e128fc9d",
                "input {i} origin fingerprint must be the wallet's bitcoin appkey"
            );
            let segments: Vec<u32> = path
                .into_iter()
                .map(|child| match *child {
                    bitcoin::bip32::ChildNumber::Normal { index } => index,
                    hardened => panic!("input {i} has a hardened segment {hardened}"),
                })
                .collect();
            assert_eq!(
                segments.len(),
                4,
                "input {i} path {path} must be account-kind/account/keychain/index"
            );
            assert_eq!(segments[0], 0, "account kind must be Segwitv1");
            assert!(segments[2] < 2, "keychain must be external or internal");
        }

        // Change goes back to the wallet's INTERNAL keychain, so the app can recognise it as its
        // own rather than reading it as a payment out.
        let change: Vec<_> = psbt
            .outputs
            .iter()
            .filter(|o| o.tap_internal_key.is_some())
            .collect();
        assert_eq!(change.len(), 1, "expected exactly one change output");
    }
}
