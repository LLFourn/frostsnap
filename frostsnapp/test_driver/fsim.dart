import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import 'diagnostic_rerun.dart';
import 'emulator.dart';
import 'eval_strings.dart';
import 'regtest.dart';
import 'sim_harness.dart';

// fsim: interactively drive the running sim app + devices through the SAME SimHarness
// methods the keygen test uses — no second implementation that can drift.
//
//   fsim serve [--devices N]    launch the app + N devices ONCE, listen for commands
//   fsim <cmd> ...              run ONE command against the running daemon, exit
//
// Device commands take `--device N` (1-based, default 1) to pick which virtual device.
// By default `serve` hands the keyboard to a human (real typing works; `enter` does not);
// pass `--agent-owns-keyboard` to let the driver own text input instead (enables `enter`,
// blocks the physical keyboard). One mode for the session — no hybrid.
//
// `serve` holds a SimHarness and forwards each command to its methods over a control
// socket, so the app stays alive across commands: send one, see the result, try the
// next — a failed attempt is just followed by another command on the same live app
// (no relaunch). `test` runs the driver e2e tests. See `_usage` for commands. Run via the
// repo-root `./fsim` launcher (e.g. `./fsim serve`, `./fsim test keygen`).

/// This session's STATE ROOT: `<identity>/.fsim`, holding its control socket, serve.log, app dir, and
/// screenshots. Identity = `--dir <path>` if given, else the INVOCATION cwd (FSIM_INVOCATION_CWD, captured
/// by the `./fsim` wrapper BEFORE it cd's into the package — `Directory.current` is the package dir, not
/// where the user ran fsim). The directory IS the session id, so two fsim runs in different dirs never
/// collide. Set once by [main] via [_resolveStateRoot].
late final Directory _stateRoot;

/// Resolve [_stateRoot] from `--dir`/FSIM_INVOCATION_CWD, stripping `--dir <path>` out of [args] and
/// returning the rest. Fails fast if the longest unix socket under the root would exceed the OS `sun_path`
/// limit (rather than truncating or hashing).
List<String> _resolveStateRoot(List<String> args) {
  String? dir;
  final rest = <String>[];
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--dir' && i + 1 < args.length) {
      dir = args[++i];
    } else {
      rest.add(args[i]);
    }
  }
  final invocationCwd =
      Platform.environment['FSIM_INVOCATION_CWD'] ?? Directory.current.path;
  // A relative `--dir` is relative to WHERE THE USER RAN fsim (the invocation cwd), NOT the package dir the
  // wrapper cd'd into. No `--dir` → the invocation cwd itself.
  var identity = dir == null
      ? invocationCwd
      : (dir.startsWith('/') ? dir : '$invocationCwd/$dir');
  // Canonicalize so the same directory always maps to the same session (resolve symlinks/`..` when it
  // exists; else normalize the absolute path of a not-yet-created --dir).
  try {
    identity = Directory(identity).resolveSymbolicLinksSync();
  } catch (_) {
    identity = Directory(identity).absolute.path;
  }
  final root = Directory('$identity/.fsim');
  // The regtest control socket is the longest unix-socket path under the root, and startRegtestSession
  // guards THAT path at 100 chars (a conservative margin under macOS's 104-byte sun_path); match it here so
  // an over-long dir fails at resolution with a clear message rather than inside serve.
  final longest = '${root.path}/regtest.sock';
  const limit = 100;
  if (longest.length > limit) {
    stderr.writeln(
      'fsim: session dir too long for a unix socket (${longest.length} > $limit chars): $longest\n'
      '  use a shorter --dir',
    );
    exit(2);
  }
  _stateRoot = root;
  return rest;
}

String get _socketPath => '${_stateRoot.path}/control.sock';

/// flutter device ids whose app shares the host filesystem — so the device-input `device-<n>.sock`s
/// are reachable and a full [SimHarness] (with device channels) can run. Anything else (an Android
/// emulator) runs an app-channel-only [AppSession].
const _hostPlatforms = {'macos', 'linux', 'windows'};

const _usage = '''
fsim — drive the running sim app/devices through SimHarness.
  Session-scoped: state lives in <dir>/.fsim (--dir <path> sets the dir, default the invocation cwd) — so
  concurrent fsim sessions in different dirs are isolated. `clean` deletes only that <dir>/.fsim.
  fsim serve [--devices N] [--instances N] [--android] [--platform <d>] [--agent-owns-keyboard] [--no-regtest]
                                              launch app + listen (regtest ON by default;
                                              --no-regtest = offline). --instances N holds N app windows on
                                              ONE regtest, driven via eval as `instances[K]` (`session` ==
                                              instances[0])
  fsim up [serve flags]                     idempotently bring the sim up + return once ready
                                              (no backgrounding/polling; reuses a matching live
                                              daemon, refuses a mismatched one — `down` first)
  fsim up --android [--devices N]           bring the sim up on an Android emulator (boot/provision
                                              one if needed) with regtest bridged over adb; drive the
                                              devices via `./fsim` (below) or the in-app tray
  fsim info                                 print the running daemon's shape (platform/count/regtest)
  fsim eval [--timeout SECS] [-a name=val] "<dart>"
                                              evaluate live Dart against the running session — the harness
                                              (e.g. `session.chain()`, `await session.connect(2)`); `-a` passes
                                              a shell value in as a String (`-a addr="\$addr" "…fund(addr,…)…"`)
  fsim repl                                  interactive console: live Dart per line, session persists (Ctrl-D quits)
  fsim test [NAMES...] [--android] [--jobs N] [--retries N] [--record-failures] [--test-timeout SECS] [--nocapture|-v] [--junit PATH]
                                              run e2e driver tests (stems; ALL if none) IN PARALLEL —
                                              host: one `dart run` each; --android: each SELF-BOOTS
                                              its OWN emulator + (if it uses regtest) bridges its OWN
                                              per-worker chain (rt-<pid>) to it. --jobs caps parallelism
                                              (default = all at once);
                                              --test-timeout (default 900s) reaps a wedged test as
                                              TIMEOUT so the run never stalls; raw output goes to
                                              build/sim-failures/<test>/output.log unless
                                              --nocapture/-v streams it live; --junit writes XML.
                                              --retries N (default 0) re-runs a FAILED test up to N more
                                              times from a fresh launch — else a failure is a failure.
                                              --record-failures (android-only, needs --android): after
                                              the batch, re-run each final failure ONCE solo, recording
                                              the emulator screen (video →
                                              build/sim-failures/<test>/rerun-N.mp4; original artifacts
                                              kept; verdict unchanged)
  fsim regtest up|down|status               manage THIS session's regtest (<dir>/.fsim/regtest.*) — the
                                              serve auto-starts it; bitcoind+electrs+faucet
  fsim regtest fund <addr> <sats> | mine [n] | balance | height | address | url   drive the faucet
  fsim clean                                reap + delete ONLY this session's <dir>/.fsim (socket, regtest,
                                              app dir, emulator) — never another session or a test run
                                              (no daemon running)
  fsim shot [path]                          whole-app screenshot (incl. tray)
  fsim down                                 tear down (quit app, clean up)

 App + device DRIVING (tap / chain / hold / enter / connect / wallet / faucet / …) is now
 `fsim eval "session.…"` — see `fsim eval --help` or test_driver/COMMANDS.md for the full drive API.''';

/// The serve's app instances — `fsim up --instances N` holds N `AppSession`s on the session's ONE regtest;
/// `instances[0]` is [session]. Exposed to `fsim eval`/`repl` snippets (evaluated in THIS root library).
/// Empty until the serve's app(s) are up.
List<AppSession> instances = [];

/// The primary console session (`instances[0]`) — the common single-instance handle in eval snippets.
AppSession get session => instances.isNotEmpty
    ? instances.first
    : (throw StateError(
        'no live session — is a `fsim up`/`serve` daemon running?',
      ));

/// Fire-and-poll async harness for `fsim eval`: `evaluate` cannot top-level `await`, so a snippet's async work
/// runs in an IIFE that records its outcome into these top-level fields; the eval client polls [evalDone] then
/// reads [evalResult] / [evalError]. State persists across evals (the daemon isolate is long-lived).
/// [evalGen] stamps each fire so a stale, still-running IIFE (e.g. a blocking snippet the client timed out on)
/// can't clobber a newer eval's fields — a completion only writes them if its generation is still current.
Object? evalResult;
Object? evalError;
bool evalDone = false;
int evalGen = 0;

/// Await a snippet's result while tolerating a `void`-typed one: a `dynamic` return erases `void`, so a
/// `Future<void>` action (e.g. `session.connect(2)`) captures `null` instead of failing to compile with
/// "expression has type 'void'". Public (like the eval fields) so the fired eval IIFE can call it by name.
Future<Object?> evalCapture(dynamic Function() run) async => await run();

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(_usage);
    exit(2);
  }
  // Two ISOLATION MODELS, deliberately non-overlapping so an interactive `clean` and a concurrent `fsim
  // test` never disturb each other: the test runner scopes per worker under the shared root
  // (simTmpRoot/rt-<pid> chains + `frostsnap_sim_pool_*` emulators at 5582↑), while every interactive command
  // scopes to <dir>/.fsim (its own socket/regtest/app-dir + `frostsnap_sim_session_*` emulators at 5680↓,
  // claimed by probe). `clean` deletes ONLY <dir>/.fsim and the runner reaps ONLY its own slots — so this
  // dispatch returns BEFORE resolving any interactive session root.
  if (args.first == 'test') {
    await _runTests(args.skip(1).toList());
    return;
  }
  // Every interactive command scopes to the session state root (`<--dir or invocation-cwd>/.fsim`).
  args = _resolveStateRoot(args);
  // The interactive regtest — serve's backend AND the `fsim regtest` commands — is this session's own,
  // under the state root, not the shared node.
  regtestDirOverride = _stateRoot;
  if (args.first == 'serve') {
    await _serve(args.skip(1).toList());
  } else if (args.first == 'up') {
    await _up(args.skip(1).toList());
  } else if (args.first == 'regtest') {
    await runRegtest(args.skip(1).toList());
  } else if (args.first == 'clean') {
    await _clean();
  } else if (args.first == 'eval') {
    await _eval(args.skip(1).toList());
  } else if (args.first == 'repl') {
    await _repl(args.skip(1).toList());
  } else {
    await _client(args);
  }
}

