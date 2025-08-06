import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'watermarked_video_recorder_platform_interface.dart';
import 'src/camera_description.dart';

// Export the camera description for public use
export 'src/camera_description.dart';
// Export the camera preview widget
export 'src/camera_preview_widget.dart';

class WatermarkedVideoRecorder {
  Future<String?> getPlatformVersion() {
    return WatermarkedVideoRecorderPlatform.instance.getPlatformVersion();
  }

  /// Simple test method to verify Flutter-to-native communication
  Future<String?> testConnection() {
    return WatermarkedVideoRecorderPlatform.instance.testConnection();
  }

  /// Request camera permission and return the status
  Future<bool> requestCameraPermission() {
    return WatermarkedVideoRecorderPlatform.instance.requestCameraPermission();
  }

  /// Request microphone permission and return the status
  Future<bool> requestMicrophonePermission() {
    return WatermarkedVideoRecorderPlatform.instance.requestMicrophonePermission();
  }

  /// Request both camera and microphone permissions
  Future<Map<String, bool>> requestRecordingPermissions() {
    return WatermarkedVideoRecorderPlatform.instance.requestRecordingPermissions();
  }

  /// Initialize camera for recording (without preview)
  Future<bool> initializeCamera() {
    return WatermarkedVideoRecorderPlatform.instance.initializeCamera();
  }

  /// Get list of available cameras
  Future<List<CameraDescription>> getAvailableCameras() {
    return WatermarkedVideoRecorderPlatform.instance.getAvailableCameras();
  }

  /// Initialize camera for recording (without preview) with specific camera
  Future<bool> initializeCameraWithId(String cameraId) {
    return WatermarkedVideoRecorderPlatform.instance.initializeCameraWithId(cameraId);
  }

  /// Initialize camera for recording (without preview) with lens direction
  Future<bool> initializeCameraWithDirection(CameraLensDirection direction) {
    return WatermarkedVideoRecorderPlatform.instance.initializeCameraWithDirection(direction);
  }

  /// Dispose camera resources
  Future<void> disposeCamera() {
    return WatermarkedVideoRecorderPlatform.instance.disposeCamera();
  }

  /// Start video recording
  Future<bool> startVideoRecording() {
    return WatermarkedVideoRecorderPlatform.instance.startVideoRecording();
  }

  /// Stop video recording and return the file path
  Future<String?> stopVideoRecording() {
    return WatermarkedVideoRecorderPlatform.instance.stopVideoRecording();
  }

  /// Check if currently recording
  Future<bool> isRecording() {
    return WatermarkedVideoRecorderPlatform.instance.isRecording();
  }

  /// Save video file to device gallery
  Future<bool> saveVideoToGallery(String videoPath) {
    return WatermarkedVideoRecorderPlatform.instance.saveVideoToGallery(videoPath);
  }

  /// Set the watermark image path (asset or file path)
  Future<void> setWatermarkImage(String path) {
    return WatermarkedVideoRecorderPlatform.instance.setWatermarkImage(path);
  }

  /// Check if camera is ready for recording
  Future<bool> isCameraReady() {
    return WatermarkedVideoRecorderPlatform.instance.isCameraReady();
  }

  /// Get detailed camera state for debugging
  Future<Map<String, dynamic>> getCameraState() {
    return WatermarkedVideoRecorderPlatform.instance.getCameraState();
  }

  /// Start recording with watermark in a single call
  /// Handles asset copying, watermark setup, camera initialization, and recording start
  Future<bool> startRecordingWithWatermark({required String watermarkPath, CameraLensDirection cameraDirection = CameraLensDirection.back}) {
    return WatermarkedVideoRecorderPlatform.instance.startRecordingWithWatermark(watermarkPath: watermarkPath, cameraDirection: cameraDirection);
  }

  /// Stop recording and save to gallery in a single call
  /// Returns the video path if successful, null otherwise
  Future<String?> stopRecordingAndSaveToGallery() {
    return WatermarkedVideoRecorderPlatform.instance.stopRecordingAndSaveToGallery();
  }

  /// Start camera preview and return the texture ID for Flutter widget
  Future<int?> startCameraPreview({CameraLensDirection cameraDirection = CameraLensDirection.back}) {
    return WatermarkedVideoRecorderPlatform.instance.startCameraPreview(cameraDirection: cameraDirection);
  }

  /// Stop camera preview
  Future<void> stopCameraPreview() {
    return WatermarkedVideoRecorderPlatform.instance.stopCameraPreview();
  }

  /// Check if camera preview is active
  Future<bool> isPreviewActive() {
    return WatermarkedVideoRecorderPlatform.instance.isPreviewActive();
  }

  /// Get the current texture ID for the camera preview
  Future<int?> getPreviewTextureId() {
    return WatermarkedVideoRecorderPlatform.instance.getPreviewTextureId();
  }

  /// Start preview with watermark overlay
  Future<int?> startPreviewWithWatermark({required String watermarkPath, CameraLensDirection cameraDirection = CameraLensDirection.back}) {
    return WatermarkedVideoRecorderPlatform.instance.startPreviewWithWatermark(watermarkPath: watermarkPath, cameraDirection: cameraDirection);
  }

  /// Pause the current video recording (segment-based)
  Future<bool> pauseRecording() {
    return WatermarkedVideoRecorderPlatform.instance.pauseRecording();
  }

  /// Resume video recording after a pause (segment-based)
  Future<bool> resumeRecording() {
    return WatermarkedVideoRecorderPlatform.instance.resumeRecording();
  }

  /// Capture a still photo from the camera with watermark and save to gallery
  Future<String?> capturePhotoWithWatermark() {
    return WatermarkedVideoRecorderPlatform.instance.capturePhotoWithWatermark();
  }

  /// Start simple video recording without watermarks or complex audio session management
  Future<bool> startSimpleVideoRecording({String direction = 'back'}) {
    return WatermarkedVideoRecorderPlatform.instance.startSimpleVideoRecording(direction);
  }

  /// Stop simple video recording and return the video file path
  Future<String?> stopSimpleVideoRecording() {
    return WatermarkedVideoRecorderPlatform.instance.stopSimpleVideoRecording();
  }
}
