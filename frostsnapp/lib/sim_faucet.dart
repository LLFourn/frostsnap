import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

/// Client for the `sim_regtest` faucet control socket (JSON request/reply lines). The faucet
/// backend lives ABOVE the app in its own process (shared across sessions); both the in-app sim
/// tray and the `./simctl` harness drive it through this ONE client, so the wire protocol has a
/// single implementation that can't drift. The server handles one connection at a time, so each
/// caller opens a short-lived connection (connect → request(s) → close) rather than holding the
/// socket and starving other clients.
class SimFaucet {
  final Socket _socket;
  final Queue<Completer<Map<String, dynamic>>> _pending = Queue();
  late final StreamSubscription<String> _sub;

  SimFaucet._(this._socket) {
    _sub = _socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line.trim().isEmpty) return;
          final reply = jsonDecode(line) as Map<String, dynamic>;
          if (_pending.isNotEmpty) _pending.removeFirst().complete(reply);
        });
  }

  static Future<SimFaucet> connect(String socketPath) async {
    final socket = await Socket.connect(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    return SimFaucet._(socket);
  }

  Future<Map<String, dynamic>> _send(Map<String, dynamic> req) {
    final completer = Completer<Map<String, dynamic>>();
    _pending.add(completer);
    _socket.write('${jsonEncode(req)}\n');
    return completer.future;
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
  Future<void> down() => _ok({'cmd': 'down'});

  Future<void> close() async {
    await _sub.cancel();
    _socket.destroy();
  }
}
