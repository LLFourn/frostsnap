import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'sim_harness.dart';

// A desktop sim app must not outlive whatever launched it. A SIGKILLed test driver or runner never
// runs its teardown, and the runner's process-tree reap can't find an app whose parent is gone, so
// the app has to end itself.
//
// Host only. Run: `./fsim test app_owner_exit`.
Future<void> main() async {
  final device = Platform.environment['SIM_FLUTTER_DEVICE'] ?? 'macos';
  if (!const {'macos', 'linux', 'windows'}.contains(device)) {
    stdout.writeln(
      '$simTestSkippedMarker: an emulator app is not a host process',
    );
    return;
  }

  final owner = await Process.start('dart', [
    'run',
    'test_driver/app_owner_probe.dart',
  ]);
  owner.stderr.listen(stderr.add);
  final ownerPid = Completer<int>();
  owner.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((
    line,
  ) {
    stdout.writeln('[owner] $line');
    final m = RegExp(r'^OWNER_PID=(\d+)$').firstMatch(line);
    if (m != null && !ownerPid.isCompleted) {
      ownerPid.complete(int.parse(m.group(1)!));
    }
  });

  int? app;
  try {
    final ownerVm = await Future.any([
      ownerPid.future,
      owner.exitCode.then<int>(
        (code) => throw StateError(
          'the owner exited ($code) before launching the app',
        ),
      ),
    ]).timeout(const Duration(minutes: 10));
    final children = await Process.run('pgrep', ['-P', '$ownerVm']);
    final pids = (children.stdout as String)
        .split('\n')
        .map((l) => int.tryParse(l.trim()))
        .whereType<int>()
        .toList();
    if (pids.length != 1) {
      throw StateError(
        'expected the owner to have exactly one child, the app; got $pids',
      );
    }
    app = pids.single;

    Process.killPid(ownerVm, ProcessSignal.sigkill);

    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (_alive(app)) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError(
          'the app ($app) was still running 15s after its owner was SIGKILLed',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    stdout.writeln(
      'APP_OWNER_EXIT_OK: the app exited after its owner was SIGKILLed',
    );
  } finally {
    owner.kill(ProcessSignal.sigkill);
    if (app != null && _alive(app)) Process.killPid(app, ProcessSignal.sigkill);
  }
}

bool _alive(int pid) => Process.runSync('kill', ['-0', '$pid']).exitCode == 0;
