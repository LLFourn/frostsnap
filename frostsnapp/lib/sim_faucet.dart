import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

/// Client for the `sim_regtest` faucet control socket (JSON request/reply lines). The faucet
/// backend lives ABOVE the app in its own process (shared across sessions); both the in-app sim
/// tray and the `./fsim` harness drive it through this ONE client, so the wire protocol has a
/// single implementation that can't drift. The server handles one connection at a time, so each
/// caller opens a short-lived connection (connect → request(s) → close) rather than holding the
/// socket and starving other clients.
class SimFaucet {
  /// How long a single command may go unanswered before the connection is declared unusable.
  /// Every faucet op is either local bookkeeping or a bounded chain query; none legitimately
  /// takes this long.
  static const _replyTimeout = Duration(seconds: 30);

  final Socket _socket;
  final Queue<Completer<Map<String, dynamic>>> _pending = Queue();
  late final StreamSubscription<String> _sub;

  /// Why this connection is unusable, once it is. Set on close, error, or an unanswered
  /// command; every later call fails with it immediately rather than waiting on a socket that
  /// is never going to answer.
  Object? _dead;

  SimFaucet._(this._socket) {
    _sub = _socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (line.trim().isEmpty) return;
            final reply = jsonDecode(line) as Map<String, dynamic>;
            if (_pending.isNotEmpty) _pending.removeFirst().complete(reply);
          },
          // Without these, a backend that goes away leaves every queued command waiting
          // forever: the completer is only ever completed by an incoming line, and no line is
          // ever coming. A dropped control socket must surface as a failure, not a hang.
          onError: (Object e) => _die('faucet control socket errored: $e'),
          onDone: () => _die('faucet control socket closed by the backend'),
          cancelOnError: false,
        );
  }

  /// Fail every waiting command and refuse all later ones.
  void _die(String why) {
    _dead ??= StateError(why);
    while (_pending.isNotEmpty) {
      _pending.removeFirst().completeError(_dead!);
    }
  }

  /// Connect to the faucet control endpoint: a unix socket PATH (the host), or a `host:port` TCP
  /// endpoint (the sim bridges the host control socket over TCP so an Android emulator can reach it).
  static Future<SimFaucet> connect(String endpoint) async {
    final colon = endpoint.lastIndexOf(':');
    final port = colon > 0 ? int.tryParse(endpoint.substring(colon + 1)) : null;
    final socket = port != null
        ? await Socket.connect(endpoint.substring(0, colon), port)
        : await Socket.connect(
            InternetAddress(endpoint, type: InternetAddressType.unix),
            0,
          );
    return SimFaucet._(socket);
  }

  Future<Map<String, dynamic>> _send(Map<String, dynamic> req) {
    final dead = _dead;
    if (dead != null) return Future.error(dead);
    final completer = Completer<Map<String, dynamic>>();
    _pending.add(completer);
    _socket.write('${jsonEncode(req)}\n');
    // A command that times out also kills the connection: replies are matched to requests by
    // ARRIVAL ORDER, so once one is outstanding-but-abandoned every later reply would be paired
    // with the wrong command. Better to fail loudly than to answer the wrong question.
    return completer.future.timeout(
      _replyTimeout,
      onTimeout: () {
        _die(
          'faucet `${req['cmd']}` went unanswered for ${_replyTimeout.inSeconds}s',
        );
        throw _dead!;
      },
    );
  }

  Future<Map<String, dynamic>> _ok(Map<String, dynamic> req) async {
    final reply = await _send(req);
    if (reply['ok'] != true) {
      throw StateError('faucet ${req['cmd']} failed: ${reply['error']}');
    }
    return reply;
  }

  /// The serving backend's PID (its owner token), or null if no live backend replied within
  /// [timeout]. Bounded because a backend mid-startup may have the socket bound (connect
  /// succeeds via the kernel backlog) but not be serving yet.
  Future<int?> pingPid({Duration timeout = const Duration(seconds: 3)}) async {
    try {
      final reply = await _send({'cmd': 'ping'}).timeout(timeout);
      return reply['ok'] == true ? reply['pid'] as int? : null;
    } catch (_) {
      return null;
    }
  }

  Future<int> balanceSat() async =>
      (await _ok({'cmd': 'balance'}))['sat'] as int;

  /// electrs's CONFIRMED balance for a single [address], in sats. Coinbase-immune (scoped to
  /// one script), unlike [balanceSat] — use it to cross-check that a send actually landed at a
  /// freshly-vended node address.
  Future<int> addressBalanceSat(String address) async =>
      (await _ok({'cmd': 'address_balance', 'address': address}))['sat'] as int;
  Future<int> blockHeight() async =>
      (await _ok({'cmd': 'height'}))['height'] as int;
  Future<String> faucetAddress() async =>
      (await _ok({'cmd': 'faucet_address'}))['address'] as String;
  Future<String> electrumUrl() async =>
      (await _ok({'cmd': 'electrum_url'}))['url'] as String;
  Future<String> fund(String address, int sats) async =>
      (await _ok({'cmd': 'fund', 'address': address, 'sats': sats}))['txid']
          as String;
  Future<void> mine(int blocks) => _ok({'cmd': 'mine', 'blocks': blocks});

  /// Track an app wallet's output [descriptor] in a node-side watch-only wallet, so the node can
  /// see its coins and build spends of them — the Core/Sparrow side of "another wallet builds the
  /// PSBT, Frostsnap signs it". Rescans, so it is correct before or after the wallet is funded.
  Future<void> watchDescriptor(String descriptor) =>
      _ok({'cmd': 'watch_descriptor', 'descriptor': descriptor});

  /// Forward a raw bitcoind JSON-RPC call and return its decoded result — the escape
  /// hatch for one-off chain/descriptor questions (`deriveaddresses`,
  /// `getdescriptorinfo`, `decodepsbt`, …). A test-local need composes here in the
  /// test file instead of growing a dedicated control verb plus wrapper.
  Future<Object?> rpc(String method, [List<Object?> params = const []]) async =>
      (await _ok({'cmd': 'rpc', 'method': method, 'params': params}))['result'];

  /// A base64 PSBT paying [sats] to [address], funded from the coins of the wallet last passed to
  /// [watchDescriptor]. Unsigned, and built entirely by bitcoind — nothing in it comes from the
  /// app's own transaction builder.
  Future<String> createPsbt(String address, int sats) async =>
      (await _ok({
            'cmd': 'create_psbt',
            'address': address,
            'sats': sats,
          }))['psbt']
          as String;

  /// The controllable electrum front doors — what the app sees as its two servers. Each entry
  /// carries `id` (`a`/`b`), `url`, `mode`, `identity`, `fingerprint`, `connections` (live) and
  /// `accepted` (cumulative). Use `accepted` to ask whether the app RECONNECTED: the live count
  /// cannot tell a kept connection from a torn-down-and-remade one.
  Future<List<Map<String, dynamic>>> electrumServers() async =>
      ((await _ok({'cmd': 'electrum_list'}))['servers'] as List)
          .cast<Map<String, dynamic>>();

  /// Put front door [id] in [mode] — `tcp`, `tls`, `down` or `hang` — and return the url to reach
  /// it on. The url comes back because `tls` changes the scheme; the port never moves.
  ///
  /// `tls` needs an [identity] NAME. [shape] says how to mint that name the first time it is used
  /// (`normal`, `expired`, `wrong_host`, `signed_by`) and is refused if the name already exists as
  /// something else; `signed_by` also needs [issuer], the name of an identity already served.
  Future<String> electrumSetMode(
    String id,
    String mode, {
    String? identity,
    String? shape,
    String? issuer,
  }) async =>
      (await _ok({
            'cmd': 'electrum_set_mode',
            'id': id,
            'mode': mode,
            if (identity != null) 'identity': identity,
            if (shape != null) 'shape': shape,
            if (issuer != null) 'issuer': issuer,
          }))['url']
          as String;

  /// Kill every live connection to front door [id], leaving the door itself open — a server that
  /// passed the app's connectivity probe and then died mid-session. Returns how many were killed.
  Future<int> electrumDropConnections(String id) async =>
      (await _ok({'cmd': 'electrum_drop_connections', 'id': id}))['dropped']
          as int;

  Future<void> down() => _ok({'cmd': 'down'});

  Future<void> close() async {
    _die('faucet connection closed by this client');
    await _sub.cancel();
    _socket.destroy();
  }
}
