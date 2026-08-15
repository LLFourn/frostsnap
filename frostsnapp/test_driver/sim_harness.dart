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

import 'app_errors.dart';
import 'emulator_lifecycle.dart' show shouldKillEmulatorOnTearDown;
import 'generational_runtime.dart';
import 'ime_text.dart' show encodeImeText, imeTextPreflightError;
import 'label_resolve.dart';
import 'driver_phase.dart';
import 'test_outcome.dart'
    show simTestExpectedFailDeclaredMarker, simTestExpectedFailHitMarker;

export 'app_errors.dart'
    show AppError, AppErrorExpectation, AppErrorRaised, simErrorWidgetLabel;
export 'driver_phase.dart';
export 'label_resolve.dart'
    show AmbiguousTarget, LabelCandidate, describeAmbiguity, matchesLabel;
export 'test_outcome.dart'
    show
        classifyRun,
        simTestExpectedFailDeclaredMarker,
        simTestExpectedFailHitMarker,
        simTestSkippedMarker,
        statusIsFailure;
import 'label_diagnostics.dart'
    show diagnoseDriverFailure, labelMatchesAny, tapUntilExhaustedError;
import 'silent_clock.dart';
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

/// One assertion that is expected to FAIL until [fixedBy] is in the tree.
///
/// Hand it to `runScenario`/`runInstances`, which DECLARES it before any setup runs, then wrap the
/// assertion it describes with [guard]. Declaring up front is what makes the missing case
/// detectable: a scenario that returns before reaching its guard has declared an expectation it
/// never tested, and the runner calls that XPASS rather than a pass.
///
/// The expectation covers that ONE assertion. An e2e reaches its subject only after launching the
/// app, driving the UI and talking to a backend, so anything scenario-wide would report a startup
/// crash or a flaky tap as expected and hide a real regression — only what [guard]'s body throws is
/// caught, and everything around it fails the run normally.
///
/// When it starts passing the run FAILS with `XPASS` — delete the expectation and inline the
/// assertion in the same change that fixed it.
class ExpectedFailure {
  final String what;
  final String fixedBy;

  ExpectedFailure(this.what, {required this.fixedBy});

  /// Emitted by the scenario runner BEFORE the body, so an unreached [guard] is visible.
  /// `print` rather than `stdout.writeln` so the markers are interceptable in-process — the
  /// runner reads the child's stdout either way, and the protocol is worth testing directly.
  void declare() {
    print('$simTestExpectedFailDeclaredMarker: $what (fixed by $fixedBy)');
  }

  /// Run [assertion], swallowing ONLY its failure and recording that the expectation held.
  /// Returns whether it was hit, so the scenario can `return` past checks that only make sense
  /// once the defect is gone — a return keeps every `finally` and the Scenario teardown running,
  /// where throwing here would fail the run and swallowing silently would let later assertions
  /// fail on a state the defect caused.
  ///
  /// Keep this around the SMALLEST thing that can fail for the documented reason. Observation —
  /// RPCs, polling, diagnostics — belongs outside it: a backend that is merely broken must not
  /// be reported as a known defect.
  Future<bool> guard(Future<void> Function() assertion) async {
    try {
      await assertion();
      return false;
    } catch (e) {
      print('$simTestExpectedFailHitMarker: $what — $e');
      return true;
    }
  }
}

/// Root for all sim temp artifacts — disposable app dirs, the fsim control socket,
/// ad-hoc screenshots — grouped under one folder instead of loose in the system temp
/// root. Created on demand.
Directory simTmpRoot() {
  final dir = Directory('${Directory.systemTemp.path}/frostsnap-sim');
  dir.createSync(recursive: true);
  return dir;
}

/// Run [ready]; on failure run [dispose] then rethrow the readiness failure (a disposal failure is
/// aggregated, never silently swallowed). The provisioning seam uses it so a post-launch readiness
/// failure cannot orphan the launched app/emulator/bridge.
Future<T> readyOrDispose<T>({
  required Future<T> Function() ready,
  required Future<void> Function() dispose,
}) async {
  try {
    return await ready();
  } catch (readyErr, st) {
    try {
      await dispose();
    } catch (disposeErr) {
      throw StateError(
        '$readyErr; additionally disposing the half-provisioned session failed: $disposeErr',
      );
    }
    Error.throwWithStackTrace(readyErr, st);
  }
}

/// The provisioning seam's readiness TRANSACTION — the composition that fixes the dropped
/// `--devices N`: converge the fleet to [target], THEN settle [recognize], and only then return; a
/// failure at EITHER step runs [dispose] before rethrowing ([readyOrDispose]). Fakeable so the
/// composition itself — ordering, return-gating, atomicity — is host-testable, not only its
/// ingredients.
Future<void> provisionReadiness({
  required int target,
  required Future<List<int>> Function() numbers,
  required Future<int> Function() addOne,
  required Future<void> Function(int) removeOne,
  required Future<void> Function() recognize,
  required Future<void> Function() dispose,
}) => readyOrDispose(
  ready: () async {
    await convergeFleetTo(target, numbers, addOne, removeOne);
    await recognize();
  },
  dispose: dispose,
);

/// Converge the sim fleet to EXACTLY [target] devices: [numbers] reads the live device numbers,
/// [addOne] hot-plugs one (returning its number), [removeOne] removes one by number. This is how a
/// test's device count is delivered at runtime — a shared APK can't bake a per-test count and the
/// emulator app can't read the host env, so the fleet is converged over the app channel after
/// launch. Shrinking removes the HIGHEST numbers first (the newest devices — convergence runs at
/// provision time, before any test state exists; this is how `deviceCount: 0` works on android,
/// whose APK launches with one baked-in device). The final count is ASSERTED to equal [target]:
/// a mismatch is a hard setup failure, not a silent "3-device test runs with 1 and still passes
/// the early steps". A stuck add/remove (one that doesn't change the fleet) throws rather than
/// spin.
Future<void> convergeFleetTo(
  int target,
  Future<List<int>> Function() numbers,
  Future<int> Function() addOne,
  Future<void> Function(int) removeOne,
) async {
  for (var fleet = await numbers(); fleet.length != target;) {
    if (fleet.length < target) {
      await addOne();
    } else {
      await removeOne(fleet.reduce((a, b) => a > b ? a : b));
    }
    final next = await numbers();
    if (next.length == fleet.length) {
      throw StateError(
        'fleet convergence is stuck at ${fleet.length} device(s) '
        '(target $target)',
      );
    }
    fleet = next;
  }
  final fleet = await numbers();
  if (fleet.length != target) {
    throw StateError(
      'sim fleet has ${fleet.length} device(s), expected exactly $target — '
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
        jsonDecode(
              // RAW: the on-stage listing is what a failure report is BUILT from.
              await _session._rawRequestData('semantics-snapshot'),
            )
            as Map<String, dynamic>;
    final nodes = root['nodes'] as List<dynamic>? ?? const <dynamic>[];
    return [for (final node in nodes) Map<String, dynamic>.from(node as Map)];
  }

  /// Structured JSON for scripts/tests. Prefer [labels] or [grep] for the stable targeting contract.
  Future<String> json() => _session._rawRequestData('semantics-snapshot');

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
      // An error raised after the last command would otherwise escape: nothing follows it to
      // attribute it to, and the scenario would report success over a broken app.
      for (final h in s._sessions) {
        await h._checkAppErrors('end of scenario "$name"');
      }
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
    ExpectedFailure? expectedToFail,
  }) async {
    if (instances > _maxInstances) {
      throw StateError(
        'runInstances($name): $instances instances exceeds the fixed max $_maxInstances — bump '
        'Scenario._maxInstances (and provision more AVDs).',
      );
    }
    // BEFORE any setup: a scenario that dies during launch, or returns without reaching its guard,
    // must still be seen to have declared an expectation it did not test.
    expectedToFail?.declare();
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
  /// [AppSession.tearDown]. Attaches [chain] so `faucet()` works. The seam owns FULL READINESS: no caller
  /// receives an AppSession before [deviceCount] devices exist (android launches bake count 1 — the sandboxed
  /// APK can't read the host env, so the fleet is grown over the app channel) AND the chain-recognition
  /// handshake has settled; a post-launch readiness failure tears the session down instead of orphaning it.
  /// Callers layer only their own bookkeeping (the Scenario registers for teardown; the serve holds the
  /// instances).
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
      return _readyInstance(h, deviceCount);
    }

    final sdk = androidSdkRoot();
    final avd = emulatorAvd(deviceIndex);
    final serial = emulatorSerial(deviceIndex);
    await ensureAvd(sdk, avd);
    Future<void> Function()? unbridge;
    // The catch below only guards pre/at-launch failures (unbridge/kill are the only resources
    // standing there). Post-launch readiness runs AFTER it: once the session exists, its own
    // tearDown (via _readyInstance) owns cleanup.
    final AppSession session;
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
      session = h;
    } catch (_) {
      try {
        await unbridge?.call();
      } catch (_) {}
      try {
        await killEmulator(sdk, serial);
      } catch (_) {}
      rethrow;
    }
    return _readyInstance(session, deviceCount);
  }

  /// The seam's FULL-readiness step: grow the fleet to [deviceCount] over the app channel (host
  /// launches already bake the count — growth no-ops) and settle the chain-recognition handshake so
  /// flows never race the per-device UI. FAILURE-ATOMIC via [readyOrDispose]: a readiness failure
  /// tears the launched session down (emulator + bridge included) before rethrowing.
  static Future<AppSession> _readyInstance(
    AppSession h,
    int deviceCount,
  ) async {
    await provisionReadiness(
      target: deviceCount,
      numbers: h.deviceNumbers,
      addOne: h.addDevice,
      removeOne: h.removeDevice,
      recognize: h._awaitChainRecognized,
      dispose: h.tearDown,
    );
    return h;
  }

  /// The FIXED stride for the per-instance device index (shared with the runner), so an emulator's
  /// port/AVD (or a host window slot) never collides across concurrent workers OR instances.
  static const _maxInstances = maxInstancesPerTest;

  /// Provision app instance [index] of [totalInstances] for THIS scenario: the shared [provisionAppInstance]
  /// seam — which owns growth + chain recognition — PLUS the only test bookkeeping left: registering the
  /// ready session for teardown.
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
    // The seam returned a READY session (fleet grown, chain recognized) — and it tears a
    // half-provisioned one down itself, so registration can safely follow.
    _sessions.add(h);
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

