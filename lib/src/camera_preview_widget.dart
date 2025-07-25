import 'dart:io';
import 'package:flutter/material.dart';
import '../watermarked_video_recorder.dart';

/// A Flutter widget that displays a real-time camera preview
/// with optional watermark overlay using the watermarked_video_recorder plugin
class CameraPreviewWidget extends StatefulWidget {
  /// The camera direction to use for preview
  final CameraLensDirection cameraDirection;

  /// Optional watermark image path (asset or file path)
  final String? watermarkPath;

  /// Widget to display when camera is not ready
  final Widget? loadingWidget;

  /// Widget to display when camera fails to initialize
  final Widget? errorWidget;

  /// Callback when camera preview starts successfully
  final void Function(int textureId)? onPreviewStarted;

  /// Callback when camera preview stops
  final VoidCallback? onPreviewStopped;

  /// Callback when camera preview fails
  final Function(String error)? onPreviewError;

  /// How the preview should fit within the container
  final BoxFit fit;

  /// Optional: Use an existing texture ID instead of starting a new preview
  final int? textureId;

  const CameraPreviewWidget({
    super.key,
    this.cameraDirection = CameraLensDirection.back,
    this.watermarkPath,
    this.loadingWidget,
    this.errorWidget,
    this.onPreviewStarted,
    this.onPreviewStopped,
    this.onPreviewError,
    this.fit = BoxFit.contain,
    this.textureId,
  });

  @override
  State<CameraPreviewWidget> createState() => _CameraPreviewWidgetState();
}

class _CameraPreviewWidgetState extends State<CameraPreviewWidget> {
  final WatermarkedVideoRecorder _recorder = WatermarkedVideoRecorder();

  int? _textureId;
  bool _isPreviewActive = false;
  bool _isLoading = true;
  bool _hasError = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    if (widget.textureId != null) {
      // Use provided textureId, skip initialization
      setState(() {
        _textureId = widget.textureId;
        _isPreviewActive = true;
        _isLoading = false;
      });
      if (_textureId != null) {
        widget.onPreviewStarted?.call(_textureId!);
      }
    } else {
      _initializePreview();
    }
  }

  @override
  void dispose() {
    if (widget.textureId == null) {
      _stopPreview();
    }
    super.dispose();
  }

  Future<void> _initializePreview() async {
    try {
      setState(() {
        _isLoading = true;
        _hasError = false;
        _errorMessage = null;
      });

      // Request permissions first
      final permissions = await _recorder.requestRecordingPermissions();
      if (!(permissions['camera'] ?? false) || !(permissions['microphone'] ?? false)) {
        throw Exception('Camera and microphone permissions are required');
      }

      // Start preview based on whether watermark is provided
      if (widget.watermarkPath != null) {
        _textureId = await _recorder.startPreviewWithWatermark(watermarkPath: widget.watermarkPath!, cameraDirection: widget.cameraDirection);
      } else {
        _textureId = await _recorder.startCameraPreview(cameraDirection: widget.cameraDirection);
      }

      if (_textureId != null) {
        setState(() {
          _isPreviewActive = true;
          _isLoading = false;
        });
        widget.onPreviewStarted?.call(_textureId!);
      } else {
        throw Exception('Failed to get texture ID from camera preview');
      }
    } catch (e) {
      setState(() {
        _hasError = true;
        _errorMessage = e.toString();
        _isLoading = false;
      });
      widget.onPreviewError?.call(e.toString());
    }
  }

  Future<void> _stopPreview() async {
    if (_isPreviewActive) {
      try {
        await _recorder.stopCameraPreview();
        setState(() {
          _isPreviewActive = false;
          _textureId = null;
        });
        widget.onPreviewStopped?.call();
      } catch (e) {
        // Log error but don't throw since this is cleanup
        debugPrint('Error stopping camera preview: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return widget.loadingWidget ?? const Center(child: CircularProgressIndicator());
    }

    if (_hasError) {
      return widget.errorWidget ??
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 48, color: Colors.red),
                const SizedBox(height: 16),
                Text('Camera Error', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(_errorMessage ?? 'Unknown error occurred', style: Theme.of(context).textTheme.bodyMedium, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                ElevatedButton(onPressed: _initializePreview, child: const Text('Retry')),
              ],
            ),
          );
    }

    if (_textureId == null) {
      return const Center(child: Text('Camera preview not available'));
    }

    // Build the camera preview with proper aspect ratio and rotation
    return _buildCameraPreview();
  }

  Widget _buildCameraPreview() {
    // Platform-specific mirroring behavior:
    // - iOS: Native code sets isVideoMirrored = false, so we need to mirror front camera in Flutter
    // - Android: Native code doesn't handle mirroring, so system default applies (usually already mirrored)
    final shouldMirror = Platform.isIOS && widget.cameraDirection == CameraLensDirection.front;

    // Since we set videoOrientation to portrait, the dimensions should be 1080x1920
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Transform.scale(
        scaleX: shouldMirror ? -1.0 : 1.0, // Only mirror front camera on iOS
        scaleY: 1.0, // Keep vertical scale normal
        child: FittedBox(
          fit: widget.fit,
          child: SizedBox(
            width: 1080, // Portrait width (was 1920 for landscape)
            height: 1920, // Portrait height (was 1080 for landscape)
            child: Texture(textureId: _textureId!),
          ),
        ),
      ),
    );
  }
}
