import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:frostsnap/snackbar.dart';
import 'package:frostsnap/src/rust/api/camera.dart' as camera;

class MobileQrScanner<T> extends StatefulWidget {
  final String title;
  final Future<T?> Function(BarcodeCapture) onDetect;
  final Widget? overlayWidget;

  const MobileQrScanner({
    super.key,
    required this.title,
    required this.onDetect,
    this.overlayWidget,
  });

  @override
  State<MobileQrScanner<T>> createState() => _MobileQrScannerState<T>();
}

class _MobileQrScannerState<T> extends State<MobileQrScanner<T>> {
  final controller = MobileScannerController(
    facing: CameraFacing.back,
    returnImage: true,
    detectionSpeed: DetectionSpeed.normal,
    // Lower resolution significantly improves animated PSBT scanning speed
    // without noticeably affecting single-frame address QR detection
    cameraResolution: Size(640, 480),
  );
  double _zoom = 0.0;
  double _baseZoom = 0.0;
  bool finishedScanning = false;

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (finishedScanning) return;
    try {
      final result = await widget.onDetect(capture);
      if (result != null && !finishedScanning && mounted) {
        finishedScanning = true;
        Navigator.pop(context, result);
      }
    } catch (e) {
      if (mounted) {
        showErrorSnackbar(context, "Error scanning QR: $e");
      }
    }
  }

  Future<void> _updateZoom(double newZoom) async {
    if ((newZoom - _zoom).abs() > 0.03) {
      setState(() => _zoom = newZoom);
      try {
        await controller.setZoomScale(_zoom);
      } catch (e) {
        // ignore
      }
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          GestureDetector(
            onScaleStart: (details) => _baseZoom = _zoom,
            onScaleUpdate: (details) {
              final newZoom = (_baseZoom + (details.scale - 1.0) * 0.3).clamp(
                0.0,
                1.0,
              );
              _updateZoom(newZoom);
            },
            child: MobileScanner(controller: controller, onDetect: _onDetect),
          ),
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
            bottom: 50,
            left: 20,
            right: 20,
            child: Card(
              color: colorScheme.surface.withValues(alpha: 0.8),
              elevation: 4,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.zoom_out,
                      color: colorScheme.onSurface,
                      size: 20,
                    ),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          activeTrackColor: colorScheme.primary,
                          inactiveTrackColor: colorScheme.outline,
                          thumbColor: colorScheme.primary,
                          overlayColor: colorScheme.primary.withValues(
                            alpha: 0.8,
                          ),
                        ),
                        child: Slider(
                          value: _zoom,
                          onChanged: (value) => _updateZoom(value),
                        ),
                      ),
                    ),
                    Icon(Icons.zoom_in, color: colorScheme.onSurface, size: 20),
                  ],
                ),
              ),
            ),
          ),
          if (widget.overlayWidget != null)
            Positioned(
              bottom: 140,
              left: 24,
              right: 24,
              child: widget.overlayWidget!,
            ),
        ],
      ),
    );
  }
}

/// The lens Android/iOS ship: CameraX via `mobile_scanner`, so a frame only
/// reaches `onFrame` once MLKit has already spotted a barcode in it.
class MobileCameraLens extends StatefulWidget {
  final void Function(camera.Frame frame) onFrame;

  const MobileCameraLens({super.key, required this.onFrame});

  @override
  State<MobileCameraLens> createState() => _MobileCameraLensState();
}

class _MobileCameraLensState extends State<MobileCameraLens> {
  final controller = MobileScannerController(
    facing: CameraFacing.back,
    returnImage: true,
    detectionSpeed: DetectionSpeed.normal,
    // Lower resolution significantly improves animated PSBT scanning speed
    // without noticeably affecting single-frame address QR detection
    cameraResolution: Size(640, 480),
  );
  double _zoom = 0.0;
  double _baseZoom = 0.0;

  void _onDetect(BarcodeCapture capture) {
    final imageBytes = capture.image;
    if (imageBytes == null) return;
    widget.onFrame(camera.Frame(data: imageBytes, width: 0, height: 0));
  }

  Future<void> _updateZoom(double newZoom) async {
    if ((newZoom - _zoom).abs() > 0.03) {
      setState(() => _zoom = newZoom);
      try {
        await controller.setZoomScale(_zoom);
      } catch (e) {
        // ignore
      }
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Stack(
      children: [
        GestureDetector(
          onScaleStart: (details) => _baseZoom = _zoom,
          onScaleUpdate: (details) {
            final newZoom = (_baseZoom + (details.scale - 1.0) * 0.3).clamp(
              0.0,
              1.0,
            );
            _updateZoom(newZoom);
          },
          child: MobileScanner(controller: controller, onDetect: _onDetect),
        ),
        Positioned(
          bottom: 50,
          left: 20,
          right: 20,
          child: Card(
            color: colorScheme.surface.withValues(alpha: 0.8),
            elevation: 4,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(28),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.zoom_out, color: colorScheme.onSurface, size: 20),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: colorScheme.primary,
                        inactiveTrackColor: colorScheme.outline,
                        thumbColor: colorScheme.primary,
                        overlayColor: colorScheme.primary.withValues(
                          alpha: 0.8,
                        ),
                      ),
                      child: Slider(
                        value: _zoom,
                        onChanged: (value) => _updateZoom(value),
                      ),
                    ),
                  ),
                  Icon(Icons.zoom_in, color: colorScheme.onSurface, size: 20),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