/// Remove all sim temp artifacts under the session root (disposable app dirs, screenshots, a
/// stopped backend's files) and reap any running regtest backend — for clearing residue left by
/// a killed session. Refuses while a serve daemon is live so it can't nuke an active session;
/// `./fsim down` first.
Future<void> _clean() async {
  if (await _daemonAlive()) {
    stderr.writeln('fsim: a serve daemon is running — run `./fsim down` first');
    exit(1);
  }
  // Reap THIS session's regtest (a graceful `down` already self-reaped it; this catches a killed session's
  // leftover) — scoped to <dir>/.fsim/regtest.*, so it never touches another session's backend.
  await reapRegtestSessionDir(_stateRoot);
  // Reap THIS session's self-booted android emulators if a hard-killed session left them (recorded serials, one
  // per line) — scoped to this session, NEVER a global sweep that could kill a concurrent test run's pool emu.
  final emSerialFile = File('${_stateRoot.path}/emulator-serials');
  if (await emSerialFile.exists()) {
    for (final serial in (await emSerialFile.readAsString()).split('\n')) {
      if (serial.trim().isEmpty) continue;
      try {
        await killEmulator(androidSdkRoot(), serial.trim());
      } catch (_) {}
    }
  }
  // Delete ONLY this session's state root (`<dir>/.fsim`) — never the cwd/worktree or a shared root, so a
  // `clean` in one session can't nuke another's (the per-session regtest reaping is Task 2).
  final root = _stateRoot;
  if (await root.exists()) await root.delete(recursive: true);
  stdout.writeln(jsonEncode({'ok': true, 'cleaned': root.path}));
}

const _evalHelp =
    r'''fsim eval [--timeout SECS] [-a name=value ...] "<dart>" — evaluate live Dart against the running
session: the SAME harness the e2e tests drive. The snippet is an expression; you may `await`. The SESSION
persists across evals (drive actions accumulate); to reuse a captured VALUE, hold it in the shell and pass it
back with `-a name=value` (bound as a String, never as code). (Multi-statement / imports / decls: use
`fsim test <file>`.) A snippet times out after 60s (--timeout SECS to change) so a blocking `await`/`waitFor`
recovers instead of hanging forever.

  addr=$(fsim eval "await (await session.faucet()).faucetAddress()")
  fsim eval -a addr="$addr" "await (await session.faucet()).fund(addr, 100000)"

Console scope:
  session                  the AppSession harness (the app + its virtual devices)
  instances[K]             the K-th app instance (`up --instances N`); session == instances[0]
  session.device(n)        a virtual device (raw pixel input + framebuffer)
  await session.faucet()   this session's regtest faucet (fund/mine/balances)

Common:
  session.chain()                          connected chain order -> List<int>
  session.deviceNumbers()                  all device numbers
  await session.connect(n) / disconnect(n) plug / unplug device n (+ downstream)
  await session.setChain([3, 1, 2])        re-cable to exactly these devices, in order
  session.tap(label) / enterText(label, t) / exists(label)
  await session.semantics().labels()       current targetable app labels
  await session.device(n).holdConfirm(x, y)         device hold-to-confirm
  (await session.faucet()).blockHeight() / .fund(addr, sats) / .balanceSat()

Full reference (every session / device / faucet method): test_driver/COMMANDS.md
''';

/// `fsim eval "<dart>"` — ship a live Dart snippet to the running daemon and evaluate it against the console
/// scope (`session` + the daemon's root library), printing its value or its error. Connects to the daemon's
/// VM service (published at `<dir>/.fsim/vmservice.uri` by [_serve]) and runs the snippet through the
/// fire-and-poll async harness, so the snippet MAY `await`. State persists across calls (stateful console).
/// The snippet is a Dart EXPRESSION (its value is the result); statements/decls need the `fsim test` file path.
/// `--help` (or no snippet) prints [_evalHelp] — a cheat-sheet pointing at test_driver/COMMANDS.md.
/// Connect to the running daemon's VM service (published at `<dir>/.fsim/vmservice.uri` by [_serve]) and
/// return the service + the isolate/root-library ids to evaluate against. Exits with a clear message if
/// there is no live session.
Future<(VmService, String, String)> _connectDaemon() async {
  final uriFile = File('${_stateRoot.path}/vmservice.uri');
  if (!uriFile.existsSync()) {
    stderr.writeln(
      'no live session — is `fsim up` running? (missing ${uriFile.path})',
    );
    exit(1);
  }
  final base = Uri.parse(uriFile.readAsStringSync().trim());
  final wsPath = base.path.endsWith('/') ? '${base.path}ws' : '${base.path}/ws';
  final ws = base.replace(scheme: 'ws', path: wsPath).toString();
  final VmService service;
  try {
    service = await vmServiceConnectUri(ws);
  } catch (e) {
    stderr.writeln(
      'cannot reach the daemon VM service ($e) — stale session? try `fsim up`',
    );
    exit(1);
  }
  final vm = await service.getVM();
  final isolateId = vm.isolates!.first.id!;
  final rootLibId = (await service.getIsolate(isolateId)).rootLib!.id!;
  return (service, isolateId, rootLibId);
}

/// Dart reserved words — none can be a variable name, so none can be an `--arg` name.
const _dartReservedWords = {
  'assert',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'default',
  'do',
  'else',
  'enum',
  'extends',
  'false',
  'final',
  'finally',
  'for',
  'if',
  'in',
  'is',
  'new',
  'null',
  'rethrow',
  'return',
  'super',
  'switch',
  'this',
  'throw',
  'true',
  'try',
  'var',
  'void',
  'while',
  'with',
  'await',
  'yield', //
};

/// Console/eval top-level names an `--arg` must not shadow.
const _reservedArgNames = {
  'session', 'instances', 'vars',
  'evalResult', 'evalError', 'evalDone', 'evalGen', 'evalCapture', //
};

/// Validate an `--arg` NAME (the value binds via the VM `scope` protocol, never spliced into source; this
/// guards the scope key + the snippet's bare reference). Must be a LETTER-initial Dart identifier — no leading
/// `_`, reserving the whole `_`-namespace for the fire wrapper's own `_fsimEval*` locals so a bound arg can't
/// shadow one — and not a reserved word or a console/eval name. Returns an error string, or null if valid.
String? _invalidArgName(String name) {
  if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9_]*$').hasMatch(name)) {
    return "invalid --arg name '$name' — must be a letter-initial Dart identifier (no leading '_')";
  }
  if (_dartReservedWords.contains(name))
    return "invalid --arg name '$name' — Dart reserved word";
  if (_reservedArgNames.contains(name))
    return "invalid --arg name '$name' — reserved console/eval name";
  return null;
}

