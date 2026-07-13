// The sim harness: one object ([AppSession]) that brings up the sim app + virtual devices, drives
// BOTH the app widget tree and the devices through one ergonomic API, and tears everything down (app
// process, the disposable app dir, all screenshots) as a unit.
//
//   - app (Flutter widget tree): driven by semantic label over flutter_driver / the VM service.
//     `app.*` + `screenshot()`.
//   - device (a framebuffer + touchscreen): driven via [AppDevice] (`device(n).*`) over the SAME app
//     channel — driver-data → the in-process `simDevicePool`.
//
// ONE transport (the app channel) on every platform: it works wherever flutter_driver can reach the
// VM service, including an adb-forwarded Android emulator. (Devices were once ALSO reachable over
// host `device-<n>.sock` sockets — a second transport that only worked on desktop; that split, and
// the [SimHarness] vs [AppSession] shapes it forced, are gone — see app-channel-only-device-driving.)
//
// Lives in test_driver/ so flutter_driver stays a dev dependency. Used by the e2e driver tests and
// by `fsim`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';
import 'package:frostsnap/sim_faucet.dart';

import 'emulator_lifecycle.dart' show shouldKillEmulatorOnTearDown;
import 'ime_text.dart' show encodeImeText, imeTextPreflightError;
import 'label_diagnostics.dart'
    show diagnoseDriverFailure, tapUntilExhaustedError;
import 'tooltip_resolve.dart' show resolveTooltip;
import 'emulator.dart'
    show
        bootEmulator,
        emulatorAvd,
        emulatorPort,
        emulatorSerial,
        ensureAvd,
        killEmulator,
        maxInstancesPerTest,
        provisionEmulator;
import 'regtest.dart'
    show
        RegtestSession,
        androidBridgeControlSocket,
        androidBridgeElectrumUrl,
        androidSdkRoot,
        bridgeRegtestToEmulator,
        startRegtestSession;

/// A scenario prints this (then exits 0) to declare itself SKIPPED — e.g. a host-only dual-instance
/// scenario running on an emulator. The test runner maps exit-0-with-this-marker to SKIPPED rather than
/// PASSED, so a never-ran test can't masquerade as a silent pass.
const simTestSkippedMarker = 'SIM_TEST_SKIPPED';

/// Root for all sim temp artifacts — disposable app dirs, the fsim control socket,
/// ad-hoc screenshots — grouped under one folder instead of loose in the system temp
/// root. Created on demand.
Directory simTmpRoot() {
  final dir = Directory('${Directory.systemTemp.path}/frostsnap-sim');
  dir.createSync(recursive: true);
  return dir;
}

/// Grow the sim fleet to EXACTLY [target] devices: [count] reads the current device count, [addOne]
/// hot-plugs one and returns the new count. This is how an android test's device count is delivered at
/// runtime — a shared APK can't bake a per-test count and the emulator app can't read the host env, so
/// the count is grown over the app channel after launch instead. The final count is ASSERTED to equal
/// [target]: a shared-APK count mismatch is a hard setup failure, not a silent "3-device test runs with
/// 1 and still passes the early steps". A stuck add (one that doesn't grow the fleet) throws rather than
/// spin. On host this is a no-op grow whose equality check just confirms the env-loaded count.
Future<void> growFleetTo(
  int target,
  Future<int> Function() count,
  Future<int> Function() addOne,
) async {
  for (var n = await count(); n < target;) {
    final grown = await addOne();
    if (grown <= n) {
      throw StateError('add-device did not grow the fleet ($n -> $grown)');
    }
    n = grown;
  }
  final fleet = await count();
  if (fleet != target) {
    throw StateError(
      'sim fleet has $fleet device(s), expected exactly $target — '
      'runtime device-count delivery is wrong',
    );
  }
}

/// Eval/test introspection for the app's current semantic-label surface.
///
/// The guaranteed surface is the same set of onstage labels that [AppSession.tap], [AppSession.waitFor],
/// and [AppSession.exists] target through FlutterDriver's `find.bySemanticsLabel`. Extra JSON fields are
/// diagnostic best effort.
class AppSemanticsInspector {
  final AppSession _session;

  AppSemanticsInspector._(this._session);

  Future<List<Map<String, dynamic>>> _nodes() async {
    final root =
        jsonDecode(await _session._requestData('semantics-snapshot'))
            as Map<String, dynamic>;
    final nodes = root['nodes'] as List<dynamic>? ?? const <dynamic>[];
    return [for (final node in nodes) Map<String, dynamic>.from(node as Map)];
  }

  /// Structured JSON for scripts/tests. Prefer [labels] or [grep] for the stable targeting contract.
  Future<String> json() => _session._requestData('semantics-snapshot');

  /// Unique targetable semantic labels, in onstage traversal order.
  Future<List<String>> labels() async {
    final seen = <String>{};
    final out = <String>[];
    for (final node in await _nodes()) {
      final label = node['label'] as String?;
      if (label != null && label.isNotEmpty && seen.add(label)) {
        out.add(label);
      }
    }
    return out;
  }

  /// Unique targetable labels whose text contains [pattern] (`String`) or matches it (`RegExp`).
  Future<List<String>> grep(Pattern pattern) async {
    return [
      for (final label in await labels())
        if (_matches(pattern, label)) label,
    ];
  }

  /// Compact human-readable snapshot for terminal use.
  Future<String> pretty() async {
    final b = StringBuffer();
    for (final node in await _nodes()) {
      final label = node['label'] as String?;
      final value = node['value'] as String?;
      final hint = node['hint'] as String?;
      final role = node['role'] as String?;
      final actions = (node['actions'] as List<dynamic>?)?.cast<String>();
      final flags = (node['flags'] as List<dynamic>?)?.cast<String>();
      final rawDepth = node['depth'] as int? ?? 0;
      final depth = rawDepth < 0 ? 0 : (rawDepth > 10 ? 10 : rawDepth);
      final parts = <String>[
        if (label != null && label.isNotEmpty) '"${_oneLine(label)}"',
        if (value != null && value.isNotEmpty) 'value="${_oneLine(value)}"',
        if (hint != null && hint.isNotEmpty) 'hint="${_oneLine(hint)}"',
        if (role != null && role != 'none') 'role=$role',
        if (actions != null && actions.isNotEmpty)
          'actions=${actions.join(',')}',
        if (flags != null && flags.isNotEmpty) 'flags=${flags.join(',')}',
      ];
      if (parts.isEmpty) continue;
      b.writeln('${''.padLeft(depth * 2)}- ${parts.join(' ')}');
    }
    return b.toString().trimRight();
  }

  bool _matches(Pattern pattern, String label) {
    if (pattern is RegExp) return pattern.hasMatch(label);
    return label.contains(pattern.toString());
  }

