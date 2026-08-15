import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:frostsnap/global.dart';
import 'package:frostsnap/sim_camera.dart';
import 'package:frostsnap/src/rust/api/qr.dart';
import 'package:frostsnap/src/rust/api/camera.dart' as camera;
import 'camera_native.dart';
import 'camera_mobile.dart';
import 'frame_scanner.dart';

export 'frame_scanner.dart' show FrameScanResult;

LensBuilder _platformLens() {
  // A virtual device has no camera, so the sim points the scanner at [simCameraScene].
  // Only the lens is substituted — everything downstream of a frame is the real scanner.
  if (kSim) {
    return (onFrame) => SimCameraLens(onFrame: onFrame);
  }
  if (Platform.isLinux || Platform.isWindows) {
    return (onFrame) => NativeCameraLens(onFrame: onFrame);
  }
  return (onFrame) => MobileCameraLens(onFrame: onFrame);
}

// PSBT-specific scanner with progress overlay
class PsbtCameraReader extends StatefulWidget {
  const PsbtCameraReader({super.key});

  @override
  State<PsbtCameraReader> createState() => _PsbtCameraReaderState();
}

class _PsbtCameraReaderState extends State<PsbtCameraReader> {
  final qrReader = PsbtQrDecoder();
  bool _processing = false;
  double _currentProgress = 0.0;

  Future<FrameScanResult<Uint8List>> _scanPsbtFrame(camera.Frame frame) async {
    // Drop frame if already processing, return current progress
    if (_processing) return FrameScanResult(progress: _currentProgress);

    _processing = true;
    try {
      final status = await qrReader.decodeQrFrame(frame: frame);
      switch (status) {
        case QrDecoderStatus_Progress(:final progress):
          _currentProgress = progress.toDouble();
          return FrameScanResult(progress: _currentProgress);
        case QrDecoderStatus_Decoded(:final field0):
          return FrameScanResult(result: field0);
        case QrDecoderStatus_Failed(:final field0):
          return FrameScanResult(
            error: "Failed to decode QR: $field0",
            progress: _currentProgress,
          );
      }
    } catch (e) {
      return FrameScanResult(
        error: "Error decoding frame: $e",
        progress: _currentProgress,
      );
    } finally {
      _processing = false;
    }
  }

  @override
  void dispose() {
    qrReader.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FrameScanner<Uint8List>(
      title: "Scan PSBT",
      scanFrame: _scanPsbtFrame,
      lens: _platformLens(),
    );
  }
}

class AddressScanner extends StatefulWidget {
  const AddressScanner({super.key});

  @override
  State<AddressScanner> createState() => _AddressScannerState();
}

class _AddressScannerState extends State<AddressScanner> {
  bool _processing = false;

  Future<String?> _handleAddressDetection(capture) async {
    if (capture.barcodes.isNotEmpty) {
      return capture.barcodes.first.rawValue;
    }
    return null;
  }

  Future<FrameScanResult<String>> _scanAddressFrame(camera.Frame frame) async {
    if (_processing) return FrameScanResult();

    _processing = true;
    try {
      final qrStrings = await readQrCodeBytes(bytes: frame.data);
      if (qrStrings.isNotEmpty) {
        return FrameScanResult(result: qrStrings.first);
      }
      return FrameScanResult();
    } catch (e) {
      return FrameScanResult(error: "Error scanning QR: $e");
    } finally {
      _processing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (Platform.isLinux || Platform.isWindows) {
      return FrameScanner<String>(
        title: "Scan Address",
        scanFrame: _scanAddressFrame,
        lens: (onFrame) => NativeCameraLens(onFrame: onFrame),
      );
    }
    return MobileQrScanner<String>(
      title: 'Scan Address',
      onDetect: _handleAddressDetection,
    );
  }
}
