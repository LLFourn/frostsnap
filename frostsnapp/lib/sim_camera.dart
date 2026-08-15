import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:frostsnap/src/rust/api/camera.dart' as camera;

/// What the sim's QR scanner "sees" — the stand-in for a phone camera pointed at another wallet's
/// screen. The harness sets the images (real encoded image bytes of real QR codes); the sim lens
/// subscribes to [frames] and gets them cycled at it like an animated QR held in front of a lens.
/// Everything downstream of the lens — grid detection, UR fountain assembly, PSBT parsing — is the
/// app's real code running on real image bytes.
///
/// Sim-only: `kSim` gates the single place a [SimCameraLens] is chosen, so a release build never
/// reaches this.
class SimCameraScene {
  List<Uint8List> _images = const [];

  /// How long each image stays in front of the lens. Slow enough that decoding a frame (which drops
  /// frames while it runs) can't starve out a part of a multi-part animated QR.
  Duration interval = const Duration(milliseconds: 150);

  /// Point the lens at these images, replacing whatever it was showing. Cycled in order, forever.
  void show(List<Uint8List> images) => _images = images;

  void clear() => _images = const [];

  /// A never-ending frame stream, like a running camera: it keeps producing while the scene is
  /// empty (yielding nothing) so a scanner opened before the harness sets a scene still works.
  Stream<camera.Frame> frames() async* {
    for (var tick = 0; ; tick++) {
      await Future<void>.delayed(interval);
      final images = _images;
      if (images.isEmpty) continue;
      yield camera.Frame(
        data: images[tick % images.length],
        width: 0,
        height: 0,
      );
    }
  }
}

final simCameraScene = SimCameraScene();

/// The sim's lens: frames come from [simCameraScene] instead of a camera, previewed like the
/// native lens previews its raw frames. Only the lens is substituted — a frame takes the same
/// path through the scanner a camera frame would.
class SimCameraLens extends StatefulWidget {
  final void Function(camera.Frame frame) onFrame;

  const SimCameraLens({super.key, required this.onFrame});

  @override
  State<SimCameraLens> createState() => _SimCameraLensState();
}

class _SimCameraLensState extends State<SimCameraLens> {
  StreamSubscription<camera.Frame>? _sub;
  Uint8List? _latest;

  @override
  void initState() {
    super.initState();
    _sub = simCameraScene.frames().listen((frame) {
      if (!mounted) return;
      setState(() => _latest = frame.data);
      widget.onFrame(frame);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final latest = _latest;
    if (latest == null) {
      return const ColoredBox(color: Colors.black);
    }
    return Center(
      child: Image.memory(latest, gaplessPlayback: true, fit: BoxFit.contain),
    );
  }
}