  String _oneLine(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// A scenario's PRIVATE regtest chain (its own backend), OWNED by the [Scenario] and reaped on
/// teardown. App instances launched against the scenario BORROW it (they never reap it). On Android the
/// app reaches it over a per-instance adb-reverse bridge set up + torn down by each [AppSession]; on host
/// the app reaches the session's unix socket + electrum directly.
class _ScenarioRegtest {
  final RegtestSession session;

  /// The launch config that points the app's regtest wallet + tray faucet at THIS session (host: the
  /// real endpoints; android: the fixed bridge loopback ports each emulator adb-reverses to the session).
  final Map<String, String> defines;

  _ScenarioRegtest(this.session, this.defines);

  Future<void> stop() => session.stop();
}

/// A running scenario: it owns the optional per-session regtest CHAIN and every app instance launched
/// against it, and tears them all down as a unit. The chain is a SCENARIO resource — owned by no single
/// app — so a scenario can launch TWO instances that share one chain (a cross-wallet send/receive), and
/// single-instance ([AppSession.runScenario]) is just the N=1 case of this one lifecycle. The chain's
/// [RegtestSession] is held here for the whole scenario, so its death-pipe write end stays open
/// (regtest-session-lifetime): drop this reference and a per-session backend could orphan.
class Scenario {
  final String name;
  final String flutterDevice;
  final _ScenarioRegtest? _regtest;
  final List<AppSession> _sessions = [];

  Scenario._(this.name, this.flutterDevice, this._regtest);

  /// Resolve the target device (explicit, else `SIM_FLUTTER_DEVICE`, else macos), start a PRIVATE
  /// per-session regtest chain if [withRegtest], run [body], capture diagnostics for EVERY launched
  /// instance on failure, then tear all instances down, reap the chain, and assert no residue.
  static Future<void> run(
    String name,
    Future<void> Function(Scenario s) body, {
    String? flutterDevice,
    bool withRegtest = false,
  }) async {
    final device =
        flutterDevice ?? Platform.environment['SIM_FLUTTER_DEVICE'] ?? 'macos';
    if (Platform.environment['SIM_REQUIRE_FLUTTER_DEVICE'] == '1' &&
        flutterDevice == null &&
        Platform.environment['SIM_FLUTTER_DEVICE'] == null) {
      throw StateError(
        'SIM_REQUIRE_FLUTTER_DEVICE=1 but SIM_FLUTTER_DEVICE is unset',
      );
    }
    final regtest = withRegtest ? await _startChain(device) : null;
    final s = Scenario._(name, device, regtest);
    try {
      await body(s);
    } catch (error, stack) {
      for (final h in s._sessions) {
        await h._captureFailure(name, error, stack);
      }
      await s._pauseForInspection();
      rethrow;
    } finally {
      await s._tearDown();
    }
    for (final h in s._sessions) {
      if (await h.appDir.exists()) {
        throw StateError('teardown left residue: ${h.appDir.path}');
      }
    }
  }

  static bool _isHost(String device) =>
      const {'macos', 'linux', 'windows'}.contains(device);

  /// Run a scenario with [instances] app instances (each provisioned via [provisionInstance] — the ONE
  /// backend-aware seam) sharing one regtest chain. The body is backend-AGNOSTIC: it drives the given
  /// [AppSession]s identically whether each is a host window or its own android emulator. Runs on every
  /// backend at any instance count up to [_maxInstances] (host = N windows, android = N emulators).
  static Future<void> runInstances(
    String name,
    int instances,
    Future<void> Function(List<AppSession> apps, Scenario s) body, {
    int deviceCount = 1,
    String? flutterDevice,
    bool withRegtest = false,
    Map<String, String> extraDartDefines = const {},
  }) async {
    if (instances > _maxInstances) {
      throw StateError(
        'runInstances($name): $instances instances exceeds the fixed max $_maxInstances — bump '
        'Scenario._maxInstances (and provision more AVDs).',
      );
    }
    await run(name, flutterDevice: flutterDevice, withRegtest: withRegtest, (
      s,
    ) async {
      final apps = <AppSession>[];
      for (var i = 0; i < instances; i++) {
        apps.add(
          await s.provisionInstance(
            i,
            totalInstances: instances,
            deviceCount: deviceCount,
            extraDartDefines: extraDartDefines,
          ),
        );
      }
      await body(apps, s);
    });
  }

  /// Two app instances (A, B) sharing ONE regtest chain — the cross-wallet send/receive shape. A thin
  /// [runInstances] wrapper (host = two windows, android = two emulators).
  static Future<void> runDual(
    String name,
    Future<void> Function(AppSession a, AppSession b, Scenario s) body, {
    String? flutterDevice,
  }) => runInstances(
    name,
    2,
    (apps, s) => body(apps[0], apps[1], s),
    flutterDevice: flutterDevice,
    withRegtest: true,
  );

  /// The scenario's shared faucet (its chain). The test drives funding/mining here. Throws if the
  /// scenario ran without regtest.
  Future<SimFaucet> faucet() {
    final r = _regtest;
    if (r == null) {
      throw StateError(
        'scenario has no regtest backend (run with withRegtest: true)',
      );
    }
    return r.session.faucet();
  }

  /// Launch an app instance against this scenario's chain, grow its fleet to exactly [deviceCount], and
  /// register it for teardown. The app BORROWS the chain (for [AppSession.faucet]); the scenario reaps
  /// it. [windowSlot] overrides the inherited window position so a second instance doesn't stack on the
  /// first (host-visual only). [diagLabel] namespaces this instance's failure diagnostics (e.g. `a`/`b`)
  /// so multiple instances don't clobber each other's artifacts.
  /// Provision app instance [index] of [total] on the shared regtest [chain] — THE single backend-aware launch
  /// seam, shared by the interactive serve (`fsim up --instances N`) and [Scenario] (tests). HOST: a
  /// window-slot app on this machine. ANDROID: this instance's OWN emulator — boot it, bridge the shared chain
  /// to it (per-serial adb-reverse), run the app on it; its emulator + bridge are reaped in
  /// [AppSession.tearDown]. Attaches [chain] so `faucet()` works. The caller supplies the launch defines (incl.
  /// SIM_REGTEST_*) and layers its own bookkeeping — the Scenario grows the fleet + waits for chain recognition
  /// ([provisionInstance]); the serve just holds the instances.
  static Future<AppSession> provisionAppInstance({
    required int index,
    required int total,
    required int slot,
    required String flutterDevice,
    required RegtestSession? chain,
    int deviceCount = 1,
    Map<String, String> extraDartDefines = const {},
    Directory? appDirRoot,
    bool agentOwnsKeyboard = true,
    // EXPLICIT session policy, not ambient env: only the TEST path (provisionInstance, whose runner
    // validated the single-test shape) derives this from SIM_KEEP_EMULATOR. The interactive serve
    // never sets it, so `SIM_KEEP_EMULATOR=1 fsim up` cannot silently skip the down-time kill.
    bool keepEmulator = false,
    IOSink? logSink,
  }) async {
    // [slot] is an EXPLICIT input, not ambient env: the test path passes its per-worker FROSTSNAP_SIM_WINDOW_SLOT
    // and the interactive serve passes a slot it CLAIMED (a serve process can't set its own env for later reads).
    final deviceIndex = slot * _maxInstances + index;
    final diagLabel = total > 1
        ? String.fromCharCode('a'.codeUnitAt(0) + index)
        : null;

    if (_isHost(flutterDevice)) {
      final h = await AppSession.launch(
        deviceCount: deviceCount,
        flutterDevice: flutterDevice,
        agentOwnsKeyboard: agentOwnsKeyboard,
        extraDartDefines: extraDartDefines,
        windowSlot: total == 1 ? null : deviceIndex,
        appDirRoot: appDirRoot,
        logSink: logSink,
      );
      h._chain = chain;
      h._diagLabel = diagLabel;
      return h;
    }

    final sdk = androidSdkRoot();
    final avd = emulatorAvd(deviceIndex);
    final serial = emulatorSerial(deviceIndex);
    await ensureAvd(sdk, avd);
    Future<void> Function()? unbridge;
    try {
      await bootEmulator(sdk, avd: avd, port: emulatorPort(deviceIndex));
      await provisionEmulator(sdk, serial);
      var launchDefines = extraDartDefines;
      if (chain != null) {
        final bridge = await bridgeRegtestToEmulator(chain, serial);
        unbridge = bridge.unbridge;
        // The SEAM owns the android regtest defines (the fixed bridge endpoints) — so a DIRECT caller (the
        // interactive serve) reaches the chain without threading them itself; the test path's identical
        // `_regtest.defines` merge idempotently.
        launchDefines = {...extraDartDefines, ...bridge.defines};
      }
      final h = await AppSession.launch(
        deviceCount: deviceCount,
        flutterDevice: serial,
        agentOwnsKeyboard: agentOwnsKeyboard,
        extraDartDefines: launchDefines,
        appDirRoot: appDirRoot,
        logSink: logSink,
      );
      h._chain = chain;
      h._diagLabel = diagLabel;
      h._emulatorSerial = serial;
      h._keepEmulator = keepEmulator;
      h._unbridge = unbridge;
      return h;
    } catch (_) {
      try {
        await unbridge?.call();
      } catch (_) {}
      try {
        await killEmulator(sdk, serial);
      } catch (_) {}
      rethrow;
    }
  }

  /// The FIXED stride for the per-instance device index (shared with the runner), so an emulator's
  /// port/AVD (or a host window slot) never collides across concurrent workers OR instances.
  static const _maxInstances = maxInstancesPerTest;

  /// Provision app instance [index] of [totalInstances] for THIS scenario: the shared [provisionAppInstance]
  /// seam (host window / android emulator on the scenario's chain) PLUS the test bookkeeping — register for
  /// teardown, grow the fleet to [deviceCount], and wait for the chain-recognition handshake before driving.
  Future<AppSession> provisionInstance(
    int index, {
    required int totalInstances,
    int deviceCount = 1,
    Map<String, String> extraDartDefines = const {},
  }) async {
    final slot =
        int.tryParse(Platform.environment['FROSTSNAP_SIM_WINDOW_SLOT'] ?? '') ??
        0;
    final h = await provisionAppInstance(
      index: index,
      total: totalInstances,
      slot: slot,
      flutterDevice: flutterDevice,
      chain: _regtest?.session,
      deviceCount: deviceCount,
      extraDartDefines: {...extraDartDefines, ...?_regtest?.defines},
      // The TEST path is the only reader of SIM_KEEP_EMULATOR (the runner validated the single-test
      // shape and forwards the env); the interactive serve never sets keepEmulator.
      keepEmulator: Platform.environment['SIM_KEEP_EMULATOR'] == '1',
    );
    // Register BEFORE growFleetTo so a stuck grow still reaps this instance (+ its emulator) in _tearDown.
    _sessions.add(h);
    await growFleetTo(
      deviceCount,
      () async => (await h.deviceNumbers()).length,
      h.addDevice,
    );
    // Wait until every launch-connected device has finished the announce handshake (recognized SET ==
    // connected chain) before the scenario drives, so flows never race the per-device UI under load.
    await h._awaitChainRecognized();
    return h;
  }

  /// When `SIM_PAUSE_ON_FAILURE=1`, hold the launched app window(s) alive for `SIM_PAUSE_SECS` (default
  /// 120) after a failure instead of tearing down — so a human can WATCH the failed UI live, and we get
  /// a timestamped screenshot trail (`paused-N.png`) showing whether a stuck dialog RECOVERS as the
  /// parallel load lifts (a load-induced lag) or stays stuck forever (a real deadlock). Diagnostic only.
  Future<void> _pauseForInspection() async {
    if (Platform.environment['SIM_PAUSE_ON_FAILURE'] != '1') return;
    final secs =
        int.tryParse(Platform.environment['SIM_PAUSE_SECS'] ?? '') ?? 120;
    final artifactsDir = Platform.environment['SIM_TEST_ARTIFACTS_DIR'];
    stderr.writeln(
      'SIM_PAUSE_ON_FAILURE: holding ${_sessions.length} window(s) alive ${secs}s '
      'for inspection (watch whether the stuck UI recovers as load lifts)',
    );
    final deadline = DateTime.now().add(Duration(seconds: secs));
    for (var i = 0; DateTime.now().isBefore(deadline); i++) {
      await Future<void>.delayed(const Duration(seconds: 3));
      for (final h in _sessions) {
        final label = h._diagLabel == null ? '' : '${h._diagLabel}-';
        try {
          await h.screenshot(
            'paused-$i',
            keep: artifactsDir != null && artifactsDir.isNotEmpty
                ? '$artifactsDir/${label}paused-$i.png'
                : null,
          );
        } catch (_) {}
      }
    }
  }

  Future<void> _tearDown() async {
    // Tear the apps down FIRST, then reap the shared chain — so no app is still talking to a chain
    // that's being killed. RegtestSession.stop also closes its death-pipe write end.
    Object? firstError;
    for (final h in _sessions) {
      try {
        await h.tearDown();
      } catch (e) {
        firstError ??= e;
      }
    }
    final r = _regtest;
    if (r != null) {
      try {
        await r.stop();
      } catch (e) {
        firstError ??= e;
      }
    }
    if (firstError != null) throw firstError;
  }

  /// Start an ISOLATED regtest backend for ONE scenario (its own chain) + the launch config that points
  /// apps at it. On host the app reaches the session's unix control socket + electrum TCP directly; on
  /// an Android emulator [device] those host endpoints are unreachable, so bridge them to THAT emulator
  /// (adb-reverse electrs + a unix→TCP faucet proxy) and point the app at the bridge. The dir is
  /// `rt-$pid` (one scenario per test process), kept SHORT so the control socket stays under the
  /// unix-socket path limit (the scenario name lives in the test's own logs).
  static Future<_ScenarioRegtest> _startChain(String device) async {
    final session = await startRegtestSession(
      Directory('${simTmpRoot().path}/rt-$pid'),
    );
    // The app's regtest endpoints: on host, the session's real electrum/control-socket directly; on
    // android, the FIXED bridge loopback ports the shared APK bakes in — each instance's own emulator gets
    // a per-serial adb-reverse of them to this session in [provisionInstance] (so N emulators share one
    // chain without colliding). No bridge here anymore: the emulator(s) don't exist until provisioned.
    return _ScenarioRegtest(
      session,
      _isHost(device)
          ? session.hostDefines
          : {
              'SIM_REGTEST_ELECTRUM_URL': androidBridgeElectrumUrl,
              'SIM_REGTEST_CONTROL_SOCKET': androidBridgeControlSocket,
            },
    );
  }
}

/// Thrown by the text-entry verbs when the session lacks the agent-owned keyboard. [toString] is JUST the
/// message (no `Bad state`/`Exception` prefix) so `fsim eval` surfaces the fix directly.
class AgentKeyboardRequired implements Exception {
  final String message;
  AgentKeyboardRequired(this.message);
  @override
  String toString() => message;
}

/// A launched sim app: the Flutter process + FlutterDriver over the (possibly adb-forwarded) VM
/// service. Drives the app widget tree by semantic label (`app.*` + `screenshot()`) AND the virtual
/// devices ([device] → [AppDevice]) over the SAME app channel, so it's the ONE session shape for host
/// and emulator alike (`SimHarness` is now an alias for it).
class AppSession {
  final Process _appProcess;
  final Directory appDir;
  final FlutterDriver driver;
  final List<String> _appLog;
  final String flutterDevice;
  int _shotSeq = 0;

  /// The scenario's regtest chain, if any — a BORROWED reference (see [faucet]). The [Scenario] owns
  /// the chain's lifetime and reaps it; this app instance never stops it (and never closes its
  /// death-pipe). Null when the scenario ran without regtest.
  RegtestSession? _chain;

  /// Failure-diagnostics sub-label (e.g. `a`/`b` for a dual-instance scenario): non-null writes this
  /// instance's artifacts under `<dir>/<label>/` so instances don't clobber each other; null keeps the
  /// flat single-instance layout.
  String? _diagLabel;

  /// When this instance provisioned its OWN android emulator (the app-instance seam on android), the
  /// emulator's serial + the teardown of its per-serial regtest bridge — reaped in [tearDown]. Both null
  /// on host (a window instance) and on android tests without a chain (no bridge).
  String? _emulatorSerial;

  /// EXPLICIT keep-on-teardown policy, set ONLY by the provisioning seam (the runner-validated test
  /// path). Never read from the ambient environment here: an env read would let
  /// `SIM_KEEP_EMULATOR=1 fsim up` make a later `down` silently skip the kill and report success.
  bool _keepEmulator = false;
  Future<void> Function()? _unbridge;

  /// The android emulator serial this instance self-booted via the seam, or null on host. The interactive
  /// serve records these so `down`/`clean` reap EXACTLY the emulators it provisioned (never a global sweep).
  String? get emulatorSerial => _emulatorSerial;

  /// Whether the DRIVER owns text input (`--agent-owns-keyboard`). True routes text through the driver's mock
  /// input so [enterText] works (but the real keyboard is blocked); false — the `fsim up` default, so a human
  /// can type in the GUI — hands the keyboard to the app, and the text-entry verbs fail fast with a clear
  /// message instead of a cryptic driver `Bad state`.
  final bool agentOwnsKeyboard;

  AppSession(
    this._appProcess,
    this.appDir,
    this.driver,
    this._appLog,
    this.flutterDevice,
    this.agentOwnsKeyboard,
  ) {
    // Record the app's exit so the failure classifier can consult it WITHOUT awaiting — an OOM
    // force-stop mid-drive must classify as "app exited", not as a label/connection problem.
    unawaited(_appProcess.exitCode.then((c) => _appExitStatus = c));
  }

  /// Cached completion of [appExitCode]; null while the app is alive.
  int? _appExitStatus;

  SimFaucet? _faucet;

  /// The session's faucet, over the BORROWED [_chain] (the [Scenario]/serve owns the chain). CACHED and
  /// reused: the `fsim eval` console calls this repeatedly, and a fresh connection per call would pile up on
  /// the long-lived daemon isolate and stall the faucet server. Throws if the session has no regtest backend.
  Future<SimFaucet> faucet() async {
    final c = _chain;
    if (c == null) {
      throw StateError(
        'no regtest backend on this session (an offline serve, or a scenario run withRegtest: false)',
      );
    }
    return _faucet ??= await c.faucet();
  }

  /// Close + drop the cached [faucet] connection (if any). The `fsim eval` console calls this after EACH eval
  /// so the backend's SINGLE-connection control server (`tools/sim_regtest`) is freed for the app tray +
  /// `fsim regtest` CLI between evals — the connection is held only for the duration of one eval, honouring
  /// [SimFaucet]'s short-lived-connection contract. (Within a snippet the cache still lets repeated
  /// `session.faucet()` calls share one connection, so a multi-call snippet can't deadlock the server.)
  Future<void> closeFaucet() async {
    final f = _faucet;
    _faucet = null;
    await f?.close();
  }

  /// Resolves when the launched app process exits — e.g. its window was closed, which (with
  /// `applicationShouldTerminateAfterLastWindowClosed`) terminates the launched app process.
  /// `fsim serve` watches this so the daemon never outlives a dead app (a zombie daemon would answer
  /// `up` with already:true against nothing).
  Future<int> get appExitCode => _appProcess.exitCode;

  /// Launch the instrumented sim app and return a session that drives the app + devices over the app
  /// channel. [agentOwnsKeyboard] true routes text through the driver's mock input so [enterText]
  /// works but the real keyboard is blocked; false hands the keyboard to a human.
  static Future<AppSession> launch({
    int deviceCount = 1,
    String flutterDevice = 'macos',
    bool agentOwnsKeyboard = true,
    Map<String, String> extraDartDefines = const {},
    int? windowSlot,
    IOSink? logSink,
    // Root under which the disposable app dir (+ its screenshots) is created. Interactive `fsim serve`
    // passes its session state root (`<dir>/.fsim`); the test runner leaves it null → the shared temp root.
    Directory? appDirRoot,
  }) async {
    // An AppSession holds no host device sockets, but the launch shape still depends on whether the
    // target shares the host filesystem: a desktop host uses our disposable appDir (and has no build
    // flavor); an emulator keeps its sandbox app-support dir (host paths are meaningless there) and
    // needs the `direct` build flavor.
    final hostPlatform = const {
      'macos',
      'linux',
      'windows',
    }.contains(flutterDevice);
    // ANDROID always types via the real on-screen keyboard (fsim-android-ime-text): the driver's mock
    // text input is HOST-only, so a non-host target forces user-keyboard mode regardless of the flag —
    // the ONE enforcement point for every launch path.
    final effectiveAgentKeyboard = hostPlatform && agentOwnsKeyboard;
    final (proc, dir, drv, log) = await _launchApp(
      deviceCount: deviceCount,
      flutterDevice: flutterDevice,
      agentOwnsKeyboard: effectiveAgentKeyboard,
      extraDartDefines: extraDartDefines,
      shareHostAppDir: hostPlatform,
      flavor: hostPlatform ? null : 'direct',
      windowSlot: windowSlot,
      logSink: logSink,
      appDirRoot: appDirRoot,
    );
    return AppSession(
      proc,
      dir,
      drv,
      log,
      flutterDevice,
      effectiveAgentKeyboard,
    );
  }

  static const _macosSimAppBinary =
      'build/macos/Build/Products/Debug/Frostsnap.app/Contents/MacOS/Frostsnap';
  // The linux bundle executable is `Frostsnap` (capital F): `linux/CMakeLists.txt` sets BINARY_NAME.
  static const _linuxSimAppBinary = 'build/linux/x64/debug/bundle/Frostsnap';

  /// Build the macOS debug sim app once. Parallel workers direct-launch this binary so they don't
  /// serialize on `flutter run`'s shared build directory.
  static Future<String> ensureMacosSimAppBuilt({IOSink? logSink}) =>
      _ensureDesktopSimAppBuilt('macos', _macosSimAppBinary, logSink: logSink);

  /// Build the Linux debug sim app once (the host-desktop equivalent of [ensureMacosSimAppBuilt]).
  static Future<String> ensureLinuxSimAppBuilt({IOSink? logSink}) =>
      _ensureDesktopSimAppBuilt('linux', _linuxSimAppBinary, logSink: logSink);

  /// `flutter build <target> --debug` the sim app ONCE (macOS/Linux desktop) and return its absolute
  /// bundle-binary path, so parallel workers direct-launch the prebuilt binary instead of each running a
  /// `flutter run` build (which would serialize on the shared build dir).
  static Future<String> _ensureDesktopSimAppBuilt(
    String target,
    String binaryPath, {
    IOSink? logSink,
  }) => _withFlutterBuildLock(() async {
    final proc = await Process.start('flutter', [
      'build',
      target,
      '--debug',
      '-t',
      'test_driver/sim_app.dart',
      '--dart-define=SIM=true',
    ]);
    final output = StringBuffer();
    void capture(String prefix, String line) {
      final tagged = '[$prefix] $line';
      output.writeln(tagged);
      logSink?.writeln(tagged);
    }

    final drains = [
      proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach((line) => capture('build', line)),
      proc.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach((line) => capture('build:err', line)),
    ];
    final code = await proc.exitCode;
    await Future.wait(drains);
    if (code != 0) {
      throw StateError('flutter build $target failed with exit $code\n$output');
    }
    final binary = File(binaryPath);
    if (!await binary.exists()) {
      throw StateError(
        'flutter build $target succeeded but $binaryPath does not exist',
      );
    }
    return binary.absolute.path;
  });

  static const _androidSimApkBinary =
      'build/app/outputs/flutter-apk/app-direct-debug.apk';

  /// Build the Android `direct` debug sim APK once. Pool workers install this prebuilt APK
  /// (`flutter run --use-application-binary`) rather than each running a Gradle build, so only the slow
  /// test EXECUTION overlaps — not the build. The emulator app can't read the host env, so every value
  /// the host delivers per-launch via the env is baked here EXCEPT the device count (grown over the app
  /// channel at runtime) and SIM_APP_DIR (a host path, meaningless in the sandbox). The regtest
  /// endpoints are the FIXED bridge ports, so the per-session adb-reverse does the routing and this one
  /// APK serves regtest and non-regtest scenarios alike.
  static Future<String> ensureAndroidSimApkBuilt({
    IOSink? logSink,
  }) => _withFlutterBuildLock(() async {
    final proc = await Process.start('flutter', [
      'build',
      'apk',
      '--debug',
      '-t',
      'test_driver/sim_app.dart',
      '--flavor',
      'direct',
      '--dart-define=SIM=true',
      // ANDROID always types via the real on-screen keyboard (fsim-android-ime-text). This is baked at
      // BUILD time (the emulator app can't read the host env): `true` here re-enables the driver's text
      // mock, which silently swallows every TextInput.show — the IME never appears.
      '--dart-define=SIM_AGENT_OWNS_KEYBOARD=false',
      '--dart-define=SIM_REGTEST_ELECTRUM_URL=$androidBridgeElectrumUrl',
      '--dart-define=SIM_REGTEST_CONTROL_SOCKET=$androidBridgeControlSocket',
    ]);
    final output = StringBuffer();
    void capture(String prefix, String line) {
      final tagged = '[$prefix] $line';
      output.writeln(tagged);
      logSink?.writeln(tagged);
    }

    final drains = [
      proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach((line) => capture('build', line)),
      proc.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach((line) => capture('build:err', line)),
    ];
    final code = await proc.exitCode;
    await Future.wait(drains);
    if (code != 0) {
      throw StateError('flutter build apk failed with exit $code\n$output');
    }
    final binary = File(_androidSimApkBinary);
    if (!await binary.exists()) {
      throw StateError(
        'flutter build apk succeeded but $_androidSimApkBinary does not exist',
      );
    }
    return binary.absolute.path;
  });

  static Future<T> _withFlutterBuildLock<T>(Future<T> Function() body) async {
    // Serialize Flutter's writes to build/ across concurrent launches. The OS drops the lock if a
    // worker dies, so it can't deadlock.
    final buildLock = await File(
      '${simTmpRoot().path}/flutter-build.lock',
    ).open(mode: FileMode.write);
    await buildLock.lock(FileLock.blockingExclusive);
    try {
      return await body();
    } finally {
      try {
        await buildLock.unlock();
      } catch (_) {}
      try {
        await buildLock.close();
      } catch (_) {}
    }
  }

  static Map<String, String> _simLaunchEnvironment({
    required Directory appDir,
    required int deviceCount,
    required bool agentOwnsKeyboard,
    required bool shareHostAppDir,
    required Map<String, String> extraDartDefines,
    int? windowSlot,
  }) {
    // A per-launch [windowSlot] override lets ONE test process place two instances in DISTINCT slots;
    // with none, inherit the worker's slot from the env (single-instance default — unchanged).
    final slot =
        windowSlot?.toString() ??
        Platform.environment['FROSTSNAP_SIM_WINDOW_SLOT'];
    return {
      'FROSTSNAP_SIM_NO_ACTIVATE': '1',
      if (slot != null && slot.isNotEmpty) 'FROSTSNAP_SIM_WINDOW_SLOT': slot,
      if (shareHostAppDir) 'SIM_APP_DIR': appDir.path,
      'SIM_DEVICE_COUNT': '$deviceCount',
      'SIM_AGENT_OWNS_KEYBOARD': '$agentOwnsKeyboard',
      ...extraDartDefines,
    };
  }

  /// Engine switches that make a DIRECTLY-launched (not via `flutter run`) desktop debug app open its VM
  /// service on a random port, so flutter_driver can attach + the URL parse picks it up. Engine-general —
  /// used for both the macOS and the Linux direct-launch.
  static Map<String, String> _desktopVmServiceEnvironment() {
    final switches = <String>[
      'enable-dart-profiling=true',
      'vm-service-port=0',
      'enable-checked-mode=true',
      'verify-entry-points=true',
    ];
    return {
      for (var i = 0; i < switches.length; i++)
        'FLUTTER_ENGINE_SWITCH_${i + 1}': switches[i],
      'FLUTTER_ENGINE_SWITCHES': '${switches.length}',
    };
  }

  static List<String> _flutterRunArgs({
    required String flutterDevice,
    required String? flavor,
    required Directory appDir,
    required bool agentOwnsKeyboard,
    required bool shareHostAppDir,
    required Map<String, String> extraDartDefines,
  }) => [
    'run',
    '-t',
    'test_driver/sim_app.dart',
    '-d',
    flutterDevice,
    '--no-pub',
    if (!shareHostAppDir) '--no-hot',
    if (flavor != null) ...['--flavor', flavor],
    '--dart-define=SIM=true',
    // Omitted on Android — a host path is meaningless in the sandbox.
    if (shareHostAppDir) '--dart-define=SIM_APP_DIR=${appDir.path}',
    // SIM_DEVICE_COUNT is NOT baked in: the emulator app can't read the host env, and a shared APK
    // (build-once) can't carry a per-test value — the harness grows the fleet at runtime instead.
    '--dart-define=SIM_AGENT_OWNS_KEYBOARD=$agentOwnsKeyboard',
    for (final e in extraDartDefines.entries)
      '--dart-define=${e.key}=${e.value}',
  ];

  /// Start the sim target, connect FlutterDriver, enable semantics, and return the pieces both
  /// session shapes need. On macOS host runs this direct-launches the prebuilt debug app; Android
  /// stays on `flutter run` for install + adb-forwarded VM service.
  static Future<(Process, Directory, FlutterDriver, List<String>)> _launchApp({
    required int deviceCount,
    required String flutterDevice,
    required bool agentOwnsKeyboard,
    required Map<String, String> extraDartDefines,
    // Whether the app shares the host filesystem (a desktop platform). When true the app is pointed
    // at the host [appDir] via SIM_APP_DIR so its `device-<n>.sock`s land where [SimHarness] can
    // connect them. When false (an Android emulator) that host path is invalid INSIDE the sandbox,
    // so SIM_APP_DIR is omitted and the app falls back to its own app-support dir (main.dart); the
    // host [appDir] is then used only for screenshots/diagnostics.
    required bool shareHostAppDir,
    // Android build flavor (the app defines `direct`/`playstore` product flavors, so `flutter run`
    // needs one to pick the APK). Null on desktop, which has no flavors.
    String? flavor,
    // Per-launch window-slot override (host-visual): distinct slots keep two instances in one test
    // process from stacking. Null inherits the worker's slot from the env.
    int? windowSlot,
    IOSink? logSink,
    // Root for the disposable app dir (+ its screenshots); null → the shared temp root (test runner).
    Directory? appDirRoot,
  }) async {
    // Regtest (if any) reaches the app purely via extraDartDefines (SIM_REGTEST_*) — the caller's borrowed
    // chain (Scenario) or the session's own backend (serve). The app launcher owns no regtest.
    final appDir = await (appDirRoot ?? simTmpRoot()).createTemp('app-');
    // Ring buffer of recent app stdout/stderr, dumped into the failure artifacts.
    final appLog = <String>[];
    void log(String line) {
      appLog.add(line);
      if (appLog.length > 400) appLog.removeAt(0);
      logSink?.writeln(line);
    }

    // Track partial resources so a failure anywhere in setup tears them all down.
    Process? proc;
    FlutterDriver? driver;

    try {
      await Directory('${appDir.path}/screenshots').create();

      final launchEnvironment = _simLaunchEnvironment(
        appDir: appDir,
        deviceCount: deviceCount,
        agentOwnsKeyboard: agentOwnsKeyboard,
        shareHostAppDir: shareHostAppDir,
        extraDartDefines: extraDartDefines,
        windowSlot: windowSlot,
      );

      // Capture the VM service URL from the app/tool output (surface logs on stderr). `flutter run`
      // forwards an emulator's VM service to 127.0.0.1 too, so this regex matches on Android as well.
      final vmUrl = Completer<String>();
      final urlRe = RegExp(r'(http://127\.0\.0\.1:\d+/[^\s]+)');
      void wireProcessLogs(Process p) {
        p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
          (line) {
            stderr.writeln('[app] $line');
            log('[app] $line');
            if (!vmUrl.isCompleted &&
                line.toLowerCase().contains('dart vm service')) {
              final m = urlRe.firstMatch(line);
              if (m != null) vmUrl.complete(m.group(1));
            }
          },
        );
        p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(
          (line) {
            stderr.writeln('[app:err] $line');
            log('[app:err] $line');
          },
        );
        p.exitCode.then((code) {
          if (!vmUrl.isCompleted) {
            vmUrl.completeError(
              StateError('sim app exited before VM service URL (exit $code)'),
            );
          }
        });
      }

      late final String url;
      // Direct-launch the prebuilt desktop binary on its native host OS (macOS/Linux); the VM-service
      // engine switches + stdout URL parse are engine-general, not macOS-specific.
      final directDesktopLaunch =
          shareHostAppDir &&
          ((flutterDevice == 'macos' && Platform.isMacOS) ||
              (flutterDevice == 'linux' && Platform.isLinux));
      final androidAppBinary = Platform.environment['SIM_ANDROID_APP_BINARY'];
      final usePrebuiltApk =
          !shareHostAppDir &&
          androidAppBinary != null &&
          androidAppBinary.isNotEmpty;
      if (directDesktopLaunch) {
        final configuredBinary = Platform.environment['SIM_HOST_APP_BINARY'];
        final binary = configuredBinary != null && configuredBinary.isNotEmpty
            ? configuredBinary
            : Platform.isMacOS
            ? await ensureMacosSimAppBuilt(logSink: logSink)
            : await ensureLinuxSimAppBuilt(logSink: logSink);
        if (!await File(binary).exists()) {
          throw StateError('SIM_HOST_APP_BINARY does not exist: $binary');
        }
        proc = await Process.start(
          binary,
          const <String>[],
          environment: {
            ...launchEnvironment,
            ..._desktopVmServiceEnvironment(),
          },
        );
        wireProcessLogs(proc);
        log('[harness] launched desktop sim app binary: $binary');
        url = await vmUrl.future.timeout(const Duration(minutes: 5));
      } else if (usePrebuiltApk) {
        if (!await File(androidAppBinary).exists()) {
          throw StateError(
            'SIM_ANDROID_APP_BINARY does not exist: $androidAppBinary',
          );
        }
        // Install + attach to the prebuilt APK: no Gradle build, so no build-lock serialization and
        // launches overlap. Every per-build define is baked in the APK (ensureAndroidSimApkBuilt); the
        // device count grows over the app channel and the regtest chain is reached via the per-serial
        // adb-reverse, so nothing per-test needs passing here.
        proc = await Process.start('flutter', [
          'run',
          '--use-application-binary',
          androidAppBinary,
          '-d',
          flutterDevice,
          '--no-pub',
        ], environment: launchEnvironment);
        wireProcessLogs(proc);
        log('[harness] launched prebuilt android sim APK: $androidAppBinary');
        url = await vmUrl.future.timeout(const Duration(minutes: 5));
      } else {
        url = await _withFlutterBuildLock(() async {
          proc = await Process.start(
            'flutter',
            _flutterRunArgs(
              flutterDevice: flutterDevice,
              flavor: flavor,
              appDir: appDir,
              agentOwnsKeyboard: agentOwnsKeyboard,
              shareHostAppDir: shareHostAppDir,
              extraDartDefines: extraDartDefines,
            ),
            environment: launchEnvironment,
          );
          wireProcessLogs(proc!);
          return vmUrl.future.timeout(const Duration(minutes: 5));
        });
      }
      driver = await FlutterDriver.connect(dartVmServiceUrl: url);
      final drv = driver;
      // Build the semantics tree, then wait for a POSITIVE readiness signal — find.bySemanticsLabel
      // actually RESOLVING a known always-present marker — not merely for setSemantics to stop throwing.
      // setSemantics throws "No root widget is attached" until runApp attaches; and even once it
      // succeeds the tree may not be built/usable yet, so under load a scenario's first find/tap can
      // race a half-up app (the parallel-robustness flake). The sim shell wraps the app on EVERY screen,
      // so its marker is layout-independent: 'SIMULATOR' (wide/host docked panel) or 'Open simulator'
      // (narrow/emulator edge handle). Retry BOTH setSemantics and the marker wait until it resolves;
      // past a generous window fail fast with a clear cause rather than proceed into a broken tree.
      final readyMarker = RegExp('SIMULATOR|Open simulator');
      var semanticsReady = false;
      final semanticsDeadline = DateTime.now().add(const Duration(seconds: 60));
      while (!semanticsReady && DateTime.now().isBefore(semanticsDeadline)) {
        try {
          await drv.setSemantics(true);
          await drv.runUnsynchronized(
            () => drv.waitFor(
              find.bySemanticsLabel(readyMarker),
              timeout: const Duration(seconds: 2),
            ),
          );
          semanticsReady = true;
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }
      if (!semanticsReady) {
        throw StateError(
          'sim app semantics never became usable — find.bySemanticsLabel("$readyMarker") did not '
          'resolve within 60s (the app tree never finished attaching)',
        );
      }

      final launchedProc = proc;
      if (launchedProc == null) {
        throw StateError('sim launch reached success without an app process');
      }
      return (launchedProc, appDir, driver, appLog);
    } catch (_) {
      // Tear down whatever got created, then rethrow the original setup error.
      await _cleanup(driver: driver, proc: proc, appDir: appDir);
      rethrow;
    }
  }

  /// Guarded best-effort teardown of any subset of the session resources. Every step
  /// runs even if an earlier one throws; returns the first error seen (or null).
  static Future<Object?> _cleanup({
    FlutterDriver? driver,
    Process? proc,
    Directory? appDir,
  }) async {
    Object? firstError;
    Future<void> guard(Future<void> Function() step) async {
      try {
        await step();
      } catch (e) {
        firstError ??= e;
      }
    }

    if (driver != null) {
      await guard(() => driver.close().timeout(const Duration(seconds: 5)));
    }
    if (proc != null) {
      final p = proc;
      p.kill();
      await guard(
        () => p.exitCode.timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            p.kill(ProcessSignal.sigkill);
            return -1;
          },
        ),
      );
    }
    if (appDir != null && await appDir.exists()) {
      await guard(() => appDir.delete(recursive: true));
    }
    return firstError;
  }

