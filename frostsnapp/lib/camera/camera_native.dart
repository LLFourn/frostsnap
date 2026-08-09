import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:frostsnap/src/rust/api/camera.dart' as camera;

/// The Linux/Windows lens: raw frames off a `CameraDevice` stream, previewed
/// by rendering each frame ourselves since there is no platform camera view.
class NativeCameraLens extends StatefulWidget {
  final void Function(camera.Frame frame) onFrame;

  const NativeCameraLens({super.key, required this.onFrame});

  @override
  State<NativeCameraLens> createState() => _NativeCameraLensState();
}

class _NativeCameraLensState extends State<NativeCameraLens> {
  List<camera.CameraDevice>? _devices;
  camera.CameraDevice? _selectedDevice;
  Uint8List? _latestFrame;
  String? _error;
  StreamSubscription? _cameraSubscription;

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  Future<void> _loadDevices() async {
    try {
      final devices = await camera.CameraDevice.list();
      if (!mounted) return;

      if (devices.isEmpty) {
        setState(() => _error = "No camera devices found");
        return;
      }

      setState(() {
        _devices = devices;
        _selectedDevice = devices.first;
      });

      _startCamera(_selectedDevice!);
    } catch (e) {
      if (mounted) {
        setState(() => _error = "Failed to list cameras: $e");
      }
    }
  }

  Future<void> _startCamera(camera.CameraDevice device) async {
    await _cameraSubscription?.cancel();
    _cameraSubscription = null;

    // Small delay to let the device be released
    await Future.delayed(const Duration(milliseconds: 100));

    try {
      final frameStream = device.start();

      _cameraSubscription = frameStream.listen((frame) {
        if (!mounted) return;
        setState(() {
          _latestFrame = Uint8List.fromList(frame.data);
        });
        widget.onFrame(frame);
      });

      setState(() {
        _error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = "Failed to start camera: $e");
      }
    }
  }

  void _switchCamera(camera.CameraDevice device) {
    if (device.index == _selectedDevice?.index) return;

    setState(() {
      _selectedDevice = device;
      _latestFrame = null;
    });

    _startCamera(device);
  }

  @override
  void dispose() {
    _cameraSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    Widget cameraPreview;
    if (_error != null) {
      cameraPreview = Center(
        child: Card(
          margin: const EdgeInsets.all(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline, size: 48, color: colorScheme.error),
                const SizedBox(height: 16),
                SelectableText(
                  _error!,
                  style: theme.textTheme.bodyLarge,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    } else if (_latestFrame != null) {
      // Display frame (should be JPEG for MJPG cameras)
      cameraPreview = Center(
        child: Image.memory(
          _latestFrame!,
          gaplessPlayback: true,
          fit: BoxFit.contain,
        ),
      );
    } else {
      cameraPreview = const Center(child: CircularProgressIndicator());
    }

    final devices = _devices;

    return Stack(
      children: [
        cameraPreview,
        if (devices != null && devices.isNotEmpty)
          Positioned(
            top: MediaQuery.of(context).padding.top + 16,
            left: 80,
            right: 20,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: Card(
                  color: colorScheme.surface.withValues(alpha: 0.9),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.videocam, color: colorScheme.onSurface),
                        const SizedBox(width: 12),
                        Expanded(
                          child: DropdownButton<int>(
                            value: _selectedDevice?.index.toInt(),
                            isExpanded: true,
                            underline: const SizedBox(),
                            dropdownColor: colorScheme.surface,
                            autofocus: false,
                            focusColor: Colors.transparent,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: colorScheme.onSurface,
                            ),
                            items: devices.map((device) {
                              return DropdownMenuItem(
                                value: device.index.toInt(),
                                child: Text(
                                  '${device.name} (${device.width}x${device.height})',
                                ),
                              );
                            }).toList(),
                            onChanged: (index) {
                              if (index != null) {
                                final device = devices.firstWhere(
                                  (d) => d.index.toInt() == index,
                                );
                                _switchCamera(device);
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
