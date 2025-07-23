# Camera Preview Functionality

This document explains how to use the new real-time camera preview functionality in the `watermarked_video_recorder` plugin.

## 🎯 Overview

The plugin now supports real-time camera preview using Flutter's `Texture` widget, allowing you to display the camera feed directly in your Flutter app with optional watermark overlay.

## 🚀 Features

- **Real-time camera preview** with `Texture` widget
- **Camera switching** (front/back)
- **Watermark overlay** during preview
- **Permission handling** (camera + microphone)
- **Error handling** and loading states
- **Seamless integration** with existing recording functionality

## 📱 Usage

### Option 1: Using the CameraPreviewWidget (Recommended)

The easiest way to add camera preview to your app:

```dart
import 'package:watermarked_video_recorder/watermarked_video_recorder.dart';

class MyCameraScreen extends StatefulWidget {
  @override
  _MyCameraScreenState createState() => _MyCameraScreenState();
}

class _MyCameraScreenState extends State<MyCameraScreen> {
  CameraLensDirection _currentCamera = CameraLensDirection.back;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          // Camera Preview
          Expanded(
            child: CameraPreviewWidget(
              cameraDirection: _currentCamera,
              // Optional: Add watermark during preview
              watermarkPath: 'assets/images/watermark.png',
              loadingWidget: const Center(
                child: CircularProgressIndicator(),
              ),
              errorWidget: Center(
                child: Column(
                  children: [
                    const Icon(Icons.error_outline, color: Colors.red),
                    const Text('Camera Error'),
                    ElevatedButton(
                      onPressed: () => setState(() {}),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
              onPreviewStarted: () {
                print('Camera preview started');
              },
              onPreviewStopped: () {
                print('Camera preview stopped');
              },
              onPreviewError: (error) {
                print('Camera error: $error');
              },
            ),
          ),

          // Camera Controls
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    _currentCamera = _currentCamera == CameraLensDirection.back
                        ? CameraLensDirection.front
                        : CameraLensDirection.back;
                  });
                },
                child: const Text('Switch Camera'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
```

### Option 2: Direct API Usage

For more control, use the API directly:

```dart
import 'package:watermarked_video_recorder/watermarked_video_recorder.dart';

class DirectAPICameraScreen extends StatefulWidget {
  @override
  _DirectAPICameraScreenState createState() => _DirectAPICameraScreenState();
}

class _DirectAPICameraScreenState extends State<DirectAPICameraScreen> {
  final WatermarkedVideoRecorder _recorder = WatermarkedVideoRecorder();
  int? _textureId;
  bool _isPreviewActive = false;

  @override
  void initState() {
    super.initState();
    _startPreview();
  }

  @override
  void dispose() {
    _stopPreview();
    super.dispose();
  }

  Future<void> _startPreview() async {
    try {
      // Request permissions
      final permissions = await _recorder.requestRecordingPermissions();
      if (!(permissions['camera'] ?? false)) {
        print('Camera permission denied');
        return;
      }

      // Start preview
      _textureId = await _recorder.startCameraPreview(
        cameraDirection: CameraLensDirection.back,
      );

      if (_textureId != null) {
        setState(() {
          _isPreviewActive = true;
        });
      }
    } catch (e) {
      print('Error starting preview: $e');
    }
  }

  Future<void> _stopPreview() async {
    if (_isPreviewActive) {
      await _recorder.stopCameraPreview();
      setState(() {
        _isPreviewActive = false;
        _textureId = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: _textureId != null
            ? Texture(textureId: _textureId!)
            : const CircularProgressIndicator(),
      ),
    );
  }
}
```

## 🔧 API Reference

### CameraPreviewWidget

A Flutter widget that provides real-time camera preview.

#### Properties

- `cameraDirection` (CameraLensDirection): Which camera to use (front/back)
- `watermarkPath` (String?): Optional path to watermark image
- `loadingWidget` (Widget?): Widget to show while camera initializes
- `errorWidget` (Widget?): Widget to show on camera error
- `onPreviewStarted` (VoidCallback?): Called when preview starts
- `onPreviewStopped` (VoidCallback?): Called when preview stops
- `onPreviewError` (Function(String)?): Called when preview fails

### WatermarkedVideoRecorder Methods

#### Preview Methods