/// Evaluate ONE snippet against the daemon via the fire-and-poll async harness (so the snippet may `await`)
/// and return `(output, isError)` — the result's `toString()`, or the error text. [args] binds each name to a
/// value in the snippet's scope (see below).
Future<(String, bool)> _evalOnce(
  VmService service,
  String isolateId,
  String rootLibId,
  String snippet,
  Duration timeout, {
  Map<String, String> args = const {},
}) async {
  // Bind each --arg NAME to its VALUE via the VM `scope` protocol — NOT by splicing anything into source.
  // Materialise the value as a String OBJECT from its bytes (base64 can't inject) and pass its object-id as
  // scope[name]; `scope` reaches the snippet even inside the fire IIFE's closures. Names are pre-validated as
  // letter-initial identifiers and the wrapper's own locals use an `_fsimEval*` namespace, so a bound arg can
  // neither inject nor shadow a generated local.
  final scope = <String, String>{};
  for (final entry in args.entries) {
    final b64 = base64.encode(utf8.encode(entry.value));
    final ref = await service.evaluate(
      isolateId,
      rootLibId,
      "utf8.decode(base64.decode('$b64'))",
    );
    if (ref is InstanceRef && ref.id != null) scope[entry.key] = ref.id!;
  }
  // Fire an unawaited async IIFE that evaluates the snippet and records the outcome into the daemon's
  // top-level fields — `evaluate` compiles synchronously, so a top-level `await` is illegal but firing an
  // async closure is not. `_fsimEvalGen = ++evalGen` stamps this fire: on completion it writes the fields ONLY
  // if its generation is still current, so a stale still-running IIFE (a blocking snippet the client timed out
  // on, then retried) can't clobber a newer eval's fields. Close any faucet the snippet opened so its
  // connection stays short-lived across evals (the backend control server serves one connection at a time).
  final fire =
      '(() async { final _fsimEvalGen = ++evalGen; evalDone = false; evalError = null; evalResult = null; '
      'try { final _fsimEvalRes = await evalCapture(() async => $snippet); if (evalGen == _fsimEvalGen) evalResult = _fsimEvalRes; } '
      "catch (_fsimEvalErr, _fsimEvalStk) { if (evalGen == _fsimEvalGen) evalError = '\$_fsimEvalErr\\n\$_fsimEvalStk'; } "
      'finally { for (final _fsimEvalInst in instances) { try { await _fsimEvalInst.closeFaucet(); } catch (_) {} } if (evalGen == _fsimEvalGen) evalDone = true; } })()';
  final Response fired;
  try {
    fired = await service.evaluate(
      isolateId,
      rootLibId,
      fire,
      scope: scope.isEmpty ? null : scope,
    );
  } catch (e) {
    // A snippet compile error is THROWN as an RPCError (not returned as an ErrorRef) — surface it so
    // eval/repl report it (and the repl keeps going) instead of crashing. Pull the `Error:` lines out of
    // the VM's verbose details, which otherwise echo the whole fire wrapper.
    final raw = e is RPCError ? (e.details ?? e.message) : '$e';
    final errs = raw
        .split('\n')
        .where((l) => l.contains('Error:'))
        .map((l) => l.substring(l.indexOf('Error:') + 6).trim());
    return (errs.isEmpty ? raw.trim() : errs.join('; '), true);
  }
  if (fired is ErrorRef) return (fired.message ?? 'compile error', true);
  // Poll evalDone — the isolate's event loop resolves the fired Future between our sync evals — but bound it
  // with a deadline so a BLOCKING snippet (e.g. `await session.waitFor("X")` for an X that never appears)
  // makes the client RECOVER with a timeout error instead of spinning forever. The fired IIFE keeps running
  // in the daemon (harmless — gen-guarded), so a retry won't be clobbered.
  final deadline = DateTime.now().add(timeout);
  while (true) {
    final done = await service.evaluate(isolateId, rootLibId, 'evalDone');
    if (done is InstanceRef && done.valueAsString == 'true') break;
    if (DateTime.now().isAfter(deadline)) {
      return (
        'eval timed out after ${timeout.inSeconds}s; the snippet is still running in the daemon '
            '(raise --timeout, or check for a waitFor/await that never completes)',
        true,
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  final err = await service.evaluate(isolateId, rootLibId, 'evalError');
  if (err is InstanceRef && err.kind != InstanceKind.kNull) {
    return (
      await _fullStringValue(service, isolateId, err) ??
          '<${err.classRef?.name}>',
      true,
    );
  }
  // Read the result's toString(), not the raw ref, so lists/maps/records print their VALUE (`[1, 2, 3]`)
  // not `<_GrowableList>`. `toString()` is valid on the nullable field (null -> "null").
  final res = await service.evaluate(
    isolateId,
    rootLibId,
    'evalResult.toString()',
  );
  if (res is InstanceRef) {
    return (
      await _fullStringValue(service, isolateId, res) ??
          '<${res.classRef?.name}>',
      false,
    );
  }
  return ('', false);
}

/// [ref]'s complete string value — `valueAsString` is only a ~128-char PREVIEW for long strings
/// (`valueAsStringIsTruncated`), so page the rest via `getObject` offset/count ([assembleFullString]).
Future<String?> _fullStringValue(
  VmService service,
  String isolateId,
  InstanceRef ref,
) {
  final id = ref.id;
  return assembleFullString(
    ref.valueAsString,
    ref.valueAsStringIsTruncated == true && id != null,
    ref.length,
    (offset, count) async {
      final obj = await service.getObject(
        isolateId,
        id!,
        offset: offset,
        count: count,
      );
      return obj is Instance ? obj.valueAsString : null;
    },
  );
}

/// `fsim eval "<dart>"` — evaluate ONE live Dart snippet against the running session's console scope
/// (`session` + the daemon root library) and print its value or error. The session persists across evals;
/// `-a name=value` binds a shell value into the snippet scope (via the VM `scope` protocol). `--help` (or no
/// snippet) prints [_evalHelp].
Future<void> _eval(List<String> args) async {
  if (args.isEmpty || args.first == '--help' || args.first == '-h') {
    stdout.write(_evalHelp);
    exit(args.isEmpty ? 2 : 0);
  }
  var timeout = const Duration(seconds: 60);
  final argVars = <String, String>{};
  final rest = <String>[];
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--timeout' && i + 1 < args.length) {
      timeout = Duration(seconds: int.parse(args[i + 1]));
      i++;
    } else if ((args[i] == '--arg' || args[i] == '-a') && i + 1 < args.length) {
      final pair = args[i + 1];
      final eq = pair.indexOf('=');
      if (eq <= 0) {
        stderr.writeln("fsim eval: --arg expects name=value, got '$pair'");
        exit(2);
      }
      final name = pair.substring(0, eq);
      final invalid = _invalidArgName(name);
      if (invalid != null) {
        stderr.writeln('fsim eval: $invalid');
        exit(2);
      }
      argVars[name] = pair.substring(eq + 1);
      i++;
    } else {
      rest.add(args[i]);
    }
  }
  final snippet = rest.join(' ').trim();
  if (snippet.isEmpty) {
    stderr.writeln(
      'usage: fsim eval [--timeout SECS] [-a name=value ...] "<dart expression>"  (see `fsim eval --help`)',
    );
    exit(2);
  }
  final (service, isolateId, rootLibId) = await _connectDaemon();
  try {
    final (out, isError) = await _evalOnce(
      service,
      isolateId,
      rootLibId,
      snippet,
      timeout,
      args: argVars,
    );
    if (isError) {
      stderr.writeln('ERROR: $out');
      exitCode = 1;
    } else {
      stdout.writeln(out);
    }
  } finally {
    await service.dispose();
  }
  exit(exitCode);
}

/// `fsim repl` — the same console as [_eval], kept OPEN: read a line, evaluate it against the live session,
/// print the result, repeat. State persists between lines. Ctrl-D (EOF) or `exit`/`quit` leaves.
Future<void> _repl(List<String> args) async {
  final (service, isolateId, rootLibId) = await _connectDaemon();
  stdout.writeln(
    'fsim repl — live Dart against the session (`session.…`; see `fsim eval --help`). Ctrl-D / `exit` to quit.',
  );
  try {
    while (true) {
      stdout.write('fsim> ');
      final line = stdin.readLineSync();
      if (line == null) break; // EOF (Ctrl-D)
      final snippet = line.trim();
      if (snippet.isEmpty) continue;
      if (snippet == 'exit' || snippet == 'quit') break;
      final (out, isError) = await _evalOnce(
        service,
        isolateId,
        rootLibId,
        snippet,
        const Duration(seconds: 60),
      );
      stdout.writeln(isError ? 'ERROR: $out' : out);
    }
  } finally {
    await service.dispose();
  }
  stdout.writeln();
  exit(0);
}

/// Whether a `serve` daemon is listening on the control socket.
Future<bool> _daemonAlive() async {
  try {
    final socket = await Socket.connect(
      InternetAddress(_socketPath, type: InternetAddressType.unix),
      0,
    ).timeout(const Duration(seconds: 1));
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

// ---- up: one idempotent command that brings the sim up and returns only once ready ----

/// `fsim up [serve flags]` — idempotent bring-up. If a live daemon already matches the requested
/// shape (device count, regtest, keyboard mode) it's a no-op (`already:true`); on a MISMATCH it
/// refuses with a clear "down first" error rather than reporting a wrong daemon ready; otherwise it
/// launches `serve` DETACHED (which self-logs) and returns only once the control socket is live. The
/// whole point: one command, no backgrounding or readiness polling by the caller.
Future<void> _up(List<String> args) async {
  var count = 1;
  // Default to the host desktop OS so it matches what `serve`/_resolvePlatform would launch (else `up` on
  // Linux would read the launched linux daemon as an incompatible-platform mismatch).
  var wantInstances = 1;
  var wantPlatform = Platform.isLinux ? 'linux' : 'macos';
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--devices') count = int.parse(args[i + 1]);
    if (args[i] == '--instances') wantInstances = int.parse(args[i + 1]);
    if (args[i] == '--platform') wantPlatform = args[i + 1];
  }
  // `--android` targets an emulator (the exact serial is resolved by the launched `serve`, so the
  // compatibility check below matches on "is an emulator" rather than a specific serial).
  final wantAndroid = args.contains('--android');
  // The shape `serve` WOULD launch — mirror its `withRegtest = !--no-regtest`. Regtest is ON by
  // default (on the host directly, on an emulator bridged over adb); --no-regtest opts out.
  final wantRegtest = !args.contains('--no-regtest');
  final wantKeyboard = args.contains('--agent-owns-keyboard');

  if (await _daemonAlive()) {
    final info = await _query({'cmd': 'info'});
    final live = (
      count: info['count'] as int,
      instances: (info['instances'] as int?) ?? 1,
      regtest: info['regtest'] as bool,
      keyboard: info['keyboard'] as bool,
      platform: info['platform'] as String? ?? 'macos',
    );
    // Compatible iff the recorded shape matches what serve would launch — same platform kind (an
    // emulator for --android, else the exact desktop platform), device count, keyboard mode, AND
    // regtest. A real mismatch fails (down first) rather than reporting a wrong daemon ready (e.g. an
    // Android AppSession that can't serve host device commands against a desktop request).
    final liveIsAndroid = !_hostPlatforms.contains(live.platform);
    final platformOk = wantAndroid
        ? liveIsAndroid
        : live.platform == wantPlatform;
    final compatible =
        platformOk &&
        live.count == count &&
        live.instances == wantInstances &&
        live.keyboard == wantKeyboard &&
        live.regtest == wantRegtest;
    if (compatible) {
      stdout.writeln(
        jsonEncode({'ok': true, 'already': true, 'socket': _socketPath}),
      );
      exit(0);
    }
    stderr.writeln(
      jsonEncode({
        'ok': false,
        'error':
            'a different-shape sim daemon is already running '
            '(platform=${live.platform}, count=${live.count}, instances=${live.instances}, '
            'regtest=${live.regtest}, agentOwnsKeyboard=${live.keyboard}); run `./fsim down` first',
      }),
    );
    exit(1);
  }

  // No daemon: launch `serve` detached via the repo-root launcher (which runs `just maybe-gen`
  // first, then self-logs every startup step to serve.log). We TAIL that log straight to our stdout,
  // so the caller watches the bring-up live (emulator boot, regtest bridge, gradle build, app
  // launch) and we return the instant the serve writes its terminal FSIM_READY / FSIM_FAILED
  // line — no socket polling, and a failure surfaces its real reason instead of a blank timeout.
  _stateRoot.createSync(recursive: true);
  final logPath = '${_stateRoot.path}/serve.log';
  try {
    File(logPath).deleteSync(); // don't tail a stale prior-run log
  } catch (_) {}
  final launcher = '${Directory.current.parent.path}/fsim';
  // Forward this session's identity as `--dir`: the detached serve re-runs the wrapper, whose
  // FSIM_INVOCATION_CWD would be OUR cwd (the package dir), so `--dir` is what pins the daemon to the SAME
  // state root this client resolved.
  final serve = await Process.start(launcher, [
    'serve',
    '--dir',
    _stateRoot.parent.path,
    ...args,
  ], mode: ProcessStartMode.detached);

  final logFile = File(logPath);
  var shown = 0;
  final deadline = DateTime.now().add(const Duration(minutes: 8));
  while (true) {
    final log = await logFile.exists() ? await logFile.readAsString() : '';
    if (log.length > shown) {
      stdout.write(log.substring(shown)); // stream new progress lines live
      shown = log.length;
    }
    if (log.contains('FSIM_READY')) {
      stdout.writeln(
        jsonEncode({
          'ok': true,
          'started': true,
          'pid': serve.pid,
          'socket': _socketPath,
        }),
      );
      exit(0);
    }
    final failAt = log.indexOf('FSIM_FAILED:');
    if (failAt >= 0) {
      final reason = log
          .substring(failAt + 'FSIM_FAILED:'.length)
          .split('\n')
          .first
          .trim();
      stderr.writeln(
        jsonEncode({
          'ok': false,
          'error': 'sim daemon failed to start: $reason (see $logPath)',
        }),
      );
      exit(1);
    }
    if (DateTime.now().isAfter(deadline)) {
      stderr.writeln(
        jsonEncode({
          'ok': false,
          'error': 'sim daemon did not come up within 8 minutes (see $logPath)',
        }),
      );
      exit(1);
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
}

/// Connect to the live daemon, send one command, return its decoded reply (does NOT exit — used by
/// `up` to query daemon `info`, unlike `_client` which prints + exits).
Future<Map<String, dynamic>> _query(Map<String, dynamic> req) async {
  final socket = await Socket.connect(
    InternetAddress(_socketPath, type: InternetAddressType.unix),
    0,
  );
  socket.write('${jsonEncode(req)}\n');
  await socket.flush();
  final reply = await socket
      .cast<List<int>>()
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .firstWhere((l) => l.trim().isNotEmpty);
  await socket.close();
  return jsonDecode(reply) as Map<String, dynamic>;
}

// ---- test runner: run the driver e2e tests (test_driver/*_drive.dart) ----

const _driveSuffix = '_drive.dart';
const _diagnosticTimeout = Duration(seconds: 10);

class _TestSpec {
  final String file;
  final String name;
  final Directory artifactsDir;

  _TestSpec(this.file, this.name)
    : artifactsDir = Directory('build/sim-failures/$name');

  // The diagnostic re-run writes under <test>/rerun/ so _runOneTest's artifact-clear can never touch the
  // ORIGINAL failure evidence (error.txt / output.log / screenshots stay byte-for-byte intact).
  _TestSpec.at(this.file, this.name, this.artifactsDir);
}

class _TestResult {
  final _TestSpec test;
  final String status;
  final String output;
  final Duration duration;
  final String? reason;

  /// Retries taken before this (final) result; 0 = passed/failed on the first attempt.
  int retries = 0;

  _TestResult({
    required this.test,
    required this.status,
    required this.output,
    required this.duration,
    this.reason,
  });

  bool get passed => status == 'PASSED';
  bool get failed => status == 'FAILED';
  bool get timedOut => status == 'TIMEOUT';
  bool get skipped => status == 'SKIPPED';
}

List<_TestSpec> _testSpecs(List<String> files) {
  final seen = <String, int>{};
  return [
    for (final file in files)
      () {
        final stem = file.substring(0, file.length - _driveSuffix.length);
        final count = (seen[stem] ?? 0) + 1;
        seen[stem] = count;
        return _TestSpec(file, count == 1 ? stem : '$stem-$count');
      }(),
  ];
}

Future<void> _clearArtifacts(Directory dir) async {
  if (await dir.exists()) await dir.delete(recursive: true);
}

Future<void> _writeOutputLog(Directory dir, String output) async {
  await dir.create(recursive: true);
  await File('${dir.path}/output.log').writeAsString(output);
}

Future<void> _writeErrorIfAbsent(Directory dir, String error) async {
  await dir.create(recursive: true);
  final file = File('${dir.path}/error.txt');
  if (!await file.exists()) await file.writeAsString(error);
}

String _elapsed(Duration d) =>
    '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';

String _displayStatus(_TestResult r) => switch (r.status) {
  'PASSED' => 'ok',
  'FAILED' => 'FAILED',
  'TIMEOUT' => 'TIMEOUT',
  'SKIPPED' => 'SKIPPED',
  _ => r.status,
};

void _printResult(_TestResult r) {
  stdout.writeln(
    'test ${r.test.name} ... ${_displayStatus(r)} (${_elapsed(r.duration)})',
  );
}

void _printFailures(List<_TestResult> failures) {
  if (failures.isEmpty) return;
  stdout.writeln();
  stdout.writeln('failures:');
  for (final failure in failures) {
    final reason = failure.reason ?? failure.status;
    stdout.writeln(
      '  ${failure.test.name}: $reason; see ${failure.test.artifactsDir.path}',
    );
  }
}

void _printSummary(List<_TestResult> results, Duration elapsed) {
  final passed = results.where((r) => r.passed).length;
  final failed = results.where((r) => r.failed).length;
  final timedOut = results.where((r) => r.timedOut).length;
  final skipped = results.where((r) => r.skipped).length;
  final retried = results.where((r) => r.retries > 0).length;
  stdout.writeln();
  stdout.writeln(
    'test result: $passed passed; $failed failed; $timedOut timed out; '
    '$skipped skipped; finished in ${_elapsed(elapsed)}'
    '${retried > 0 ? ' ($retried retried)' : ''}',
  );
}

Future<void> _writeJunit(
  String path,
  List<_TestResult> results,
  Duration elapsed,
) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  final failed = results.where((r) => r.failed).length;
  final timedOut = results.where((r) => r.timedOut).length;
  final skipped = results.where((r) => r.skipped).length;
  final retries = results.fold<int>(0, (sum, r) => sum + r.retries);
  final b = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln(
      '<testsuite name="fsim" tests="${results.length}" failures="$failed" '
      'errors="$timedOut" skipped="$skipped" retries="$retries" '
      'time="${_junitTime(elapsed)}">',
    );
  for (final r in results) {
    b.writeln(
      '  <testcase classname="fsim" name="${_xmlEscape(r.test.name)}" '
      'retries="${r.retries}" time="${_junitTime(r.duration)}">',
    );
    if (r.skipped) {
      b.writeln('    <skipped/>');
    } else if (r.failed) {
      final message = _xmlEscape(r.reason ?? 'failed');
      b.writeln(
        '    <failure message="$message">${_xmlEscape(r.output)}</failure>',
      );
    } else if (r.timedOut) {
      final message = _xmlEscape(r.reason ?? 'timed out');
      b.writeln(
        '    <error type="timeout" message="$message">${_xmlEscape(r.output)}</error>',
      );
    }
    b.writeln('  </testcase>');
  }
  b.writeln('</testsuite>');
  await file.writeAsString(b.toString());
}

String _junitTime(Duration d) => (d.inMilliseconds / 1000).toStringAsFixed(3);

String _xmlEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

/// Run one driver test by its file STEM (`<stem>_drive.dart`), or all of them with no arg.
/// Each runs as its own `dart run` so they get a fresh app/harness; a non-zero exit from any
/// fails the whole run. Replaces the per-test justfile recipes — a new test is just a new
/// `*_drive.dart` file, discovered here automatically.
Future<void> _runTests(List<String> args) async {
  // Runs the named tests (or ALL if none) IN PARALLEL. Each test is a self-contained `dart run` owning
  // its isolated state (its own app instance(s) + per-session regtest chain); on `--android` each test
  // SELF-BOOTS its own emulator(s) and bridges the chain to them. No shared state to serialize around.
  // `--jobs N` caps the parallelism; default = run them all at once.
  final android = args.contains('--android');
  int? jobs; // null = "as many as possible"
  int? testTimeout; // per-test hard deadline, seconds
  var noCapture = false;
  String? junitPath;
  var retries =
      0; // opt-in extra attempts a FAILED test gets; default 0 = a failure is a failure
  var recordFailures = false;
  final positional = <String>[];
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--android') continue;
    if (a == '--nocapture' || a == '-v') {
      noCapture = true;
      continue;
    }
    if (a == '--jobs') {
      jobs = int.parse(args[++i]);
      continue;
    }
    if (a == '--test-timeout') {
      testTimeout = int.parse(args[++i]);
      continue;
    }
    if (a == '--junit') {
      junitPath = args[++i];
      continue;
    }
    if (a == '--retries') {
      retries = int.parse(args[++i]);
      if (retries < 0) {
        stderr.writeln('fsim test: --retries must be >= 0');
        exit(2);
      }
      continue;
    }
    if (a == '--record-failures') {
      recordFailures = true;
      continue;
    }
    if (a.startsWith('--')) continue;
    positional.add(a);
  }
  if (recordFailures) {
    final err = recordFailuresUsageError(android: android);
    if (err != null) {
      stderr.writeln(err);
      exit(2);
    }
  }

  final stems = <String, String>{}; // stem -> filename
  for (final entry in Directory('test_driver').listSync()) {
    final name = entry.uri.pathSegments.last;
    if (entry is File && name.endsWith(_driveSuffix)) {
      stems[name.substring(0, name.length - _driveSuffix.length)] = name;
    }
  }
  final available = stems.keys.toList()..sort();

  final List<String> files;
  if (positional.isEmpty) {
    files = available.map((s) => stems[s]!).toList();
  } else {
    files = [];
    for (final name in positional) {
      final file = stems[name];
      if (file == null) {
        stderr.writeln(
          'fsim test: no test "$name". Available: ${available.join(', ')}',
        );
        exit(2);
      }
      files.add(file);
    }
  }
  final tests = _testSpecs(files);

  // Default to running every test at once.
  var effJobs = (jobs ?? files.length).clamp(1, files.length);
  // Android emulator ports are a bounded budget: worker slots [0, maxTestWorkers) are reserved DISJOINT from
  // the interactive `up` session slots, so cap android parallelism there (host tests use windows — no port
  // budget). With few scenario files this never bites; any extra workers just queue.
  if (android && effJobs > maxTestWorkers) {
    stderr.writeln(
      'fsim: capping android --jobs to the $maxTestWorkers reserved test-worker slots '
      '(interactive `up` sessions take the rest); ${effJobs - maxTestWorkers} worker(s) will queue',
    );
    effJobs = maxTestWorkers;
  }
  // Per-test hard deadline so a wedged test (frozen app / unbounded wait) can't stall the run — it's
  // reaped and reported TIMEOUT instead. Generous by default: Android workers can queue behind a
  // serialized `flutter run` build/install. Host workers direct-launch a prebuilt debug app.
  final deadline = Duration(seconds: testTimeout ?? 900);
  final results = <_TestResult>[];
  final started = DateTime.now();
  stdout.writeln('running ${tests.length} tests');
  // Build the app ONCE up front (host binary / android APK), then run every test as a self-contained
  // `dart run` owning its PRIVATE per-session regtest chain — up to `effJobs` concurrently, no shared
  // state. Android tests SELF-BOOT their own emulator(s) from the worker slot (no pre-booted pool);
  // that keeps host and android on the ONE dispatch path. Concurrent output is captured + printed grouped
  // on completion (interleaved live streams would be unreadable); a single test streams live.
  final hostAppBinary = android
      ? null
      : Platform.isMacOS
      ? await AppSession.ensureMacosSimAppBuilt(logSink: stderr)
      : Platform.isLinux
      ? await AppSession.ensureLinuxSimAppBuilt(logSink: stderr)
      : null;
  final androidAppBinary = android
      ? await AppSession.ensureAndroidSimApkBuilt(logSink: stderr)
      : null;
  final sdk = android ? androidSdkRoot() : null;
  // Host device: null on macOS (the test defaults to 'macos' — unchanged); 'linux' on Linux so the test
  // targets the Linux desktop app + the prebuilt binary built above. Android self-boots ('android').
  final hostDevice = Platform.isLinux ? 'linux' : null;
  await _runBounded(tests, effJobs, (test, workerSlot) async {
    final (r, retriesTaken) = await runWithRetry<_TestResult>(
      (_) => _runOneTest(
        test,
        flutterDevice: android ? 'android' : hostDevice,
        sdk: sdk,
        hostAppBinary: hostAppBinary,
        androidAppBinary: androidAppBinary,
        windowSlot: workerSlot,
        capture: !noCapture,
        deadline: deadline,
      ),
      (res) => res.failed,
      maxAttempts: 1 + retries,
    );
    // Android: reap the emulator(s) this slot self-booted — belt-and-suspenders so a timed-out/killed
    // test (whose own teardown didn't run) can't orphan one. Deterministic serials from the slot.
    if (android && sdk != null) await _reapSlotEmulators(sdk, workerSlot);
    r.retries = retriesTaken;
    _printResult(r);
    _reportRetries(r, retriesTaken);
    results.add(r);
  });

  final failures = results.where((r) => !r.passed && !r.skipped).toList();
  _printFailures(failures);
  final elapsed = DateTime.now().difference(started);
  _printSummary(results, elapsed);
  if (junitPath != null) await _writeJunit(junitPath, results, elapsed);
  // Diagnostic phase LAST: verdict, summary, and JUnit above are frozen — the recorded re-runs below
  // never feed back into them.
  await _recordFailedTests(
    results,
    enabled: recordFailures,
    sdk: sdk,
    androidAppBinary: androidAppBinary,
    deadline: deadline,
  );
  exit(failures.isEmpty ? 0 : 1);
}

/// `--record-failures` (android-only): re-run each final failure ONCE, solo (sequentially, after the
/// whole batch), recording the emulator screen — `rerun-N.mp4` segments land at the test dir root and
/// the child's own artifacts under `<test>/rerun/`, so the ORIGINAL evidence is untouched.
/// Purely diagnostic: results are already frozen; a re-run that passes just gets `rerun-passed.txt`.
Future<void> _recordFailedTests(
  List<_TestResult> results, {
  required bool enabled,
  required String? sdk,
  required String? androidAppBinary,
  required Duration deadline,
}) async {
  final reruns = selectDiagnosticReruns(
    results,
    enabled,
    (r) => !r.passed && !r.skipped,
  );
  if (reruns.isEmpty) return;
  stderr.writeln(
    'fsim: recording diagnostic re-runs for ${reruns.length} failed test(s) …',
  );
  // The phase is purely diagnostic: ANY failure inside it (adb hiccup, boot failure, …) is reported and
  // swallowed by runSequentially — an escaping exception would change fsim's exit code, breaking the
  // frozen verdict (a missing recorder binary on CI did exactly that once: uncaught ProcessException ->
  // exit 255).
  await runSequentially(
    reruns,
    (r) => _recordOneRerun(
      r,
      sdk: sdk,
      androidAppBinary: androidAppBinary,
      deadline: deadline,
    ),
    (r, e) => stderr.writeln(
      'fsim: --record-failures: ${r.test.name}: diagnostic re-run failed: $e',
    ),
  );
}

Future<void> _recordOneRerun(
  _TestResult r, {
  required String? sdk,
  required String? androidAppBinary,
  required Duration deadline,
}) async {
  final test = r.test;
  final rerunSpec = _TestSpec.at(
    test.file,
    test.name,
    Directory('${test.artifactsDir.path}/rerun'),
  );
  // The child self-boots its emulator on the deterministic slot-0 serial; recording can only start once
  // that serial has FULLY booted. Record instance 0's emulator (a multi-instance android test would need
  // per-serial recorders — none exists today). Cleanup is INVARIANT via the nested finallys: the recorder
  // is finalized/pulled and the slot's emulators reaped even when the boot-wait, child, or pull throws.
  final adb = '$sdk/platform-tools/adb';
  final serial = emulatorSerial(0);
  _TestResult? rerun;
  final videos = <String>[];
  try {
    final childFuture = _runOneTest(
      rerunSpec,
      flutterDevice: 'android',
      sdk: sdk,
      androidAppBinary: androidAppBinary,
      windowSlot: 0,
      // The child must LEAVE its emulator running: the recorder pkill/pulls the mp4 after the child
      // exits, then the outer finally reaps the slot.
      extraEnv: const {'SIM_KEEP_EMULATOR': '1'},
      capture: true,
      deadline: deadline,
    );
    AndroidSegmentRecorder? rec;
    try {
      final ready = await waitBootCompleted(
        adb,
        serial,
        childFuture.then((_) {}, onError: (_) {}),
      );
      if (ready) {
        rec = AndroidSegmentRecorder(adb: adb, serial: serial)..start();
      } else {
        stderr.writeln(
          'fsim: --record-failures: ${test.name}: emulator $serial never finished booting — no video',
        );
      }
      rerun = await childFuture;
    } finally {
      if (rec != null) {
        videos.addAll(await rec.stopAndPull(test.artifactsDir.path));
      }
    }
  } finally {
    if (sdk != null) await _reapSlotEmulators(sdk, 0);
  }
  if (rerun.passed) {
    await File('${test.artifactsDir.path}/rerun-passed.txt').writeAsString(
      'The recorded diagnostic re-run PASSED — the original failure did not reproduce (flake '
      'evidence). The verdict above is unchanged.\n',
    );
  }
  // A started screenrecord is no evidence of a clip: report success ONLY for segments that actually
  // contain video, else surface a recording failure (runSequentially reports it; the verdict is frozen).
  final usable = await usableSegments(videos);
  if (usable.isEmpty) {
    throw StateError(
      'no usable video segment was recorded — the re-run child artifacts are in ${rerunSpec.artifactsDir.path}'
      '${rerun.passed ? ' (the re-run itself PASSED; rerun-passed.txt written)' : ''}',
    );
  }
  stderr.writeln(
    rerun.passed
        ? 'fsim: ${test.name}: diagnostic re-run PASSED (original failure stands); '
              'video: ${usable.join(', ')}'
        : 'fsim: ${test.name}: diagnostic re-run recorded; video: ${usable.join(', ')}',
  );
}

/// Kill any emulators worker [slot] could have self-booted (its device-index range), so a timed-out or
/// killed test — whose own teardown didn't run — never orphans one. Idempotent (a harmless no-op for an
/// index that never booted); deterministic serials keep it independent of the dead test process.
Future<void> _reapSlotEmulators(String sdk, int slot) async {
  for (var i = 0; i < maxInstancesPerTest; i++) {
    await killEmulator(sdk, emulatorSerial(slot * maxInstancesPerTest + i));
  }
}

/// Run [attempt] (each call is one fresh attempt, given its 1-based number) and retry while
/// [shouldRetry] holds the result, up to [maxAttempts] total. Returns the final result and the number
/// of RETRIES taken (0 on a first-try result). Pure control flow — unit-tested with a fake [attempt].
Future<(T, int)> runWithRetry<T>(
  Future<T> Function(int attempt) attempt,
  bool Function(T) shouldRetry, {
  int maxAttempts = 1,
}) async {
  for (var n = 1; ; n++) {
    final r = await attempt(n);
    if (n >= maxAttempts || !shouldRetry(r)) return (r, n - 1);
  }
}

/// Surface retries on stderr so a retried test is visible, never silently papered over.
void _reportRetries(_TestResult r, int retries) {
  if (retries == 0) return;
  final s = retries == 1 ? 'retry' : 'retries';
  stderr.writeln(
    r.passed
        ? 'fsim: ${r.test.name} recovered after $retries $s'
        : 'fsim: ${r.test.name} FAILED after ${retries + 1} attempts',
  );
}

/// Run `dart run test_driver/<file>` to completion or [deadline], whichever comes first. On the
/// deadline the test is wedged — commonly a frozen app whose VM service can't answer, so NO in-test
/// timeout can fire — so reap what it spawned and return TIMEOUT, and the run never stalls. With
/// [capture] the child's output is buffered (returned for grouped printing); else it inherits stdio.
Future<_TestResult> _runOneTest(
  _TestSpec test, {
  String? flutterDevice,
  String? sdk,
  String? hostAppBinary,
  String? androidAppBinary,
  int? windowSlot,
  Map<String, String> extraEnv = const {},
  required bool capture,
  required Duration deadline,
}) async {
  await _clearArtifacts(test.artifactsDir);
  final started = DateTime.now();
  final proc = await Process.start(
    'dart',
    ['run', 'test_driver/${test.file}'],
    mode: ProcessStartMode.normal,
    environment: {
      ...extraEnv,
      'SIM_TEST_NAME': test.name,
      'SIM_TEST_ARTIFACTS_DIR': test.artifactsDir.absolute.path,
      // For android, this is the generic 'android' — the TEST self-boots its own emulator(s) from the
      // slot (sim-unify-app-host); for host it's unset (the test defaults to macos).
      if (flutterDevice != null) 'SIM_FLUTTER_DEVICE': flutterDevice,
      if (flutterDevice != null) 'SIM_REQUIRE_FLUTTER_DEVICE': '1',
      if (hostAppBinary != null) 'SIM_HOST_APP_BINARY': hostAppBinary,
      if (androidAppBinary != null) 'SIM_ANDROID_APP_BINARY': androidAppBinary,
      if (windowSlot != null) 'FROSTSNAP_SIM_WINDOW_SLOT': '$windowSlot',
    },
  );
  final buf = StringBuffer();
  final drains = [
    proc.stdout.transform(utf8.decoder).forEach((chunk) {
      buf.write(chunk);
      if (!capture) stdout.write(chunk);
    }),
    proc.stderr.transform(utf8.decoder).forEach((chunk) {
      buf.write(chunk);
      if (!capture) stderr.write(chunk);
    }),
  ];
  int code;
  var timedOut = false;
  String? reason;
  try {
    code = await proc.exitCode.timeout(deadline);
  } on TimeoutException {
    timedOut = true;
    reason = 'timed out after ${deadline.inSeconds}s';
    await _writeOutputLog(test.artifactsDir, buf.toString());
    // Self-booted android emulators (if any) are reaped by the caller from the slot; here just kill the
    // dart process + its regtest dir (serial null → skip the emulator-specific adb reaping).
    await _captureTimeoutDiagnostics(
      test.artifactsDir,
      output: buf.toString(),
      serial: null,
      sdk: sdk,
      deadline: deadline,
    );
    await _reapHungTest(proc, null, sdk);
    code = await proc.exitCode.timeout(_diagnosticTimeout, onTimeout: () => -1);
  }
  await Future.wait(
    drains,
  ).timeout(_diagnosticTimeout, onTimeout: () => <void>[]);
  final output = buf.toString();
  // A scenario can declare itself skipped (exit 0 + marker) — e.g. a host-only dual-instance scenario
  // on an emulator. Classify that as SKIPPED so a never-ran test isn't reported as a silent PASS.
  final skipped =
      !timedOut && code == 0 && output.contains(simTestSkippedMarker);
  final status = timedOut
      ? 'TIMEOUT'
      : skipped
      ? 'SKIPPED'
      : (code == 0 ? 'PASSED' : 'FAILED');
  await _writeOutputLog(test.artifactsDir, output);
  if (status != 'PASSED') {
    reason ??= 'exit code $code';
    await _writeErrorIfAbsent(
      test.artifactsDir,
      '$status: $reason\n\nSee output.log for the child process log.\n',
    );
  }
  return _TestResult(
    test: test,
    status: status,
    output: output,
    duration: DateTime.now().difference(started),
    reason: reason,
  );
}

Future<void> _captureTimeoutDiagnostics(
  Directory dir, {
  required String output,
  required String? serial,
  required String? sdk,
  required Duration deadline,
}) async {
  await dir.create(recursive: true);
  await File('${dir.path}/error.txt').writeAsString(
    'TIMEOUT after ${deadline.inSeconds}s\n\n'
    'The child test process did not exit before the runner deadline.\n'
    'Partial child output is in output.log.\n',
  );
  if (serial != null && sdk != null) {
    await _captureAndroidTimeoutDiagnostics(dir, serial: serial, sdk: sdk);
  } else {
    await _captureHostTimeoutDiagnostics(dir);
  }
  await _captureVmDeviceFrames(dir, output);
}

Future<void> _captureAndroidTimeoutDiagnostics(
  Directory dir, {
  required String serial,
  required String sdk,
}) async {
  final adb = '$sdk/platform-tools/adb';
  final screen = await _runDiagnosticProcess(adb, [
    '-s',
    serial,
    'exec-out',
    'screencap',
    '-p',
  ], stdoutEncoding: null);
  if (screen != null && screen.exitCode == 0 && screen.stdout is List<int>) {
    await File(
      '${dir.path}/android-screen.png',
    ).writeAsBytes(screen.stdout as List<int>);
  }

  final logcat = await _runDiagnosticProcess(adb, [
    '-s',
    serial,
    'logcat',
    '-d',
  ]);
  if (logcat != null) {
    await File(
      '${dir.path}/logcat.txt',
    ).writeAsString('${logcat.stdout}${logcat.stderr}');
  }
}

Future<void> _captureHostTimeoutDiagnostics(Directory dir) async {
  if (Platform.isMacOS) {
    await _runDiagnosticProcess('screencapture', [
      '-x',
      '${dir.path}/host-screen.png',
    ]);
  } else if (Platform.isLinux) {
    await _runDiagnosticProcess('scrot', ['${dir.path}/host-screen.png']);
  }
}

Future<void> _captureVmDeviceFrames(Directory dir, String output) async {
  final url = _vmServiceUrl(output);
  if (url == null) return;
  FlutterDriver? driver;
  try {
    driver = await FlutterDriver.connect(
      dartVmServiceUrl: url,
    ).timeout(_diagnosticTimeout);
    final csv = await driver
        .runUnsynchronized(() => driver!.requestData('device-numbers'))
        .timeout(_diagnosticTimeout);
    final numbers = csv.isEmpty ? <int>[] : csv.split(',').map(int.parse);
    for (final n in numbers) {
      try {
        final b64 = await driver
            .runUnsynchronized(() => driver!.requestData('device-screen:$n'))
            .timeout(_diagnosticTimeout);
        await File('${dir.path}/device-$n.png').writeAsBytes(base64Decode(b64));
      } catch (_) {}
    }
  } catch (_) {
  } finally {
    try {
      await driver?.close().timeout(_diagnosticTimeout);
    } catch (_) {}
  }
}

String? _vmServiceUrl(String output) {
  final m = RegExp(r'(http://127\.0\.0\.1:\d+/[^\s]+)').firstMatch(output);
  return m?.group(1);
}

Future<ProcessResult?> _runDiagnosticProcess(
  String executable,
  List<String> args, {
  Encoding? stdoutEncoding = utf8,
}) async {
  try {
    return await Process.run(
      executable,
      args,
      stdoutEncoding: stdoutEncoding,
      stderrEncoding: utf8,
    ).timeout(_diagnosticTimeout);
  } catch (_) {
    return null;
  }
}

/// Best-effort reap of a timed-out test: it never ran its own teardown, so kill what it spawned — the
/// app on its emulator, the `flutter run` driving that serial, its per-session regtest backend
/// (`rt-<testpid>`), and the process itself. Serial-scoped, so a parallel run's other workers survive.
Future<void> _reapHungTest(Process proc, String? serial, String? sdk) async {
  if (serial != null && sdk != null) {
    await Process.run('$sdk/platform-tools/adb', [
      '-s',
      serial,
      'shell',
      'am',
      'force-stop',
      'com.frostsnap',
    ]);
    await Process.run('pkill', ['-9', '-f', 'sim_app.dart -d $serial']);
  }
  await reapRegtestSessionDir(Directory('${simTmpRoot().path}/rt-${proc.pid}'));
  await _killProcessTree(proc.pid);
}

Future<void> _killProcessTree(int rootPid) async {
  final pids = await _processTree(rootPid);
  if (pids.isEmpty) return;
  _signalPids(pids, ProcessSignal.sigterm);
  await Future<void>.delayed(const Duration(milliseconds: 500));
  _signalPids(pids, ProcessSignal.sigkill);

  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (DateTime.now().isBefore(deadline)) {
    if ((await _alivePids(pids)).isEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void _signalPids(List<int> pids, ProcessSignal signal) {
  for (final pid in pids.reversed) {
    try {
      Process.killPid(pid, signal);
    } catch (_) {}
  }
}

Future<Set<int>> _alivePids(List<int> pids) async {
  final ps = await Process.run('ps', ['-ax', '-o', 'pid=']);
  if (ps.exitCode != 0) return {};
  final alive = <int>{};
  for (final line in (ps.stdout as String).split('\n')) {
    final pid = int.tryParse(line.trim());
    if (pid != null) alive.add(pid);
  }
  return pids.where(alive.contains).toSet();
}

Future<List<int>> _processTree(int rootPid) async {
  final ps = await Process.run('ps', ['-ax', '-o', 'pid=,ppid=']);
  if (ps.exitCode != 0) return [rootPid];
  final children = <int, List<int>>{};
  var rootAlive = false;
  for (final line in (ps.stdout as String).split('\n')) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length < 2) continue;
    final pid = int.tryParse(parts[0]);
    final ppid = int.tryParse(parts[1]);
    if (pid == null || ppid == null) continue;
    if (pid == rootPid) rootAlive = true;
    children.putIfAbsent(ppid, () => []).add(pid);
  }

  final ordered = <int>[];
  void visit(int pid) {
    ordered.add(pid);
    for (final child in children[pid] ?? const <int>[]) {
      visit(child);
    }
  }

  visit(rootPid);
  return rootAlive || ordered.length > 1 ? ordered : <int>[];
}

/// Run [task] over [items] with at most [jobs] running concurrently (a bounded worker pool). Workers
/// pull from a shared queue; the Dart event loop is single-threaded, so `failed.add` from concurrent
/// tasks doesn't race.
Future<void> _runBounded(
  List<_TestSpec> items,
  int jobs,
  Future<void> Function(_TestSpec, int workerSlot) task,
) async {
  final queue = [...items];
  final workers = (jobs < 1 ? 1 : jobs).clamp(1, items.length);
  await Future.wait(
    List.generate(workers, (workerSlot) async {
      while (queue.isNotEmpty) {
        await task(queue.removeAt(0), workerSlot);
      }
    }),
  );
}

// ---- platform resolution: --android boots/reuses an emulator ----

/// The flutter device a launch targets. `--android` targets an emulator PER INSTANCE — the shared seam
/// (`provisionAppInstance`) self-boots + bridges each from the claimed session slot — so here it's just the
/// `android` marker. Otherwise `--platform <d>` (default: the host desktop OS), the desktop sim.
String _resolvePlatform(List<String> args) {
  if (args.contains('--android')) return 'android';
  var platform = Platform.isLinux ? 'linux' : 'macos';
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--platform') platform = args[i + 1];
  }
  return platform;
}

/// Every running emulator serial (`emulator-<port>`) per `adb devices`.
Future<Set<String>> _runningSerials(String sdk) async {
  final res = await Process.run('$sdk/platform-tools/adb', ['devices']);
  final serials = <String>{};
  for (final line in (res.stdout as String).split('\n')) {
    final m = RegExp(r'^(emulator-\d+)\s+device$').firstMatch(line.trim());
    if (m != null) serials.add(m.group(1)!);
  }
  return serials;
}

/// Grace for an EMPTY lock (created, but its owner pid not yet written) before it counts as abandoned —
/// generously longer than the microsecond create→write gap, so a live mid-write claim is never stolen.
const _lockWriteGrace = Duration(seconds: 10);

/// Whether an existing slot lock is STALE — reclaimable. STRICT on live owners: while the recorded owner PID
/// is alive the lock is NEVER stale, however long its boot / first-run SDK+AVD setup takes — so a second
/// session can't steal a slow-but-legitimate claimant that may still return the slot. Reclaim only when the
/// owner PID is gone, or — for a lock whose pid was never written (a claimer that died between create and
/// write) — once it's older than [_lockWriteGrace].
bool _lockIsStale(File lock) {
  int? owner;
  try {
    owner = int.tryParse(lock.readAsStringSync().trim());
  } catch (_) {}
  if (owner != null) {
    // A live owner is never stolen; reclaim only once its process is gone (SIGCONT = harmless probe).
    return !Process.killPid(owner, ProcessSignal.sigcont);
  }
  // No pid yet: a claimer mid-write (µs) or one that died between create and write. Reclaim only past the
  // write grace, which cannot overlap a live mid-write.
  try {
    return DateTime.now().difference(lock.statSync().modified) >
        _lockWriteGrace;
  } catch (_) {
    return false; // vanished/unreadable — let the exclusive-create retry decide
  }
}

/// Machine-global per-slot lock so only ONE session ever boots a given interactive slot. Probe-then-boot is
/// otherwise racy: two `up --android` can both see a slot free, both start `-port N`, and the LOSER's
/// [bootEmulator] then waits on + returns the WINNER's `emulator-N`. Exclusive-create is atomic AND the lock
/// records the owner PID; a held lock is reclaimed only when [_lockIsStale] — a live boot in progress is
/// never stolen.
bool _claimSlotLock(int slot) {
  final lock = File('${simTmpRoot().path}/interactive-slot-$slot.lock');
  try {
    lock.createSync(exclusive: true);
    lock.writeAsStringSync('$pid'); // owner PID for [_lockIsStale]
    return true;
  } catch (_) {
    if (!_lockIsStale(lock))
      return false; // live owner mid-boot — don't steal it
    try {
      lock.deleteSync();
      lock.createSync(
        exclusive: true,
      ); // reclaim; only one wins the exclusive create
      lock.writeAsStringSync('$pid');
      return true;
    } catch (_) {
      return false;
    }
  }
}

void _releaseSlotLock(int slot) {
  try {
    File('${simTmpRoot().path}/interactive-slot-$slot.lock').deleteSync();
  } catch (_) {}
}

// ---- daemon: holds one SimHarness, forwards commands to it ----

Future<void> _serve(List<String> args) async {
  var count = 1;
  // `--instances N`: hold N app windows (each with `count` devices) on the session's ONE regtest, drivable via
  // the eval scope as `instances[K]`. Default 1 (`session` == `instances[0]`).
  var instanceCount = 1;
  // Default: a human owns the keyboard (real typing works, `enter` is rejected). Pass
  // --agent-owns-keyboard for the driver to own text input instead (enables `enter`,
  // blocks the physical keyboard). One mode for the session — no hybrid.
  final agentOwnsKeyboard = args.contains('--agent-owns-keyboard');
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--devices') count = int.parse(args[i + 1]);
    if (args[i] == '--instances') instanceCount = int.parse(args[i + 1]);
  }
  // Regtest is ON by default (the common case is a wallet that can receive); `--no-regtest` opts out.
  final wantRegtest = !args.contains('--no-regtest');

  // SELF-LOG every startup step to serve.log from the very start, ending in a terminal
  // `FSIM_READY` / `FSIM_FAILED` line. `up` launches us detached (our stdio -> /dev/null) and
  // TAILS this file to stream progress to its own stdout and learn the real outcome — so no caller
  // ever has to poll the socket or guess at liveness.
  _stateRoot.createSync(recursive: true);
  final logSink = File('${_stateRoot.path}/serve.log').openWrite();
  final flushTimer = Timer.periodic(
    const Duration(seconds: 1),
    (_) => unawaited(logSink.flush()),
  );
  void serveLog(String s) {
    stderr.writeln(s);
    logSink.writeln(s);
  }

  // A desktop target shares the host filesystem, so its `device-<n>.sock`s are reachable and we run
  // a full SimHarness. A non-desktop target (an Android emulator) does not: those sockets live in
  // the app sandbox, so we run an AppSession (app channel only) and device-channel commands are
  // rejected as host-only (see _dispatch). Drive an emulator session via the in-app slide-in tray.
  late final String platform;
  late final bool isHost;
  late final ServerSocket server;
  final extraDefines = <String, String>{};
  // This session's OWN regtest backend (flat in <dir>/.fsim as regtest.*): started below, held for the daemon's
  // lifetime so it self-reaps on a hard kill (the death-pipe), and stopped in shutdown() on a graceful down.
  RegtestSession? rtSession;
  // Host-only liveness socket the app holds open + exits when it drops, so a hard-killed serve doesn't
  // orphan the app window (the app-side analogue of the regtest death-pipe). Accepted connections are
  // RETAINED in [livenessClients] so they aren't GC'd/finalized (which could close one and make the app
  // exit while we're still alive).
  ServerSocket? livenessSocket;
  final livenessClients = <Socket>{};
  try {
    serveLog('fsim: resolving target …');
    platform = _resolvePlatform(args);
    isHost = _hostPlatforms.contains(platform);
    serveLog('fsim: target $platform (${isHost ? 'host' : 'emulator'})');
    // An android session claims ONE slot, which reserves exactly [maxInstancesPerTest] consecutive emulator
    // indices; more instances would overrun into the NEXT interactive slot (which this session never claimed)
    // and could collide with a concurrent `up --android`. Cap it. Host tiles windows with no such budget.
    if (!isHost && instanceCount > maxInstancesPerTest) {
      throw StateError(
        '--instances $instanceCount --android exceeds the $maxInstancesPerTest emulators a session slot '
        'reserves; use up to $maxInstancesPerTest on android (host has no such limit)',
      );
    }

    // Regtest: this session owns its OWN backend flat in <dir>/.fsim (regtest.*) — started here, reaped on
    // shutdown (or self-reaped via the death-pipe on a hard kill), so `down` leaves no orphan and no shared
    // node is touched. On host the app reaches its unix control socket + electrum TCP directly; on android the
    // SHARED SEAM bridges each emulator + supplies the regtest defines per-instance (fixed baked ports +
    // per-serial adb-reverse via bridgeRegtestToEmulator), reaped with each instance in tearDown — so there's
    // nothing serve-side to do for android here.
    if (wantRegtest) {
      serveLog('fsim: starting session regtest under ${_stateRoot.path} …');
      rtSession = await startRegtestSession(_stateRoot);
      if (isHost) extraDefines.addAll(rtSession.hostDefines);
    }

    // Host only: bind a liveness socket the app holds open + exits when it drops, so a hard-killed serve
    // doesn't orphan the app window. An emulator app can't reach a host unix socket, and its window IS the
    // emulator (owned separately), so this is host-desktop-only. Wired to the app via the env below.
    if (isHost) {
      final livenessPath = '${_stateRoot.path}/liveness.sock';
      try {
        File(livenessPath).deleteSync();
      } catch (_) {}
      livenessSocket = await ServerSocket.bind(
        InternetAddress(livenessPath, type: InternetAddressType.unix),
        0,
      );
      // Accept + RETAIN each connection (never read/write): held for the session so it isn't GC'd; dropped
      // from the set when it closes. When this daemon dies the OS closes the socket → the app reads EOF.
      livenessSocket.listen((conn) {
        livenessClients.add(conn);
        conn.listen(
          (_) {},
          onDone: () => livenessClients.remove(conn),
          onError: (_) => livenessClients.remove(conn),
          cancelOnError: true,
        );
      });
      extraDefines['SIM_SERVE_LIVENESS_SOCKET'] = livenessPath;
    }

    serveLog(
      'fsim: launching $instanceCount app instance(s) on $platform (first build is slow) …',
    );
    final launched = <AppSession>[];
    // BOTH host and android provision through the SHARED seam (the same Scenario.provisionAppInstance the tests
    // use) on the session's ONE regtest — no duplicated launch loop, no second android-emulator model.
    // instances[0] is `session`; the seam attaches the regtest (android: self-boots + bridges each emulator +
    // supplies its defines), so `instances[K].faucet()` reaches THIS session's backend.
    Future<void> provisionN(int slotBase) async {
      for (var i = 0; i < instanceCount; i++) {
        launched.add(
          await Scenario.provisionAppInstance(
            index: i,
            total: instanceCount,
            slot: slotBase,
            flutterDevice: platform,
            chain: rtSession,
            deviceCount: count,
            extraDartDefines: extraDefines,
            appDirRoot: _stateRoot,
            agentOwnsKeyboard: agentOwnsKeyboard,
            logSink: logSink,
          ),
        );
      }
    }

    if (isHost) {
      // Host windows tile from slot 0 (no emulator port budget).
      await provisionN(0);
    } else {
      // Android: CLAIM a session slot ABOVE the test workers' range, provision N under its lock so a concurrent
      // `up --android` can't grab it until its emulators are running, then RELEASE (the running emulators ARE
      // the reservation). Each instance self-boots emulatorPort(interactiveGlobalSlot(s) * maxInstancesPerTest
      // + i) + bridges it.
      final sdk = androidSdkRoot();
      var claimed = false;
      for (var s = 0; s < maxInteractiveSessions; s++) {
        if (!_claimSlotLock(s)) continue;
        final slotBase = interactiveGlobalSlot(s);
        if ((await _runningSerials(
          sdk,
        )).contains(emulatorSerial(slotBase * maxInstancesPerTest))) {
          _releaseSlotLock(s);
          continue; // a live session already holds this slot's emulator(s) — advance.
        }
        serveLog(
          'fsim: claimed android session slot $s ($instanceCount emulator(s)) …',
        );
        try {
          await provisionN(slotBase);
          claimed = true;
        } catch (_) {
          // Tear down anything that booted so a failed bring-up leaves no orphan emulators.
          for (final h in launched) {
            try {
              await h.tearDown();
            } catch (_) {}
          }
          launched.clear();
          rethrow;
        } finally {
          _releaseSlotLock(s);
        }
        break;
      }
      if (!claimed) {
        throw StateError(
          'fsim: all $maxInteractiveSessions interactive android session slots are busy — `down` another first',
        );
      }
      // Record ALL N emulator serials so a HARD-killed session's `clean` reaps EXACTLY them (a graceful `down`
      // reaps via each instance's tearDown in shutdown()).
      File('${_stateRoot.path}/emulator-serials').writeAsStringSync(
        launched.map((h) => h.emulatorSerial).whereType<String>().join('\n'),
      );
    }
    instances = launched;

    // Enable THIS daemon's VM service so `fsim eval`/`repl` can ship live Dart to it against the console
    // scope (`session` / `instances[K]`), and publish the URI for the client. The daemon isolate is long-lived,
    // so state persists across evals. controlWebServer starts the service at runtime — no launch flag needed.
    final vmInfo = await developer.Service.controlWebServer(
      enable: true,
      silenceOutput: true,
    );
    final vmUri = vmInfo.serverUri;
    if (vmUri != null) {
      File('${_stateRoot.path}/vmservice.uri').writeAsStringSync('$vmUri');
    }

    try {
      File(_socketPath).deleteSync();
    } catch (_) {}
    server = await ServerSocket.bind(
      InternetAddress(_socketPath, type: InternetAddressType.unix),
      0,
    );
  } catch (e, st) {
    serveLog('FSIM_FAILED: $e');
    logSink.writeln('$st');
    await logSink.flush();
    exit(1);
  }
  serveLog('FSIM_READY $_socketPath');
  stdout.writeln('FSIM_READY $_socketPath');

  // Idempotent AND awaitable: `down`, a signal, and the app-death watcher can all race in here;
  // they share ONE cleanup future, so EVERY caller awaits the same cleanup to FINISH before its
  // exit(0) runs. (A bare boolean guard would let a second caller return + exit mid-cleanup,
  // killing the process before the first's app-dir delete / log flush completed.)
  Future<void>? shutdownFuture;
  Future<void> shutdown() {
    return shutdownFuture ??= () async {
      flushTimer.cancel();
      await server.close();
      try {
        File(_socketPath).deleteSync();
      } catch (_) {}
      try {
        File('${_stateRoot.path}/vmservice.uri').deleteSync();
      } catch (_) {}
      // tearDown reaps the app orderly on a graceful down; only THEN close the liveness socket, so its
      // watcher stays a pure hard-kill backstop (never fires mid-teardown). Best-effort per instance so one
      // hiccup doesn't strand the others' windows.
      for (final h in instances) {
        try {
          await h.tearDown();
        } catch (_) {}
      }
      for (final c in livenessClients.toList()) {
        try {
          await c.close();
        } catch (_) {}
      }
      await livenessSocket?.close();
      // Gracefully reap this session's regtest (the death-pipe is the backstop for a hard kill).
      await rtSession?.stop();
      // The instances (+ each one's emulator + regtest bridge) were reaped via tearDown above; just drop the
      // hard-kill record so `clean` doesn't later try to reap already-dead serials. (`clean` recovers a
      // HARD-killed session's emulators from this file.)
      if (args.contains('--android')) {
        try {
          File('${_stateRoot.path}/emulator-serials').deleteSync();
        } catch (_) {}
      }
      await logSink.flush();
      await logSink.close();
    }();
  }

  for (final sig in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
    sig.watch().listen((_) async {
      await shutdown();
      exit(0);
    });
  }

  // The daemon must not outlive its app: if the app dies (e.g. you close its window — the last
  // window closing terminates it and exits `flutter run`), shut down so the control socket goes
  // away and `./fsim up` RELAUNCHES instead of reporting already:true. (The captured app output
  // already logs the app finishing; awaiting shutdown() shares the one cleanup before exit.)
  for (final h in instances) {
    unawaited(
      h.appExitCode.then((_) async {
        await shutdown();
        exit(0);
      }),
    );
  }

  await for (final conn in server) {
    final lines = conn
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      if (line.trim().isEmpty) continue;
      final (reply, down) = await _dispatch(
        line,
        instances.first,
        agentOwnsKeyboard,
        wantRegtest,
        count,
        platform,
      );
      conn.write('${jsonEncode(reply)}\n');
      await conn.flush();
      if (down) {
        await conn.close();
        await shutdown();
        exit(0);
      }
    }
  }
}

