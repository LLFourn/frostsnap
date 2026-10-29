import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Re-encode [input] into [output] with its final frame held for [hold].
///
/// Android's `screenrecord` writes a frame only when the screen changes, so a clip whose last
/// seconds are static simply ends at its last change and the "hold on the result" never reaches
/// the file. `tpad=stop_mode=clone` repeats that last frame for as long as asked.
Future<void> holdLastFrame(
  String input,
  String output,
  Duration hold, {
  String ffmpeg = 'ffmpeg',
}) async {
  final seconds = hold.inMilliseconds / 1000;
  final ProcessResult run;
  try {
    run = await Process.run(ffmpeg, [
      '-y',
      '-loglevel',
      'error',
      '-i',
      input,
      '-vf',
      'tpad=stop_mode=clone:stop_duration=$seconds',
      output,
    ]);
  } on ProcessException catch (e) {
    throw StateError(
      'holding the last frame needs ffmpeg on PATH, and `$ffmpeg` could not be run: ${e.message}',
    );
  }
  if (run.exitCode != 0) {
    throw StateError(
      'ffmpeg could not hold the last frame of $input: ${(run.stderr as String).trim()}',
    );
  }
}

/// One device frame of a [DeviceTimeline]: raw RGBA in [file], rendered at [atMicros] on the clock
/// the recording markers were read on.
typedef TimelineFrame = ({int atMicros, String file});

/// What one device showed over a recording.
class DeviceTimeline {
  final String label;
  final int width;
  final int height;

  /// In render order, and never empty. The first may predate the recording: it is what the device
  /// showed when the recording started.
  final List<TimelineFrame> frames;

  /// When the device was found removed, if it was. Its slot shows its last frame greyed from then.
  final int? removedAtMicros;

  DeviceTimeline({
    required this.label,
    required this.width,
    required this.height,
    required this.frames,
    this.removedAtMicros,
  });
}

/// Where a recording's app clip was found to sit on the device frames' clock.
typedef CompositeReport = ({
  /// Device-clock time of the app clip's PTS 0, in µs.
  int originMicros,

  /// How far, in ms, [originMicros] can be from the truth. Measured against the app's own frames:
  /// latency the marker shares with every app frame moves both together, so it is not error.
  double uncertaintyMs,
});

/// ImageMagick has no usable default font, so the labels name one.
const compositeLabelFont = '/System/Library/Fonts/Supplemental/Arial.ttf';

/// The panel is resampled at this rate, so a device frame lands within one panel frame of its
/// render time.
const compositePanelFps = 30;

/// Above this the clip and the panel may be visibly out of step, so no composite is written.
const compositeMaxUncertaintyMs = 250.0;

