import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

import 'watermarked_video_recorder_platform_interface.dart';
import 'src/camera_description.dart';

/// An implementation of [WatermarkedVideoRecorderPlatform] that uses method channels.
class MethodChannelWatermarkedVideoRecorder extends WatermarkedVideoRecorderPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('watermarked_video_recorder');

  // Track current temp file for cleanup
  String? _currentTempPath;

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }

  @override
  Future<String?> testConnection() async {
    final result = await methodChannel.invokeMethod<String>('testConnection');
    return result;
  }

  @override
  Future<bool> requestCameraPermission() async {
    final result = await methodChannel.invokeMethod<bool>('requestCameraPermission');
    return result ?? false;
  }

  @override
  Future<bool> requestMicrophonePermission() async {
    final result = await methodChannel.invokeMethod<bool>('requestMicrophonePermission');
    return result ?? false;
  }

  @override
  Future<Map<String, bool>> requestRecordingPermissions() async {
    final result = await methodChannel.invokeMethod<Map<dynamic, dynamic>>('requestRecordingPermissions');
    if (result == null) return {'camera': false, 'microphone': false};

    return {'camera': result['camera'] as bool? ?? false, 'microphone': result['microphone'] as bool? ?? false};
  }

  @override
  Future<bool> initializeCamera() async {
    final result = await methodChannel.invokeMethod<bool>('initializeCamera');
    return result ?? false;
  }

  @override
  Future<List<CameraDescription>> getAvailableCameras() async {
    final result = await methodChannel.invokeMethod<List<dynamic>>('getAvailableCameras');
    if (result == null) return [];

    return result.map((camera) {
      final map = camera as Map<dynamic, dynamic>;
      return CameraDescription(
        id: map['id'] as String,
        direction: CameraLensDirection.values.firstWhere((d) => d.name == map['direction'], orElse: () => CameraLensDirection.back),
        label: map['label'] as String,
      );
    }).toList();
  }

  @override
  Future<bool> initializeCameraWithId(String cameraId) async {
    final result = await methodChannel.invokeMethod<bool>('initializeCameraWithId', {'cameraId': cameraId});
    return result ?? false;
  }

  @override
  Future<bool> initializeCameraWithDirection(CameraLensDirection direction) async {
    final result = await methodChannel.invokeMethod<bool>('initializeCameraWithDirection', {'direction': direction.name});
    return result ?? false;
  }

  @override
  Future<void> disposeCamera() async {
    await _cleanupTempFile();
    await methodChannel.invokeMethod<void>('disposeCamera');
  }

  @override
  Future<bool> startVideoRecording() async {
    final result = await methodChannel.invokeMethod<bool>('startVideoRecording');
    return result ?? false;
  }

  @override
  Future<String?> stopVideoRecording() async {
    final result = await methodChannel.invokeMethod<String>('stopVideoRecording');
    return result;
  }

  @override
  Future<bool> isRecording() async {
    final result = await methodChannel.invokeMethod<bool>('isRecording');
    return result ?? false;
  }

  @override
  Future<bool> saveVideoToGallery(String videoPath) async {
    final result = await methodChannel.invokeMethod<bool>('saveVideoToGallery', {'videoPath': videoPath});
    return result ?? false;
  }

  @override
  Future<void> setWatermarkImage(String path) async {
    await methodChannel.invokeMethod<void>('setWatermarkImage', {'path': path});
  }

  @override
  Future<bool> isCameraReady() async {
    final result = await methodChannel.invokeMethod<bool>('isCameraReady');
    return result ?? false;
  }

  @override
  Future<Map<String, dynamic>> getCameraState() async {
    final result = await methodChannel.invokeMethod<Map<dynamic, dynamic>>('getCameraState');
    if (result == null) return {};

    return Map<String, dynamic>.from(result);
  }

  @override
  Future<bool> startRecordingWithWatermark({required String watermarkPath, CameraLensDirection cameraDirection = CameraLensDirection.back}) async {
    try {
      print('startRecordingWithWatermark: Starting with direction: ${cameraDirection.name}');

      // Handle asset copying if needed
      String finalWatermarkPath = watermarkPath;
      if (watermarkPath.startsWith('assets/')) {
        print('startRecordingWithWatermark: Copying asset to temp directory');
        finalWatermarkPath = await _copyAssetToTemp(watermarkPath);
        _currentTempPath = finalWatermarkPath; // Track for cleanup
        print('startRecordingWithWatermark: Asset copied to: $finalWatermarkPath');
      }

      // Set watermark
      print('startRecordingWithWatermark: Setting watermark image');
      await setWatermarkImage(finalWatermarkPath);

      // Initialize camera
      print('startRecordingWithWatermark: Initializing camera with direction: ${cameraDirection.name}');
      final initSuccess = await initializeCameraWithDirection(cameraDirection);
      if (!initSuccess) {
        print('Failed to initialize camera with direction: ${cameraDirection.name}');
        return false;
      }
      print('startRecordingWithWatermark: Camera initialization returned success');

      // Check if camera is ready before starting recording
      print('startRecordingWithWatermark: Checking if camera is ready');
      final isReady = await isCameraReady();
      if (!isReady) {
        print('Camera not ready after initialization, waiting...');
        // Wait a bit more for camera to be ready
        await Future.delayed(const Duration(milliseconds: 500));
        final isReadyAfterWait = await isCameraReady();
        if (!isReadyAfterWait) {
          print('Camera still not ready after waiting');
          return false;
        }
        print('Camera became ready after waiting');
      } else {
        print('Camera is ready immediately');
      }

      // Start recording
      print('startRecordingWithWatermark: Starting video recording');
      final recordingSuccess = await startVideoRecording();
      if (!recordingSuccess) {
        print('Failed to start video recording');
        return false;
      }
      print('startRecordingWithWatermark: Video recording started successfully');

      return true;
    } catch (e) {
      print('Error in startRecordingWithWatermark: $e');
      // Clean up on error
      await _cleanupTempFile();
      await disposeCamera();
      return false;
    }
  }

  @override
  Future<String?> stopRecordingAndSaveToGallery() async {
    final videoPath = await stopVideoRecording();
    if (videoPath != null) {
      final saveSuccess = await saveVideoToGallery(videoPath);
      if (saveSuccess) {
        return videoPath; // Return path if save was successful
      } else {
        // Return path even if save failed, but log the failure
        print('Warning: Video recorded but failed to save to gallery');
        return videoPath;
      }
    }
    return null; // Return null if recording stop failed
  }

  /// Copy asset to temporary directory
  Future<String> _copyAssetToTemp(String assetPath) async {
    final byteData = await rootBundle.load(assetPath);
    final tempDir = await getTemporaryDirectory();
    final filename = assetPath.split('/').last;
    final file = File('${tempDir.path}/$filename');
    await file.writeAsBytes(byteData.buffer.asUint8List());
    return file.path;
  }

  /// Clean up temporary watermark file
  Future<void> _cleanupTempFile() async {
    if (_currentTempPath != null) {
      try {
        final file = File(_currentTempPath!);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        // Log but don't throw - cleanup failures shouldn't break the app
        print('Failed to cleanup temp file: $e');
      }
      _currentTempPath = null;
    }
  }

  @override
  Future<int?> startCameraPreview({CameraLensDirection cameraDirection = CameraLensDirection.back}) async {
    try {
      print('startCameraPreview: Starting preview with direction: ${cameraDirection.name}');

      final result = await methodChannel.invokeMethod<int>('startCameraPreview', {'direction': cameraDirection.name});

      print('startCameraPreview: Received texture ID: $result');
      return result;
    } catch (e) {
      print('Error in startCameraPreview: $e');
      return null;
    }
  }

  @override
  Future<void> stopCameraPreview() async {
    try {
      print('stopCameraPreview: Stopping preview');
      await methodChannel.invokeMethod<void>('stopCameraPreview');
      print('stopCameraPreview: Preview stopped successfully');
    } catch (e) {
      print('Error in stopCameraPreview: $e');
    }
  }

  @override
  Future<bool> isPreviewActive() async {
    try {
      final result = await methodChannel.invokeMethod<bool>('isPreviewActive');
      return result ?? false;
    } catch (e) {
      print('Error in isPreviewActive: $e');
      return false;
    }
  }

  @override
  Future<int?> getPreviewTextureId() async {
    try {
      final result = await methodChannel.invokeMethod<int>('getPreviewTextureId');
      return result;
    } catch (e) {
      print('Error in getPreviewTextureId: $e');
      return null;
    }
  }

  @override
  Future<int?> startPreviewWithWatermark({required String watermarkPath, CameraLensDirection cameraDirection = CameraLensDirection.back}) async {
    try {
      print('startPreviewWithWatermark: Starting preview with watermark');

      // Handle asset copying if needed
      String finalWatermarkPath = watermarkPath;
      if (watermarkPath.startsWith('assets/')) {
        print('startPreviewWithWatermark: Copying asset to temp directory');
        finalWatermarkPath = await _copyAssetToTemp(watermarkPath);
        _currentTempPath = finalWatermarkPath; // Track for cleanup
        print('startPreviewWithWatermark: Asset copied to: $finalWatermarkPath');
      }

      final result = await methodChannel.invokeMethod<int>('startPreviewWithWatermark', {
        'watermarkPath': finalWatermarkPath,
        'direction': cameraDirection.name,
      });

      print('startPreviewWithWatermark: Received texture ID: $result');
      return result;
    } catch (e) {
      print('Error in startPreviewWithWatermark: $e');
      // Clean up on error
      await _cleanupTempFile();
      return null;
    }
  }
}
