import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:frostsnap/sim_faucet.dart';

import 'sim_harness.dart' show simTmpRoot;

// The Dart side of the regtest faucet (regtest-bitcoin-receiving): manage the standalone
// `sim_regtest` backend (`./simctl regtest up|down|status`) and drive its faucet over the
// control socket (`fund`/`mine`/`balance`/`address`/`url`). The backend lives ABOVE the app
// (its own process, shared across sessions), so it's addressed by a well-known socket — not
// owned by any app instance. The wire client is the shared [SimFaucet] (also used by the in-app
// tray), so the protocol has one implementation.

/// Well-known paths for the shared regtest backend (one per sim-temp-root).
Directory _regtestDir() {
  final dir = Directory('${simTmpRoot().path}/regtest');
  dir.createSync(recursive: true);
  return dir;
}

String get regtestControlSocket => '${_regtestDir().path}/control.sock';
String get regtestUrlFile => '${_regtestDir().path}/electrum_url';
String get _regtestLogFile => '${_regtestDir().path}/backend.log';

/// The PID the backend at [controlSocket] reports from `ping`, or null if none is (yet) live. Only
/// the process that won `bind_control_socket` serves, so its PID identifies the live backend at that
/// socket — the AUTHORITY for ownership (a spawner compares it against the child it started).
Future<int?> _ownerPidAt(String controlSocket) async {
  SimFaucet? faucet;
  try {
    faucet = await SimFaucet.connect(controlSocket);
    return await faucet.pingPid();
  } catch (_) {
    return null;
  } finally {
    await faucet?.close();
  }
}

/// The shared backend's owner PID (see [_ownerPidAt]).
Future<int?> regtestOwnerPid() => _ownerPidAt(regtestControlSocket);

/// Whether a faucet backend is live at the well-known control socket (connect + ping).
Future<bool> regtestLive() async => (await regtestOwnerPid()) != null;

/// `./simctl regtest <up|down|status|fund|mine|balance|address|url>`.
Future<void> runRegtest(List<String> args) async {
  final sub = args.isEmpty ? 'status' : args.first;
  final rest = args.skip(1).toList();
  switch (sub) {
    case 'up':
      await _up();
    case 'down':
      await _down();
    case 'status':
      await _status();
    case 'fund':
      await _withFaucet((faucet) async {
        if (rest.length < 2) {
          stderr.writeln('usage: regtest fund <address> <sats>');
          exit(2);
        }
        final txid = await faucet.fund(rest[0], int.parse(rest[1]));
        stdout.writeln(jsonEncode({'ok': true, 'txid': txid}));
      });
    case 'mine':
      await _withFaucet((faucet) async {
        await faucet.mine(rest.isEmpty ? 1 : int.parse(rest.first));
        stdout.writeln(jsonEncode({'ok': true}));
      });
    case 'balance':
      await _withFaucet(
        (faucet) async => stdout.writeln(
          jsonEncode({'ok': true, 'sat': await faucet.balanceSat()}),
        ),
      );
    case 'height':
      await _withFaucet(
        (faucet) async => stdout.writeln(
          jsonEncode({'ok': true, 'height': await faucet.blockHeight()}),
        ),
      );
    case 'address':
      await _withFaucet(
        (faucet) async => stdout.writeln(
          jsonEncode({'ok': true, 'address': await faucet.faucetAddress()}),
        ),
      );
    case 'url':
      await _withFaucet(
        (faucet) async => stdout.writeln(
          jsonEncode({'ok': true, 'url': await faucet.electrumUrl()}),
        ),
      );
    default:
      stderr.writeln(
        'regtest: unknown subcommand "$sub" '
        '(up|down|status|fund|mine|balance|height|address|url)',
      );
      exit(2);
  }
}

Future<void> _withFaucet(Future<void> Function(SimFaucet) body) async {
  if (!await regtestLive()) {
    stderr.writeln('regtest: no backend running (run `./simctl regtest up`)');
    exit(1);
  }
  final faucet = await SimFaucet.connect(regtestControlSocket);
  try {
    await body(faucet);
  } finally {
    await faucet.close();
  }
}

/// The repo root (the `./simctl` launcher cd's into `frostsnapp`, so the cwd's parent is root).
String _repoRoot() => Directory.current.parent.path;

