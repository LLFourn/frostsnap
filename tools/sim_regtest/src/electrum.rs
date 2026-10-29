//! The electrum front doors: the sim's two "electrum servers".
//!
//! The app's electrum client sees nothing but a socket, so everything a test needs to vary —
//! whether the server accepts, whether it speaks TLS, which certificate it presents, whether
//! the session survives — is a property of that socket rather than of `electrs`. A front door
//! is a listener the harness owns that proxies to the one real electrs behind it, and can be
//! reconfigured underneath a running app.
//!
//! Two doors on one chain are the two servers the app's primary/backup slots point at; nothing
//! the app does can tell them from two `electrs` instances. They differ only in HOST, and that
//! is load-bearing: TOFU keys its trust store by hostname alone, so two doors sharing
//! `127.0.0.1` would share one trust entry and "trusted for A but not B" could not exist. Door
//! `a` is reached as `127.0.0.1` and door `b` as `localhost` — two names for the same loopback,
//! two trust keys.
//!
//! That assignment is not arbitrary. Both listen on `127.0.0.1` only, and the app connects with
//! RFC 8305 happy eyeballs, which starts the IPv4 attempt 250ms after the IPv6 one. `localhost`
//! resolves to `::1` first, so it costs that 250ms on every connect. Door `a` is the primary
//! every existing regtest test already uses, so it takes the literal address and pays nothing;
//! only tests that deliberately exercise the backup meet the delay.
//!
//! Async, unlike the rest of this crate, because a TLS proxy is bidirectional: one task must
//! read from the client and write to electrs while another does the reverse, and a blocking
//! `rustls` connection cannot be split between two threads. `copy_bidirectional` over
//! `tokio_rustls` is the whole of it.

use std::collections::HashMap;
use std::net::{Ipv4Addr, SocketAddr};
use std::os::fd::{AsFd, OwnedFd};
use std::sync::{Arc, Mutex};

use anyhow::{anyhow, Context};
use rcgen::{CertificateParams, KeyPair};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use tokio::net::{TcpListener, TcpStream};
use tokio::runtime::Runtime;
use tokio::task::JoinHandle;
use tokio_rustls::TlsAcceptor;

/// What a door does with a connection — the vocabulary a caller sets it to.
///
/// Two INDEPENDENT properties are folded into this one request enum: which transport the door
/// speaks, and whether it is serving at all. `Tcp`/`Tls` set the transport (and resume
/// serving); `Down`/`Hang` change only availability and leave the transport alone. The door
/// stores them apart — see [`Transport`] and [`Availability`] — because a door taken down must
/// keep the url the app has persisted in its settings, scheme included.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Mode {
    /// Plaintext passthrough — a working server.
    Tcp,
    /// Terminate TLS with the named identity, then pass through.
    Tls(String),
    /// A connection is closed the instant it arrives, as against a server that is not there.
    /// See [`accept_loop`] for why this is a reset rather than an ECONNREFUSED.
    Down,
    /// Accept and never write a byte — a wedged server, or a firewall that swallows the
    /// response. Distinct from [`Mode::Down`] in that it costs the client its connect timeout.
    Hang,
}

impl Mode {
    pub fn as_str(&self) -> &'static str {
        match self {
            Mode::Tcp => "tcp",
            Mode::Tls(_) => "tls",
            Mode::Down => "down",
            Mode::Hang => "hang",
        }
    }
}

/// What a door speaks when it is serving. Survives [`Availability`] changes: taking a TLS door
/// down and bringing it back must not silently move it to plaintext, and must not change the
/// url the app already has.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Transport {
    Plain,
    Tls(String),
}

impl Transport {
    fn scheme(&self) -> &'static str {
        match self {
            Transport::Plain => "tcp",
            Transport::Tls(_) => "ssl",
        }
    }
}

/// Whether a door is answering, independent of what it speaks.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Availability {
    Serving,
    Down,
    Hang,
}

/// How to mint an identity the first time its name is used.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Shape {
    /// Valid, self-signed, SAN matching the door's host.
    Normal,
    /// Self-signed and well-formed but past its `notAfter`.
    Expired,
    /// Valid, but its SAN names a different host.
    WrongHost,
    /// A leaf signed by ANOTHER identity, for the cross-host forgery case. The issuer is a
    /// plain leaf, not a CA — which is exactly the point: webpki ignores `basicConstraints` on
    /// a trust anchor, so a TOFU cert promoted into the root store could mint this.
    SignedBy,
}

impl Shape {
    pub fn parse(s: &str) -> anyhow::Result<Self> {
        Ok(match s {
            "normal" => Shape::Normal,
            "expired" => Shape::Expired,
            "wrong_host" => Shape::WrongHost,
            "signed_by" => Shape::SignedBy,
            other => return Err(anyhow!("unknown identity shape `{other}`")),
        })
    }
}

/// A request for an identity by name, plus how to mint it if it does not exist yet.
#[derive(Clone, Debug)]
pub struct IdentitySpec {
    pub name: String,
    pub shape: Shape,
    pub issuer: Option<String>,
}

struct Identity {
    cert: rcgen::Certificate,
    key: KeyPair,
    fingerprint: String,
    shape: Shape,
    issuer: Option<String>,
    /// The door host this was minted against. Part of the name's meaning: the SAN is baked in,
    /// so the same name served on the other door would present a certificate for the wrong
    /// server while still reporting itself as normal.
    host: String,
}

