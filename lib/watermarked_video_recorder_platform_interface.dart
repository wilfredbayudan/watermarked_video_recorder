import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'watermarked_video_recorder_method_channel.dart';
import 'src/camera_description.dart';

abstract class WatermarkedVideoRecorderPlatform extends PlatformInterface {
  /// Constructs a WatermarkedVideoRecorderPlatform.
  WatermarkedVideoRecorderPlatform() : super(token: _token);

  static final Object _token = Object();

  static WatermarkedVideoRecorderPlatform _instance = MethodChannelWatermarkedVideoRecorder();

  /// The default instance of [WatermarkedVideoRecorderPlatform] to use.
  ///
  /// Defaults to [MethodChannelWatermarkedVideoRecorder].
  static WatermarkedVideoRecorderPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [WatermarkedVideoRecorderPlatform] when
  /// they register themselves.
  static set instance(WatermarkedVideoRecorderPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }

  /// Simple test method to verify Flutter-to-native communication
  Future<String?> testConnection() {
    throw UnimplementedError('testConnection() has not been implemented.');
  }

  /// Request camera permission and return the status
  Future<bool> requestCameraPermission() {
    throw UnimplementedError('requestCameraPermission() has not been implemented.');
  }

  /// Request microphone permission and return the status
  Future<bool> requestMicrophonePermission() {
    throw UnimplementedError('requestMicrophonePermission() has not been implemented.');
  }

  /// Request both camera and microphone permissions
  Future<Map<String, bool>> requestRecordingPermissions() {
    throw UnimplementedError('requestRecordingPermissions() has not been implemented.');
  }

  /// Initialize camera for recording (without preview)
  Future<bool> initializeCamera() {
    throw UnimplementedError('initializeCamera() has not been implemented.');
  }

  /// Get list of available cameras
  Future<List<CameraDescription>> getAvailableCameras() {
    throw UnimplementedError('getAvailableCameras() has not been implemented.');
  }

  /// Initialize camera for recording (without preview) with specific camera
  Future<bool> initializeCameraWithId(String cameraId) {
    throw UnimplementedError('initializeCameraWithId() has not been implemented.');
  }

  /// Initialize camera for recording (without preview) with lens direction
  Future<bool> initializeCameraWithDirection(CameraLensDirection direction) {
    throw UnimplementedError('initializeCameraWithDirection() has not been implemented.');
  }

  /// Dispose camera resources
  Future<void> disposeCamera() {
    throw UnimplementedError('disposeCamera() has not been implemented.');
  }

  /// Start video recording
  Future<bool> startVideoRecording() {
    throw UnimplementedError('startVideoRecording() has not been implemented.');
  }

  /// Stop video recording and return the file path
  Future<String?> stopVideoRecording() {
    throw UnimplementedError('stopVideoRecording() has not been implemented.');
  }

  /// Check if currently recording
  Future<bool> isRecording() {
    throw UnimplementedError('isRecording() has not been implemented.');
  }

  /// Save video file to device gallery
  Future<bool> saveVideoToGallery(String videoPath) {
    throw UnimplementedError('saveVideoToGallery() has not been implemented.');
  }

  /// Set the watermark image path (asset or file path)
  Future<void> setWatermarkImage(String path) {
    throw UnimplementedError('setWatermarkImage() has not been implemented.');
  }

  /// Check if camera is ready for recording
  Future<bool> isCameraReady() {
    throw UnimplementedError('isCameraReady() has not been implemented.');
  }

  /// Get detailed camera state for debugging
  Future<Map<String, dynamic>> getCameraState() {
    throw UnimplementedError('getCameraState() has not been implemented.');
  }

  /// Start recording with watermark in a single call
  /// Handles asset copying, watermark setup, camera initialization, and recording start
  Future<bool> startRecordingWithWatermark({required String watermarkPath, CameraLensDirection cameraDirection = CameraLensDirection.back}) {
    throw UnimplementedError('startRecordingWithWatermark() has not been implemented.');
  }

  /// Stop recording and save to gallery in a single call
  /// Returns the video path if successful, null otherwise
  Future<String?> stopRecordingAndSaveToGallery() {
    throw UnimplementedError('stopRecordingAndSaveToGallery() has not been implemented.');
  }
}