```dart
// Start camera preview and return texture ID
Future<int?> startCameraPreview({
  CameraLensDirection cameraDirection = CameraLensDirection.back
})

// Stop camera preview
Future<void> stopCameraPreview()

// Check if preview is active
Future<bool> isPreviewActive()

// Get current texture ID
Future<int?> getPreviewTextureId()

// Start preview with watermark overlay
Future<int?> startPreviewWithWatermark({
  required String watermarkPath,
  CameraLensDirection cameraDirection = CameraLensDirection.back
})
```

#### Existing Recording Methods

```dart
// Start recording with watermark
Future<bool> startRecordingWithWatermark({
  required String watermarkPath,
  CameraLensDirection cameraDirection = CameraLensDirection.back
})

// Stop recording and save to gallery
Future<String?> stopRecordingAndSaveToGallery()

// Request permissions
Future<Map<String, bool>> requestRecordingPermissions()
```

## 🔄 Integration with Existing Code

The camera preview functionality integrates seamlessly with your existing recording workflow:

```dart
class WorkoutRecordingScreen extends StatefulWidget {
  @override
  _WorkoutRecordingScreenState createState() => _WorkoutRecordingScreenState();
}

class _WorkoutRecordingScreenState extends State<WorkoutRecordingScreen> {
  final WatermarkedVideoRecorder _recorder = WatermarkedVideoRecorder();
  bool _isRecording = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          // Camera Preview
          Expanded(
            child: CameraPreviewWidget(
              cameraDirection: CameraLensDirection.back,
              watermarkPath: 'assets/images/workout_logo.png',
            ),
          ),

          // Recording Controls
          Container(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton(
                  onPressed: _isRecording ? _stopRecording : _startRecording,
                  child: Text(_isRecording ? 'Stop' : 'Start Recording'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _startRecording() async {
    final success = await _recorder.startRecordingWithWatermark(
      watermarkPath: 'assets/images/workout_logo.png',
      cameraDirection: CameraLensDirection.back,
    );

    if (success) {
      setState(() {
        _isRecording = true;
      });
    }
  }

  Future<void> _stopRecording() async {
    final videoPath = await _recorder.stopRecordingAndSaveToGallery();
    setState(() {
      _isRecording = false;
    });

    if (videoPath != null) {
      print('Video saved: $videoPath');
    }
  }
}
```

## 🛠️ Technical Details

### How It Works

1. **Texture Creation**: The plugin creates a native texture using OpenGL (Android) or Metal (iOS)
2. **Camera Setup**: Camera2 API (Android) or AVFoundation (iOS) provides camera frames
3. **Frame Processing**: Frames are processed and rendered to the texture
4. **Flutter Display**: Flutter's `Texture` widget displays the texture content
5. **Watermark Overlay**: Optional watermark is composited over the camera feed

### Platform Support

- **Android**: Uses Camera2 API with SurfaceTexture
- **iOS**: Uses AVFoundation with AVCaptureVideoPreviewLayer
- **Cross-platform**: Unified API through Flutter's method channels

### Performance Considerations

- **Memory Efficient**: Uses hardware acceleration for frame processing
- **Battery Optimized**: Minimal CPU usage for frame rendering
- **Smooth Preview**: 30fps preview with proper frame timing

## 🐛 Troubleshooting

### Common Issues

1. **Camera Permission Denied**

   ```dart
   // Always request permissions before starting preview
   final permissions = await _recorder.requestRecordingPermissions();
   if (!(permissions['camera'] ?? false)) {
     // Handle permission denied
   }
   ```

2. **Preview Not Showing**

   - Check if texture ID is returned from `startCameraPreview()`
   - Ensure camera permissions are granted
   - Verify camera is not in use by another app

3. **Performance Issues**
   - Use appropriate resolution for your use case
   - Consider device capabilities for high-resolution preview

### Debug Information

Enable debug logging to troubleshoot issues:

```dart
// The plugin includes comprehensive logging
// Check console output for detailed information about:
// - Camera initialization
// - Texture creation
// - Frame processing
// - Error conditions
```

## 📋 Requirements

- Flutter 3.0.0 or higher
- Android API level 21+ (Android 5.0+)
- iOS 12.0+
- Camera and microphone permissions

## 🔮 Future Enhancements

- **Multiple camera support** (ultra-wide, telephoto)
- **Custom preview filters** and effects
- **Zoom and focus controls**
- **Flash control**
- **Exposure and white balance settings**
