import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../test_driver/regtest.dart';

// Regression for the flattened session layout (fsim-eval-unified-drive Task 2): the regtest's files live
// FLAT in the session root (`regtest.{sock,url,log}`) next to daemon files + app dirs, so a regtest reap must
// own ONLY those files — never a recursive delete of the shared root. With no live backend,
// reapRegtestSessionDir exercises just the file-cleanup path.
void main() {
  test(
    'reap removes only the regtest files from a shared session root',
    () async {
      final root = Directory.systemTemp.createTempSync('fsim-flat-shared-');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      File('${root.path}/control.sock').writeAsStringSync('daemon');
      File('${root.path}/serve.log').writeAsStringSync('log');
      Directory('${root.path}/app-0').createSync();
      for (final n in ['regtest.sock', 'regtest.url', 'regtest.log']) {
        File('${root.path}/$n').writeAsStringSync('');
      }

      await reapRegtestSessionDir(root);

      expect(
        root.existsSync(),
        isTrue,
        reason: 'shared session root must survive a regtest reap',
      );
      expect(
        File('${root.path}/control.sock').existsSync(),
        isTrue,
        reason: 'daemon socket must survive',
      );
      expect(File('${root.path}/serve.log').existsSync(), isTrue);
      expect(
        Directory('${root.path}/app-0').existsSync(),
        isTrue,
        reason: 'app dir must survive',
      );
      for (final n in ['regtest.sock', 'regtest.url', 'regtest.log']) {
        expect(
          File('${root.path}/$n').existsSync(),
          isFalse,
          reason: '$n should be reaped',
        );
      }
    },
  );

  test('reap rmdirs a dedicated regtest dir once its files are gone', () async {
    final dir = Directory.systemTemp.createTempSync('fsim-flat-dedicated-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    for (final n in ['regtest.sock', 'regtest.url', 'regtest.log']) {
      File('${dir.path}/$n').writeAsStringSync('');
    }

    await reapRegtestSessionDir(dir);

    expect(
      dir.existsSync(),
      isFalse,
      reason: 'an emptied dedicated regtest dir should be rmdir-d',
    );
  });
}
