import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Drift guard for the drive-API reference (fsim-eval-unified-drive Task 3): every PUBLIC instance method of
// the `fsim eval` console-scope classes (AppSession, AppDevice, AppSemanticsInspector, SimFaucet) must be
// documented in test_driver/COMMANDS.md, so eval visibility can't silently fall behind the harness. Add a
// public method → document it (or add it to `ignore` if it is genuinely not a drive command).
void main() {
  final commands = File('test_driver/COMMANDS.md').readAsStringSync();

  // Public methods that are NOT user drive commands (lifecycle / internal plumbing) — intentionally absent.
  const ignore = {'tearDown', 'pingPid', 'closeFaucet'};

  Set<String> publicInstanceMethods(String file, String className) {
    final src = File(file).readAsStringSync();
    final start = src.indexOf('class $className');
    expect(
      start,
      greaterThanOrEqualTo(0),
      reason: 'class $className not in $file',
    );
    final after = src.substring(start);
    final end = after.indexOf('\n}'); // the class's column-0 closing brace
    final body = end < 0 ? after : after.substring(0, end);
    // A method decl at 2-space indent: `<return type> name(` with a lowercase name.
    final re = RegExp(
      r'^  (?:Future<[^;{]*>|[A-Za-z_][\w<>?,. ]*)\s+([a-z][A-Za-z0-9]*)\s*\(',
      multiLine: true,
    );
    final names = <String>{};
    for (final m in re.allMatches(body)) {
      final decl = m.group(0)!;
      if (decl.contains('static'))
        continue; // statics aren't `session.` drive verbs
      if (decl.trimLeft().startsWith('set '))
        continue; // setters are wiring, not drive verbs
      final name = m.group(1)!;
      if (!name.startsWith('_') && !ignore.contains(name)) names.add(name);
    }
    return names;
  }

  const scope = {
    'test_driver/sim_harness.dart': [
      'AppSession',
      'AppDevice',
      'AppSemanticsInspector',
    ],
    'lib/sim_faucet.dart': ['SimFaucet'],
  };

  for (final entry in scope.entries) {
    for (final cls in entry.value) {
      test('COMMANDS.md documents every public $cls method', () {
        final methods = publicInstanceMethods(entry.key, cls);
        expect(
          methods,
          isNotEmpty,
          reason: 'no methods parsed for $cls — regex drift?',
        );
        final undocumented =
            methods.where((m) => !commands.contains('$m(')).toList()..sort();
        expect(
          undocumented,
          isEmpty,
          reason:
              '$cls methods missing from test_driver/COMMANDS.md: $undocumented '
              '(document them or add to `ignore` if not drive commands)',
        );
      });
    }
  }
}