/// Compose [appClip] with [devices] beside it into [output], aligned by the two markers the clip
/// contains: the square patch the app drew on the left edge at mid-height at [startMarkerMicros]
/// and again at [endMarkerMicros], [markerSize] of the clip's height on a side. Both markers are
/// trimmed off. Needs `ffmpeg` and `magick`.
Future<CompositeReport> compositeRecording({
  required String appClip,
  required String output,
  required List<DeviceTimeline> devices,
  required int startMarkerMicros,
  required int endMarkerMicros,
  required double markerSize,
  required Directory workDir,
  Duration holdLast = Duration.zero,
  String ffmpeg = 'ffmpeg',
  String magick = 'magick',
}) async {
  final appHeight = await _videoHeight(appClip, ffmpeg);
  // The middle half of the patch, on even pixels, so anti-aliasing and chroma subsampling at its
  // edges never reach the sample.
  final quarter = (markerSize * appHeight / 4).floor() & ~1;
  final markerRect = (
    x: quarter,
    y: (appHeight ~/ 2 - quarter) & ~1,
    w: 2 * quarter,
    h: 2 * quarter,
  );
  final runs = await _markerRuns(appClip, markerRect, ffmpeg);
  if (runs.length < 2) {
    throw StateError(
      'expected the start and end markers in $appClip, found ${runs.length} magenta run(s); '
      'the recording missed a marker, so it cannot be aligned',
    );
  }
  final start = runs.first;
  final end = runs.last;
  // A frame's PTS is when it reached the screen, so each patch arrived after the last frame
  // without it and by the first frame with it. Each marker therefore bounds the origin to an
  // interval. Intervals that do not meet mean the render-to-screen delay changed between the two;
  // then each holds the origin for its end of the clip, and only their hull bounds both.
  (int, int) originBounds(int drawnAt, _MarkerRun run) => (
    drawnAt - (run.firstWith * 1e6).round(),
    drawnAt - (run.lastWithout * 1e6).round(),
  );
  final (startLow, startHigh) = originBounds(startMarkerMicros, start);
  final (endLow, endHigh) = originBounds(endMarkerMicros, end);
  final meet = math.max(startLow, endLow) <= math.min(startHigh, endHigh);
  final low = meet ? math.max(startLow, endLow) : math.min(startLow, endLow);
  final high = meet
      ? math.min(startHigh, endHigh)
      : math.max(startHigh, endHigh);
  final originMicros = (low + high) ~/ 2;
  final uncertaintyMs = (high - low) / 2000;
  if (uncertaintyMs > compositeMaxUncertaintyMs) {
    throw StateError(
      'the markers place the clip only to within ${uncertaintyMs.toStringAsFixed(0)} ms '
      '(limit ${compositeMaxUncertaintyMs.toStringAsFixed(0)} ms), so the device panel could be '
      'out of step with the app',
    );
  }

  final from = start.firstWithout;
  final to = end.firstWith;
  final panelFrames = ((to - from) * compositePanelFps).floor();
  final panels = <String>[];
  final labels = <String>[];
  for (final (i, device) in devices.indexed) {
    final panel = '${workDir.path}/panel-$i.mkv';
    await _encodePanel(
      device,
      panel,
      firstMicros: originMicros + (from * 1e6).round(),
      frameCount: panelFrames,
      ffmpeg: ffmpeg,
    );
    panels.add(panel);
    final label = '${workDir.path}/label-$i.png';
    await _run(magick, [
      '-size',
      '${device.width * 2}x48',
      'xc:black',
      '-fill',
      'white',
      '-font',
      compositeLabelFont,
      '-pointsize',
      '26',
      '-gravity',
      'center',
      '-annotate',
      '+0+0',
      device.label,
      label,
    ], what: 'drawing the label "${device.label}"');
    labels.add(label);
  }

  final inputs = <String>['-i', appClip];
  final graph = StringBuffer(
    '[0:v]trim=start=$from:end=$to,setpts=PTS-STARTPTS,fps=$compositePanelFps,'
    'format=yuv420p[app];',
  );
  for (final (i, panel) in panels.indexed) {
    inputs.addAll([
      '-i',
      panel,
      '-loop',
      '1',
      '-framerate',
      '$compositePanelFps',
      '-i',
      labels[i],
    ]);
    final dev = 1 + 2 * i;
    graph.write(
      '[${dev + 1}:v]format=yuv420p[l$i];'
      '[$dev:v]scale=iw*2:ih*2:flags=neighbor,format=yuv420p[d$i];'
      '[l$i][d$i]vstack=inputs=2:shortest=1[s$i];',
    );
  }
  final stacked = devices.length == 1
      ? '[s0]null[panel];'
      : '${[for (var i = 0; i < devices.length; i++) '[s$i]'].join()}'
            'vstack=inputs=${devices.length}[panel];';
  graph
    ..write(stacked)
    ..write(
      '[panel]scale=-2:\'min(ih,$appHeight)\':flags=neighbor,'
      'pad=iw:$appHeight:0:(oh-ih)/2:black[fit];'
      '[app][fit]hstack=inputs=2:shortest=1,fps=$compositePanelFps',
    );
  if (holdLast > Duration.zero) {
    graph.write(
      ',tpad=stop_mode=clone:stop_duration=${holdLast.inMilliseconds / 1000}',
    );
  }
  graph.write('[out]');
  await _run(ffmpeg, [
    '-y',
    '-loglevel',
    'error',
    ...inputs,
    '-filter_complex',
    '$graph',
    '-map',
    '[out]',
    '-c:v',
    'libx264',
    '-pix_fmt',
    'yuv420p',
    output,
  ], what: 'compositing $appClip');
  return (originMicros: originMicros, uncertaintyMs: uncertaintyMs);
}

/// PTS seconds around one showing of the marker: the frame before it, its first frame, and the
/// first frame after it.
typedef _MarkerRun = ({
  double lastWithout,
  double firstWith,
  double firstWithout,
});