/// Forward one command to a [SimHarness] method. Returns the reply and whether to shut
/// down. A failing command returns `{ok:false,error}` but keeps the daemon (and the
/// app) alive, so the next command can try something else.
Future<(Map<String, dynamic>, bool)> _dispatch(
  String line,
  AppSession h,
  bool agentOwnsKeyboard,
  bool withRegtest,
  int launchDeviceCount,
  String platform,
) async {
  final Map<String, dynamic> req;
  try {
    req = jsonDecode(line) as Map<String, dynamic>;
  } catch (e) {
    return ({'ok': false, 'error': 'bad json: $e'}, false);
  }
  // Only the daemon-control verbs remain here — the drive surface (device driving, chain, wallet, …) moved to
  // `fsim eval "session.…"` against this daemon's live harness.
  final cmd = req['cmd'];
  try {
    switch (cmd) {
      case 'info':
        // The daemon's LAUNCH shape — `./fsim up` compares `count` against the requested
        // --devices to decide whether an already-live daemon satisfies the request. It's the
        // launch count, NOT the live count, so runtime adds (tray / add-device) don't flip
        // idempotence. `currentDevices` reports the live fleet (the app-side source of truth) for
        // introspection.
        final current = (await h.deviceNumbers()).length;
        return (
          {
            'ok': true,
            'count': launchDeviceCount,
            // How many app instances the serve holds (`up --instances N`); part of the shape `up`
            // idempotence checks, so a 2-instance request won't reuse a 1-instance daemon.
            'instances': instances.length,
            'currentDevices': current,
            'regtest': withRegtest,
            'keyboard': agentOwnsKeyboard,
            // The launch platform is part of the observable shape so `up` won't treat an Android
            // (AppSession) daemon and a desktop request as interchangeable.
            'platform': platform,
          },
          false,
        );
      case 'shot':
        // No path -> the session dir (cleaned up on teardown); an explicit path is kept.
        final reqPath = req['path'] as String?;
        final path = reqPath == null
            ? await h.screenshot('manual')
            : await h.screenshot('manual', keep: reqPath);
        return ({'ok': true, 'path': path}, false);
      case 'down':
        return ({'ok': true, 'down': true}, true);
      default:
        return ({'ok': false, 'error': 'unknown cmd: ${req['cmd']}'}, false);
    }
  } catch (e) {
    return ({'ok': false, 'error': '$e'}, false);
  }
}

