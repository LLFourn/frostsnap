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

/// The PID the live backend reports from `ping`, or null if none is (yet) live. This is the
/// AUTHORITY for ownership: only the process that won `bind_control_socket` serves, so its PID
/// identifies the live backend. A spawner compares it against the child it started to know
/// whether it owns the node or merely raced and lost (see [ensureRegtestBackend]).
Future<int?> regtestOwnerPid() async {
  SimFaucet? faucet;
  try {
    faucet = await SimFaucet.connect(regtestControlSocket);
    return await faucet.pingPid();
  } catch (_) {
    return null;
  } finally {
    await faucet?.close();
  }
}

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

  // Build first so compile/download errors surface synchronously (the first build downloads
  // the pinned bitcoind + electrs binaries).
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

  // Spawn the backend DETACHED (it outlives this call), logging to a file so failures are
  // diagnosable. We deliberately do NOT unlink the control/url paths here: a second concurrent
  // spawn could delete a socket the other backend just bound, orphaning its node. The Rust
  // binary's bind_control_socket owns stale-socket cleanup and refuses a LIVE one — that
  // singleton guard (not Dart) is the sole authority, so concurrent spawns resolve to one node.
  //
  // `child.pid` is the sim_regtest PID itself: the shell `exec`s into the binary (no fork), so
  // no intermediate process intervenes. We use it below to decide ownership authoritatively.
  final child = await Process.start(
    'sh',
    [
      '-c',
      'exec "\$1" --control-socket "\$2" --url-file "\$3" > "\$4" 2>&1',
      'sim_regtest',
      '$root/target/debug/sim_regtest',
      regtestControlSocket,
      regtestUrlFile,
      _regtestLogFile,
    ],
    workingDirectory: root,
    mode: ProcessStartMode.detached,
  );

  // Ready = a backend is serving (reports a PID) AND the URL file is written. Ownership is NOT
  // "we took the spawn branch" — under a concurrent auto-start two callers can both spawn, but
  // the Rust bind_control_socket singleton lets exactly ONE serve and every loser's child exits.
  // We own the live node only if its reported PID is the child WE spawned; a non-matching PID
  // means a racer won, so we attach (owned:false) and our teardown must never stop the shared
  // node another session relies on.
  final waitSecs =
      int.tryParse(Platform.environment['SIMCTL_REGTEST_WAIT_SECS'] ?? '') ??
      600;
  final deadline = DateTime.now().add(Duration(seconds: waitSecs));
  while (DateTime.now().isBefore(deadline)) {
    final ownerPid = await regtestOwnerPid();
    if (ownerPid != null && await File(regtestUrlFile).exists()) {
      return (
        url: (await File(regtestUrlFile).readAsString()).trim(),
        owned: ownerPid == child.pid,
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  throw StateError(
    'regtest backend did not come up within ${waitSecs}s; see $_regtestLogFile',
  );
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