/// Identities minted on demand and kept for the session, so a name means the same BYTES every
/// time it is served. TOFU change-detection is a byte comparison, so a name that re-minted per
/// connection would look like a cert rotation on every reconnect.
#[derive(Default)]
struct Identities(HashMap<String, Identity>);

impl Identities {
    /// The identity for `spec`, minting it against `host` if this name is new.
    ///
    /// A name already in use for a DIFFERENT certificate — different shape, issuer, or door host
    /// — is an ERROR rather than a silent reuse. The store is shared by both doors and the SAN is
    /// baked in at minting, so serving `a1` on the other door would quietly present a certificate
    /// for the wrong server; every assertion downstream would then be about a certificate the
    /// test did not ask for.
    fn resolve(
        &mut self,
        spec: &IdentitySpec,
        host: &str,
    ) -> anyhow::Result<(TlsAcceptor, String)> {
        if let Some(existing) = self.0.get(&spec.name) {
            if existing.host != host {
                return Err(anyhow!(
                    "identity `{}` was minted for `{}` and cannot be served on `{}`: its SAN is \
                     fixed at minting, so use a separate name per door",
                    spec.name,
                    existing.host,
                    host,
                ));
            }
            if existing.shape != spec.shape || existing.issuer != spec.issuer {
                return Err(anyhow!(
                    "identity `{}` already exists as {:?}/{:?}, cannot re-mint as {:?}/{:?}",
                    spec.name,
                    existing.shape,
                    existing.issuer,
                    spec.shape,
                    spec.issuer,
                ));
            }
        } else {
            let identity = self.mint(spec, host)?;
            self.0.insert(spec.name.clone(), identity);
        }

        let identity = &self.0[&spec.name];
        let acceptor = acceptor_for(identity)?;
        Ok((acceptor, identity.fingerprint.clone()))
    }

    fn mint(&self, spec: &IdentitySpec, host: &str) -> anyhow::Result<Identity> {
        let san = match spec.shape {
            Shape::WrongHost => "not-this-server.invalid".to_string(),
            _ => host.to_string(),
        };
        let mut params = CertificateParams::new(vec![san])
            .with_context(|| format!("certificate parameters for `{}`", spec.name))?;
        // Wide validity so a long-lived branch never has a certificate rot out from under it;
        // `Expired` picks its own window instead.
        params.not_before = rcgen::date_time_ymd(2020, 1, 1);
        params.not_after = match spec.shape {
            Shape::Expired => rcgen::date_time_ymd(2021, 1, 1),
            _ => rcgen::date_time_ymd(2100, 1, 1),
        };

        let key = KeyPair::generate().context("generate key pair")?;
        let cert = match spec.shape {
            Shape::SignedBy => {
                let issuer_name = spec
                    .issuer
                    .as_deref()
                    .ok_or_else(|| anyhow!("shape `signed_by` needs an `issuer`"))?;
                let issuer = self.0.get(issuer_name).ok_or_else(|| {
                    anyhow!("issuer identity `{issuer_name}` has not been served yet")
                })?;
                params
                    .signed_by(&key, &issuer.cert, &issuer.key)
                    .context("sign the leaf with the issuer identity")?
            }
            _ => params.self_signed(&key).context("self-sign")?,
        };

        let fingerprint = sha256_fingerprint(cert.der());
        Ok(Identity {
            cert,
            key,
            fingerprint,
            shape: spec.shape,
            issuer: spec.issuer.clone(),
            host: host.to_string(),
        })
    }
}

/// SHA256 of the certificate DER as lowercase hex — the same form the app's
/// `UntrustedCertificate::fingerprint` carries, so a test can compare the two directly.
fn sha256_fingerprint(der: &CertificateDer<'_>) -> String {
    use sha2::{Digest, Sha256};
    hex::encode(Sha256::digest(der.as_ref()))
}

fn acceptor_for(identity: &Identity) -> anyhow::Result<TlsAcceptor> {
    let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(
        identity.key.serialize_der().to_vec(),
    ));
    let config = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(vec![identity.cert.der().clone()], key)
        .context("build the server TLS config")?;
    Ok(TlsAcceptor::from(Arc::new(config)))
}

struct DoorState {
    transport: Transport,
    availability: Availability,
    /// The identity the transport presents, `(name, fingerprint)`. Kept while the door is down,
    /// because it is the certificate the door will present when it comes back.
    identity: Option<(String, String)>,
    /// Built when the transport is TLS, so the accept loop does not have to touch the identity
    /// store (and cannot fail) per connection.
    acceptor: Option<TlsAcceptor>,
    conns: Vec<LiveConn>,
    /// Every connection this door has EVER accepted. Monotonic, so "did the client reconnect?"
    /// is an exact question. The live count cannot answer it: a teardown and a reconnect both
    /// end at one connection, and sampling for the gap between them is a race a test loses.
    accepted: u64,
}

/// A connection the door is currently serving.
struct LiveConn {
    task: JoinHandle<()>,
    /// A duplicate of the client socket's descriptor. `SO_LINGER` is a property of the socket
    /// itself, not of a handle, so setting it here changes how the LAST close behaves — which is
    /// what lets a deliberate kill reset the peer while an ordinary proxy completion still sends
    /// a FIN. Setting it up-front on every socket instead would make the door non-transparent:
    /// a healthy session's normal close would reset the client too, and a backend that closed
    /// gracefully would be indistinguishable from the session failure `drop_connections`
    /// synthesizes.
    fd: OwnedFd,
}