/// Build the `sim_regtest` binary (idempotent; the first run downloads the pinned bitcoind +
/// electrs). Concurrent invocations coordinate via cargo's target lock, so it's safe to call from
/// parallel session spawns. Throws on build failure.
Future<void> _buildRegtest(String root) async {
  stderr.writeln(
    'regtest: building sim_regtest (first run downloads bitcoind + electrs)…',
  );
  final build = await Process.run('cargo', [
    'build',
    '-q',
    '-p',
    'sim_regtest',
  ], workingDirectory: root);
  if (build.exitCode != 0) {
    throw StateError('regtest build failed:\n${build.stderr}');
  }
}

/// Spawn a `sim_regtest` backend DETACHED at the given socket/url/log paths. Each backend picks its
/// OWN dynamic bitcoind/electrs ports + a private datadir (electrsd/bitcoind), so independent paths
/// give independent chains. Returns the child Process; `child.pid` is the sim_regtest PID itself
/// (the shell `exec`s into it) AND its process-group leader (detached ⇒ setsid), so it's the handle
/// for reaping the backend + its children together.
Future<Process> _spawnRegtest(
  String root,
  String controlSocket,
  String urlFile,
  String logFile,
) {
  // We deliberately do NOT unlink the control/url paths here: a second concurrent spawn at the SAME
  // socket could delete one the other backend just bound. The Rust bind_control_socket owns
  // stale-socket cleanup and refuses a LIVE one — that singleton guard is the sole authority.
  return Process.start(
    'sh',
    [
      '-c',
      'exec "\$1" --control-socket "\$2" --url-file "\$3" > "\$4" 2>&1',
      'sim_regtest',
      '$root/target/debug/sim_regtest',
      controlSocket,
      urlFile,
      logFile,
    ],
    workingDirectory: root,
    mode: ProcessStartMode.detached,
  );
}

int get _regtestWaitSecs =>
    int.tryParse(Platform.environment['SIMCTL_REGTEST_WAIT_SECS'] ?? '') ?? 600;