  /// The app's live device numbers (1..N), via the `device-numbers` driver-data endpoint — the
  /// app-side source of truth that BOTH the tray + button and `./fsim add-device` grow. App
  /// channel only, so it works on an emulator (no host sockets involved).
  Future<List<int>> deviceNumbers() async {
    final csv = await _requestData('device-numbers');
    return csv.isEmpty ? <int>[] : csv.split(',').map(int.parse).toList();
  }

  /// Add a virtual device to the fleet at runtime (CLI/harness parity with the tray + button) and
  /// return its 1-based number. App channel only — triggers the in-app pool add via driver data.
  /// [SimHarness] overrides this to also connect the new device's host socket.
  Future<int> addDevice() async => int.parse(await _requestData('add-device'));

  /// Delete every wallet from the COORDINATOR (via `coord.deleteKey` — the same path the "Hold to Delete"
  /// UI triggers) while the virtual devices KEEP their shares, so a recovery flow can restore it from them.
  /// Returns the number of wallets deleted.
  Future<int> deleteWallet() async =>
      int.parse(await _requestData('delete-wallet'));

  // ---- device driving over the APP channel (FRB pool) ----
  // These drive the in-process `simDevicePool` via driver-data, so a scenario drives a device the
  // SAME way on host and emulator — the one device transport. Coordinates are
  // device-framebuffer coords (240x280), same as the device channel.