impl LiveConn {
    /// Kill this connection so the client sees a RESET: a session that died, not one that ended.
    fn reset(self) {
        let _ = socket2::SockRef::from(&self.fd).set_linger(Some(std::time::Duration::ZERO));
        self.task.abort();
    }
}

/// One controllable electrum endpoint in front of the shared `electrs`.
pub struct Door {
    id: String,
    host: String,
    /// Fixed for the door's lifetime. A mode change must not move the endpoint, because the app
    /// has the url persisted in its settings by then.
    port: u16,
    state: Arc<Mutex<DoorState>>,
    identities: Arc<Mutex<Identities>>,
}

impl Door {
    pub fn id(&self) -> &str {
        &self.id
    }

    /// The url the app should be pointed at, e.g. `tcp://127.0.0.1:50001`. Its scheme comes from
    /// the TRANSPORT alone, so taking a door down does not invalidate the url the app has
    /// already persisted.
    pub fn url(&self) -> String {
        let state = self.state.lock().unwrap();
        format!("{}://{}:{}", state.transport.scheme(), self.host, self.port)
    }

    /// The door's mode in the caller's vocabulary: unavailability wins, since that is what a
    /// client meets first.
    pub fn mode(&self) -> Mode {
        let state = self.state.lock().unwrap();
        match (&state.availability, &state.transport) {
            (Availability::Down, _) => Mode::Down,
            (Availability::Hang, _) => Mode::Hang,
            (Availability::Serving, Transport::Plain) => Mode::Tcp,
            (Availability::Serving, Transport::Tls(name)) => Mode::Tls(name.clone()),
        }
    }

    /// `(identity name, fingerprint)` when serving TLS.
    pub fn identity(&self) -> Option<(String, String)> {
        self.state.lock().unwrap().identity.clone()
    }

    /// Connections accepted over this door's whole life — see [`DoorState::accepted`].
    pub fn accepted_count(&self) -> u64 {
        self.state.lock().unwrap().accepted
    }

    /// Live connections, pruned of finished ones.
    pub fn connection_count(&self) -> usize {
        let mut state = self.state.lock().unwrap();
        state.conns.retain(|c| !c.task.is_finished());
        state.conns.len()
    }

    /// Put the door in `mode`, returning the url to reach it on.
    ///
    /// `Tcp`/`Tls` set the transport and resume serving; `Down`/`Hang` change availability only,
    /// so a TLS door that is taken down and brought back is still the same TLS door on the same
    /// url. Atomic against connections in flight: everything already accepted is dropped, and
    /// the accept loop cannot admit a connection under the old state once this returns. The
    /// identity is resolved FIRST, so a bad spec leaves the door exactly as it was rather than
    /// tearing it down and failing to restore it.
    pub fn set_mode(&self, mode: Mode, spec: Option<IdentitySpec>) -> anyhow::Result<String> {
        let tls = match &mode {
            Mode::Tls(name) => {
                let spec = spec.unwrap_or_else(|| IdentitySpec {
                    name: name.clone(),
                    shape: Shape::Normal,
                    issuer: None,
                });
                let (acceptor, fingerprint) =
                    self.identities.lock().unwrap().resolve(&spec, &self.host)?;
                Some((acceptor, spec.name, fingerprint))
            }
            _ => None,
        };

        let mut state = self.state.lock().unwrap();
        for conn in state.conns.drain(..) {
            conn.reset();
        }
        match &mode {
            Mode::Tcp => {
                state.transport = Transport::Plain;
                state.availability = Availability::Serving;
                state.acceptor = None;
                state.identity = None;
            }
            Mode::Tls(name) => {
                let (acceptor, _, fingerprint) = tls.expect("a Tls mode always resolves a cert");
                state.transport = Transport::Tls(name.clone());
                state.availability = Availability::Serving;
                state.acceptor = Some(acceptor);
                state.identity = Some((name.clone(), fingerprint));
            }
            Mode::Down => state.availability = Availability::Down,
            Mode::Hang => state.availability = Availability::Hang,
        }
        let url = format!("{}://{}:{}", state.transport.scheme(), self.host, self.port);
        drop(state);
        Ok(url)
    }

    /// Drop every live connection, as a server dying mid-session does. Returns how many.
    ///
    /// The door stays in its mode: the next connect succeeds. That is the shape of the failure
    /// where a server passes the connectivity probe and then cannot serve — retrying the same
    /// server keeps working right up to the point it matters.
    pub fn drop_connections(&self) -> usize {
        let mut state = self.state.lock().unwrap();
        state.conns.retain(|c| !c.task.is_finished());
        let dropped = state.conns.len();
        for conn in state.conns.drain(..) {
            conn.reset();
        }
        dropped
    }
}

/// One loop for the door's whole life, reading the door's state per connection.
///
/// The listener is never dropped and re-bound, because the port is the door's identity: the app
/// has the url persisted in its settings, and under `--jobs N` a released port is a port another
/// session's door can claim. `Down` therefore closes each connection the instant it arrives
/// rather than refusing it — an RST where a dead server would give ECONNREFUSED. Both are
/// "this server did not serve me", which is what the failover paths under test act on; the
/// distinction is not worth a port race.
///
/// Reading the state, admitting the connection and registering its task happen under ONE hold of
/// the lock. Split apart, a `set_mode` or `drop_connections` could drain between the read and the
/// registration, and the loop would then insert a task running under the state the caller just
/// left — so "no connection survives the transition" would be false exactly when it is being
/// relied on. Nothing in the guarded section awaits, so holding a blocking mutex across it is
/// sound.
async fn accept_loop(listener: TcpListener, backend: SocketAddr, state: Arc<Mutex<DoorState>>) {
    loop {
        let Ok((sock, _)) = listener.accept().await else {
            return;
        };
        admit(&mut state.lock().unwrap(), sock, backend);
    }
}