// ---- client: run one command against the running daemon ----

/// Connect to the daemon, waiting for it to come up rather than failing instantly:
/// `./fsim serve` builds + launches the app (cold builds take a while), so a `./fsim <cmd>`
/// fired right after should just block until the control socket is ready — no external
/// "wait for FSIM_READY" polling. Retries until [FSIM_WAIT_SECS] (default 300s), then
/// gives up so a genuine missing-daemon mistake still errors. Announces once so a wait is
/// visible, not a silent hang.
Future<Socket> _connectWaiting() async {
  final addr = InternetAddress(_socketPath, type: InternetAddressType.unix);
  final waitSecs =
      int.tryParse(Platform.environment['FSIM_WAIT_SECS'] ?? '') ?? 300;
  final deadline = DateTime.now().add(Duration(seconds: waitSecs));
  var announced = false;
  while (true) {
    try {
      return await Socket.connect(addr, 0);
    } on SocketException {
      if (DateTime.now().isAfter(deadline)) rethrow;
      if (!announced) {
        stderr.writeln('fsim: waiting for the sim daemon to come up …');
        announced = true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }
}

Future<void> _client(List<String> args) async {
  final req = _argsToCommand(args);
  if (req == null) {
    stderr.writeln(_usage);
    exit(2);
  }
  final Socket socket;
  try {
    socket = await _connectWaiting();
  } catch (e) {
    stderr.writeln('fsim: no daemon at $_socketPath (run `fsim serve`): $e');
    exit(1);
  }
  socket.write('${jsonEncode(req)}\n');
  await socket.flush();
  final reply = await socket
      .cast<List<int>>()
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .firstWhere((l) => l.trim().isNotEmpty);
  await socket.close();
  stdout.writeln(reply);
  exit((jsonDecode(reply) as Map<String, dynamic>)['ok'] == true ? 0 : 1);
}

/// Translate `fsim <cmd> ...` argv into the wire command, or null if unrecognized. Only the daemon-control
/// verbs remain — the drive surface (tap/chain/hold/enter/…) is now `fsim eval "session.…"` (see
/// `fsim eval --help` / test_driver/COMMANDS.md).
Map<String, dynamic>? _argsToCommand(List<String> args) {
  final pos = args.where((a) => !a.startsWith('--')).toList();
  if (pos.isEmpty) return null;
  switch (pos.first) {
    case 'info':
      return {'cmd': 'info'};
    case 'shot':
      return {'cmd': 'shot', if (pos.length > 1) 'path': pos[1]};
    case 'down':
      return {'cmd': 'down'};
    default:
      return null;
  }
}