  Future<void> _device(String cmd) async {
    await _deviceQuery(cmd);
  }

  /// Drive a device endpoint and return its reply — for the query endpoints (chain/id/is-connected/
  /// screen) that return data, not just an ack.
  Future<String> _deviceQuery(String cmd) => _requestData(cmd);

  /// Every app-channel driver-data request funnels through here so they share ONE client-side timeout:
  /// a slow/stuck app can't make a single request hang the scenario forever. (A FULLY wedged app —
  /// VM service unable to answer at all, e.g. a frozen UI thread — is caught by the runner's per-test
  /// deadline, since no client-side timeout can fire if the isolate never schedules the reply.)
  Future<String> _requestData(String message) async {
    try {
      return await _rawRequestData(message);
    } catch (original) {
      // Non-finder call: participates in app-exit/connection/action classification only.
      throw await _diagnosed(original, verb: 'requestData("$message")');
    }
  }

  Future<String> _rawRequestData(String message) => driver
      .runUnsynchronized(() => driver.requestData(message))
      .timeout(_cmdTimeout);

  /// An app-channel handle to virtual device [number] (1-based, default 1): the same method surface
  /// the host socket had, but every call goes over the app channel (driver-data → the in-process
  /// `simDevicePool`), so it drives a device IDENTICALLY on host and emulator.
  AppDevice device([int number = 1]) => AppDevice(this, number);