/// Decide what to do with an accepted connection and register the task that does it.
///
/// Takes `&mut DoorState` rather than the `Mutex`, so choosing the behaviour and recording the
/// task cannot be split across two acquisitions: the caller is already holding the lock, and
/// there is no way to express "read the state, release, spawn, re-acquire" without changing this
/// signature. That split is what would break the contract — `set_mode` and `drop_connections`
/// drain only what is registered, so a task admitted under the old state but registered after the
/// drain would outlive a transition that promised to remove it.
fn admit(state: &mut DoorState, sock: TcpStream, backend: SocketAddr) {
    // Counted before the mode is consulted: a client that reached the door reached it, even if
    // the door then closes on it.
    state.accepted += 1;
    // Duplicated BEFORE the socket moves into the proxy task, so a later kill can still reach
    // the socket to reset it. Nothing is changed about the socket here: a session that ends by
    // itself closes gracefully, and the door stays byte-transparent.
    let fd = match sock.as_fd().try_clone_to_owned() {
        Ok(fd) => fd,
        Err(_) => return,
    };
    let task = match (state.availability, state.transport.clone()) {
        (Availability::Down, _) => return,
        (Availability::Hang, _) => tokio::spawn(hang(sock)),
        (Availability::Serving, Transport::Plain) => tokio::spawn(proxy_plain(sock, backend)),
        (Availability::Serving, Transport::Tls(_)) => match state.acceptor.clone() {
            Some(acceptor) => tokio::spawn(proxy_tls(sock, backend, acceptor)),
            // A TLS transport is only ever stored together with its acceptor.
            None => return,
        },
    };
    state.conns.retain(|c| !c.task.is_finished());
    state.conns.push(LiveConn { task, fd });
}

async fn proxy_plain(mut client: TcpStream, backend: SocketAddr) {
    let Ok(mut server) = TcpStream::connect(backend).await else {
        return;
    };
    let _ = tokio::io::copy_bidirectional(&mut client, &mut server).await;
}

async fn proxy_tls(client: TcpStream, backend: SocketAddr, acceptor: TlsAcceptor) {
    let Ok(mut tls) = acceptor.accept(client).await else {
        return;
    };
    let Ok(mut server) = TcpStream::connect(backend).await else {
        return;
    };
    let _ = tokio::io::copy_bidirectional(&mut tls, &mut server).await;
}

async fn hang(sock: TcpStream) {
    let _held = sock;
    std::future::pending::<()>().await;
}

/// The doors, and the runtime they run on. Dropping this stops every door.
pub struct ElectrumServers {
    doors: Vec<Arc<Door>>,
    // Declared last so the doors' handles are gone before the runtime shuts down.
    _rt: Runtime,
}

impl ElectrumServers {
    /// Two doors in front of `backend` (the real electrs), both serving plaintext — so a fresh
    /// session behaves exactly like the single direct endpoint this replaced.
    pub fn start(backend: SocketAddr) -> anyhow::Result<Self> {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .context("build the front-door runtime")?;
        let identities = Arc::new(Mutex::new(Identities::default()));

        let mut doors = Vec::new();
        for (id, host) in [("a", "127.0.0.1"), ("b", "localhost")] {
            // Bound once, here, and held for the door's lifetime — never released to express a
            // mode. Two sessions racing for the same port is otherwise a live failure under
            // `--jobs N`, not just a test artefact.
            let listener = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0))
                .with_context(|| format!("bind door `{id}`"))?;
            let port = listener.local_addr()?.port();
            listener.set_nonblocking(true)?;

            let state = Arc::new(Mutex::new(DoorState {
                transport: Transport::Plain,
                availability: Availability::Serving,
                identity: None,
                acceptor: None,
                conns: Vec::new(),
                accepted: 0,
            }));
            let _guard = rt.enter();
            rt.spawn(accept_loop(
                TcpListener::from_std(listener)?,
                backend,
                state.clone(),
            ));
            drop(_guard);