/// Wait until a backend is serving at [controlSocket] (reports a PID) AND its [urlFile] is written;
/// return that live PID. Throws on timeout.
Future<int> _waitRegtestReady(
  String controlSocket,
  String urlFile,
  String logFile,
) async {
  final deadline = DateTime.now().add(Duration(seconds: _regtestWaitSecs));
  while (DateTime.now().isBefore(deadline)) {
    final ownerPid = await _ownerPidAt(controlSocket);
    if (ownerPid != null && await File(urlFile).exists()) return ownerPid;
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  throw StateError(
    'regtest backend did not come up within ${_regtestWaitSecs}s; see $logFile',
  );
}

/// Ensure a regtest backend is up and return its electrum URL plus whether THIS call started it
/// (`owned: true`) or attached to a live one (`owned: false`). The node is a PERSISTENT shared
/// resource: callers (`SimHarness.launch`, `./simctl regtest up`) only start-or-attach and NEVER
/// stop it — it's reaped only by `./simctl regtest down` / `./simctl clean`. `owned` exists just so
/// `./simctl regtest up` can report started-vs-attached. Throws on build/startup failure.
Future<({String url, bool owned})> ensureRegtestBackend() async {
  if (await regtestLive()) {
    return (
      url: (await File(regtestUrlFile).readAsString()).trim(),
      owned: false,
    );
  }
  final root = _repoRoot();
  await _buildRegtest(root);
  // Ownership is NOT "we took the spawn branch": under a concurrent auto-start two callers can both
  // spawn, but the Rust bind_control_socket singleton lets exactly ONE serve and every loser's child
  // exits. We own the live node only if its reported PID is the child WE spawned; a non-matching PID
  // means a racer won, so we attach (owned:false) and never stop the shared node another session uses.
  final child = await _spawnRegtest(
    root,
    regtestControlSocket,
    regtestUrlFile,
    _regtestLogFile,
  );
  final ownerPid = await _waitRegtestReady(
    regtestControlSocket,
    regtestUrlFile,
    _regtestLogFile,
  );
  return (
    url: (await File(regtestUrlFile).readAsString()).trim(),
    owned: ownerPid == child.pid,
  );
}

/// An ISOLATED regtest backend owned by ONE test session: its own bitcoind+electrs (dynamic ports +
/// private datadir) addressed by a per-session control socket, so parallel tests never share a chain
/// (a foreign `mine` can't confirm another test's pending receive). Unlike the shared persistent
/// node, the owner MUST [stop] it — there is no `regtest down`/`clean` for it.
class RegtestSession {
  /// The electrum URL (`tcp://127.0.0.1:<dynamic-port>`) for this session's chain.
  final String url;

  /// This session's faucet control socket ([faucet] connects here; the runner bridges it to the
  /// session's emulator).
  final String controlSocket;

  /// The sim_regtest PID == its process-group leader — the reap handle for [stop].
  final int pid;

  /// This session's private dir (control socket, url file, backend log) — removed on [stop].
  final Directory dir;

  RegtestSession._({
    required this.url,
    required this.controlSocket,
    required this.pid,
    required this.dir,
  });

  Future<SimFaucet> faucet() => SimFaucet.connect(controlSocket);

  /// Stop this session's backend, reap its bitcoind/electrs by process group, and remove its dir
  /// (idempotent). Mirrors [stopRegtestBackend] but targets THIS session's socket + the PID we
  /// spawned — no shared-node discovery, so it can never stop another session's node. Reached only
  /// after a successful start, so the dir's backend log survives a STARTUP failure (kept for
  /// diagnosis there) but leaves no residue on the normal path.
  Future<void> stop() async {
    try {
      final f = await SimFaucet.connect(controlSocket);
      try {
        await f.down();
      } catch (_) {
      } finally {
        await f.close();
      }
    } catch (_) {}
    if (!await _processExits(pid, const Duration(seconds: 10))) {
      await _killProcessGroup(pid);
    }
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }
}

/// Reap a possibly-running isolated regtest session rooted at [dir].
///
/// Used by the outer test runner's timeout path, where the timed-out test process
/// may never reach [RegtestSession.stop]. We no longer have the in-process
/// [RegtestSession] value, so recover the backend PID from its control socket (or,
/// during startup, the process command line), then reap the whole backend process
/// group so bitcoind/electrs children do not leak.
Future<void> reapRegtestSessionDir(Directory dir) async {
  final controlSocket = '${dir.path}/control.sock';
  final pid =
      await _ownerPidAt(controlSocket) ??
      await _pidForControlSocket(controlSocket);
  if (pid != null) {
    try {
      final f = await SimFaucet.connect(controlSocket);
      try {
        await f.down();
      } catch (_) {
      } finally {
        await f.close();
      }
    } catch (_) {}
    if (!await _processExits(pid, const Duration(seconds: 10))) {
      await _killProcessGroup(pid);
    }
  }
  try {
    if (await dir.exists()) await dir.delete(recursive: true);
  } catch (_) {}
}

Future<int?> _pidForControlSocket(String controlSocket) async {
  final ps = await Process.run('ps', ['-ax', '-o', 'pid=,command=']);
  if (ps.exitCode != 0) return null;
  for (final line in (ps.stdout as String).split('\n')) {
    final trimmed = line.trimLeft();
    if (trimmed.isEmpty) continue;
    final sep = trimmed.indexOf(RegExp(r'\s+'));
    if (sep < 0) continue;
    final pid = int.tryParse(trimmed.substring(0, sep));
    final command = trimmed.substring(sep).trimLeft();
    if (pid != null &&
        command.contains('sim_regtest') &&
        command.contains('--control-socket') &&
        command.contains(controlSocket)) {
      return pid;
    }
  }
  return null;
}

/// Start a fresh, isolated [RegtestSession] under [dir] (created if absent). Always spawns its own
/// backend (no attach) — the caller owns it and MUST `stop()` it. Throws on build/startup failure.
Future<RegtestSession> startRegtestSession(Directory dir) async {
  dir.createSync(recursive: true);
  final controlSocket = '${dir.path}/control.sock';
  // Unix-domain socket paths are capped (~104 bytes on macOS). An over-long path makes the backend's
  // bind fail in a way it misreads as a "stale socket" (then crashes on a remove that ENOENTs), so
  // fail CLEARLY here with the actual cause — keep per-session dirs short.
  if (controlSocket.length > 100) {
    throw StateError(
      'regtest control socket path too long (${controlSocket.length} > 100): '
      '$controlSocket — use a shorter session dir',
    );
  }
  final urlFile = '${dir.path}/electrum_url';
  final logFile = '${dir.path}/backend.log';
  final root = _repoRoot();
  await _buildRegtest(root);
  final child = await _spawnRegtest(root, controlSocket, urlFile, logFile);
  try {
    final pid = await _waitRegtestReady(controlSocket, urlFile, logFile);
    return RegtestSession._(
      url: (await File(urlFile).readAsString()).trim(),
      controlSocket: controlSocket,
      pid: pid,
      dir: dir,
    );
  } catch (_) {
    // The backend process group may be alive but never became ready — with no RegtestSession to
    // return, the caller can't stop it, so reap it here (child.pid == pgid, detached) before rethrow.
    await _killProcessGroup(child.pid);
    rethrow;
  }
}

/// Stop a running backend (sends `down`, which makes it drop bitcoind/electrs) and ensure it is
/// actually reaped. No-op if not running.
Future<void> stopRegtestBackend() async {
  // Capture the owner PID BEFORE stopping: after `down` the socket closes and the backend is no
  // longer addressable, so this is our only handle for the force-kill backstop below.
  final pid = await regtestOwnerPid();
  if (pid == null) return;

  final faucet = await SimFaucet.connect(regtestControlSocket);
  try {
    await faucet.down();
  } catch (_) {
    // The backend may close the socket as it shuts down; that's still a successful stop.
  } finally {
    await faucet.close();
  }

  // Backstop against a hung/slow Drop: the backend normally reaps bitcoind+electrs as it exits,
  // but if it doesn't (observed: it removed its socket then lingered, orphaning the children and
  // leaving itself unreachable to a second `down`), wait for it to die, then SIGKILL its process
  // group. It is spawned via setsid (ProcessStartMode.detached), so pid == pgid and a
  // negative-pid kill reaps the bitcoind/electrs children with it.
  if (!await _processExits(pid, const Duration(seconds: 10))) {
    await _killProcessGroup(pid);
  }
}

/// Poll until process [pid] is gone or [timeout] elapses; returns whether it exited.
Future<bool> _processExits(int pid, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  while (await _processAlive(pid)) {
    if (DateTime.now().isAfter(deadline)) return false;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  return true;
}

/// Whether [pid] exists, via `kill -0` (probe, no signal).
Future<bool> _processAlive(int pid) async =>
    (await Process.run('kill', ['-0', '$pid'])).exitCode == 0;

/// SIGTERM then SIGKILL the process GROUP led by [pid] (negative pid), reaping the backend and
/// its bitcoind/electrs children together.
Future<void> _killProcessGroup(int pid) async {
  await Process.run('kill', ['-TERM', '-$pid']);
  await Future<void>.delayed(const Duration(milliseconds: 500));
  await Process.run('kill', ['-KILL', '-$pid']);
}

Future<void> _up() async {
  try {
    final backend = await ensureRegtestBackend();
    stdout.writeln(
      jsonEncode({
        'ok': true,
        'url': backend.url,
        if (!backend.owned) 'already': true,
      }),
    );
  } catch (e) {
    stderr.writeln('regtest: $e');
    exit(1);
  }
}

Future<void> _down() async {
  final wasLive = await regtestLive();
  await stopRegtestBackend();
  stdout.writeln(
    jsonEncode({'ok': true, 'down': true, if (!wasLive) 'note': 'not running'}),
  );
}

Future<void> _status() async {
  if (await regtestLive()) {
    final url = (await File(regtestUrlFile).readAsString()).trim();
    stdout.writeln(jsonEncode({'ok': true, 'running': true, 'url': url}));
  } else {
    stdout.writeln(jsonEncode({'ok': true, 'running': false}));
  }
}

// ---- emulator bridge: make a host-side regtest reachable from an Android emulator ----

/// The TCP port from an electrum URL (`tcp://host:port`, `ssl://host:port`, or `host:port`).
int electrumPort(String url) {
  final u = Uri.parse(url.contains('://') ? url : 'tcp://$url');
  if (u.port == 0) throw StateError('cannot parse electrum port from "$url"');
  return u.port;
}

/// Proxy a host unix socket over a loopback TCP port so an adb-reversed emulator can reach it. Each
/// TCP connection opens a fresh unix connection and pipes both ways (the faucet protocol is short
/// connect→request→close exchanges). Returns the listening server — close it to stop the bridge.
Future<ServerSocket> bridgeUnixOverTcp(String unixPath) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((client) async {
    final Socket upstream;
    try {
      upstream = await Socket.connect(
        InternetAddress(unixPath, type: InternetAddressType.unix),
        0,
      );
    } catch (_) {
      client.destroy();
      return;
    }
    unawaited(client.cast<List<int>>().pipe(upstream).catchError((_) {}));
    unawaited(upstream.cast<List<int>>().pipe(client).catchError((_) {}));
  });
  return server;
}

/// The Android SDK root from ANDROID_HOME / ANDROID_SDK_ROOT / android/local.properties / the macOS
/// default. Throws a clear error if none resolves.
String androidSdkRoot() {
  for (final v in [
    Platform.environment['ANDROID_HOME'],
    Platform.environment['ANDROID_SDK_ROOT'],
  ]) {
    if (v != null && v.isNotEmpty && Directory(v).existsSync()) return v;
  }
  final lp = File('android/local.properties');
  if (lp.existsSync()) {
    for (final line in lp.readAsLinesSync()) {
      final m = RegExp(r'^\s*sdk\.dir\s*=\s*(.+)$').firstMatch(line);
      if (m != null && Directory(m.group(1)!.trim()).existsSync()) {
        return m.group(1)!.trim();
      }
    }
  }
  final fallback = '${Platform.environment['HOME']}/Library/Android/sdk';
  if (Directory(fallback).existsSync()) return fallback;
  throw StateError(
    'Android SDK not found — set ANDROID_HOME or android/local.properties sdk.dir',
  );
}

/// What [bridgeRegtestToEmulator] returns: the app dart-defines pointing at the bridged endpoints, and
/// [unbridge] to tear the bridge down (close the proxy + remove the adb reverses).
class RegtestEmulatorBridge {
  final Map<String, String> defines;
  final Future<void> Function() unbridge;
  RegtestEmulatorBridge(this.defines, this.unbridge);
}

// FIXED emulator-side bridge ports. The app binary is built ONCE and shared across tests, so the
// regtest URLs it reads must be CONSTANT — they cannot carry a per-session host port. We expose the
// chain on these fixed emulator-loopback ports and let a per-serial `adb reverse` map them to THIS
// session's dynamic host ports. Reverses are per-serial, so parallel emulators reuse the same fixed
// ports without colliding, and a crashed scenario's stale reverse is overwritten by the next claim of
// that slot rather than leaking a distinct port.
const _bridgeElectrumPort = 53321;
const _bridgeControlPort = 53322;

/// The fixed emulator-side regtest endpoints the shared android sim APK bakes in: the app reaches the
/// chain at these constant loopback ports, and [bridgeRegtestToEmulator]'s per-serial adb-reverse
/// routes them to each session. Single source of truth for both the baked define and the live bridge.
const androidBridgeElectrumUrl = 'tcp://127.0.0.1:$_bridgeElectrumPort';
const androidBridgeControlSocket = '127.0.0.1:$_bridgeControlPort';

/// Bridge a per-session regtest [session] to the Android emulator [serial] so its app can reach the
/// host-side chain: adb-reverse electrs' port and a unix→tcp faucet proxy onto fixed emulator ports
/// ([_bridgeElectrumPort]/[_bridgeControlPort]) that each map to this session's dynamic host ports. The
/// app then runs regtest unaware it's remote.
Future<RegtestEmulatorBridge> bridgeRegtestToEmulator(
  RegtestSession session,
  String serial,
) async {
  final adb = '${androidSdkRoot()}/platform-tools/adb';
  final ePort = electrumPort(session.url);
  await Process.run(adb, [
    '-s',
    serial,
    'reverse',
    'tcp:$_bridgeElectrumPort',
    'tcp:$ePort',
  ]);
  final controlProxy = await bridgeUnixOverTcp(session.controlSocket);
  await Process.run(adb, [
    '-s',
    serial,
    'reverse',
    'tcp:$_bridgeControlPort',
    'tcp:${controlProxy.port}',
  ]);
  Future<void> unbridge() async {
    try {
      await controlProxy.close();
    } catch (_) {}
    for (final p in [_bridgeElectrumPort, _bridgeControlPort]) {
      await Process.run(adb, ['-s', serial, 'reverse', '--remove', 'tcp:$p']);
    }
  }

  return RegtestEmulatorBridge({
    'SIM_REGTEST_ELECTRUM_URL': androidBridgeElectrumUrl,
    'SIM_REGTEST_CONTROL_SOCKET': androidBridgeControlSocket,
  }, unbridge);
}
