import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../test_driver/recording.dart';

// A clip whose last seconds are static ends at its last change, because screenrecord writes no
// frame while nothing moves. Holding the last frame must actually lengthen the file.
void main() {
  final hasFfmpeg =
      Process.runSync('which', ['ffmpeg']).exitCode == 0 &&
      Process.runSync('which', ['ffprobe']).exitCode == 0;
  final hasMagick = Process.runSync('which', ['magick']).exitCode == 0;

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

  group('composite', () {
    const origin = 10000000;
    const marker = 24 / 640;
    const red = [255, 0, 0, 255];
    const blue = [0, 0, 255, 255];
    const green = [0, 255, 0, 255];
    late Directory dir;

    /// [gaps] are spans with no frames, as a loaded emulator's screenrecord leaves.
    Future<String> appClip(
      List<(double, double)> markers, {
      List<(double, double)> gaps = const [],
    }) async {
      final clip = '${dir.path}/app.mp4';
      final filters = [
        for (final (on, off) in markers)
          'drawbox=x=0:y=308:w=24:h=24:color=0xFF00FF:t=fill:'
              "enable='between(t,$on,$off)'",
        for (final (from, to) in gaps) "select='not(between(t,$from,$to))'",
      ];
      final made = await Process.run('ffmpeg', [
        '-y',
        '-loglevel',
        'error',
        '-f',
        'lavfi',
        '-i',
        'color=gray:size=360x640:rate=30:duration=4',
        if (filters.isNotEmpty) ...['-vf', filters.join(',')],
        '-fps_mode',
        'passthrough',
        '-pix_fmt',
        'yuv420p',
        clip,
      ]);
      expect(made.exitCode, 0, reason: '${made.stderr}');
      return clip;
    }

    Future<TimelineFrame> frame(String name, int at, List<int> rgba) async {
      final file = '${dir.path}/$name.rgba';
      await File(
        file,
      ).writeAsBytes([for (var i = 0; i < 24 * 28; i++) ...rgba]);
      return (atMicros: at, file: file);
    }

    Future<List<int>> pixel(String clip, double at, int x, int y) async {
      final run = await Process.run('ffmpeg', [
        '-loglevel',
        'error',
        '-ss',
        '$at',
        '-i',
        clip,
        '-frames:v',
        '1',
        '-vf',
        // 2×2, because a single pixel has no chroma sample in yuv420p.
        'crop=2:2:$x:$y',
        '-f',
        'rawvideo',
        '-pix_fmt',
        'rgb24',
        '-',
      ], stdoutEncoding: null);
      expect(run.exitCode, 0, reason: '${run.stderr}');
      return run.stdout as List<int>;
    }

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('composite-');
      addTearDown(() => dir.delete(recursive: true));
    });

    test(
      'the panel follows each device on the clip timeline and the markers are trimmed off',
      () async {
        final clip = await appClip([(0.5, 0.8), (3.0, 3.3)]);
        final out = '${dir.path}/out.mp4';
        final report = await compositeRecording(
          appClip: clip,
          output: out,
          devices: [
            DeviceTimeline(
              label: '1',
              width: 24,
              height: 28,
              frames: [
                await frame('a0', origin - 5000000, red),
                await frame('a1', origin + 2000000, blue),
              ],
            ),
            DeviceTimeline(
              label: '2',
              width: 24,
              height: 28,
              frames: [await frame('b0', origin, green)],
              removedAtMicros: origin + 2500000,
            ),
          ],
          startMarkerMicros: origin + 500000,
          endMarkerMicros: origin + 3000000,
          markerSize: marker,
          workDir: dir,
        );
        expect(report.originMicros, closeTo(origin, 34000));
        expect(report.uncertaintyMs, lessThan(34));
        expect(await durationOf(out), closeTo(2.2, 0.1));

        // The panel is centred beside the 360x640 app: two 48-high labels, two 56-high devices.
        const panelX = 360 + 24;
        const deviceA = 216 + 48 + 28;
        const deviceB = 216 + 48 + 56 + 48 + 28;
        // Clip time t is output time t - 0.83, the first frame without the start marker.
        final aEarly = await pixel(out, 0.7, panelX, deviceA);
        final aLate = await pixel(out, 1.7, panelX, deviceA);
        final bLive = await pixel(out, 1.0, panelX, deviceB);
        final bGone = await pixel(out, 2.0, panelX, deviceB);
        expect(aEarly[0], greaterThan(200));
        expect(aEarly[2], lessThan(60));
        expect(aLate[2], greaterThan(200));
        expect(aLate[0], lessThan(60));
        expect(bLive[1], greaterThan(200));
        expect(bLive[0], lessThan(60));
        expect((bGone[0] - bGone[1]).abs(), lessThan(20));
        expect((bGone[1] - bGone[2]).abs(), lessThan(20));
        final app = await pixel(out, 0.1, 12, 320);
        expect(app[0], closeTo(128, 20), reason: 'the start marker is trimmed');
      },
      skip: hasFfmpeg && hasMagick
          ? false
          : 'ffmpeg/ffprobe/magick not on PATH',
    );

    test(
      'a clip missing a marker is not composited',
      () async {
        final clip = await appClip([(0.5, 0.8)]);
        await expectLater(
          compositeRecording(
            appClip: clip,
            output: '${dir.path}/out.mp4',
            devices: [
              DeviceTimeline(
                label: '1',
                width: 24,
                height: 28,
                frames: [await frame('a0', origin, red)],
              ),
            ],
            startMarkerMicros: origin + 500000,
            endMarkerMicros: origin + 3000000,
            markerSize: marker,
            workDir: dir,
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('missed a marker'),
            ),
          ),
        );
      },
      skip: hasFfmpeg ? false : 'ffmpeg/ffprobe not on PATH',
    );

    test(
      'markers that disagree about the clip are not composited',
      () async {
        final clip = await appClip([(0.5, 0.8), (3.0, 3.3)]);
        await expectLater(
          compositeRecording(
            appClip: clip,
            output: '${dir.path}/out.mp4',
            devices: [
              DeviceTimeline(
                label: '1',
                width: 24,
                height: 28,
                frames: [await frame('a0', origin, red)],
              ),
            ],
            startMarkerMicros: origin + 500000,
            endMarkerMicros: origin + 2000000,
            markerSize: marker,
            workDir: dir,
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('out of step'),
            ),
          ),
        );
      },
      skip: hasFfmpeg ? false : 'ffmpeg/ffprobe not on PATH',
    );

    Future<CompositeReport> composite(
      String clip,
      double start,
      double end,
    ) async => compositeRecording(
      appClip: clip,
      output: '${dir.path}/out.mp4',
      devices: [
        DeviceTimeline(
          label: '1',
          width: 24,
          height: 28,
          frames: [await frame('a0', origin, red)],
        ),
      ],
      startMarkerMicros: origin + (start * 1e6).round(),
      endMarkerMicros: origin + (end * 1e6).round(),
      markerSize: marker,
      workDir: dir,
    );

    test(
      'a gap before each marker widens the uncertainty, even when the markers agree',
      () async {
        final clip = await appClip(
          [(0.5, 0.8), (3.0, 3.3)],
          gaps: [(0.1, 0.5), (2.6, 3.0)],
        );
        final report = await composite(clip, 0.5, 3.0);
        // The last frames without a marker are at 0.067 s and 2.567 s, 0.433 s before each.
        expect(report.uncertaintyMs, closeTo(217, 20));
        expect(
          (report.originMicros - origin).abs() / 1000,
          lessThanOrEqualTo(report.uncertaintyMs),
        );
      },
      skip: hasFfmpeg && hasMagick
          ? false
          : 'ffmpeg/ffprobe/magick not on PATH',
    );

    test(
      'gaps too wide to place the clip are not composited',
      () async {
        final clip = await appClip(
          [(0.9, 1.2), (3.0, 3.3)],
          gaps: [(0.2, 0.9), (2.3, 3.0)],
        );
        await expectLater(
          composite(clip, 0.9, 3.0),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('only to within'),
            ),
          ),
        );
      },
      skip: hasFfmpeg && hasMagick
          ? false
          : 'ffmpeg/ffprobe/magick not on PATH',
    );

    test(
      'markers whose intervals do not meet are bounded by both',
      () async {
        // Each marker, at 30 fps, bounds the origin to a 33 ms interval. Stamping the end marker
        // 100 ms late puts its interval 100 ms past the start's.
        final clip = await appClip([(0.5, 0.8), (3.0, 3.3)]);
        final report = await composite(clip, 0.5, 3.1);
        expect(report.uncertaintyMs, closeTo(67, 5));
        // The hull runs from the start interval's low end, the true origin, to 133 ms past it.
        expect(report.originMicros, closeTo(origin + 67000, 5000));
      },
      skip: hasFfmpeg && hasMagick
          ? false
          : 'ffmpeg/ffprobe/magick not on PATH',
    );

    test(
      'a marker in the first frame is not used',
      () async {
        final clip = await appClip([(0, 0.3), (3.0, 3.3)]);
        await expectLater(
          composite(clip, 0, 3.0),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('nothing bounds'),
            ),
          ),
        );
      },
      skip: hasFfmpeg && hasMagick
          ? false
          : 'ffmpeg/ffprobe/magick not on PATH',
    );
  });
}
