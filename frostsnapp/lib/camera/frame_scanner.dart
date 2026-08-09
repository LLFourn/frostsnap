import 'package:flutter/material.dart';
import 'package:frostsnap/snackbar.dart';
import 'package:frostsnap/src/rust/api/camera.dart' as camera;

class FrameScanResult<T> {
  final T? result;
  final double? progress;
  final String? error;

  const FrameScanResult({this.result, this.progress, this.error});

  static FrameScanResult<T> success<T>(T result) =>
      FrameScanResult(result: result);

  static FrameScanResult<T> withProgress<T>(double progress) =>
      FrameScanResult(progress: progress);

  static FrameScanResult<T> withError<T>(String error) =>
      FrameScanResult(error: error);
}

/// A lens fills the screen with its camera preview plus any lens-specific
/// controls, and reports frames through `onFrame`. Everything downstream of a
/// frame — decoding, progress, the error snackbar, popping with the result —
/// lives in [FrameScanner], so every lens shares the one implementation of it.
typedef LensBuilder =
    Widget Function(void Function(camera.Frame frame) onFrame);

class FrameScanner<T> extends StatefulWidget {
  final String title;
  final Future<FrameScanResult<T>> Function(camera.Frame) scanFrame;
  final LensBuilder lens;

  const FrameScanner({
    super.key,
    required this.title,
    required this.scanFrame,
    required this.lens,
  });

  @override
  State<FrameScanner<T>> createState() => _FrameScannerState<T>();
}

class _FrameScannerState<T> extends State<FrameScanner<T>> {
  double? progress;
  bool _finishedScanning = false;

  Future<void> _onFrame(camera.Frame frame) async {
    if (_finishedScanning) return;

    try {
      final result = await widget.scanFrame(frame);
      if (_finishedScanning || !mounted) return;

      if (result.error != null) {
        showErrorSnackbar(context, result.error!);
        return;
      }

      if (result.progress != null && progress != result.progress) {
        setState(() {
          progress = result.progress!;
        });
      }

      if (result.result != null) {
        setState(() {
          _finishedScanning = true;
        });
        Navigator.pop(context, result.result);
      }
    } catch (e) {
      if (mounted && !_finishedScanning) {
        showErrorSnackbar(context, "Error scanning frame: $e");
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          widget.lens(_onFrame),
          Positioned(
            top: MediaQuery.of(context).padding.top + 16,
            left: 16,
            child: FilledButton.tonal(
              onPressed: () => Navigator.pop(context),
              style: FilledButton.styleFrom(
                shape: const CircleBorder(),
                padding: const EdgeInsets.all(12),
                backgroundColor: colorScheme.surface.withValues(alpha: 0.8),
                foregroundColor: colorScheme.onSurface,
              ),
              child: const Icon(Icons.close),
            ),
          ),
          Positioned(
            bottom: 140,
            left: 24,
            right: 24,
            child: Card(
              elevation: 8,
              color: colorScheme.surface.withValues(alpha: 0.8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.qr_code_scanner,
                          color: colorScheme.onSurface,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          widget.title,
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: colorScheme.onSurface,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    if (progress != null) ...[
                      const SizedBox(height: 16),
                      LinearProgressIndicator(
                        value: progress,
                        backgroundColor: colorScheme.surfaceContainerHighest,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          colorScheme.primary,
                        ),
                        minHeight: 6,
                        borderRadius: BorderRadius.circular(3),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        "${(progress! * 100).round()}% complete",
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
