import 'package:flutter_test/flutter_test.dart';
import 'package:watermarked_video_recorder/watermarked_video_recorder.dart';
import 'package:watermarked_video_recorder/watermarked_video_recorder_platform_interface.dart';
import 'package:watermarked_video_recorder/watermarked_video_recorder_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockWatermarkedVideoRecorderPlatform with MockPlatformInterfaceMixin implements WatermarkedVideoRecorderPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');

  @override
  Future<String?> testConnection() => Future.value('Mock test connection successful');

  @override
  Future<bool> requestCameraPermission() => Future.value(true);

  @override
  Future<bool> requestMicrophonePermission() => Future.value(true);

  @override
  Future<bool> initializeCamera() => Future.value(true);

  @override
  Future<void> disposeCamera() => Future.value();

  @override
  Future<Map<String, bool>> requestRecordingPermissions() => Future.value({'camera': true, 'microphone': true});

  @override
  Future<List<CameraDescription>> getAvailableCameras() {
    // TODO: implement getAvailableCameras
    throw UnimplementedError();
  }

  @override
  Future<bool> initializeCameraWithDirection(CameraLensDirection direction) {
    // TODO: implement initializeCameraWithDirection
    throw UnimplementedError();
  }

  @override
  Future<bool> initializeCameraWithId(String cameraId) {
    // TODO: implement initializeCameraWithId
    throw UnimplementedError();
  }

  @override
  Future<bool> isRecording() {
    // TODO: implement isRecording
    throw UnimplementedError();
  }

  @override
  Future<bool> saveVideoToGallery(String videoPath) {
    // TODO: implement saveVideoToGallery
    throw UnimplementedError();
  }

  @override
  Future<void> setWatermarkImage(String path) {
    // TODO: implement setWatermarkImage
    throw UnimplementedError();
  }

  @override
  Future<bool> startVideoRecording() {
    // TODO: implement startVideoRecording
    throw UnimplementedError();
  }

  @override
  Future<String?> stopVideoRecording() {
    // TODO: implement stopVideoRecording
    throw UnimplementedError();
  }

  @override
  Future<bool> startRecordingWithWatermark({required String watermarkPath, CameraLensDirection cameraDirection = CameraLensDirection.back}) {
    // TODO: implement startRecordingWithWatermark
    throw UnimplementedError();
  }

  @override
  Future<String?> stopRecordingAndSaveToGallery() {
    // TODO: implement stopRecordingAndSaveToGallery
    throw UnimplementedError();
  }

  @override
  Future<Map<String, dynamic>> getCameraState() {
    // TODO: implement getCameraState
    throw UnimplementedError();
  }

  @override
  Future<bool> isCameraReady() {
    // TODO: implement isCameraReady
    throw UnimplementedError();
  }

  @override
  Future<String?> capturePhotoWithWatermark() {
    // TODO: implement capturePhotoWithWatermark
    throw UnimplementedError();
  }

  @override
  Future<int?> getPreviewTextureId() {
    // TODO: implement getPreviewTextureId
    throw UnimplementedError();
  }

  @override
  Future<bool> isPreviewActive() {
    // TODO: implement isPreviewActive
    throw UnimplementedError();
  }

  @override
  Future<bool> pauseRecording() {
    // TODO: implement pauseRecording
    throw UnimplementedError();
  }

  @override
  Future<bool> resumeRecording() {
    // TODO: implement resumeRecording
    throw UnimplementedError();
  }

  @override
  Future<int?> startCameraPreview({CameraLensDirection cameraDirection = CameraLensDirection.back}) {
    // TODO: implement startCameraPreview
    throw UnimplementedError();
  }

  @override
  Future<int?> startPreviewWithWatermark({required String watermarkPath, CameraLensDirection cameraDirection = CameraLensDirection.back}) {
    // TODO: implement startPreviewWithWatermark
    throw UnimplementedError();
  }

  @override
  Future<void> stopCameraPreview() {
    // TODO: implement stopCameraPreview
    throw UnimplementedError();
  }
}

void main() {
  final WatermarkedVideoRecorderPlatform initialPlatform = WatermarkedVideoRecorderPlatform.instance;

  test('$MethodChannelWatermarkedVideoRecorder is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelWatermarkedVideoRecorder>());
  });

  test('getPlatformVersion', () async {
    WatermarkedVideoRecorder watermarkedVideoRecorderPlugin = WatermarkedVideoRecorder();
    MockWatermarkedVideoRecorderPlatform fakePlatform = MockWatermarkedVideoRecorderPlatform();
    WatermarkedVideoRecorderPlatform.instance = fakePlatform;

    expect(await watermarkedVideoRecorderPlugin.getPlatformVersion(), '42');
  });
}
