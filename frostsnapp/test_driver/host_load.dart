import 'dart:io';

// Several sessions share one machine, and when they swamp it an emulator or app is starved: a
// command times out and it reads like the app hanging. When the host has more runnable work than
// cores, a failure should say so before anyone debugs the app.

/// The 1-minute load average from `sysctl -n vm.loadavg` (`{ 8.56 9.73 11.43 }`) or
/// `/proc/loadavg` (`8.56 9.73 11.43 3/1234 5678`), or null if [raw] is neither.
double? parseLoad1(String raw) {
  final first = RegExp(r'\d+(?:\.\d+)?').firstMatch(raw)?.group(0);
  return first == null ? null : double.tryParse(first);
}

/// Why the host is the likely cause, or null when it has cores to spare.
String? hostLoadFinding({required double load1, required int cores}) {
  if (load1 <= cores) return null;
  return 'the host is overloaded (load ${load1.toStringAsFixed(1)} on $cores cores), so the '
      'app or emulator may simply be starved — suspect that before the app';
}

/// [hostLoadFinding] for this machine, or null when the load cannot be read — this only ever adds
/// to a report, so it must not replace the failure it explains.
Future<String?> currentHostLoadFinding() async {
  try {
    final String raw;
    if (Platform.isMacOS) {
      raw =
          (await Process.run('sysctl', [
                '-n',
                'vm.loadavg',
              ]).timeout(const Duration(seconds: 2))).stdout
              as String;
    } else if (Platform.isLinux) {
      raw = await File('/proc/loadavg').readAsString();
    } else {
      return null;
    }
    final load1 = parseLoad1(raw);
    if (load1 == null) return null;
    return hostLoadFinding(load1: load1, cores: Platform.numberOfProcessors);
  } catch (_) {
    return null;
  }
}