            doors.push(Arc::new(Door {
                id: id.to_string(),
                host: host.to_string(),
                port,
                state,
                identities: identities.clone(),
            }));
        }

        Ok(Self { doors, _rt: rt })
    }

    pub fn doors(&self) -> &[Arc<Door>] {
        &self.doors
    }

    pub fn door(&self, id: &str) -> anyhow::Result<&Arc<Door>> {
        self.doors
            .iter()
            .find(|d| d.id == id)
            .ok_or_else(|| anyhow!("no electrum server `{id}` (have `a` and `b`)"))
    }

    /// Door `a` — the one [`crate::Regtest::electrum_url`] points the app's primary slot at.
    pub fn primary(&self) -> &Arc<Door> {
        &self.doors[0]
    }

    /// Door `b` — the app's backup slot.
    pub fn backup(&self) -> &Arc<Door> {
        &self.doors[1]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpStream as StdStream;
    use std::time::Duration;

    /// A backend that echoes whatever it is sent, standing in for electrs. The doors are byte
    /// proxies, so proving transparency needs a peer that answers — not the real index. The
    /// real-electrs path is covered by `faucet_lib_and_control_socket`, which drives a door with
    /// an actual electrum client.
    fn echo_backend() -> SocketAddr {
        let listener = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let addr = listener.local_addr().unwrap();
        std::thread::spawn(move || {
            while let Ok((mut sock, _)) = listener.accept() {
                std::thread::spawn(move || {
                    let mut buf = [0u8; 1024];
                    while let Ok(n) = sock.read(&mut buf) {
                        if n == 0 || sock.write_all(&buf[..n]).is_err() {
                            return;
                        }
                    }
                });
            }
        });
        addr
    }

    /// `host:port` from a door url, for a raw client connect.
    fn authority(url: &str) -> String {
        url.split_once("://").unwrap().1.to_string()
    }

    fn connect(url: &str) -> std::io::Result<StdStream> {
        let stream = StdStream::connect(authority(url))?;
        stream.set_read_timeout(Some(Duration::from_millis(500)))?;
        Ok(stream)
    }

    /// Send `msg` through a plaintext door and read the echo back.
    fn round_trip(url: &str, msg: &[u8]) -> std::io::Result<Vec<u8>> {
        let mut stream = connect(url)?;
        stream.write_all(msg)?;
        let mut buf = vec![0u8; msg.len()];
        stream.read_exact(&mut buf)?;
        Ok(buf)
    }

    /// A TLS client that trusts anything and reports the leaf it was shown — the harness's own
    /// half of a handshake, deliberately NOT the app's verifier (the app's TOFU behaviour is
    /// what the e2e tests are for; this only proves the door presents what it says it does).
    fn presented_cert(url: &str) -> anyhow::Result<Vec<u8>> {
        use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified};
        use rustls::pki_types::{ServerName, UnixTime};
        use rustls::{DigitallySignedStruct, SignatureScheme};

        #[derive(Debug)]
        struct AcceptAny(Mutex<Option<Vec<u8>>>);

        impl rustls::client::danger::ServerCertVerifier for AcceptAny {
            fn verify_server_cert(
                &self,
                end_entity: &CertificateDer<'_>,
                _: &[CertificateDer<'_>],
                _: &ServerName<'_>,
                _: &[u8],
                _: UnixTime,
            ) -> Result<ServerCertVerified, rustls::Error> {
                *self.0.lock().unwrap() = Some(end_entity.to_vec());
                Ok(ServerCertVerified::assertion())
            }
            fn verify_tls12_signature(
                &self,
                _: &[u8],
                _: &CertificateDer<'_>,
                _: &DigitallySignedStruct,
            ) -> Result<HandshakeSignatureValid, rustls::Error> {
                Ok(HandshakeSignatureValid::assertion())
            }
            fn verify_tls13_signature(
                &self,
                _: &[u8],
                _: &CertificateDer<'_>,
                _: &DigitallySignedStruct,
            ) -> Result<HandshakeSignatureValid, rustls::Error> {
                Ok(HandshakeSignatureValid::assertion())
            }
            fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
                rustls::crypto::ring::default_provider()
                    .signature_verification_algorithms
                    .supported_schemes()
            }
        }

        let verifier = Arc::new(AcceptAny(Mutex::new(None)));
        let config = rustls::ClientConfig::builder()
            .dangerous()
            .with_custom_certificate_verifier(verifier.clone())
            .with_no_client_auth();
        let authority = authority(url);
        let (host, _) = authority.rsplit_once(':').unwrap();
        let server_name = ServerName::try_from(host.to_string())?;
        let mut conn = rustls::ClientConnection::new(Arc::new(config), server_name)?;
        let mut sock = connect(url)?;
        // Drive the handshake only; `complete_io` returns once neither side wants more.
        while conn.is_handshaking() {
            conn.complete_io(&mut sock)?;
        }
        let captured = verifier.0.lock().unwrap().take();
        captured.ok_or_else(|| anyhow!("handshake completed without presenting a certificate"))
    }

    fn sha256_hex(der: &[u8]) -> String {
        use sha2::{Digest, Sha256};
        hex::encode(Sha256::digest(der))
    }

    fn spec(name: &str, shape: Shape, issuer: Option<&str>) -> IdentitySpec {
        IdentitySpec {
            name: name.to_string(),
            shape,
            issuer: issuer.map(str::to_owned),
        }
    }

    /// Every mode does what it claims to a real client, and a mode change never moves the
    /// endpoint — the app has the url persisted by the time a test changes anything.
    #[test]
    fn each_mode_behaves_as_advertised_on_a_stable_port() {
        let servers = ElectrumServers::start(echo_backend()).expect("start front doors");
        let door = servers.primary();
        let port = authority(&door.url())
            .rsplit_once(':')
            .unwrap()
            .1
            .to_string();

        // tcp: a transparent proxy.
        assert_eq!(door.mode(), Mode::Tcp, "doors come up serving plaintext");
        assert_eq!(
            round_trip(&door.url(), b"ping").expect("tcp round trip"),
            b"ping",
            "a tcp door must pass bytes through untouched"
        );

        // down: the connection dies immediately. Not a refusal — the door holds its port for
        // life — but promptly, which is what distinguishes it from `hang` below. Read without
        // writing first: writing into a socket the peer has already closed races the RST, and
        // whether the client sees EOF or a reset is not the property under test.
        door.set_mode(Mode::Down, None).expect("down");
        let mut closed = connect(&door.url()).expect("a down door holds its port");
        let mut buf = [0u8; 1];
        // EOF specifically, not "EOF or reset". `Down` drops the socket with no shutdown, so it
        // is the one path where an unconditional SO_LINGER would show: a door that is merely
        // closed must not arrive looking like a session that was KILLED, or the app would fail
        // over from a server that simply is not up rather than retrying it.
        match closed.read(&mut buf) {
            Ok(0) => {}
            Ok(n) => panic!("a down door answered with {n} byte(s)"),
            Err(e) => panic!(
                "a down door must close gracefully, not reset — reset is reserved for a killed \
                 session: {e:?}"
            ),
        }

        // hang: accepts and says nothing, so the client spends its connect timeout.
        door.set_mode(Mode::Hang, None).expect("hang");
        let mut hung = connect(&door.url()).expect("a hung door still accepts");
        hung.write_all(b"ping").expect("write to a hung door");
        let mut buf = [0u8; 1];
        let timed_out = hung
            .read(&mut buf)
            .expect_err("a hung door must never answer");
        assert!(
            matches!(
                timed_out.kind(),
                std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
            ),
            "expected a read timeout, got {timed_out:?}"
        );

        // tls: a real handshake, presenting the identity the door reports.
        let url = door
            .set_mode(
                Mode::Tls("a1".into()),
                Some(spec("a1", Shape::Normal, None)),
            )
            .expect("tls");
        assert!(url.starts_with("ssl://"), "tls changes the scheme: {url}");
        let (name, fingerprint) = door.identity().expect("a tls door reports its identity");
        assert_eq!(name, "a1");
        assert_eq!(
            sha256_hex(&presented_cert(&url).expect("tls handshake")),
            fingerprint,
            "the door must present the certificate it reports"
        );

        // Back to plaintext, and the endpoint never moved through any of it.
        door.set_mode(Mode::Tcp, None).expect("back to tcp");
        assert_eq!(
            authority(&door.url()).rsplit_once(':').unwrap().1,
            port,
            "a mode change must not move the door's port"
        );
        assert_eq!(
            round_trip(&door.url(), b"again").expect("tcp round trip"),
            b"again"
        );
    }

    /// A name means the same bytes every time, because TOFU change-detection is a byte
    /// comparison — a re-minted `a1` would look like a certificate rotation on every reconnect.
    #[test]
    fn an_identity_name_is_stable_and_shapes_cannot_be_swapped_under_it() {
        let servers = ElectrumServers::start(echo_backend()).expect("start front doors");
        let door = servers.primary();

        let url = door
            .set_mode(
                Mode::Tls("a1".into()),
                Some(spec("a1", Shape::Normal, None)),
            )
            .expect("tls a1");
        let first = presented_cert(&url).expect("handshake");

        // Away and back: same name, same bytes.
        door.set_mode(Mode::Tcp, None).expect("tcp");
        let url = door
            .set_mode(
                Mode::Tls("a1".into()),
                Some(spec("a1", Shape::Normal, None)),
            )
            .expect("tls a1 again");
        assert_eq!(
            presented_cert(&url).expect("handshake"),
            first,
            "re-serving an identity must present the same certificate"
        );

        // A different name is a different certificate — the rotation case.
        let url = door
            .set_mode(
                Mode::Tls("a2".into()),
                Some(spec("a2", Shape::Normal, None)),
            )
            .expect("tls a2");
        assert_ne!(
            presented_cert(&url).expect("handshake"),
            first,
            "a different identity name must be a different certificate"
        );

        // Reusing a name for a different shape is refused: the test would be asserting about a
        // certificate it did not get.
        let clash = door.set_mode(
            Mode::Tls("a1".into()),
            Some(spec("a1", Shape::Expired, None)),
        );
        let clash = clash.expect_err("re-minting a name as another shape must fail");
        assert!(
            clash.to_string().contains("already exists"),
            "unhelpful error: {clash}"
        );
    }

    /// The forgery fixture: a leaf the door serves on one host, signed by an identity trusted
    /// for another. Nothing here asserts what the APP does with it — that is the e2e's job —
    /// only that the harness can produce it.
    #[test]
    fn an_identity_can_be_signed_by_another() {
        let servers = ElectrumServers::start(echo_backend()).expect("start front doors");
        let (a, b) = (servers.primary(), servers.backup());

        let a_url = a
            .set_mode(
                Mode::Tls("a1".into()),
                Some(spec("a1", Shape::Normal, None)),
            )
            .expect("tls a1");
        let issuer_der = presented_cert(&a_url).expect("handshake with a");

        let b_url = b
            .set_mode(
                Mode::Tls("b_evil".into()),
                Some(spec("b_evil", Shape::SignedBy, Some("a1"))),
            )
            .expect("tls b_evil");
        let forged_der = presented_cert(&b_url).expect("handshake with b");

        assert_ne!(forged_der, issuer_der, "the forgery is its own certificate");
        // Signed by a1's key: verifying the leaf against a1 as the sole trust anchor succeeds,
        // which is precisely the capability the root-store bug handed to any trusted cert.
        let anchor = webpki::anchor_from_trusted_cert(&CertificateDer::from(issuer_der.clone()))
            .expect("a1 as a trust anchor")
            .to_owned();
        let end_entity = CertificateDer::from(forged_der.clone());
        let cert = webpki::EndEntityCert::try_from(&end_entity).expect("parse the forgery");
        cert.verify_for_usage(
            webpki::ALL_VERIFICATION_ALGS,
            &[anchor],
            &[],
            rustls::pki_types::UnixTime::since_unix_epoch(std::time::Duration::from_secs(
                1_767_225_600,
            )),
            webpki::KeyUsage::server_auth(),
            None,
            None,
        )
        .expect("the forgery must chain to its issuer");

        // A name that has never been served cannot be an issuer.
        let missing = b.set_mode(
            Mode::Tls("b_evil2".into()),
            Some(spec("b_evil2", Shape::SignedBy, Some("never_served"))),
        );
        assert!(missing
            .expect_err("unknown issuer must fail")
            .to_string()
            .contains("never_served"),);
    }

    /// A session that dies after the connection was established — the failure where a server
    /// passes the connectivity probe and then cannot serve. The door stays up, so the next
    /// connect succeeds and a client that simply retries the same server never learns anything.
    #[test]
    fn dropping_connections_kills_live_sessions_and_leaves_the_door_open() {
        let servers = ElectrumServers::start(echo_backend()).expect("start front doors");
        let door = servers.primary();

        let mut held: Vec<StdStream> = (0..3)
            .map(|_| {
                let mut s = connect(&door.url()).expect("connect");
                // Round-trip each one so the proxy task is definitely established before we
                // count; accept alone does not mean the door has spawned its task yet.
                s.write_all(b"x").unwrap();
                let mut buf = [0u8; 1];
                s.read_exact(&mut buf).unwrap();
                s
            })
            .collect();
        assert_eq!(door.connection_count(), 3, "three live sessions");

        assert_eq!(door.drop_connections(), 3, "all three are dropped");
        assert_eq!(door.connection_count(), 0);
        for stream in &mut held {
            stream.write_all(b"y").ok();
            let mut buf = [0u8; 1];
            assert!(
                stream.read(&mut buf).map(|n| n == 0).unwrap_or(true),
                "a dropped session must not still answer"
            );
        }

        assert_eq!(
            round_trip(&door.url(), b"after").expect("the door is still open"),
            b"after",
            "dropping sessions must not take the door down"
        );
    }

    /// Admission is one critical section, and the type says so: `admit` takes `&mut DoorState`,
    /// so a caller must already hold the lock and cannot read the state, release it, spawn, and
    /// re-acquire to register. That split is the bug this replaced — `set_mode` and
    /// `drop_connections` drain only what is registered, so a task admitted under the old state
    /// but registered after the drain would outlive a transition that promised to remove it.
    ///
    /// Deliberately not a racing test. One was written first — eight threads hammering connects
    /// against 2000 transitions — and measured against a deliberately re-split `accept_loop`: it
    /// caught the bug 0 times out of 5. The unguarded window is a few instructions wide with no
    /// await in it, so a probabilistic test is a green light that means nothing. What is left is
    /// the decision itself, which is deterministic.
    #[test]
    fn admission_and_registration_are_one_critical_section() {
        let servers = ElectrumServers::start(echo_backend()).expect("start front doors");
        let door = servers.primary();
        let url = door.url();

        // A transition drains what admission registered, with no window in between: the count is
        // zero the instant `set_mode` returns, and the sockets are dead.
        door.set_mode(Mode::Tcp, None).expect("tcp");
        let mut live: Vec<StdStream> = (0..4)
            .map(|_| {
                let mut s = connect(&url).expect("connect");
                s.write_all(b"x").unwrap();
                let mut buf = [0u8; 1];
                s.read_exact(&mut buf).unwrap();
                s
            })
            .collect();
        assert_eq!(door.connection_count(), 4);
        door.set_mode(Mode::Down, None).expect("down");
        assert_eq!(
            door.connection_count(),
            0,
            "set_mode must leave nothing registered"
        );
        for stream in &mut live {
            let mut buf = [0u8; 1];
            stream.write_all(b"y").ok();
            assert!(
                stream.read(&mut buf).map(|n| n == 0).unwrap_or(true),
                "a connection admitted before the transition must not still answer"
            );
        }
    }

    /// Availability and transport are independent: a TLS door taken down keeps its url, its
    /// identity, and comes back as the same TLS door. The app has that url persisted in its
    /// settings by then, so a door that reported `tcp://` while down would be describing a
    /// server the app is not configured to reach.
    #[test]
    fn taking_a_tls_door_down_does_not_change_what_it_is() {
        let servers = ElectrumServers::start(echo_backend()).expect("start front doors");
        let door = servers.primary();

        let serving = door
            .set_mode(
                Mode::Tls("a1".into()),
                Some(spec("a1", Shape::Normal, None)),
            )
            .expect("tls");
        let cert = presented_cert(&serving).expect("handshake");

        for unavailable in [Mode::Down, Mode::Hang] {
            let reported = door
                .set_mode(unavailable.clone(), None)
                .expect("change availability");
            assert_eq!(
                reported, serving,
                "{unavailable:?} must keep the url the app has persisted"
            );
            assert_eq!(door.url(), serving, "{unavailable:?} url drifted");
            assert_eq!(
                door.mode(),
                unavailable,
                "the door reports its availability first"
            );
            assert_eq!(
                door.identity().map(|(name, _)| name),
                Some("a1".to_string()),
                "{unavailable:?} must keep the certificate it will present when it returns"
            );
        }

        // Back to serving, still the same TLS door with the same certificate.
        let resumed = door
            .set_mode(
                Mode::Tls("a1".into()),
                Some(spec("a1", Shape::Normal, None)),
            )
            .expect("resume");
        assert_eq!(resumed, serving);
        assert_eq!(
            presented_cert(&resumed).expect("handshake"),
            cert,
            "resuming must present the same certificate"
        );
    }

    /// An identity name is bound to the door it was minted for, because its SAN is. Serving it
    /// on the other door would present a certificate for the wrong server while still reporting
    /// a normal identity.
    #[test]
    fn an_identity_cannot_be_served_on_the_door_it_was_not_minted_for() {
        let servers = ElectrumServers::start(echo_backend()).expect("start front doors");
        let (a, b) = (servers.primary(), servers.backup());

        a.set_mode(
            Mode::Tls("a1".into()),
            Some(spec("a1", Shape::Normal, None)),
        )
        .expect("tls on a");

        let before = (b.mode(), b.url(), b.identity());
        let rejected = b
            .set_mode(
                Mode::Tls("a1".into()),
                Some(spec("a1", Shape::Normal, None)),
            )
            .expect_err("a1 belongs to door a");
        assert!(
            rejected.to_string().contains("minted for"),
            "unhelpful error: {rejected}"
        );
        assert_eq!(
            (b.mode(), b.url(), b.identity()),
            before,
            "a rejected identity must leave the target door untouched"
        );

        // Its own name on door b is fine, and gets door b's host in its SAN.
        b.set_mode(
            Mode::Tls("b1".into()),
            Some(spec("b1", Shape::Normal, None)),
        )
        .expect("b1 on b");
    }

    /// A backend that answers once and then hangs up by itself — an ordinary end of session.
    fn closing_backend() -> SocketAddr {
        let listener = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let addr = listener.local_addr().unwrap();
        std::thread::spawn(move || {
            while let Ok((mut sock, _)) = listener.accept() {
                let mut buf = [0u8; 1];
                if sock.read_exact(&mut buf).is_ok() {
                    let _ = sock.write_all(&buf);
                }
                drop(sock);
            }
        });
        addr
    }

    /// A door must not turn every close into a reset. Which one the client sees decides what the
    /// app CONCLUDES: a FIN is an orderly end, which the app treats as "stopped gracefully" and
    /// answers by reconnecting to the same server; a reset is a session that died, which is what
    /// rotates it away. Making every socket linger-0 up front collapses the two, so a backend
    /// that simply finished would be misread as the failure `drop_connections` synthesizes.
    #[test]
    fn an_ordinary_close_is_graceful_and_only_a_kill_resets() {
        // Backend hangs up on its own: the client must see EOF, not a reset.
        let graceful = ElectrumServers::start(closing_backend()).expect("start");
        let door = graceful.primary();
        let mut stream = connect(&door.url()).expect("connect");
        stream.write_all(b"x").unwrap();
        let mut echo = [0u8; 1];
        stream.read_exact(&mut echo).expect("backend answers once");
        let mut buf = [0u8; 1];
        assert_eq!(
            stream.read(&mut buf).ok(),
            Some(0),
            "a backend closing by itself must reach the client as EOF, not a reset — \
             the app reads the difference as graceful-stop vs session-failed"
        );

        // Deliberate kill of a healthy session: the client must see a RESET.
        let killed = ElectrumServers::start(echo_backend()).expect("start");
        let door = killed.primary();
        let mut stream = connect(&door.url()).expect("connect");
        stream.write_all(b"y").unwrap();
        stream.read_exact(&mut echo).unwrap();
        assert_eq!(door.drop_connections(), 1);
        // READ without writing first. Writing to a peer that has already sent FIN provokes a
        // reset of its own, which makes the two cases indistinguishable — the discriminator has
        // to be what arrives unprompted.
        match stream.read(&mut buf) {
            Err(e) if e.kind() == std::io::ErrorKind::ConnectionReset => {}
            Ok(0) => panic!(
                "drop_connections closed politely (EOF): the app reads that as a graceful stop \
                 and reconnects to the SAME server instead of failing over"
            ),
            other => panic!("expected a reset from a killed session, got {other:?}"),
        }
    }

    /// The two doors are separate endpoints on separate hosts — the property the whole TOFU
    /// half of this rests on, since the trust store is keyed by host alone.
    #[test]
    fn the_two_doors_are_independent_and_differently_named() {
        let servers = ElectrumServers::start(echo_backend()).expect("start front doors");
        let (a, b) = (servers.primary(), servers.backup());

        assert!(a.url().contains("127.0.0.1"), "door a: {}", a.url());
        assert!(b.url().contains("localhost"), "door b: {}", b.url());
        assert_ne!(
            authority(&a.url()).rsplit_once(':').unwrap().1,
            authority(&b.url()).rsplit_once(':').unwrap().1,
            "the doors must not share a port"
        );

        // Taking one down leaves the other serving.
        a.set_mode(Mode::Down, None).expect("a down");
        assert!(round_trip(&a.url(), b"anyone there").is_err(), "a is down");
        assert_eq!(
            round_trip(&b.url(), b"still here").expect("b is unaffected"),
            b"still here"
        );
    }
}
