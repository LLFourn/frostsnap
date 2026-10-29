import 'dart:io';

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