/// Each contiguous run of frames whose [rect] is magenta.
Future<List<_MarkerRun>> _markerRuns(
  String clip,
  ({int x, int y, int w, int h}) rect,
  String ffmpeg,
) async {
  final probe = await _run(ffmpeg, [
    '-loglevel',
    'error',
    '-i',
    clip,
    '-vf',
    'crop=${rect.w}:${rect.h}:${rect.x}:${rect.y},signalstats,'
        'metadata=print:file=-',
    '-f',
    'null',
    '-',
  ], what: 'looking for the recording markers in $clip');
  final frames = <(double, bool)>[];
  ({double pts, double? u, double? v})? frame;
  void flush() {
    if (frame case (pts: final pts, u: final u?, v: final v?)) {
      // Magenta is far from neutral (128) in both chroma channels; nothing in the app's palette is.
      frames.add((pts, u > 180 && v > 180));
    }
  }

  for (final line in (probe.stdout as String).split('\n')) {
    if (_number(RegExp(r'pts_time:([\d.]+)'), line) case final pts?) {
      flush();
      frame = (pts: pts, u: null, v: null);
    } else if (frame != null) {
      frame = (
        pts: frame.pts,
        u: _number(RegExp(r'signalstats\.UAVG=([\d.]+)'), line) ?? frame.u,
        v: _number(RegExp(r'signalstats\.VAVG=([\d.]+)'), line) ?? frame.v,
      );
    }
  }
  flush();
  final runs = <_MarkerRun>[];
  double? before;
  double? on;
  double? onBefore;
  for (final (time, magenta) in frames) {
    if (magenta && on == null) {
      if (before == null) {
        throw StateError(
          'a marker is in the first frame of $clip, so nothing bounds when it arrived',
        );
      }
      on = time;
      onBefore = before;
    }
    if (!magenta) {
      if (on != null && onBefore != null) {
        runs.add((lastWithout: onBefore, firstWith: on, firstWithout: time));
        on = null;
      }
      before = time;
    }
  }
  if (on != null && onBefore != null) {
    runs.add((
      lastWithout: onBefore,
      firstWith: on,
      firstWithout: frames.last.$1,
    ));
  }
  return runs;
}

/// [device] resampled to [compositePanelFps] from [firstMicros], as a lossless clip.
Future<void> _encodePanel(
  DeviceTimeline device,
  String output, {
  required int firstMicros,
  required int frameCount,
  required String ffmpeg,
}) async {
  final proc = await Process.start(ffmpeg, [
    '-y',
    '-loglevel',
    'error',
    '-f',
    'rawvideo',
    '-pix_fmt',
    'rgba',
    '-s',
    '${device.width}x${device.height}',
    '-r',
    '$compositePanelFps',
    '-i',
    '-',
    '-c:v',
    'ffv1',
    output,
  ]);
  final stderr = proc.stderr.transform(const SystemEncoding().decoder).join();
  proc.stdout.drain<void>();
  final removedAt = device.removedAtMicros;
  final frames = device.frames;
  var next = 0;
  var shownFile = frames.first.file;
  var shown = await File(shownFile).readAsBytes();
  Uint8List? greyed;
  var cutShort = false;
  for (var k = 0; k < frameCount; k++) {
    final at = firstMicros + k * 1000000 ~/ compositePanelFps;
    while (next < frames.length && frames[next].atMicros <= at) {
      next++;
    }
    final file = frames[next == 0 ? 0 : next - 1].file;
    if (file != shownFile) {
      shown = await File(file).readAsBytes();
      shownFile = file;
      greyed = null;
    }
    try {
      proc.stdin.add(
        removedAt != null && at >= removedAt
            ? greyed ??= _greyed(shown)
            : shown,
      );
      // A long recording is gigabytes of raw frames, so they go no faster than ffmpeg takes them.
      await proc.stdin.flush();
    } catch (_) {
      cutShort = true;
      break;
    }
  }
  try {
    await proc.stdin.close();
  } catch (_) {}
  if (await proc.exitCode != 0 || cutShort) {
    throw StateError(
      'ffmpeg could not encode the panel for ${device.label}: ${(await stderr).trim()}',
    );
  }
}

Uint8List _greyed(Uint8List rgba) {
  final out = Uint8List.fromList(rgba);
  for (var i = 0; i < out.length; i += 4) {
    // Half the luminance, so a removed device reads as switched off rather than as a grey screen.
    final grey = (out[i] * 3 + out[i + 1] * 6 + out[i + 2]) ~/ 20;
    out[i] = out[i + 1] = out[i + 2] = grey;
  }
  return out;
}

Future<int> _videoHeight(String clip, String ffmpeg) async {
  final probe = await _run(ffmpeg, [
    '-hide_banner',
    '-i',
    clip,
    '-f',
    'null',
    '-frames:v',
    '1',
    '-',
  ], what: 'reading the size of $clip');
  final height = _number(RegExp(r', \d+x(\d+)'), probe.stderr as String);
  if (height == null) {
    throw StateError('ffmpeg reported no video size for $clip');
  }
  return height.toInt();
}

Future<ProcessResult> _run(
  String tool,
  List<String> args, {
  required String what,
}) async {
  final ProcessResult run;
  try {
    run = await Process.run(tool, args);
  } on ProcessException catch (e) {
    throw StateError(
      '$what needs $tool on PATH, and it could not be run: ${e.message}',
    );
  }
  if (run.exitCode != 0) {
    throw StateError('$what failed: ${(run.stderr as String).trim()}');
  }
  return run;
}

double? _number(RegExp pattern, String line) =>
    double.tryParse(pattern.firstMatch(line)?[1] ?? '');