/// The app's out-of-band liveness, read off its log pipe (which fails
/// independently of the driver channel). Two signals with distinct meanings:
/// [lastBeatAt] is the main isolate's deliberate 1 Hz [kSimBeatMarker] —
/// proof the half every driver request needs can still schedule — and is
/// what the load-tolerant waits extend on. [lastOutputAt] is ANY line
/// (tool, Rust threads), which can keep flowing while the main isolate is
/// wedged, so it is diagnostics only: a timeout reporting both says WHICH
/// half died instead of burning a reproduction cycle on the question.
class _AppLiveness {
  DateTime lastOutputAt = DateTime.now();
  DateTime lastBeatAt = DateTime.now();

  String describe() {
    String age(DateTime t) =>
        (DateTime.now().difference(t).inMilliseconds / 1000).toStringAsFixed(1);
    return 'last main-isolate beat ${age(lastBeatAt)}s ago; '
        'last output ${age(lastOutputAt)}s ago';
  }
}

/// A launched sim app: the Flutter process + FlutterDriver over the (possibly adb-forwarded) VM
/// service. Drives the app widget tree by semantic label (`app.*` + `screenshot()`) AND the virtual
/// devices ([device] → [AppDevice]) over the SAME app channel, so it's the ONE session shape for host
/// and emulator alike (`SimHarness` is now an alias for it).
class AppSession {
  Process _appProcess;
  final Directory appDir;
  FlutterDriver driver;
  List<String> _appLog;
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
    this._liveness,
  ) {
    // Record the app's exit so the failure classifier can consult it WITHOUT awaiting — an OOM
    // force-stop mid-drive must classify as "app exited", not as a label/connection problem.
    unawaited(_appProcess.exitCode.then((c) => _appExitStatus = c));
    _runtime.watch(_appProcess.exitCode);
  }

  /// The generational lifecycle behind [restartApp]: expected old-generation exits are
  /// suppressed, unexpected exits fire [appExitCode], a failed relaunch is terminal.
  final GenerationalRuntime _runtime = GenerationalRuntime();

  /// Everything [restartApp]'s relaunch needs to reproduce the ORIGINAL launch shape
  /// (defines carry the regtest wiring; flavor/share derive from the platform). Captured
  /// by [launch]; null for sessions constructed outside it, which then cannot restart.
  ({
    Map<String, String> extraDartDefines,
    bool shareHostAppDir,
    String? flavor,
    int? windowSlot,
    IOSink? logSink,
  })?
  _launchConfig;

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

  /// Resolves when the app dies UNEXPECTEDLY — e.g. its window was closed, which (with
  /// `applicationShouldTerminateAfterLastWindowClosed`) terminates the launched app process —
  /// or when a [restartApp] relaunch fails terminally. A restart's own kill of the OLD
  /// generation does NOT resolve this. `fsim serve` watches this so the daemon never
  /// outlives a dead app (a zombie daemon would answer `up` with already:true against
  /// nothing) yet survives an in-place restart.
  Future<int> get appExitCode => _runtime.unexpectedExit;

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
    final (proc, dir, drv, log, liveness) = await _launchApp(
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
    final session = AppSession(
      proc,
      dir,
      drv,
      log,
      flutterDevice,
      effectiveAgentKeyboard,
      liveness,
    );
    session._launchConfig = (
      extraDartDefines: extraDartDefines,
      shareHostAppDir: hostPlatform,
      flavor: hostPlatform ? null : 'direct',
      windowSlot: windowSlot,
      logSink: logSink,
    );
    return session;
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
  static Future<(Process, Directory, FlutterDriver, List<String>, _AppLiveness)>
  _launchApp({
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
    // Relaunch into THIS app dir instead of a fresh temp one — the restartApp path,
    // where the same dir means the same sqlite db (restore-from-db by construction).
    Directory? existingAppDir,
  }) async {
    // Regtest (if any) reaches the app purely via extraDartDefines (SIM_REGTEST_*) — the caller's borrowed
    // chain (Scenario) or the session's own backend (serve). The app launcher owns no regtest.
    final appDir =
        existingAppDir ?? await (appDirRoot ?? simTmpRoot()).createTemp('app-');
    // Ring buffer of recent app stdout/stderr, dumped into the failure artifacts.
    final appLog = <String>[];
    final liveness = _AppLiveness();
    void log(String line) {
      appLog.add(line);
      if (appLog.length > 400) appLog.removeAt(0);
      logSink?.writeln(line);
    }

    // Track partial resources so a failure anywhere in setup tears them all down.
    Process? proc;
    FlutterDriver? driver;

    try {
      await Directory('${appDir.path}/screenshots').create(recursive: true);

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
            liveness.lastOutputAt = DateTime.now();
            // Beats are a 1 Hz signal, not information: track, don't echo.
            if (line.contains(kSimBeatMarker)) {
              liveness.lastBeatAt = DateTime.now();
              return;
            }
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
            liveness.lastOutputAt = DateTime.now();
            if (line.contains(kSimBeatMarker)) {
              liveness.lastBeatAt = DateTime.now();
              return;
            }
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
      Object? lastAttemptError;
      // The budget charges beat-less time observed during THIS wait
      // ([SilentClock]): the driver is connected by now, so a healthy main
      // isolate beats at 1 Hz however starved the guest — a loaded launch
      // keeps extending, a hung one stops beating and fails on the same
      // budget a fixed deadline gave it (hard-capped; the per-test deadline
      // bounds everything regardless).
      final semanticsClock = SilentClock(
        started: DateTime.now(),
        budget: const Duration(seconds: 60),
      );
      while (!semanticsReady) {
        if (semanticsClock.expired(
          now: DateTime.now(),
          lastActivityAt: liveness.lastBeatAt,
        )) {
          break;
        }
        try {
          await drv.setSemantics(true);
          await drv.runUnsynchronized(
            () => drv.waitFor(
              find.bySemanticsLabel(readyMarker),
              timeout: const Duration(seconds: 2),
            ),
          );
          semanticsReady = true;
        } catch (e) {
          lastAttemptError = e;
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }
      if (!semanticsReady) {
        throw StateError(
          'sim app semantics never became usable — find.bySemanticsLabel("$readyMarker") did not '
          'resolve: ${semanticsClock.describe(now: DateTime.now(), lastActivityAt: liveness.lastBeatAt)} '
          '(${liveness.describe()}; last attempt: $lastAttemptError)',
        );
      }

      final launchedProc = proc;
      if (launchedProc == null) {
        throw StateError('sim launch reached success without an app process');
      }
      return (launchedProc, appDir, driver, appLog, liveness);
    } catch (_) {
      // Tear down whatever got created, then rethrow the original setup error. A REUSED
      // app dir survives (its db is the session's state — deleting it on a failed
      // relaunch would destroy exactly what a retry or postmortem needs).
      await _cleanup(
        driver: driver,
        proc: proc,
        appDir: existingAppDir == null ? appDir : null,
      );
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

  /// Test-only seam: awaited between the new generation's install and the
  /// converge/seed/readiness steps, so a test can hold a restart mid-span (overlap
  /// must be rejected for the WHOLE span) or fail it there (a post-launch failure
  /// must be a FAILED restart: terminal, and it fires the daemon teardown).
  Future<void> Function()? restartPostLaunchGate;

  /// Kill and relaunch the app IN PLACE — same app dir (host) / same emulator and data
  /// dir (android) — so the new generation restores from the SAME sqlite db, proving
  /// restore-from-db. The app comes back with ZERO devices attached (a restarted app
  /// meets whatever gets plugged in next — physical devices are not part of the app);
  /// re-add them with [addDeviceFromSavedState] using states saved beforehand. Device
  /// numbering continues across the restart (the new generation's pool is seeded with
  /// the old one's next number, honored exactly), so numbers stay session-unique.
  ///
  /// The WHOLE span — counter read, kill, relaunch, converge-to-empty, seed,
  /// readiness — is ONE generation transaction: a second restart is rejected until it
  /// completes, and a failure anywhere in it is a FAILED restart (the session is
  /// terminally dead and the daemon teardown fires). The serve daemon survives a
  /// successful restart: only an UNEXPECTED app death still tears the session down.
  Future<void> restartApp() async {
    final config = _launchConfig;
    if (config == null) {
      throw StateError(
        'restartApp needs a session created by AppSession.launch (no launch config)',
      );
    }
    await _runtime.restart(() async {
      // Counter read INSIDE the transaction: the runtime's dead/single-flight guards
      // run first, so a restart after a failed one errors instead of RPCing the
      // stale driver. The new generation's pool starts empty and is seeded with it
      // so numbering continues.
      final nextNumber = int.parse(
        await _requestData('next-device-number', effect: DriverEffect.observes),
      );
      // Drain the OLD generation before killing it. Anything it raised and nobody has collected
      // dies with the process otherwise, so a restart would silently swallow the very errors this
      // exists to catch — including one raised between the last command's drain and this restart.
      await _checkAppErrors('restartApp (errors from the outgoing app)');
      // Kill the old generation. The driver connection dies with it.
      try {
        await driver.close().timeout(const Duration(seconds: 5));
      } catch (_) {}
      final old = _appProcess;
      old.kill();
      if (_emulatorSerial != null) {
        // `flutter run` owns the attachment, not the app's life: force-stop makes the
        // APP process die too (its data dir survives — that is the point).
        final adb = '${androidSdkRoot()}/platform-tools/adb';
        await Process.run(adb, [
          '-s',
          _emulatorSerial!,
          'shell',
          'am',
          'force-stop',
          'com.frostsnap',
        ]);
      }
      await old.exitCode.timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          old.kill(ProcessSignal.sigkill);
          return -1;
        },
      );

      // Relaunch into the SAME context, empty-fleet.
      final (proc, _, drv, log, liveness) = await _launchApp(
        deviceCount: 0,
        flutterDevice: flutterDevice,
        agentOwnsKeyboard: agentOwnsKeyboard,
        extraDartDefines: config.extraDartDefines,
        shareHostAppDir: config.shareHostAppDir,
        flavor: config.flavor,
        windowSlot: config.windowSlot,
        logSink: config.logSink,
        existingAppDir: appDir,
      );
      _appProcess = proc;
      driver = drv;
      _appLog = log;
      _liveness = liveness;
      _appExitStatus = null;
      unawaited(proc.exitCode.then((c) => _appExitStatus = c));
      final gate = restartPostLaunchGate;
      if (gate != null) await gate();
      // Android relaunches from the APK, whose baked-in launch device the host env
      // cannot suppress — converge to the EMPTY fleet a restart promises (a host
      // relaunch honors SIM_DEVICE_COUNT=0, so this is a no-op there), THEN seed
      // so the session's numbering continues, then let recognition converge on the
      // empty chain. A failure in any of these makes the closure throw, which the
      // runtime treats as a failed restart.
      for (final n in await deviceNumbers()) {
        await removeDevice(n);
      }
      await _requestData(
        'seed-next-number:$nextNumber',
        effect: DriverEffect.mutates,
      );
      await _awaitChainRecognized();
      return proc.exitCode;
    });
  }

  /// Block the app's UI isolate for [how long] — SIM-ONLY, and the only way to make "the app
  /// stopped answering" happen on purpose. Returns when the stall ends; callers that want to act
  /// DURING it should not await this.
  void stallApp(Duration duration) {
    // Deliberately NOT awaited: the app cannot answer while it is stalled, so waiting for a reply
    // would just time out. Errors are dropped for the same reason — the request not returning IS
    // the intended effect.
    unawaited(
      _requestData(
        'stall:${duration.inMilliseconds}',
        effect: DriverEffect.detached,
      ).catchError((_) => ''),
    );
  }

  /// SIM-ONLY: put [count] controls carrying the SAME semantic label on screen, so the shape that
  /// actually breaks a tap — two identical hit-testable targets — is deterministic rather than a
  /// mid-transition accident. With [settleAfter], drops to one after that delay.
  Future<void> showDuplicateTargets(
    String label,
    int count, {
    Duration? settleAfter,
  }) async {
    await _requestData(
      'duplicate-target:$label:$count:${settleAfter?.inMilliseconds ?? 0}',
      effect: DriverEffect.mutates,
    );
    // The request only sets the notifier; the controls exist a FRAME later. Returning before then
    // leaves the fixture racing whatever the test does next — the opposite of what a fixture for a
    // timing bug is for, and it made this very test pass a tap that should have been ambiguous.
    await _awaitReachable(label, count);
  }

  /// Wait until [label] has exactly [count] hit-testable instances.
  Future<void> _awaitReachable(String label, int count) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    var seen = -1;
    while (true) {
      final match = (await _labelCandidates()).where((c) => c.label == label);
      seen = match.isEmpty ? 0 : match.first.hitTestable;
      if (seen == count) return;
      if (!DateTime.now().isBefore(deadline)) {
        throw StateError(
          'the duplicate-target fixture never showed $count reachable "$label" (saw $seen)',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// Every on-stage label with how many instances a tap could reach.
  Future<List<LabelCandidate>> _labelCandidates({String? withinKey}) async =>
      LabelCandidate.fromJson(
        jsonDecode(
              await _rawRequestData(
                withinKey == null
                    ? 'hit-testable-labels'
                    : 'hit-testable-labels-within:$withinKey',
              ),
            )
            as List,
      );

  /// Activations of the duplicate-target fixture since it was shown — so "acted EXACTLY once" is
  /// asserted from the app rather than trusted of a retry loop.
  ///
  /// RAW, because the question matters most right after a timed-out action has quarantined the
  /// session: that is exactly when you need to know whether it fired. A late-landing stray can only
  /// push this count UP, so an "at most once" assertion cannot be masked by the race.
  Future<int> duplicateTargetTaps() async =>
      int.parse(await _rawRequestData('duplicate-target-taps'));

  /// Make a tap on the fixture RECORD itself and then block the isolate for [duration] — the only
  /// way to time out an ACTION that was genuinely dispatched, rather than a phase before it.
  Future<void> blockDuplicateTargetTap(Duration duration) => _requestData(
    'duplicate-target-block-on-tap:${duration.inMilliseconds}',
    effect: DriverEffect.mutates,
  );

  /// How many instances of [label] a tap could actually reach right now — the same criterion the
  /// driver's finder uses, counted without deduplication. Zero, or more than one, is exactly when a
  /// singular action cannot proceed.
  Future<int> hitTestableCount(Pattern label, {String? within}) async {
    final matching = (await _labelCandidates(
      withinKey: within,
    )).where((c) => matchesLabel(label, c.label));
    return matching.fold<int>(0, (sum, c) => sum + c.hitTestable);
  }

  /// SIM-ONLY: provoke a real Flutter error, one per source — a throw inside `build` (the red
  /// screen), an async throw escaping its zone, and a framework error that renders nothing.
  Future<void> provokeBuildError() =>
      _requestData('provoke-build-error', effect: DriverEffect.mutates);

  Future<void> provokeAsyncError({Duration after = Duration.zero}) =>
      _requestData(
        'provoke-async-error:${after.inMilliseconds}',
        effect: DriverEffect.mutates,
      );

  Future<void> provokeFrameworkError() =>
      _requestData('provoke-framework-error', effect: DriverEffect.mutates);

  /// Show a control that DESTROYS ITSELF when tapped: the tap arms a build failure and the control
  /// is inside the subtree that throws, so the label the driver just acted on disappears.
  Future<void> armTappableBuildError() =>
      _requestData('arm-tappable-build-error', effect: DriverEffect.mutates);

  Future<void> clearProvokedError() =>
      _requestData('clear-provoked-error', effect: DriverEffect.mutates);

  /// SIM-ONLY: make the NEXT app-channel request block for [duration] — so a diagnostic probe can
  /// be put in front of an app that will not answer, without stalling the isolate beforehand.
  Future<void> blockNextDataRequest(Duration duration) => _requestData(
    'block-next-request:${duration.inMilliseconds}',
    effect: DriverEffect.mutates,
  );

  Future<void> clearDuplicateTargets() async {
    await _requestData('duplicate-target-clear', effect: DriverEffect.mutates);
  }

  /// Keep the app animating for [duration] while it stays responsive — a stand-in for the wallet
  /// confetti, with a duration a test can rely on. Any driver command that runs with frame sync ON
  /// blocks for as long as this lasts; one that correctly disabled it is unaffected.
  Future<void> animateApp(Duration duration) async {
    await _requestData(
      'animate:${duration.inMilliseconds}',
      effect: DriverEffect.mutates,
    );
  }

  /// The app's live device numbers (1..N), via the `device-numbers` driver-data endpoint — the
  /// app-side source of truth that BOTH the tray + button and `./fsim add-device` grow. App
  /// channel only, so it works on an emulator (no host sockets involved).
  Future<List<int>> deviceNumbers() async {
    final csv = await _requestData(
      'device-numbers',
      effect: DriverEffect.observes,
    );
    return csv.isEmpty ? <int>[] : csv.split(',').map(int.parse).toList();
  }

  /// Add a virtual device to the fleet at runtime (CLI/harness parity with the tray + button) and
  /// return its 1-based number. App channel only — triggers the in-app pool add via driver data.
  /// [SimHarness] overrides this to also connect the new device's host socket.
  /// Always factory-fresh (the bundled digest); make it stale afterwards with
  /// [AppDevice.setFirmwareDigest].
  Future<int> addDevice() async =>
      int.parse(await _requestData('add-device', effect: DriverEffect.mutates));

  /// Remove device [n] from the fleet: it is disconnected (daisy-chain semantics — its
  /// downstream falls off) and its number TOMBSTONED, never reused, so the surviving
  /// devices keep their numbers. Operations on a removed number error. Removal drops the
  /// device's state — save its state first if it matters.
  Future<void> removeDevice(int n) =>
      _requestData('remove-device:$n', effect: DriverEffect.mutates);

  /// The durable state of device [n] (seed + firmware digest + flash) as an opaque
  /// base64 saved state for [addDeviceFromSavedState]. Requires the device DISCONNECTED
  /// (unplug it, then pocket it — the physical action); the device stays in the fleet.
  Future<String> saveDeviceState(int n) =>
      _requestData('save-device-state:$n', effect: DriverEffect.observes);

  /// Restore a device from a [saveDeviceState] string as a NEW fleet member (fresh
  /// number) plugged into the chain tail; same identity, key shares intact. Rejects a
  /// saved state whose device identity is already live (one device per identity).
  Future<int> addDeviceFromSavedState(String state) async => int.parse(
    await _requestData(
      'add-device-from-saved-state:$state',
      effect: DriverEffect.mutates,
    ),
  );

  /// Test support: cache device [n]'s in-app handle, REMOVE the device, then drive the
  /// CACHED handle through every stateful method. Returns one `op: error` line per
  /// probe — pinning that a stale handle errors clearly instead of succeeding or
  /// panicking below the FRB surface. (Removes the device as a side effect.)
  Future<String> staleDeviceHandleProbe(int n) =>
      _requestData('stale-handle-probe:$n', effect: DriverEffect.mutates);

  /// Delete every wallet from the COORDINATOR (via `coord.deleteKey` — the same path the "Hold to Delete"
  /// UI triggers) while the virtual devices KEEP their shares, so a recovery flow can restore it from them.
  /// Returns the number of wallets deleted.
  Future<int> deleteWallet() async => int.parse(
    await _requestData('delete-wallet', effect: DriverEffect.mutates),
  );

  // ---- device driving over the APP channel (FRB pool) ----
  // These drive the in-process `simDevicePool` via driver-data, so a scenario drives a device the
  // SAME way on host and emulator — the one device transport. Coordinates are
  // device-framebuffer coords (240x280), same as the device channel.

  /// Drive a device endpoint that CHANGES the device (press, connect, re-cable, type).
  Future<void> _device(String cmd) async {
    await _requestData(cmd, effect: DriverEffect.mutates);
  }

  /// Drive a device endpoint and return its reply — for the query endpoints (chain/id/is-connected/
  /// screen) that return data, not just an ack.
  Future<String> _deviceQuery(String cmd) =>
      _requestData(cmd, effect: DriverEffect.observes);

  /// Did the request fail because WE stopped waiting, leaving the app-side handler running — as
  /// opposed to the app answering with an error, which leaves nothing behind? Only the former can
  /// still land. Same predicate the driver path uses to recognise a timeout.
  static bool _weGaveUp(Object error) =>
      error is TimeoutException ||
      (error is DriverError && '$error'.contains('Timeout while executing'));

  /// Every app-channel driver-data request funnels through here so they share ONE client-side timeout:
  /// a slow/stuck app can't make a single request hang the scenario forever. (A FULLY wedged app —
  /// VM service unable to answer at all, e.g. a frozen UI thread — is caught by the runner's per-test
  /// deadline, since no client-side timeout can fire if the isolate never schedules the reply.)
  ///
  /// [effect] is required for the same reason it is on the driver wrappers: nothing cancels the
  /// app-side handler when this gives up, so a MUTATING endpoint can still complete after its
  /// caller has moved on (see [appChannelQuarantines]).
  Future<String> _requestData(
    String message, {
    required DriverEffect effect,
  }) async {
    _assertNoStray('requestData("$message")');
    try {
      final result = await _rawRequestData(message);
      await _checkAppErrors('requestData("$message")');
      return result;
    } catch (original) {
      if (original is AppErrorRaised) rethrow;
      // Quarantine FIRST, unconditionally. An app error explains the failure better and is raised
      // in preference — but if it were raised before this, an abandoned mutation would leave no
      // stray marked and the next command would proceed over work that may still land.
      if (appChannelQuarantines(
        effect: effect,
        abandoned: _weGaveUp(original),
      )) {
        _strayCommand = (
          phase: DriverPhase.action,
          verb: 'requestData("$message")',
        );
      }
      // Drain on the FAILURE path too: an app error is usually the reason the command failed.
      await _checkAppErrors('requestData("$message")');
      // Non-finder call: participates in app-exit/connection/action classification only.
      throw await _diagnosed(
        original,
        verb: 'requestData("$message") [${_appLiveness()}]',
      );
    }
  }

  /// NEVER wrap this in `driver.runUnsynchronized`. Frame sync is APP-SIDE GLOBAL state, and
  /// `runUnsynchronized` restores it to ON in a `finally` — so a data request nested inside an
  /// action (`tapTooltip` reads the semantics snapshot before it taps) silently re-enabled the
  /// frame sync the outer `_rawDriverCall` had just disabled. The following `driver.tap` then hit
  /// `waitForElement`'s `transientCallbackCount == 0` wait (handler_factory.dart), which a running
  /// animation never satisfies: the wallet's confetti hung a tap for the full 20s under parallel
  /// load, while the same test passed solo because the confetti had finished by then.
  ///
  /// A data request has no reason to touch frame sync: the app-side handler answers it directly and
  /// never calls `waitForElement`. Dropping the wrapper also saves two round trips per request.
  Future<String> _rawRequestData(String message) async {
    final started = DateTime.now();
    try {
      return await _boundedBySilentClock(
        driver.requestData(message),
        budget: _cmdTimeout,
        what: 'requestData("$message")',
      );
    } finally {
      final took = DateTime.now().difference(started);
      if (took > const Duration(seconds: 2)) {
        _note(
          '[harness] slow requestData("$message"): ${took.inMilliseconds}ms '
          '(${_appLiveness()})',
        );
      }
    }
  }

  /// Await [op], failing only on POSITIVE evidence the awaited half is
  /// stuck: the [budget] is charged against time WITHOUT a main-isolate
  /// beat, observed during THIS wait only ([SilentClock]), never against
  /// host wall-clock alone. A loaded-but-alive system — emulator guest
  /// descheduled by host builds — keeps beating and keeps its request open,
  /// where a fixed `.timeout` failed a healthy run (the startup-reliability
  /// 2-in-3). A wedged main isolate stops beating even while Rust threads
  /// keep logging, and fails on the unchanged budget; the hard cap bounds
  /// beating-but-unanswering, and the runner's per-test deadline bounds
  /// everything regardless.
  Future<T> _boundedBySilentClock<T>(
    Future<T> op, {
    required Duration budget,
    required String what,
  }) async {
    final clock = SilentClock(started: DateTime.now(), budget: budget);
    while (true) {
      try {
        return await op.timeout(const Duration(seconds: 1));
      } on TimeoutException {
        final now = DateTime.now();
        if (clock.expired(now: now, lastActivityAt: _liveness.lastBeatAt)) {
          throw TimeoutException(
            '$what unanswered: '
            '${clock.describe(now: now, lastActivityAt: _liveness.lastBeatAt)}',
            now.difference(clock.started),
          );
        }
      }
    }
  }

  /// [_requestData] with a caller-chosen timeout, for the few endpoints whose app-side
  /// work legitimately outlasts [_cmdTimeout] (e.g. typing a whole backup on a device).
  Future<String> _requestDataTimeout(
    String message,
    Duration timeout, {
    required DriverEffect effect,
  }) async {
    _assertNoStray('requestData("$message")');
    try {
      final result = await driver
          .requestData(message, timeout: timeout)
          .timeout(timeout);
      await _checkAppErrors('requestData("$message")');
      return result;
    } catch (original) {
      if (original is AppErrorRaised) rethrow;
      if (appChannelQuarantines(
        effect: effect,
        abandoned: _weGaveUp(original),
      )) {
        _strayCommand = (
          phase: DriverPhase.action,
          verb: 'requestData("$message")',
        );
      }
      await _checkAppErrors('requestData("$message")');
      throw await _diagnosed(
        original,
        verb: 'requestData("$message") [${_appLiveness()}]',
      );
    }
  }

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
    final csv = await _requestData(
      'recognized-device-ids',
      effect: DriverEffect.observes,
    );
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
    // Beat-charged deadline, same reasoning as [_boundedBySilentClock]: an
    // announce handshake grinding under load keeps the main isolate beating
    // and the wait alive; a dead app stops beating and fails on the
    // unchanged budget (hard-capped so a live app with a real recognition
    // bug still fails, just later and with the same clear error).
    final clock = SilentClock(started: DateTime.now(), budget: timeout);
    for (;;) {
      final got = await _recognizedIds();
      if (got.length == expected.length && got.containsAll(expected)) return;
      final now = DateTime.now();
      if (clock.expired(now: now, lastActivityAt: _liveness.lastBeatAt)) {
        throw StateError(
          'coordinator recognized {${got.join(',')}} but the connected chain is '
          '{${expected.join(',')}}: '
          '${clock.describe(now: now, lastActivityAt: _liveness.lastBeatAt)} '
          '(${_appLiveness()}; device announce/recognition did not settle)',
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
    final m =
        jsonDecode(await _requestData('metrics', effect: DriverEffect.observes))
            as Map<String, dynamic>;
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
    ExpectedFailure? expectedToFail,
  }) => Scenario.runInstances(
    name,
    1,
    (apps, s) => body(apps.single),
    deviceCount: deviceCount,
    flutterDevice: flutterDevice,
    withRegtest: withRegtest,
    extraDartDefines: extraDartDefines,
    expectedToFail: expectedToFail,
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
    // Re-assert (the device-render can lag the hold). Drive the ACTUAL fleet numbers —
    // they are session-scoped labels, not positions (android's converged fleet starts
    // past the tombstoned baked-in device, and a restarted generation continues higher).
    final fleet = await deviceNumbers();
    if (fleet.length != deviceCount) {
      throw StateError(
        'createWallet(deviceCount: $deviceCount) needs exactly that many '
        'connected devices, found $fleet',
      );
    }
    var confirmed = false;
    for (var attempt = 0; attempt < 8 && !confirmed; attempt++) {
      for (final n in fleet) {
        await device(n).holdConfirm(_keygenConfirmX, _keygenConfirmY);
      }
      confirmed = await exists('Yes');
    }
    if (!confirmed) {
      throw StateError('devices never confirmed the security code');
    }
    await tapUntil('Yes', RegExp('Unplug devices to continue'));
    for (final n in fleet) {
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
  /// repainting — the reason every driver ACTION here runs frame-sync-disabled), so a synchronized read
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
        effect: DriverEffect.observes,
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

  _AppLiveness _liveness;

  String _appLiveness() {
    final exit = _appExitStatus;
    return exit != null
        ? 'app process EXITED ($exit); ${_liveness.describe()}'
        : 'app process alive; ${_liveness.describe()}';
  }

  /// A harness-side diagnostic line: live on stderr like app output, and into
  /// the failure-artifact ring buffer so it lands next to the app lines it
  /// explains.
  void _note(String line) {
    stderr.writeln(line);
    _appLog.add(line);
    if (_appLog.length > 400) _appLog.removeAt(0);
  }

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

  /// How much longer the harness-side guard runs than the command it guards. The driver command
  /// carries its own timeout; if the outer guard used the SAME budget it would start earlier
  /// (it also covers the frame-sync toggles), win the race, and replace the command's specific
  /// failure with a generic one. The margin makes the informative error the one that surfaces.
  static const Duration _outerMargin = Duration(seconds: 5);

  /// Budget for the frame-sync toggles themselves — they are a round trip, not an interaction.
  static const Duration _syncTimeout = Duration(seconds: 10);

  /// Budget for the pre-dispatch finder resolve, and for the post-timeout liveness probe. Short:
  /// both only need to distinguish "immediately true" from "not happening".
  static const Duration _probeTimeout = Duration(seconds: 3);

  /// Set when a driver command timed out: neither `Future.timeout` nor the app-side command
  /// timeout CANCELS anything, so that operation is still running. Anything issued afterwards
  /// would race it — and the abandoned command's own `finally` can re-enable frame sync in the
  /// middle of it. Later calls fail fast against this instead of producing junk.
  ({DriverPhase phase, String verb})? _strayCommand;

  /// Set while the scenario is shutting down. Quarantine exists to stop a test trusting results
  /// that could be racing an in-flight command; teardown has no results to protect and MUST run,
  /// so it is exempt.
  bool _tearingDown = false;

  /// Refuse any NORMAL operation — either channel, mutation or observation — while something
  /// outstanding could corrupt its result. Only the `_raw*` diagnostic transports bypass this, so
  /// the failure being reported can still be probed and screenshotted.
  void _assertNoStray(String verb) {
    final stray = _strayCommand;
    if (stray == null || _tearingDown) return;
    throw SessionQuarantined(
      strayVerb: stray.verb,
      strayPhase: stray.phase,
      refusedVerb: verb,
    );
  }

  /// Run one phase against its own budget, tagging a timeout with the phase it died in.
  Future<T> _phase<T>(
    DriverPhase phase,
    DriverEffect effect,
    String verb,
    Duration budget,
    Future<T> Function() body, {
    Pattern? target,
  }) async {
    final started = DateTime.now();
    try {
      return await body().timeout(budget);
    } catch (e) {
      // Whichever layer noticed first. The driver's own command timeout usually beats the guard
      // above — and its message ("Timeout while executing tap") names the ACTION, never the step
      // inside it that stalled, which is the whole reason this wrapper exists.
      final isTimeout =
          e is TimeoutException ||
          (e is DriverError && '$e'.contains('Timeout while executing'));
      if (!isTimeout) rethrow;
      throw DriverPhaseTimeout(
        phase: phase,
        effect: effect,
        verb: verb,
        budget: budget,
        elapsed: DateTime.now().difference(started),
        abandoned: e is TimeoutException,
        target: target,
      );
    }
  }

  /// RAW driver transport — no failure diagnosis. Used by predicates ([_appears]/[exists], which
  /// treat failure as `false` and must not pay a probe per negative poll) and by the classifier's
  /// own snapshot probe (which must never diagnose itself — that would recurse).
  ///
  /// This is `driver.runUnsynchronized` opened up, so each phase gets its own budget and a timeout
  /// says which one it died in. `runUnsynchronized` is `SetFrameSync(false)` / action /
  /// `SetFrameSync(true)` under ONE budget shared with the action's own, which loses that.
  Future<T> _rawDriverCall<T>(
    Future<T> Function() call, {
    required DriverEffect effect,
    Duration? timeout,
    Duration? probeBudget,
    DateTime? deadline,
    String verb = 'driver call',
    SerializableFinder? preflight,
    Pattern? targetLabel,
  }) async {
    _assertNoStray(verb);
    final budget = timeout ?? _cmdTimeout;
    // A caller-supplied deadline bounds the WHOLE command, not just its action: the frame-sync
    // toggles carry their own budget and would otherwise overshoot it on their own.
    Duration cap(Duration d) {
      if (deadline == null) return d;
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) return Duration.zero;
      return left < d ? left : d;
    }

    try {
      await _phase(
        DriverPhase.frameSyncOff,
        effect,
        verb,
        cap(_syncTimeout),
        () => driver.sendCommand(const SetFrameSync(false)),
      );
      // NOT try/finally: a `finally` that throws REPLACES the exception being unwound, so a restore
      // failing against a still-blocked app would report frameSyncOn and lose the action timeout
      // that actually explains the failure. The primary error is held and rethrown instead.
      Object? primary;
      T? result;
      try {
        if (preflight != null) {
          // Presence WITHOUT hit-testability. The action's own resolve demands hit-testable, so a
          // miss here and a miss there are different facts the extension reports identically.
          await _phase(
            DriverPhase.preflight,
            effect,
            verb,
            cap((probeBudget ?? _probeTimeout) + _outerMargin),
            () => driver.waitFor(
              preflight,
              timeout: probeBudget ?? _probeTimeout,
            ),
          );
        }
        result = await _phase(
          DriverPhase.action,
          effect,
          verb,
          cap(budget + _outerMargin),
          call,
          target: targetLabel,
        );
      } catch (e) {
        primary = e;
      }
      try {
        await _phase(
          DriverPhase.frameSyncOn,
          effect,
          verb,
          // Attempted, but within what is LEFT: the caller must not wait another independent phase
          // budget past its deadline.
          cap(_syncTimeout),
          () => driver.sendCommand(const SetFrameSync(true)),
        );
      } catch (restoreFailed) {
        // With nothing else wrong this IS the failure, and it is terminal. Otherwise the restore
        // is still outstanding — record that so the session quarantines — but report the CAUSE: a
        // `finally` that throws replaces the error being unwound.
        if (primary == null) {
          primary = restoreFailed;
        } else if (restoreFailed is DriverPhaseTimeout) {
          _strayCommand = (phase: DriverPhase.frameSyncOn, verb: verb);
        }
      }
      if (primary == null) {
        await _checkAppErrors(verb, deadline: deadline);
        return result as T;
      }
      // The timeout's own policy runs FIRST and unconditionally: it is what marks a stray, and an
      // app error raised ahead of it would leave a still-pending mutation unrecorded. The app error
      // is then raised in preference as the better explanation — never instead of the bookkeeping.
      final reported = primary is DriverPhaseTimeout
          ? await _afterPhaseTimeout(primary, verb: verb, deadline: deadline)
          : primary;
      await _checkAppErrors(verb, deadline: deadline);
      throw reported;
    } on DriverPhaseTimeout catch (e) {
      // frameSyncOff failing lands HERE, before the checks below the action. Order matters exactly
      // as it does there: _afterPhaseTimeout is what MARKS a stray, so it runs first and
      // unconditionally — an app error raised ahead of it would leave an abandoned command
      // unrecorded and the next one would proceed over work that may still land.
      final reported = await _afterPhaseTimeout(
        e,
        verb: verb,
        deadline: deadline,
      );
      await _checkAppErrors(verb, deadline: deadline);
      throw reported;
    }
  }

  /// The ONE place a phase timeout decides what it leaves behind, so no phase can quietly skip
  /// [quarantinesSession] (the frame-sync toggles run outside the action's own try, and used to).
  Future<Object> _afterPhaseTimeout(
    DriverPhaseTimeout e, {
    required String verb,
    DateTime? deadline,
  }) async {
    if (quarantinesSession(
      effect: e.effect,
      phase: e.phase,
      abandoned: e.abandoned,
    )) {
      _strayCommand = (phase: e.phase, verb: verb);
    }
    if (e.phase != DriverPhase.action || e.effect != DriverEffect.mutates) {
      return e;
    }
    // No label to ask about (a tooltip, a coordinate, a text entry): say so, rather than let a
    // missing answer read as "the app stopped responding" — those are different facts.
    if (e.target == null) return e.withProbe(ProbeOutcome.notApplicable);
    // Out of time is NOT the same as asked-and-silent. Returning early here without sending the
    // probe and then reporting `unanswered` would claim an observation about the app that was never
    // made — the distinction ProbeOutcome exists to keep.
    if (deadline != null && !DateTime.now().isBefore(deadline)) {
      return e.withProbe(ProbeOutcome.notAttempted);
    }
    // The hit-test probe belongs to this call too, so it runs within what is left rather than on
    // its own budget: the phase timeout already says which phase died and that it is still running.
    final report = await _diagnosticWithin<String?>(
      deadline,
      () => _hitTestReport(e.target),
      null,
    );
    return report == null
        ? e.withProbe(ProbeOutcome.unanswered)
        : e.withProbe(ProbeOutcome.answered, report);
  }

  /// The app's own answer to "what is at this label, and what does a tap there hit?" — null when
  /// the app cannot say (no target recorded, or it stopped answering, which is itself reported).
  Future<String?> _hitTestReport(Pattern? target) async {
    if (target == null) return null;
    try {
      // The protocol takes a CONCRETE label, and `tap` takes a Pattern: interpolating a RegExp
      // would send its description ("RegExp: pattern=Send flags=") and the app would truthfully
      // answer that no widget carries it. Resolve the matcher against what is on stage first —
      // the same labels the finder matched — and ask about that one.
      final String? label;
      if (target is String) {
        label = target;
      } else {
        final onStage = await _probeOnStageLabels().timeout(_probeTimeout);
        label = onStage.where((l) => labelMatchesAny(target, [l])).firstOrNull;
      }
      if (label == null) return 'nothing on stage matches $target any more';
      return await _rawRequestData('hit-test:$label').timeout(_probeTimeout);
    } catch (_) {
      return null;
    }
  }

  /// The diagnosing driver wrapper: on failure, classify (label miss / app exited / action failure /
  /// connection drop) instead of surfacing a raw DriverError or TimeoutException. [finder] is the
  /// FINDER-phase Pattern only — typing/IME/non-finder phases must pass none, or a genuine action
  /// failure could be rewritten as a label miss.
  Future<T> _driverCall<T>(
    Future<T> Function() call, {
    required DriverEffect effect,
    Duration? timeout,
    Duration? probeBudget,
    DateTime? deadline,
    Pattern? finder,
    String verb = 'driver call',
    bool preflight = false,
    SerializableFinder? preflightFinder,
    String? scope,
  }) async {
    try {
      return await _rawDriverCall(
        call,
        timeout: timeout,
        verb: verb,
        // ACTIONS only. A wait is called precisely because its target is not on stage yet, so
        // resolving it first would cap every wait at the probe budget instead of its own.
        preflight:
            preflightFinder ??
            (preflight && finder != null
                ? find.bySemanticsLabel(finder)
                : null),
        effect: effect,
        probeBudget: probeBudget,
        deadline: deadline,
        targetLabel: finder,
      );
    } on SessionQuarantined {
      // NOT a fact about the target. The classifier below rewrites a failure whose finder is absent
      // into a label miss, which would turn "this session is poisoned" into "no such label" — the
      // same false-fact substitution the refusal exists to prevent.
      rethrow;
    } on AppErrorRaised {
      // Nor is this. A build failure typically REPLACES its subtree with an error widget, so the
      // finder is now absent and diagnosis would rewrite "the app threw" into "no such label",
      // dropping the summary and stack — the app's own explanation of the failure.
      rethrow;
    } catch (original) {
      // The driver resolved the finder and found SEVERAL targets, which it phrases as a fact about
      // its own widget search. The test needs which labels matched and how many reachable
      // instances each has — only the app can say that.
      if (_isAmbiguity('$original')) {
        // Probing for candidates is part of THIS call, so it is bounded by the same deadline: past
        // it, report the ambiguity without the counts rather than spend a probe budget the caller
        // is no longer waiting for.
        throw AmbiguousTarget(
          verb: verb,
          detail: await _diagnosticWithin(
            deadline,
            () => _describeAmbiguity(finder, '$original', within: scope),
            'several widgets matched "$finder" (no time left to count them)',
          ),
        );
      }
      // Diagnosis PROBES the app, and a caller's deadline has to bound the explaining as well as
      // the acting: against an app that has stopped answering, those probes wait out their own
      // budget and blow the deadline long after the action itself gave up. A phase timeout already
      // says which phase died and that it is still running, so there is something to report.
      // A SCOPED preflight miss must be explained by the scope, not by the whole screen: the global
      // probe would either find the label somewhere else entirely and report a generic action
      // failure, or miss it and still never say which ancestor was searched.
      if (scope != null &&
          original is DriverPhaseTimeout &&
          original.phase == DriverPhase.preflight) {
        throw StateError(
          '$verb failed: ${await _diagnosticWithin(deadline, () => _describeScopedMiss(scope, finder), 'no match within "$scope" (no time left to list it)')}',
        );
      }
      final diagnosed = await _diagnosticWithin<Object?>(
        deadline,
        () => _diagnosed(original, finder: finder, verb: verb),
        null,
      );
      if (diagnosed == null) rethrow;
      throw diagnosed;
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

  /// Take whatever Flutter errors the app has raised since the last drain, over the RAW transport.
  ///
  /// Raw on purpose: a drain that went through the checked path would itself be a checked boundary
  /// and recurse. Same reason failure diagnostics bypass the gated transport.
  /// What this session has already received, per app generation — see [AppErrorCursor]. Advanced
  /// only after a read RETURNS, so an abandoned read leaves it where it was.
  final _errorCursor = AppErrorCursor();

  Future<List<AppError>> _drainAppErrors(DateTime? deadline) async {
    // Bounded by the caller's deadline like every other post-command probe. Skipping is SAFE, not a
    // loss: the app holds its pending errors until something drains them, so the next command or
    // the end-of-scenario drain still reports them. Running past the deadline is not safe — it
    // silently re-breaks "the deadline covers the whole call".
    if (deadline != null && !DateTime.now().isBefore(deadline)) return const [];
    try {
      final payload =
          jsonDecode(
                await _diagnosticWithin(
                  deadline,
                  () => _rawRequestData(
                    'read-flutter-errors:${_errorCursor.generation ?? ''}'
                    ':${_errorCursor.sinceId}',
                  ),
                  '{"generation":"","events":[]}',
                ),
              )
              as Map<String, dynamic>;
      // Only now, holding the response, is it safe to move the cursor — and the generation decides
      // whether this is a continuation or a fresh app whose ids started over.
      return _errorCursor.accept(
        payload['generation'] as String? ?? '',
        AppError.fromJson(payload['events'] as List? ?? const []),
      );
    } catch (_) {
      // A drain that cannot be answered must not invent errors, and must not mask the failure the
      // caller is already handling.
      return const [];
    }
  }

  /// Drain after an operation — SUCCEEDED or FAILED — and throw if the app raised anything no
  /// active expectation claims. Attributed to [verb], which is the command it followed.
  Future<void> _checkAppErrors(String verb, {DateTime? deadline}) async {
    if (_tearingDown) return;
    final raised = await _drainAppErrors(deadline);
    if (raised.isEmpty) return;
    final unclaimed = <AppError>[];
    for (final e in raised) {
      if (_errorExpectations.any((x) => x.consume(e))) continue;
      unclaimed.add(e);
    }
    if (unclaimed.isEmpty) return;
    throw AppErrorRaised(verb: verb, errors: unclaimed);
  }

  final _errorExpectations = <AppErrorExpectation>[];

  /// Run [body] allowing Flutter errors matching [pattern]; anything else still fails, and the
  /// scope FAILS if nothing matched — an allowance that never fires is suppression.
  Future<T> expectAppErrors<T>(
    Pattern pattern,
    Future<T> Function() body,
  ) async {
    final expectation = AppErrorExpectation(pattern);
    _errorExpectations.add(expectation);
    try {
      final result = await body();
      await _checkAppErrors('expectAppErrors("$pattern")');
      if (!expectation.matched) {
        throw StateError(
          'expectAppErrors("$pattern") saw no matching Flutter error — the allowance is stale, '
          'and a stale allowance silently suppresses real ones',
        );
      }
      return result;
    } finally {
      _errorExpectations.remove(expectation);
    }
  }

  /// Why a scoped target did not resolve: the ancestor is absent, or it is there and holds nothing
  /// matching. Answered from the SCOPED endpoint, so the labels listed are the ones the action
  /// actually searched.
  Future<String> _describeScopedMiss(String scope, Pattern? label) async {
    final List<LabelCandidate> inScope;
    try {
      inScope = await _labelCandidates(withinKey: scope);
    } catch (e) {
      // ONLY the app's explicit not-found means the scope is absent. A transport timeout, a
      // malformed payload or a dead app means the scope was never observed at all — reporting that
      // as "no widget keyed X" would state a fact about the tree from a probe that never saw it.
      if ('$e'.contains('no widget keyed')) {
        return 'no widget keyed "$scope" is on stage, so nothing could be searched for "$label"';
      }
      return 'no match for "$label" within "$scope"; the app could not be asked what that scope '
          'holds ($e)';
    }
    final labels = inScope.map((c) => '"${c.label}"').toList();
    return 'no widget matches "$label" within "$scope" — labels in that scope: '
        '${labels.isEmpty ? '(none)' : labels.join(', ')}';
  }

  /// Run a diagnostic within what is LEFT of [deadline], falling back to [ifOutOfTime] when the
  /// budget is gone or the probe does not answer inside it.
  ///
  /// Checking that time remains and THEN letting a probe spend its own budget is not a bound: a
  /// probe started with a sliver left still runs to its own timeout, and the caller waits. The
  /// failures these explain are self-describing, so losing the extra detail costs little; blowing
  /// the caller's deadline to obtain it costs the deadline.
  Future<T> _diagnosticWithin<T>(
    DateTime? deadline,
    Future<T> Function() probe,
    T ifOutOfTime,
  ) async {
    if (deadline == null) return probe();
    final left = deadline.difference(DateTime.now());
    if (left <= Duration.zero) return ifOutOfTime;
    try {
      return await probe().timeout(left);
    } catch (_) {
      return ifOutOfTime;
    }
  }

  /// FlutterDriver's ambiguity failure, which it phrases as a widget-count fact. Raised while
  /// RESOLVING the finder, before the action is dispatched — which is what makes it safe to retry.
  static bool _isAmbiguity(String message) =>
      message.contains('ambiguously found multiple matching widgets');

  /// Ask the app which labels matched and how many instances a tap could reach. DIAGNOSTIC ONLY —
  /// it never authorizes an action, so its inherent raciness cannot decide anything.
  Future<String> _describeAmbiguity(
    Pattern? finder,
    String driverMessage, {
    String? within,
  }) async {
    if (finder == null) return 'several widgets matched';
    try {
      return describeAmbiguity(
        finder,
        await _labelCandidates(withinKey: within),
        driverCount: driverMatchCount(driverMessage),
        within: within,
      );
    } catch (e) {
      return 'several widgets matched "$finder"; the app could not be asked which ($e)';
    }
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

  Future<void> tap(Pattern label) => _tapWithin(label, _cmdTimeout);

  /// [tap] bounded by [budget] — the ONE attempt, preflight included, so a caller holding a
  /// deadline cannot overshoot it by a phase budget it never chose.
  Future<void> _tapWithin(
    Pattern label,
    Duration budget, {
    DateTime? deadline,
  }) => _driverCall(
    () => driver.tap(find.bySemanticsLabel(label), timeout: budget),
    finder: label,
    verb: 'tap("$label")',
    preflight: true,
    effect: DriverEffect.mutates,
    timeout: budget,
    probeBudget: budget < _probeTimeout ? budget : _probeTimeout,
    deadline: deadline,
  );

  /// Tap the ONE control matching [label] inside the widget keyed [ancestorKey] — the standard
  /// answer when a label is ambiguous only because the screen holds more than one region.
  ///
  /// The observed case: a dialog's own primary "Close" action and the dialog CHROME's header X are
  /// both labelled "Close" and both stay hit-testable, so no plain label can name either. Scoping
  /// to the dialog content picks the action without inventing a private key for the button or
  /// renaming anything a user hears.
  Future<void> tapWithin(String ancestorKey, Pattern label) {
    final scoped = find.descendant(
      of: find.byValueKey(ancestorKey),
      matching: find.bySemanticsLabel(label),
      matchRoot: true,
    );
    return _driverCall(
      () => driver.tap(scoped, timeout: _cmdTimeout),
      finder: label,
      verb: 'tapWithin("$ancestorKey", "$label")',
      // The SAME finder resolved without hit-testability BEFORE dispatch, exactly as `tap` does.
      // Without it a missing ancestor or descendant dies in the mutating ACTION phase, which
      // quarantines the session over a tap that was never sent.
      preflightFinder: scoped,
      scope: ancestorKey,
      effect: DriverEffect.mutates,
    );
  }

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
    // The composite READS the snapshot and then TAPS; the tap is what can still land, so the
    // whole thing is treated as mutating.
    effect: DriverEffect.mutates,
  );

  /// Tap the app surface at GLOBAL LOGICAL coordinates (origin top-left of the Flutter view) — the
  /// positional escape hatch for what no finder can target. Same coordinate space as the semantics
  /// snapshot's global bounds; no adb, no display-scale math, works on host and android alike.
  Future<void> tapAppAt(double x, double y) => _driverCall(
    () => _rawRequestData('tap-at:$x,$y'),
    verb: 'tapAppAt',
    effect: DriverEffect.mutates,
  );

  /// Tap [label] once it names exactly ONE reachable control — for a target that is briefly
  /// duplicated, e.g. two sheets stacked while one closes over the other.
  ///
  /// The decision boundary is the ACTION, never a count: it retries the tap itself and stops at the
  /// first one that succeeds, so it cannot fire twice and cannot act on a count that changed after
  /// it was read. Only [AmbiguousTarget] is retried — the driver raises it before dispatching, so
  /// nothing happened. A timeout is NOT retried: per [quarantinesSession] it may still land, and a
  /// second tap would be racing the first.
  Future<void> tapWhenUnique(
    Pattern label, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    await attemptUntilUnique(
      attempt: (remaining) => _tapWithin(label, remaining, deadline: deadline),
      timeout: timeout,
      target: '$label',
    );
  }

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
        timeout: timeout + const Duration(seconds: 1),
        verb: 'appears("$label")',
        effect: DriverEffect.observes,
      );
      return true;
    } on SessionQuarantined {
      // A refusal is not an answer about the label. Swallowing it as `false` reports a present
      // label as absent, and the test then branches wrongly far from the cause.
      rethrow;
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
        preflight: true,
        effect: DriverEffect.mutates,
      );
      await _driverCall(
        () => _typeViaIme(text),
        timeout: _imeTimeout,
        verb: 'enterText IME typing',
        effect: DriverEffect.mutates,
      );
      return;
    }
    _requireAgentKeyboard();
    await _driverCall(
      () => driver.tap(find.bySemanticsLabel(label), timeout: _cmdTimeout),
      finder: label,
      verb: 'enterText focus tap("$label")',
      preflight: true,
      effect: DriverEffect.mutates,
    );
    await _driverCall(
      () => driver.enterText(text, timeout: _cmdTimeout),
      verb: 'enterText typing',
      effect: DriverEffect.mutates,
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
        effect: DriverEffect.mutates,
      );
      return;
    }
    _requireAgentKeyboard();
    await _driverCall(
      () => driver.enterText(text, timeout: _cmdTimeout),
      verb: 'enterFocusedText typing',
      effect: DriverEffect.mutates,
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
      await _requestData('keyboard-visible', effect: DriverEffect.observes) ==
      'true';

  /// RAW variant for composites already under one diagnosing wrapper (enterText's IME phase).
  Future<bool> _rawKeyboardVisible() async =>
      await _rawRequestData('keyboard-visible') == 'true';

  /// Exact UNTRIMMED value length of the focused text field (the semantics snapshot trims values, so
  /// edge whitespace is invisible there). Throws if no text field is focused. The android REPLACE
  /// clear backspaces exactly this many times.
  Future<int> focusedTextLength() async => int.parse(
    await _requestData('focused-text-length', effect: DriverEffect.observes),
  );

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
    effect: DriverEffect.observes,
  );

  /// Text of the widget with `ValueKey(key)` — for content that has no stable semantic label (e.g. an
  /// address string, whose label IS the value we're trying to read). Reads this app's own widget tree,
  /// so it's per-app and can't be raced like the process-global system clipboard.
  // NO finder context: a ValueKey is absent from the semantics snapshot — key-as-Pattern would
  // always manufacture a false label miss.
  Future<String> getTextByKey(String key) => _driverCall(
    () => driver.getText(find.byValueKey(key), timeout: _cmdTimeout),
    verb: 'getTextByKey("$key")',
    effect: DriverEffect.observes,
  );

  /// The app clipboard, via the sim_app driver data handler — e.g. to read a wallet receive
  /// address after tapping its Copy button (the address Text has no stable label to target).
  Future<String> getClipboard() =>
      _requestData('clipboard', effect: DriverEffect.observes);

  /// Set the app clipboard (e.g. to seed a recipient address before tapping a Paste button), via
  /// the sim_app driver data handler. Portable counterpart to [getClipboard] — uses Flutter's
  /// Clipboard, so scenarios need no platform pasteboard tool (pbcopy/xclip) and stay cross-platform.
  Future<void> setClipboard(String text) =>
      _requestData('setclip:$text', effect: DriverEffect.mutates);

  /// The wallet's checksummed output descriptor — hand it to [SimFaucet.watchDescriptor] so the
  /// regtest node can watch the wallet and build PSBTs that spend it.
  Future<String> walletDescriptor() =>
      _requestData('wallet-descriptor', effect: DriverEffect.observes);

  /// Put a base64 [psbt] in front of the sim camera as the animated `crypto-psbt` QR another wallet
  /// would be displaying, and return how many QR parts it took. The app's scanner then reads it
  /// through its real decode path — nothing gets to skip ahead of the lens.
  Future<int> showPsbtQr(String psbt) async => int.parse(
    await _requestData('psbt-qr:$psbt', effect: DriverEffect.mutates),
  );

  /// Empty the sim camera's view, so a later scan can't re-decode the last [showPsbtQr].
  Future<void> hideQr() =>
      _requestData('psbt-qr-clear', effect: DriverEffect.mutates);

  Future<void> waitFor(
    Pattern label, {
    Duration timeout = const Duration(seconds: 30),
  }) => _driverCall(
    () => driver.waitFor(find.bySemanticsLabel(label), timeout: timeout),
    timeout: timeout + const Duration(seconds: 1),
    finder: label,
    verb: 'waitFor("$label")',
    effect: DriverEffect.observes,
  );

  Future<void> waitForAbsent(
    Pattern label, {
    Duration timeout = const Duration(seconds: 30),
  }) => _driverCall(
    () => driver.waitForAbsent(find.bySemanticsLabel(label), timeout: timeout),
    timeout: timeout + const Duration(seconds: 1),
    verb: 'waitForAbsent("$label")',
    effect: DriverEffect.observes,
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
        timeout: _minObserve + const Duration(seconds: 1),
        verb: 'exists("$label")',
        effect: DriverEffect.observes,
      );
      return true;
    } on SessionQuarantined {
      // A refusal is not an answer about the label. Swallowing it as `false` reports a present
      // label as absent, and the test then branches wrongly far from the cause.
      rethrow;
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
    // RAW: capturing evidence must work while quarantined — a screenshot of the failure is most
    // wanted exactly when the session has been poisoned.
    final png = base64Decode(await _rawRequestData('app-screenshot'));
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
    await _requestData('delete-secure-key', effect: DriverEffect.mutates);
  }

  /// Whether the app's secure key currently exists — verify a [deleteSecureKey] actually removed it.
  /// ANDROID-ONLY: errors on a host session.
  Future<bool> secureKeyExists() async =>
      (await _requestData(
        'secure-key-exists',
        effect: DriverEffect.observes,
      )) ==
      'true';

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
      try {
        await _captureExtra(dir);
      } catch (_) {}
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
    // RAW: `deviceNumbers` is a gated observation, so in a quarantined session it would throw here
    // and — because the caller's guard wraps the error-file write too — cost us error.txt itself.
    final csv = await _rawRequestData('device-numbers');
    for (final n
        in csv.isEmpty ? const <int>[] : csv.split(',').map(int.parse)) {
      try {
        await device(n).screen('${dir.path}/device-$n.png');
      } catch (_) {}
    }
  }

  /// Quit the app and delete the disposable app dir (which holds all harness
  /// screenshots) — no residue. The first cleanup error (if any) is rethrown once
  /// everything has been torn down.
  Future<void> tearDown() async {
    _tearingDown = true;
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

  /// The full text (`#N WORD1 … WORD25`) of the backup this device is currently
  /// DISPLAYING — privileged sim observation, independent of which display page is
  /// visible (the pen-and-paper analog). Throws if no backup is on screen.
  Future<String> displayedBackup() =>
      _session._deviceQuery('device-displayed-backup:$_number');

  /// The whole "write it down" half in ONE call: wait for this device's backup
  /// display, capture its full text, then drive the real paged display (swipes +
  /// the final hold, widget-owned geometry) until the device's own
  /// `BackupRecorded` fires for THIS display run. Returns the text — feed it to
  /// [typeBackup] for the entry half. Cancel/reset/power-off/replacement of the
  /// display before the confirm throws (lifecycle is never success); so does
  /// exceeding the deadline. Takes ~40 s.
  Future<String> recordBackup() => _session._requestDataTimeout(
    'device-record-backup:$_number',
    const Duration(minutes: 3),
    effect: DriverEffect.mutates,
  );

  /// Advance the paged backup display one page (the swipe span comes from the display
  /// widget's own geometry contract — no device pixels here).
  Future<void> backupDisplayNext() =>
      _session._device('device-backup-next:$_number');

  /// Hold the backup display's confirmation control long enough to confirm ("I've
  /// recorded it") — the point is probed from the confirmation page's own hit-testing.
  Future<void> backupDisplayConfirm() =>
      _session._device('device-backup-confirm:$_number');

  /// Type a full backup (`#N WORD1 … WORD25`, case-insensitive BIP39 words) on this
  /// device's backup-entry screen as REAL touches — numeric share index, letter keys
  /// (scrolling as needed), a word-selector tap per word. The device judges checksum
  /// validity itself; an invalid set types through and throws. Takes ~a minute.
  Future<void> typeBackup(String text) => _session._requestDataTimeout(
    'device-type-backup:$_number:$text',
    const Duration(minutes: 6),
    effect: DriverEffect.mutates,
  );

  /// Plug this device into / out of the chain (the router applies daisy-chain semantics) and WAIT until
  /// the coordinator's recognized set has caught up — so "connected" means connected AND recognized, and
  /// no caller races the per-device UI that only renders post-recognition.
  Future<void> setConnected(bool connected) async {
    await _session._device(
      'device-${connected ? 'connect' : 'disconnect'}:$_number',
    );
    await _session._awaitChainRecognized();
  }

  /// Set the firmware digest this device claims (64 hex chars) — any time,
  /// connected or not; the next announce (a replug's re-handshake, or the next
  /// boot) reports it. Any digest the coordinator doesn't recognize makes the
  /// app offer the bundled sim-image upgrade, so this is how a scenario
  /// invalidates an EXISTING device's firmware and forces the upgrade flow.
  Future<void> setFirmwareDigest(String digestHex) =>
      _session._device('device-set-firmware-digest:$_number:$digestHex');

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

  /// This device's CURRENT id. Stable across connect/disconnect and a saved-state
  /// restore; a device that has been ERASED comes back with a new one (the erase wipes
  /// the flash header the id derives from), so never cache it across an erase.
  Future<String> deviceId() => _session._deviceQuery('device-id:$_number');

  /// Write the device framebuffer to [path] as a PNG (the endpoint returns a base64 PNG).
  Future<void> screen(String path) async {
    // RAW: device-frame capture is failure diagnostics, same as the app screenshot.
    final b64 = await _session._rawRequestData('device-screen:$_number');
    await File(path).writeAsBytes(base64Decode(b64));
  }
}

/// `SimHarness` was the desktop session shape — an [AppSession] plus host `device-<n>.sock` channels.
/// Now that devices drive over the app channel on every platform (see [AppDevice]), the two shapes
/// are one; this alias keeps existing callers compiling.
typedef SimHarness = AppSession;