  // ---- chain composition (pool-level; one source of truth via setChain), over the app channel ----
  // The connected chain is an ordered list of 1-based device numbers (first = the device on the
  // coordinator USB port). connect/disconnect/reorder all funnel through setChain.

  /// The connected chain, in order.
  Future<List<int>> chain() => device(1).chain();

  /// Re-cable the chain to exactly [order] (1-based numbers, in order).
  Future<void> setChain(List<int> order) => device(1).setChain(order);

  /// Connect [number] by plugging it into the tail of the chain (the router applies the daisy-chain
  /// semantics — the single source of truth, same as the tray).
  Future<void> connect(int number) => device(number).setConnected(true);

  /// Disconnect [number] AND everything downstream (pulling a daisy-chain device cuts those below).
  Future<void> disconnect(int number) => device(number).setConnected(false);

  // ---- device RECOGNITION (coordinator-side) — a DISTINCT gate from pool/chain membership ----
  // A device joins the sim pool/chain the instant it's plugged, but the COORDINATOR only knows it after
  // the announce handshake — and the UI built from the coordinator's list (the keygen "Device name N"
  // field, signer availability) appears only then. Flows must gate on recognition, not pool membership,
  // or they race a slow handshake under load. connect/disconnect and the initial fleet do this for the
  // caller (see [AppDevice.setConnected], [Scenario.launch]), so no scenario sprinkles its own wait.

  /// The ids (lowercase hex) of devices the coordinator has recognized, via `recognized-device-ids` —
  /// the SAME id form [AppDevice.deviceId] returns, so the two sets are directly comparable.
  Future<Set<String>> _recognizedIds() async {
    final csv = await _requestData('recognized-device-ids');
    return csv.isEmpty ? <String>{} : csv.split(',').toSet();
  }

