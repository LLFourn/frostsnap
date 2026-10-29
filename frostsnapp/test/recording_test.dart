import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../test_driver/recording.dart';

// A clip whose last seconds are static ends at its last change, because screenrecord writes no
// frame while nothing moves. Holding the last frame must actually lengthen the file.
void main() {
  final hasFfmpeg =
      Process.runSync('which', ['ffmpeg']).exitCode == 0 &&
      Process.runSync('which', ['ffprobe']).exitCode == 0;

  Future<double> durationOf(String file) async {
    final probe = await Process.run('ffprobe', [
      '-v',
      'error',
      '-show_entries',
      'format=duration',
      '-of',
      'default=noprint_wrappers=1:nokey=1',
      file,
    ]);
    return double.parse((probe.stdout as String).trim());
  }

  test(
    'the final frame is held for as long as asked',
    () async {
      final dir = await Directory.systemTemp.createTemp('hold-last-');
      addTearDown(() => dir.delete(recursive: true));
      final clip = '${dir.path}/clip.mp4';
      final made = await Process.run('ffmpeg', [
        '-y',
        '-loglevel',
        'error',
        '-f',
        'lavfi',
        '-i',
        'testsrc=duration=1:size=64x64:rate=10',
        clip,
      ]);
      expect(made.exitCode, 0, reason: '${made.stderr}');

      final held = '${dir.path}/held.mp4';
      await holdLastFrame(clip, held, const Duration(seconds: 2));
      expect(await durationOf(clip), closeTo(1, 0.2));
      expect(await durationOf(held), closeTo(3, 0.2));
    },
    skip: hasFfmpeg ? false : 'ffmpeg/ffprobe not on PATH',
  );

  test('a missing ffmpeg is named in the failure', () async {
    await expectLater(
      holdLastFrame(
        'in.mp4',
        'out.mp4',
        const Duration(seconds: 1),
        ffmpeg: 'no-such-ffmpeg-binary',
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('needs ffmpeg'),
        ),
      ),
    );
  });
}