  /// Wait until the coordinator's recognized id SET equals the CURRENT connected chain's id set, so a
  /// connect/disconnect/re-cable is recognition-synchronous. Compares the actual id SET (not a count),
  /// so a same-cardinality re-cable (e.g. chain 1 → 2) is NOT satisfied by stale recognition of the old
  /// device. Reads [chain] once (it already reflects a daisy-chain disconnect CASCADE) — the gate is the
  /// resulting connected set, not just the toggled device. Bounded timeout throws a clear error (never
  /// hangs); near-instant no-op on host where recognition is quick.
  Future<void> _awaitChainRecognized({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final expected = <String>{};
    for (final n in await chain()) {
      expected.add(await device(n).deviceId());
    }
    final deadline = DateTime.now().add(timeout);
    for (;;) {
      final got = await _recognizedIds();
      if (got.length == expected.length && got.containsAll(expected)) return;
      if (DateTime.now().isAfter(deadline)) {
        throw StateError(
          'coordinator recognized {${got.join(',')}} but the connected chain is '
          '{${expected.join(',')}} after ${timeout.inSeconds}s '
          '(device announce/recognition did not settle)',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  /// Move [number] one position toward the head (the coordinator end).
  Future<void> moveUp(int number) async {
    final order = await chain();
    final i = order.indexOf(number);
    if (i > 0) {
      order
        ..removeAt(i)
        ..insert(i - 1, number);
      await setChain(order);
    }
  }

  /// Move [number] one position toward the tail.
  Future<void> moveDown(int number) async {
    final order = await chain();
    final i = order.indexOf(number);
    if (i >= 0 && i < order.length - 1) {
      order
        ..removeAt(i)
        ..insert(i + 1, number);
      await setChain(order);
    }
  }

  /// Disconnect/connect [number] (the keygen driver's post-keygen unplug).
  Future<void> unplug([int number = 1]) => disconnect(number);
  Future<void> plug([int number = 1]) => connect(number);

  /// The app's FlutterView size + system insets (LOGICAL px) — for occlusion checks against a
  /// widget's screen rect (e.g. is a button below `height - bottomInset`, i.e. behind the nav bar).
  Future<({double width, double height, double topInset, double bottomInset})>
  viewMetrics() async {
    final m = jsonDecode(await _requestData('metrics')) as Map<String, dynamic>;
    return (
      width: (m['width'] as num).toDouble(),
      height: (m['height'] as num).toDouble(),
      topInset: (m['topInset'] as num).toDouble(),
      bottomInset: (m['bottomInset'] as num).toDouble(),
    );
  }

  /// Inspect the app's current onstage semantic-label surface — the same labels targeted by [tap],
  /// [waitFor], [exists], and text-entry helpers. Accessors fetch a fresh snapshot.
  AppSemanticsInspector semantics() => AppSemanticsInspector._(this);

  // ---- reusable flows (driven over the app channel, so they run on host AND emulator) ----

  /// Run [body] against a single [AppSession] on [flutterDevice] (or `SIM_FLUTTER_DEVICE`, default
  /// macos). The single-instance case of [Scenario]: [withRegtest] starts a PRIVATE per-session chain
  /// the app borrows (concurrent scenarios never share one). Captures diagnostics and asserts no
  /// residue — all via [Scenario], so a two-instance scenario is the same lifecycle with two launches.
  static Future<void> runScenario(
    String name,
    Future<void> Function(AppSession h) body, {
    int deviceCount = 1,
    String? flutterDevice,
    bool withRegtest = false,
    Map<String, String> extraDartDefines = const {},
  }) => Scenario.runInstances(
    name,
    1,
    (apps, s) => body(apps.single),
    deviceCount: deviceCount,
    flutterDevice: flutterDevice,
    withRegtest: withRegtest,
    extraDartDefines: extraDartDefines,
  );

  /// Device-screen point of the keygen security-code confirm button (the KeygenCheck screen, sim-3).
  static const _keygenConfirmX = 120;
  static const _keygenConfirmY = 215;

  /// Drive a full keygen to a created wallet: create → name the wallet + [deviceCount] devices →
  /// (threshold) → generate → each device hold-confirms the security code → unplug to finalize →
  /// the wallet home. Devices are driven over the APP channel ([holdConfirm]/[disconnectDevice]),
  /// so this runs unchanged on host and emulator.
  Future<void> createWallet({
    String name = 'SimTest',
    int deviceCount = 1,
    String devicePrefix = 'SimDev',
  }) async {
    await tapUntil(RegExp('Create a multi-sig wallet'), 'Wallet name');
    await enterText('Wallet name', name);
    await tapUntil('Next', 'Device name 1');
    for (var i = 1; i <= deviceCount; i++) {
      await enterText('Device name $i', '$devicePrefix$i');
    }
    if (deviceCount == 1) {
      // 1-of-1 is below the recommended threshold, so it has an extra confirm dialog.
      await tapUntil('Continue with 1 device', 'Continue anyway');
      await tapUntil('Continue anyway', 'Generate keys');
    } else {
      // N devices: Continue → Choose threshold (defaults to recommended) → Generate keys.
      await tapUntil('Continue with $deviceCount devices', 'Generate keys');
    }
    await tapUntil('Generate keys', RegExp('Security Check'));
    // Each device confirms the security code via hold-to-confirm; the app reveals "Yes" at N/N.
    // Re-assert (the device-render can lag the hold).
    var confirmed = false;
    for (var attempt = 0; attempt < 8 && !confirmed; attempt++) {
      for (var n = 1; n <= deviceCount; n++) {
        await device(n).holdConfirm(_keygenConfirmX, _keygenConfirmY);
      }
      confirmed = await exists('Yes');
    }
    if (!confirmed) {
      throw StateError('devices never confirmed the security code');
    }
    await tapUntil('Yes', RegExp('Unplug devices to continue'));
    for (var n = 1; n <= deviceCount; n++) {
      await device(n).setConnected(false);
    }
    await waitFor(RegExp('Receive'));
  }

  /// From a created wallet, open a device's "Record backup information" sheet: enter the backup
  /// checklist (the wallet's unfinished-backups banner) → connect [device] → tap its Backup. Leaves
  /// the sheet (with the "Show secret backup" action) on screen.
  Future<void> openDeviceBackup({int device = 1}) async {
    await tapUntil(RegExp('unfinished backups'), RegExp('Backup keys'));
    await this.device(device).setConnected(true);
    await tapUntil('Backup', RegExp('Record backup information'));
  }

  /// Assert the widget [label] sits ABOVE the bottom system inset — i.e. is not occluded by the
  /// navigation bar. Compares the widget's screen rect ([FlutterDriver.getBottomRight]) with
  /// [viewMetrics]. Trivially true where there's no bottom inset (a desktop host); on the emulator
  /// it catches a control rendered behind the nav bar.
  Future<void> expectAboveBottomInset(Pattern label) async {
    final m = await viewMetrics();
    final safeBottom = m.height - m.bottomInset;
    final br = await _settledBottomRight(label);
    if (br.dy > safeBottom) {
      throw StateError(
        'widget "$label" is occluded by the ${m.bottomInset.toStringAsFixed(0)}px bottom '
        'inset: its bottom is ${br.dy.toStringAsFixed(0)} but the safe area ends at '
        '${safeBottom.toStringAsFixed(0)} (view height ${m.height.toStringAsFixed(0)})',
      );
    }
  }

  /// The on-screen bottom-right of [label] once it has stopped moving (e.g. a sheet has finished
  /// sliding in). We can't use flutter_driver's frame-sync (`pumpAndSettle`'s out-of-process
  /// equivalent) for this: the sim app never reaches frame-idle (a live tray/device keeps
  /// repainting — the reason every other call here is `runUnsynchronized`), so a synchronized read
  /// just times out. So we do what out-of-process drivers do when they can't hook the frame loop
  /// (cf. Appium/Playwright explicit waits): sample the geometry until two reads agree, then use it.
  Future<DriverOffset> _settledBottomRight(
    Pattern label, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final finder = find.bySemanticsLabel(label);
    final deadline = DateTime.now().add(timeout);
    var prev = double.nan;
    while (true) {
      final br = await _driverCall(
        () => driver.getBottomRight(finder, timeout: _cmdTimeout),
        finder: label,
        verb: 'getBottomRight("$label")',
      );
      if ((br.dy - prev).abs() < 1.0 || DateTime.now().isAfter(deadline)) {
        return br;
      }
      prev = br.dy;
      // Sample a heartbeat apart: a backgrounded window only advances the slide-in on each forced
      // frame, so two reads within one beat are the SAME un-repainted frame and would falsely "settle".
      await Future<void>.delayed(_heartbeat);
    }
  }

  // ---- app channel (widget tree, by semantic label) ----
  // `label` is a Pattern: a String matches the accessible name exactly; a RegExp
  // matches a substring (needed for composite widgets, e.g. a card that merges its
  // title + subtitle into one semantics label).
  //
  // Every command runs UNSYNCHRONIZED and with a timeout. Unsynchronized because the
  // sim device tray repaints whenever the device screen changes, so the app rarely
  // reaches the frame-quiescent state flutter_driver waits for by default — a
  // synchronized command (e.g. a tap that triggers device activity) would otherwise
  // never return. The timeout turns an unresolvable target into a fast, clear failure
  // instead of an indefinite hang (flutter_driver waits forever with no timeout).

  /// Per-command timeout for app interactions.
  static const Duration _cmdTimeout = Duration(seconds: 20);

  /// The sim_app.dart forced-frame heartbeat period (its `main()` pumps one beat this often while the
  /// agent drives a backgrounded window). macOS paints a backgrounded/occluded window ONLY on this beat,
  /// so the flutter_driver semantics tree is at most this stale. Keep in sync with the heartbeat there.
  static const Duration _heartbeat = Duration(seconds: 1);

  /// Floor for any BOUNDED "is it there now?" semantics read ([exists], a re-check inside [tapUntil]).
  /// It must span at least one [_heartbeat] — we use 2x for margin — or it can poll ENTIRELY within the
  /// gap between two beats and see only the stale tree, missing a state that already changed but hasn't
  /// repainted. That is exactly the signing-share `1/1` flake under parallel load: the share landed but
  /// an 800ms check expired before the next forced frame painted the counter. No bounded read here may
  /// be shorter than this.
  static const Duration _minObserve = Duration(seconds: 2);

  /// RAW driver transport — no failure diagnosis. Used by predicates ([_appears]/[exists], which
  /// treat failure as `false` and must not pay a probe per negative poll) and by the classifier's
  /// own snapshot probe (which must never diagnose itself — that would recurse).
  Future<T> _rawDriverCall<T>(Future<T> Function() call, [Duration? timeout]) =>
      driver.runUnsynchronized(call).timeout(timeout ?? _cmdTimeout);

  /// The diagnosing driver wrapper: on failure, classify (label miss / app exited / action failure /
  /// connection drop) instead of surfacing a raw DriverError or TimeoutException. [finder] is the
  /// FINDER-phase Pattern only — typing/IME/non-finder phases must pass none, or a genuine action
  /// failure could be rewritten as a label miss.
  Future<T> _driverCall<T>(
    Future<T> Function() call, {
    Duration? timeout,
    Pattern? finder,
    String verb = 'driver call',
  }) async {
    try {
      return await _rawDriverCall(call, timeout);
    } catch (original) {
      throw await _diagnosed(original, finder: finder, verb: verb);
    }
  }

  Future<StateError> _diagnosed(
    Object original, {
    Pattern? finder,
    required String verb,
  }) async {
    final d = await diagnoseDriverFailure(
      original: original,
      verb: verb,
      finder: finder,
      appExitStatus: () => _appExitStatus,
      probeLabels: _probeOnStageLabels,
      appLogTail: _recentAppLog,
    );
    return StateError(d.message);
  }

  /// RAW probe transport for the classifier (see [_rawDriverCall] — no recursion).
  Future<List<String>> _probeOnStageLabels() async {
    final nodes =
        jsonDecode(await _rawRequestData('semantics-snapshot'))['nodes']
            as List;
    return [
      for (final n in nodes)
        if (((n as Map)['label'] as String?)?.isNotEmpty ?? false)
          n['label'] as String,
    ];
  }

  String _recentAppLog([int lines = 40]) => _appLog
      .skip(_appLog.length > lines ? _appLog.length - lines : 0)
      .join('\n');

  Future<void> tap(Pattern label) => _driverCall(
    () => driver.tap(find.bySemanticsLabel(label), timeout: _cmdTimeout),
    finder: label,
    verb: 'tap("$label")',
  );

  /// Tap a control by its TOOLTIP — for tooltip-only buttons (e.g. an icon pencil) that expose no
  /// targetable semantic label. [tooltip] (String or RegExp) is resolved against the on-stage
  /// tooltips to exactly one — zero/many error with a diagnostic listing — then tapped via
  /// FlutterDriver's widget finder (never by coordinates).
  Future<void> tapTooltip(Pattern tooltip) => _driverCall(
    () async {
      // RAW fetch: this composite already sits under ONE diagnosing wrapper — a diagnosed inner
      // call would classify (and probe) the same failure twice.
      final nodes =
          jsonDecode(await _rawRequestData('semantics-snapshot'))['nodes']
              as List;
      final available = <String>[
        for (final n in nodes)
          if ((n['tooltip'] as String?)?.isNotEmpty ?? false)
            n['tooltip'] as String,
      ];
      final exact = resolveTooltip(tooltip, available);
      await driver.tap(find.byTooltip(exact), timeout: _cmdTimeout);
      // No finder context: tooltips aren't labels (the resolver already gave zero/many diagnostics),
      // so a failure here is an action/driver failure by construction.
    },
    timeout: _cmdTimeout * 2,
    verb: 'tapTooltip("$tooltip")',
  );

  /// Tap the app surface at GLOBAL LOGICAL coordinates (origin top-left of the Flutter view) — the
  /// positional escape hatch for what no finder can target. Same coordinate space as the semantics
  /// snapshot's global bounds; no adb, no display-scale math, works on host and android alike.
  Future<void> tapAppAt(double x, double y) =>
      _driverCall(() => _rawRequestData('tap-at:$x,$y'), verb: 'tapAppAt');

  /// Tap [label] and wait for [expect] to appear. Distinguishes two failure modes of
  /// an unsynchronized tap:
  ///  - the tap *no-ops* (landed before the control was interactable) — [label] is
  ///    still present afterwards, so re-tap;
  ///  - the tap *worked but the result is slow* (e.g. a brief "preparing" step before
  ///    the next screen) — [label] is gone, so DON'T re-tap (it would hit nothing);
  ///    just wait longer for [expect].
  /// Throws if [expect] never appears.
  Future<void> tapUntil(
    Pattern label,
    Pattern expect, {
    int tries = 8,
    Duration settle = const Duration(seconds: 30),
  }) async {
    for (var i = 0; i < tries; i++) {
      await tap(label);
      if (await _appears(expect, const Duration(seconds: 3))) return;
      // Tap took effect (button gone) but the result is slow — wait it out. This re-check reads the
      // semantics tree, so it must span a forced-frame [_heartbeat] ([_minObserve]) or a backgrounded
      // window could still show the stale (pre-tap) button and we'd wrongly re-tap.
      if (!await _appears(label, _minObserve)) {
        await waitFor(expect, timeout: settle);
        return;
      }
      // Otherwise [label] is still there: the tap no-op'd, so loop and re-tap.
    }
    // Diagnose the MISSING expect Pattern (the tapped label demonstrably matched) — best-effort
    // probe so a dead connection still surfaces the plain exhaustion error, and matched-on-stage
    // reports the timing truth instead of an absurd "no match" that lists the match.
    List<String>? probed;
    try {
      probed = await _probeOnStageLabels();
    } catch (_) {}
    throw StateError(tapUntilExhaustedError(label, expect, tries, probed));
  }

  Future<bool> _appears(Pattern label, Duration timeout) async {
    try {
      // RAW: a predicate treats failure as `false` — diagnosing it would probe on every poll.
      await _rawDriverCall(
        () => driver.waitFor(find.bySemanticsLabel(label), timeout: timeout),
        timeout + const Duration(seconds: 1),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The HOST text verbs need [agentOwnsKeyboard] — without it flutter_driver's `enter_text` throws a
  /// cryptic `Bad state`. Fail fast with the fix instead. Android never needs it: text rides the real
  /// on-screen keyboard there.
  void _requireAgentKeyboard() {
    if (!agentOwnsKeyboard) {
      throw AgentKeyboardRequired(
        'text entry on a host session needs the agent-owned keyboard, but this session hands the '
        'keyboard to a human. Relaunch with `fsim up --agent-owns-keyboard` (android sessions are '
        'unaffected: they always type via the on-screen keyboard).',
      );
    }
  }

  /// Whether this session drives an android emulator ([flutterDevice] is the adb serial there).
  bool get _isAndroid => !Scenario._isHost(flutterDevice);

  /// Overall budget for one IME-typed entry: the keyboard-visible gate (30s) + clear + `input text`.
  static const Duration _imeTimeout = Duration(seconds: 60);

  Future<void> enterText(Pattern label, String text) async {
    // Two DISTINCT diagnostic phases: the focus tap carries the label as finder context; the
    // typing/IME phase carries none — a typing failure must never read as a focus-label miss.
    if (_isAndroid) {
      _imePreflight(
        text,
      ); // BEFORE any UI mutation — a rejected payload touches nothing.
      await _driverCall(
        () => driver.tap(find.bySemanticsLabel(label), timeout: _cmdTimeout),
        finder: label,
        verb: 'enterText focus tap("$label")',
      );
      await _driverCall(
        () => _typeViaIme(text),
        timeout: _imeTimeout,
        verb: 'enterText IME typing',
      );
      return;
    }
    _requireAgentKeyboard();
    await _driverCall(
      () => driver.tap(find.bySemanticsLabel(label), timeout: _cmdTimeout),
      finder: label,
      verb: 'enterText focus tap("$label")',
    );
    await _driverCall(
      () => driver.enterText(text, timeout: _cmdTimeout),
      verb: 'enterText typing',
    );
  }

  /// Type [text] into the currently-focused text field (NO finder) — for an autofocused field that has
  /// no stable semantic label, e.g. the send Amount input.
  Future<void> enterFocusedText(String text) async {
    // Preconditions OUTSIDE the diagnosing wrapper: their intentional ArgumentError /
    // AgentKeyboardRequired must reach the caller as documented, not re-wrapped as a probed failure.
    if (_isAndroid) {
      _imePreflight(text);
      await _driverCall(
        () => _typeViaIme(text),
        timeout: _imeTimeout,
        verb: 'enterFocusedText IME typing',
      );
      return;
    }
    _requireAgentKeyboard();
    await _driverCall(
      () => driver.enterText(text, timeout: _cmdTimeout),
      verb: 'enterFocusedText typing',
    );
  }

  void _imePreflight(String text) {
    final err = imeTextPreflightError(text);
    if (err != null) throw ArgumentError(err);
  }

  /// Type through the REAL on-screen keyboard: wait for it, restore the mock path's REPLACE semantics,
  /// then inject [text] as OS-level key events (`input text`). The IME stays visible throughout —
  /// that's the point (recordings show real interaction); its soft keys don't animate, since injection
  /// is hardware-style. Replace = move-to-end + counted backspaces: a select-all chord
  /// (`input keycombination` Ctrl+A, numeric or named) never reaches the Flutter field (verified live),
  /// and a focus tap can land the cursor MID-value, so the end-anchor matters.
  Future<void> _typeViaIme(String text) async {
    await _waitKeyboardVisible();
    // VERIFIED clear: count from the app's dedicated query (the semantics SNAPSHOT trims values —
    // edge whitespace would be invisible and survive), backspace exactly that many, then RE-QUERY.
    // A long `input keyevent` batch can occasionally drop an event (observed once live: one char of
    // a 26-key clear survived), so retry until empty — backspaces past empty are no-ops, making the
    // loop convergent. The query throws if no text field is focused, so a mis-targeted enterText
    // fails loudly instead of typing into the void.
    var len = await _rawFocusedTextLength();
    for (var attempt = 0; len > 0; attempt++) {
      if (attempt >= 3) {
        throw StateError(
          'the focused field failed to clear ($len chars remain after $attempt attempts)',
        );
      }
      await adb(['shell', 'input', 'keyevent', '123']); // KEYCODE_MOVE_END
      // One batched call — `input keyevent` takes many codes.
      await adb([
        'shell',
        'input',
        'keyevent',
        ...List.filled(len, '67'), // KEYCODE_DEL (backspace)
      ]);
      len = await _rawFocusedTextLength();
    }
    if (text.isNotEmpty) {
      await adb(['shell', 'input', 'text', encodeImeText(text)]);
    }
  }

  /// Whether the on-screen keyboard is up RIGHT NOW, as the app itself sees it (bottom viewInset > 0).
  Future<bool> keyboardVisible() async =>
      await _requestData('keyboard-visible') == 'true';

  /// RAW variant for composites already under one diagnosing wrapper (enterText's IME phase).
  Future<bool> _rawKeyboardVisible() async =>
      await _rawRequestData('keyboard-visible') == 'true';

  /// Exact UNTRIMMED value length of the focused text field (the semantics snapshot trims values, so
  /// edge whitespace is invisible there). Throws if no text field is focused. The android REPLACE
  /// clear backspaces exactly this many times.
  Future<int> focusedTextLength() async =>
      int.parse(await _requestData('focused-text-length'));

  /// RAW variant for composites already under one diagnosing wrapper (enterText's IME phase).
  Future<int> _rawFocusedTextLength() async =>
      int.parse(await _rawRequestData('focused-text-length'));

  Future<void> _waitKeyboardVisible() async {
    // Nudge-then-poll: right after a cold emulator boot the IME service is still initializing and
    // DROPS the show request fired by the field gaining focus — and Android never retries a dropped
    // show. Each nudge re-requests the IME for the live input connection (app-side 'show-keyboard'),
    // so the gate self-heals as soon as the service is ready.
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      // RAW transports: this loop runs inside enterText's diagnosing wrapper (see _rawDriverCall).
      await _rawRequestData('show-keyboard');
      final settle = DateTime.now().add(const Duration(seconds: 2));
      while (DateTime.now().isBefore(settle)) {
        if (await _rawKeyboardVisible()) return;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    throw StateError(
      'the on-screen keyboard never appeared — is the focused control a text field?',
    );
  }

  /// Hide the on-screen keyboard if it's up (android). Gated on [keyboardVisible] — an ungated BACK
  /// would pop a route — and waits until the inset actually drops so a following tap lands on the
  /// restored layout. No-op on host and when already hidden.
  Future<void> dismissKeyboard() async {
    if (!_isAndroid || !await keyboardVisible()) return;
    await adb(['shell', 'input', 'keyevent', '4']); // KEYCODE_BACK
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (await keyboardVisible()) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('the on-screen keyboard did not hide after BACK');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  /// Run adb against THIS session's emulator and return stdout — the escape hatch for android-only
  /// needs (key events, dumpsys, …) so one-offs don't require harness changes. Throws on host
  /// sessions and on a nonzero exit (with stderr).
  Future<String> adb(List<String> args) async {
    if (!_isAndroid) {
      throw StateError(
        'session.adb is android-only (this is a $flutterDevice session)',
      );
    }
    final serial = _emulatorSerial ?? flutterDevice;
    final r = await Process.run('${androidSdkRoot()}/platform-tools/adb', [
      '-s',
      serial,
      ...args,
    ]);
    if (r.exitCode != 0) {
      throw StateError(
        'adb ${args.join(' ')} failed (${r.exitCode}): ${(r.stderr as String).trim()}',
      );
    }
    return r.stdout as String;
  }

  Future<String> getText(Pattern label) => _driverCall(
    () => driver.getText(find.bySemanticsLabel(label), timeout: _cmdTimeout),
    finder: label,
    verb: 'getText("$label")',
  );

  /// Text of the widget with `ValueKey(key)` — for content that has no stable semantic label (e.g. an
  /// address string, whose label IS the value we're trying to read). Reads this app's own widget tree,
  /// so it's per-app and can't be raced like the process-global system clipboard.
  // NO finder context: a ValueKey is absent from the semantics snapshot — key-as-Pattern would
  // always manufacture a false label miss.
  Future<String> getTextByKey(String key) => _driverCall(
    () => driver.getText(find.byValueKey(key), timeout: _cmdTimeout),
    verb: 'getTextByKey("$key")',
  );

  /// The app clipboard, via the sim_app driver data handler — e.g. to read a wallet receive
  /// address after tapping its Copy button (the address Text has no stable label to target).
  Future<String> getClipboard() => _requestData('clipboard');

  /// Set the app clipboard (e.g. to seed a recipient address before tapping a Paste button), via
  /// the sim_app driver data handler. Portable counterpart to [getClipboard] — uses Flutter's
  /// Clipboard, so scenarios need no platform pasteboard tool (pbcopy/xclip) and stay cross-platform.
  Future<void> setClipboard(String text) => _requestData('setclip:$text');

  Future<void> waitFor(
    Pattern label, {
    Duration timeout = const Duration(seconds: 30),
  }) => _driverCall(
    () => driver.waitFor(find.bySemanticsLabel(label), timeout: timeout),
    timeout: timeout + const Duration(seconds: 1),
    finder: label,
    verb: 'waitFor("$label")',
  );

  Future<void> waitForAbsent(
    Pattern label, {
    Duration timeout = const Duration(seconds: 30),
  }) => _driverCall(
    () => driver.waitForAbsent(find.bySemanticsLabel(label), timeout: timeout),
    timeout: timeout + const Duration(seconds: 1),
    verb: 'waitForAbsent("$label")',
  );

  /// Whether a control with semantic [label] is present right now. Reads the semantics tree, so it waits
  /// [_minObserve] (≥ one forced-frame [_heartbeat]); a shorter check races the heartbeat and can miss a
  /// just-changed-but-unpainted state.
  Future<bool> exists(Pattern label) async {
    try {
      // RAW: a predicate treats failure as `false` — diagnosing it would probe on every negative.
      await _rawDriverCall(
        () =>
            driver.waitFor(find.bySemanticsLabel(label), timeout: _minObserve),
        _minObserve + const Duration(seconds: 1),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Dismiss the topmost `showBottomSheetOrDialog`. Its layout is responsive: the WIDE layout is a
  /// Dialog with a 'Close' button (host), the COMPACT layout is a drag-handle bottom sheet with NO
  /// Close button (the emulator's narrow screen). So tap Close where it exists, else dismiss the sheet
  /// the way a user would — the Android system Back gesture pops the modal route. Keeps sheet-closing
  /// portable across host and emulator without baking a Close button into the app's mobile sheets.
  Future<void> dismissSheetOrDialog() async {
    if (await exists('Close')) {
      await tap('Close');
      return;
    }
    // No Close button → android: send BACK to THIS instance's OWN emulator. Use the instance's serial
    // ([flutterDevice]), NOT the global SIM_FLUTTER_DEVICE — under the app-instance seam that env is the
    // generic 'android' and each instance self-boots its own distinct emulator (a dual test has two).
    if (Scenario._isHost(flutterDevice)) {
      throw StateError(
        'no Close button on host device "$flutterDevice": cannot dismiss the sheet',
      );
    }
    await Process.run('${androidSdkRoot()}/platform-tools/adb', [
      '-s',
      flutterDevice,
      'shell',
      'input',
      'keyevent',
      'KEYCODE_BACK',
    ]);
  }

  // ---- whole-app screenshot (incl. the tray) ----

  /// Capture the whole Flutter surface (app + tray) to `<appDir>/screenshots/`. The
  /// file is removed with everything else on [tearDown]; pass [keep] for a path
  /// outside the app dir to retain a shot. Returns the written path.
  ///
  /// Renders OFF-SCREEN through the render tree (the `app-screenshot` endpoint's
  /// RenderRepaintBoundary.toImage), NOT the OS window — so the shot is fresh even when the window is
  /// backgrounded (macOS pauses a backgrounded window's compositing; `driver.screenshot()` would
  /// otherwise return a stale frame, which is why this used to osascript-foreground the window) and it
  /// works per-instance for multi-app scenarios. Same idea as the device-framebuffer snapshot.
  Future<String> screenshot(String name, {String? keep}) async {
    final png = base64Decode(await _requestData('app-screenshot'));
    final path = keep ?? '${appDir.path}/screenshots/${_shotSeq++}-$name.png';
    await File(path).writeAsBytes(png);
    return path;
  }

  // ---- video: native emulator screen recording (android only) ----

  /// The in-progress recording (the detached `adb shell screenrecord` process + its on-device file), or null.
  ({Process proc, String deviceFile})? _recording;

  /// Record [body] as one Android emulator clip, finalize it to host [path], and return the body's result.
  /// Stopping is always attempted after a successful start, including when [body] throws.
  Future<T> record<T>(
    String path,
    Future<T> Function() body, {
    String deviceFile = '/sdcard/fsim-rec.mp4',
  }) async {
    await startRecording(deviceFile: deviceFile);
    try {
      return await body();
    } finally {
      await stopRecording(path);
    }
  }

  /// Start recording this (android) session's emulator screen to [deviceFile] on the device — a NATIVE
  /// `screenrecord` that runs ON the emulator, so it captures the flow AS you drive it via eval with no perf
  /// cost to driving. Call it MID-RUN (after setup), drive, then [stopRecording] to pull the mp4. Android only
  /// (host has no emulator screen); `screenrecord` caps a single recording at 180s.
  Future<void> startRecording({
    String deviceFile = '/sdcard/fsim-rec.mp4',
  }) async {
    final serial = _emulatorSerial;
    if (serial == null) {
      throw StateError(
        'recording needs an android session (emulator screenrecord) — this is a host session',
      );
    }
    if (_recording != null) {
      throw StateError('already recording — stopRecording() first');
    }
    final adb = '${androidSdkRoot()}/platform-tools/adb';
    final proc = await Process.start(adb, [
      '-s',
      serial,
      'shell',
      'screenrecord',
      deviceFile,
    ]);
    proc.stdout.drain<void>();
    proc.stderr.drain<void>();
    _recording = (proc: proc, deviceFile: deviceFile);
  }

  /// Stop the [startRecording] recording and pull its mp4 to host [path], returning it. SIGINT is what
  /// finalizes the mp4 (a bare kill truncates it); screenrecord then exits.
  Future<String> stopRecording(String path) async {
    final rec = _recording;
    final serial = _emulatorSerial;
    if (rec == null || serial == null) {
      throw StateError('no recording in progress — startRecording() first');
    }
    final adb = '${androidSdkRoot()}/platform-tools/adb';
    // SIGINT finalizes the mp4 (a bare kill truncates it). It may have already self-stopped at the 180s cap —
    // then pkill matches nothing; the exit-wait + pull below are the real checks.
    final pkill = await Process.run(adb, [
      '-s',
      serial,
      'shell',
      'pkill',
      '-INT',
      'screenrecord',
    ]);
    // The mp4 is only flushed once screenrecord actually EXITS. A timeout means it's still running (didn't
    // finalize) — the file would be truncated, so fail rather than pull garbage.
    final exited = await rec.proc.exitCode
        .then((_) => true)
        .timeout(const Duration(seconds: 10), onTimeout: () => false);
    if (!exited) {
      throw StateError(
        'recording did not finalize within 10s (screenrecord still running); pkill exit '
                '${pkill.exitCode} ${(pkill.stderr as String).trim()}'
            .trim(),
      );
    }
    // The pull is the real success check — Process.run does NOT throw on a nonzero exit, so verify it (device
    // disconnect / missing file / unwritable host path all surface here) before reporting success.
    final pull = await Process.run(adb, [
      '-s',
      serial,
      'pull',
      rec.deviceFile,
      path,
    ]);
    if (pull.exitCode != 0) {
      final err = (pull.stderr as String).trim();
      throw StateError(
        'failed to pull the recording ($serial:${rec.deviceFile} -> $path): '
        '${err.isNotEmpty ? err : (pull.stdout as String).trim()}',
      );
    }
    // Best-effort cleanup of the on-device file. Only NOW clear the state — a thrown failure above leaves
    // _recording set so a retry can pull again.
    await Process.run(adb, ['-s', serial, 'shell', 'rm', '-f', rec.deviceFile]);
    _recording = null;
    return path;
  }

  // ---- secure key (sim: exercise the "hardware key is gone" path) ----

  /// Delete the app's secure key — on android the StrongBox/TEE `AndroidKeyStore` key. The next access
  /// regenerates it, so the app hits its key-gone / recovery path, otherwise near-impossible to reproduce.
  /// ANDROID-ONLY: errors on a host session (the desktop provider's key is a fixed constant).
  Future<void> deleteSecureKey() async {
    await _requestData('delete-secure-key');
  }

  /// Whether the app's secure key currently exists — verify a [deleteSecureKey] actually removed it.
  /// ANDROID-ONLY: errors on a host session.
  Future<bool> secureKeyExists() async =>
      (await _requestData('secure-key-exists')) == 'true';

  // ---- failure diagnostics ----

  /// On a scenario failure, dump where it stopped to the runner-provided artifacts dir
  /// (`SIM_TEST_ARTIFACTS_DIR`) or `build/sim-failures/<name>/` when run directly.
  /// (a gitignored, persistent dir — survives tearDown): the whole-app screenshot,
  /// the error + stack + recent app logs, and (via [_captureExtra]) any per-session
  /// extras. Best-effort: a capture step failing must not mask the original error.
  Future<void> _captureFailure(
    String name,
    Object error,
    StackTrace stack,
  ) async {
    final configuredDir = Platform.environment['SIM_TEST_ARTIFACTS_DIR'];
    final runnerOwnedDir = configuredDir != null && configuredDir.isNotEmpty;
    final base = runnerOwnedDir ? configuredDir : 'build/sim-failures/$name';
    // A dual-instance scenario gives each app a [_diagLabel] so their artifacts land in separate
    // subdirs instead of clobbering each other; a single instance ([_diagLabel] null) keeps the flat
    // layout (and the runner's timeout-artifact handling) unchanged.
    final dir = Directory(_diagLabel == null ? base : '$base/$_diagLabel');
    try {
      // The runner owns SIM_TEST_ARTIFACTS_DIR and may already have timeout
      // artifacts there; direct runs still get a fresh directory per failure.
      if (!runnerOwnedDir && await dir.exists())
        await dir.delete(recursive: true);
      await dir.create(recursive: true);
      try {
        await screenshot('app', keep: '${dir.path}/app.png');
      } catch (_) {}
      await _captureExtra(dir);
      final errorText =
          '$error\n\n$stack\n\n--- recent app log ---\n${_appLog.join('\n')}\n';
      final errorFile = File('${dir.path}/error.txt');
      final path = runnerOwnedDir && await errorFile.exists()
          ? '${dir.path}/scenario-error.txt'
          : errorFile.path;
      await File(path).writeAsString(errorText);
      stderr.writeln('sim-failure diagnostics: ${dir.absolute.path}');
    } catch (_) {
      // Diagnostics are best-effort; never mask the scenario's own error.
    }
  }

  /// Each virtual device's framebuffer PNG into the failure-diagnostics [dir], over the app channel
  /// (so it works on host AND emulator). Best-effort per device.
  Future<void> _captureExtra(Directory dir) async {
    for (final n in await deviceNumbers()) {
      try {
        await device(n).screen('${dir.path}/device-$n.png');
      } catch (_) {}
    }
  }

  /// Quit the app and delete the disposable app dir (which holds all harness
  /// screenshots) — no residue. The first cleanup error (if any) is rethrown once
  /// everything has been torn down.
  Future<void> tearDown() async {
    // Close the console's cached faucet connection (if the eval console opened one) before teardown.
    try {
      await _faucet?.close();
    } catch (_) {}
    final err = await _cleanup(
      driver: driver,
      proc: _appProcess,
      appDir: appDir,
    );
    // If this instance owns an android emulator: remove its regtest bridge, then kill the emulator (after
    // the app is down). Best-effort so a bridge/kill hiccup never masks the app-cleanup error.
    try {
      await _unbridge?.call();
    } catch (_) {}
    final serial = _emulatorSerial;
    // [_keepEmulator] (explicit seam policy — never ambient env): the `--record-failures` runner is
    // recording this emulator's screen and must pkill/pull the mp4 AFTER this child exits — killing
    // it here would strand the recording on a dead device. The runner reaps the slot's emulators
    // itself once the video is pulled.
    Object? killErr;
    if (serial != null &&
        shouldKillEmulatorOnTearDown(
          serial: serial,
          keepEmulator: _keepEmulator,
        )) {
      // PROPAGATE a kill failure (killEmulator now blocks until the process is confirmed gone):
      // swallowing it here is how `down` used to report success over a surviving emulator.
      try {
        await killEmulator(androidSdkRoot(), serial);
      } catch (e) {
        killErr = e;
      }
    }
    if (err != null && killErr != null) {
      throw StateError('$err; additionally the emulator kill failed: $killErr');
    }
    if (err != null) throw err;
    if (killErr != null) throw killErr;
  }
}

/// An app-channel handle to one virtual device (1-based [_number]): the same method surface the
/// host-only `device-<n>.sock` client had, but every call goes over the app channel (driver-data → the
/// in-process `simDevicePool`) — so a scenario drives a device IDENTICALLY on host and emulator, and
/// `./fsim` device commands are no longer host-only. Returned by [AppSession.device].
class AppDevice {
  final AppSession _session;
  final int _number;
  AppDevice(this._session, this._number);

  /// Tap (touch down then up) at `(x,y)`.
  Future<void> tap(int x, int y) =>
      _session._device('device-tap:$_number:$x:$y');

  /// Press and hold at `(x,y)` for [duration] — the device integrates the elapsed wall-clock and a
  /// hold-to-confirm control fires past its threshold.
  Future<void> hold(int x, int y, Duration duration) =>
      _session._device('device-hold:$_number:$x:$y:${duration.inMilliseconds}');

  /// Hold a hold-to-confirm button at `(x,y)` long enough to fire it.
  Future<void> holdConfirm(
    int x,
    int y, [
    Duration duration = const Duration(milliseconds: 2600),
  ]) => hold(x, y, duration);

  /// Swipe from `(x1,y1)` to `(x2,y2)` over [duration] (advances the device's review screens).
  Future<void> swipe(int x1, int y1, int x2, int y2, Duration duration) =>
      _session._device(
        'device-swipe:$_number:$x1:$y1:$x2:$y2:${duration.inMilliseconds}',
      );

  /// Raw single touch (press when `liftUp` false, release when true).
  Future<void> touch(int x, int y, {required bool liftUp}) =>
      _session._device('device-touch:$_number:$x:$y:${liftUp ? 'up' : 'down'}');

  /// Plug this device into / out of the chain (the router applies daisy-chain semantics) and WAIT until
  /// the coordinator's recognized set has caught up — so "connected" means connected AND recognized, and
  /// no caller races the per-device UI that only renders post-recognition.
  Future<void> setConnected(bool connected) async {
    await _session._device(
      'device-${connected ? 'connect' : 'disconnect'}:$_number',
    );
    await _session._awaitChainRecognized();
  }

  /// Whether this device is connected (its number is in the chain).
  Future<bool> isConnected() async =>
      (await _session._deviceQuery('device-is-connected:$_number')) == 'true';

  /// The connected chain as 1-based device numbers, in order (pool-level — any device answers it).
  Future<List<int>> chain() async {
    final csv = await _session._deviceQuery('device-chain');
    return csv.isEmpty ? <int>[] : csv.split(',').map(int.parse).toList();
  }

  /// Re-cable the chain to exactly these 1-based numbers, in order (pool-level), and WAIT until the
  /// coordinator's recognized set matches the resulting chain.
  Future<void> setChain(List<int> order) async {
    await _session._device('device-set-chain:${order.join(',')}');
    await _session._awaitChainRecognized();
  }

  Future<String> deviceId() => _session._deviceQuery('device-id:$_number');

  /// Write the device framebuffer to [path] as a PNG (the endpoint returns a base64 PNG).
  Future<void> screen(String path) async {
    final b64 = await _session._deviceQuery('device-screen:$_number');
    await File(path).writeAsBytes(base64Decode(b64));
  }
}

/// `SimHarness` was the desktop session shape — an [AppSession] plus host `device-<n>.sock` channels.
/// Now that devices drive over the app channel on every platform (see [AppDevice]), the two shapes
/// are one; this alias keeps existing callers compiling.
typedef SimHarness = AppSession;
