import Flutter
import UIKit
import AVFoundation
import Photos
import CoreImage

// MARK: - Flutter Texture Implementation

class CameraPreviewTexture: NSObject, FlutterTexture {
  private var pixelBuffer: CVPixelBuffer?
  private let pixelBufferLock = NSLock()
  
  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    pixelBufferLock.lock()
    defer { pixelBufferLock.unlock() }
    
    guard let pixelBuffer = pixelBuffer else {
      return nil
    }
    
    return Unmanaged.passRetained(pixelBuffer)
  }
  
  func updatePixelBuffer(_ buffer: CVPixelBuffer) {
    pixelBufferLock.lock()
    defer { pixelBufferLock.unlock() }
    
    // For now, just use the original buffer
    // The orientation correction will be handled by the main plugin class
    pixelBuffer = buffer
  }
}

// MARK: - Main Plugin Class

public class WatermarkedVideoRecorderPlugin: NSObject, FlutterPlugin, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
  private var captureSession: AVCaptureSession?
  private var videoInput: AVCaptureDeviceInput?
  private var audioInput: AVCaptureDeviceInput?
  private var videoOutput: AVCaptureVideoDataOutput?
  private var audioOutput: AVCaptureAudioDataOutput?
  private var isInitialized = false
  private var isRecording = false
  private var currentVideoPath: String?
  private var watermarkImagePath: String?
  private var recordingCompletionHandler: ((String?) -> Void)?
  private var pendingVideoPath: String?
  
  // Video encoding properties
  private var videoWriter: AVAssetWriter?
  private var videoWriterInput: AVAssetWriterInput?
  private var audioWriterInput: AVAssetWriterInput?
  private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
  
  // Frame counting for debugging
  private var videoFrameCount = 0
  private var audioSampleCount = 0

  // New properties for the new method
  private var isSettingUpWriter = false
  private var pendingVideoURL: URL?
  
  // Orientation properties
  private var currentCameraPosition: AVCaptureDevice.Position = .back
  
  // Watermark properties
  private var watermarkImage: CIImage?
  private var watermarkSize: CGSize = CGSize.zero
  private var watermarkPosition: CGPoint = CGPoint.zero
  private var ciContext: CIContext?

  // Camera initialization tracking
  private var isCameraInitializing = false
  private var cameraInitCompletionHandler: ((Bool) -> Void)?

  // Preview-related properties
  private var isPreviewActive = false
  private var previewTextureId: Int64?
  private var previewLayer: AVCaptureVideoPreviewLayer?
  private var previewTexture: CameraPreviewTexture?
  private var textureRegistry: FlutterTextureRegistry?
  private var previewFrameCount = 0
  private var totalFrameCount = 0

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "watermarked_video_recorder", binaryMessenger: registrar.messenger())
    let instance = WatermarkedVideoRecorderPlugin()
    instance.textureRegistry = registrar.textures()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformVersion":
      result("iOS " + UIDevice.current.systemVersion)
    case "testConnection":
      result("Hello from iOS! Plugin connection successful!")
    case "requestCameraPermission":
      requestCameraPermission(result: result)
    case "requestMicrophonePermission":
      requestMicrophonePermission(result: result)
    case "requestRecordingPermissions":
      requestRecordingPermissions(result: result)
    case "initializeCamera":
      let success = initializeCamera()
      result(success)
    case "getAvailableCameras":
      let cameras = getAvailableCameras()
      result(cameras)
    case "initializeCameraWithId":
      let args = call.arguments as? [String: Any]
      let cameraId = args?["cameraId"] as? String
      let success = if let cameraId = cameraId { initializeCameraWithId(cameraId) } else { false }
      result(success)
    case "initializeCameraWithDirection":
      let args = call.arguments as? [String: Any]
      let direction = args?["direction"] as? String
      print("iOS: Received direction: \(direction ?? "nil")")
      let success = if let direction = direction { initializeCameraWithDirection(direction) } else { false }
      result(success)
    case "disposeCamera":
      disposeCamera()
      result(nil)
    case "startVideoRecording":
      let success = startVideoRecording()
      result(success)
    case "stopVideoRecording":
      let videoPath = stopVideoRecording()
      result(videoPath)
    case "isRecording":
      result(isRecording)
    case "saveVideoToGallery":
      let args = call.arguments as? [String: Any]
      let videoPath = args?["videoPath"] as? String
      let success = if let videoPath = videoPath { saveVideoToGallery(videoPath) } else { false }
      result(success)
    case "setWatermarkImage":
      let args = call.arguments as? [String: Any]
      let path = args?["path"] as? String
      setWatermarkImage(path)
      result(nil)
    case "isCameraReady":
      let ready = captureSession != nil && captureSession!.isRunning && !isCameraInitializing
      result(ready)
    case "getCameraState":
      let state: [String: Any] = [
        "captureSession": captureSession != nil,
        "isRunning": captureSession?.isRunning ?? false,
        "isCameraInitializing": isCameraInitializing,
        "isRecording": isRecording,
        "isInitialized": isInitialized,
        "videoOutput": videoOutput != nil,
        "audioOutput": audioOutput != nil
      ]
      result(state)
    case "startCameraPreview":
      let args = call.arguments as? [String: Any]
      let direction = args?["direction"] as? String
      let textureId: Int64? = if let direction = direction { startCameraPreview(direction: direction) } else { nil }
      result(textureId)
    case "stopCameraPreview":
      stopCameraPreview()
      result(nil)
    case "isPreviewActive":
      result(isPreviewActive)
    case "getPreviewTextureId":
      // Return texture ID if preview is active or if recording is active (they share the same camera)
      let textureId = isPreviewActive ? previewTextureId : (isRecording ? previewTextureId : nil)
      print("getPreviewTextureId: previewActive=\(isPreviewActive), recording=\(isRecording), textureId=\(textureId ?? -1)")
      result(textureId)
    case "startPreviewWithWatermark":
      let args = call.arguments as? [String: Any]
      let watermarkPath = args?["watermarkPath"] as? String
      let direction = args?["direction"] as? String
      let textureId: Int64? = if let watermarkPath = watermarkPath, let direction = direction {
        startPreviewWithWatermark(watermarkPath: watermarkPath, direction: direction)
      } else { nil }
      result(textureId)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
  
  private func requestCameraPermission(result: @escaping FlutterResult) {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      result(true)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { granted in
        DispatchQueue.main.async {
          result(granted)
        }
      }
    case .denied, .restricted:
      result(false)
    @unknown default:
      result(false)
    }
  }
  
  private func requestMicrophonePermission(result: @escaping FlutterResult) {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      result(true)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        DispatchQueue.main.async {
          result(granted)
        }
      }
    case .denied, .restricted:
      result(false)
    @unknown default:
      result(false)
    }
  }
  
  private func requestRecordingPermissions(result: @escaping FlutterResult) {
    let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    
    let permissions = [
      "camera": cameraStatus == .authorized,
      "microphone": microphoneStatus == .authorized
    ]
    
    if cameraStatus == .notDetermined || microphoneStatus == .notDetermined {
      // Request permissions that haven't been determined
      var cameraRequested = false
      var microphoneRequested = false
      
      if cameraStatus == .notDetermined {
        cameraRequested = true
        AVCaptureDevice.requestAccess(for: .video) { _ in
          DispatchQueue.main.async {
            if !microphoneRequested {
              result([
                "camera": AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
                "microphone": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
              ])
            }
          }
        }
      }
      
      if microphoneStatus == .notDetermined {
        microphoneRequested = true
        AVCaptureDevice.requestAccess(for: .audio) { _ in
          DispatchQueue.main.async {
            if !cameraRequested {
              result([
                "camera": AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
                "microphone": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
              ])
            }
          }
        }
      }
    } else {
      result(permissions)
    }
  }

  private func initializeCamera() -> Bool {
    print("Camera initialization started")
    
    if isCameraInitializing {
      print("Camera is already initializing")
      return false
    }
    
    isCameraInitializing = true
    
    do {
      // Create session
      let session = AVCaptureSession()
      session.beginConfiguration()
      session.sessionPreset = .high

      // Find back camera (default)
      guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
        print("No back camera found")
        isCameraInitializing = false
        return false
      }
      
      // Store the camera position for orientation calculations
      currentCameraPosition = .back
      
      let input = try AVCaptureDeviceInput(device: camera)
      if session.canAddInput(input) {
        session.addInput(input)
      } else {
        print("Cannot add camera input")
        isCameraInitializing = false
        return false
      }

      // Add audio input for recording
      if let audioDevice = AVCaptureDevice.default(for: .audio) {
        let audioInput = try AVCaptureDeviceInput(device: audioDevice)
        if session.canAddInput(audioInput) {
          session.addInput(audioInput)
          print("Added audio input")
        } else {
          print("Cannot add audio input")
        }
      } else {
        print("No audio device found")
      }

      // Add video output for real-time frame processing
      let videoOutput = AVCaptureVideoDataOutput()
      videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue.global(qos: .userInitiated))
      videoOutput.alwaysDiscardsLateVideoFrames = true
      if session.canAddOutput(videoOutput) {
        session.addOutput(videoOutput)
        self.videoOutput = videoOutput
        print("Added video data output with delegate")
        
        // Configure video orientation for preview
        if let connection = videoOutput.connection(with: .video) {
          let orientationHint = getVideoOrientationHint()
          print("Setting video connection orientation to: \(orientationHint) degrees")
          
          // Apply the same orientation logic as recording
          if orientationHint == 270 {
            // Front camera in portrait - rotate 90 degrees clockwise
            connection.videoOrientation = .portrait
            print("Set video connection to portrait for front camera")
          } else if orientationHint == 90 {
            // Back camera in portrait - rotate 90 degrees clockwise
            connection.videoOrientation = .portrait
            print("Set video connection to portrait for back camera")
          } else if orientationHint == 180 {
            connection.videoOrientation = .landscapeRight
            print("Set video connection to landscapeRight")
          } else {
            connection.videoOrientation = .landscapeLeft
            print("Set video connection to landscapeLeft")
          }
          
          // For front camera, also set mirroring
          if currentCameraPosition == .front {
            connection.isVideoMirrored = false // No mirroring - handle in Flutter
            print("Disabled video mirroring for front camera (will handle in Flutter)")
          } else {
            connection.isVideoMirrored = false
            print("Disabled video mirroring for back camera")
          }
        }
      } else {
        print("Cannot add video data output")
        isCameraInitializing = false
        return false
      }

      // Add audio output for real-time audio processing
      let audioOutput = AVCaptureAudioDataOutput()
      audioOutput.setSampleBufferDelegate(nil, queue: DispatchQueue.global(qos: .userInitiated))
      if session.canAddOutput(audioOutput) {
        session.addOutput(audioOutput)
        self.audioOutput = audioOutput
        print("Added audio data output")
      } else {
        print("Cannot add audio data output")
      }

      session.commitConfiguration()
      captureSession = session
      videoInput = input
      isInitialized = true
      
      // Start the capture session on a background queue
      DispatchQueue.global(qos: .userInitiated).async {
        session.startRunning()
        
        DispatchQueue.main.async {
          self.isCameraInitializing = false
          print("Camera initialized successfully and session is running")
        }
      }
      
      print("Camera initialization completed")
      return true
    } catch {
      print("Camera initialization error: \(error)")
      isCameraInitializing = false
      return false
    }
  }

  private func getAvailableCameras() -> [[String: Any]] {
    var cameras: [[String: Any]] = []
    
    // Check for back camera
    if let backCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
      cameras.append([
        "id": backCamera.uniqueID,
        "direction": "back",
        "label": "Back Camera"
      ])
    }
    
    // Check for front camera
    if let frontCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) {
      cameras.append([
        "id": frontCamera.uniqueID,
        "direction": "front",
        "label": "Front Camera"
      ])
    }
    
    // Check for external cameras (using a more compatible approach)
    let externalCameras = AVCaptureDevice.devices(for: .video)
    for camera in externalCameras {
      // Only include external cameras that are not built-in
      if camera.deviceType != .builtInWideAngleCamera && 
         camera.deviceType != .builtInTelephotoCamera && 
         camera.deviceType != .builtInUltraWideCamera {
        cameras.append([
          "id": camera.uniqueID,
          "direction": "external",
          "label": "External Camera"
        ])
      }
    }
    
    return cameras
  }

  private func initializeCameraWithId(_ cameraId: String) -> Bool {
    print("Camera initialization with ID: \(cameraId)")
    
    if isCameraInitializing {
      print("Camera is already initializing")
      return false
    }
    
    isCameraInitializing = true
    
    do {
      // Find camera by ID
      guard let camera = AVCaptureDevice(uniqueID: cameraId) else {
        print("Camera with ID \(cameraId) not found")
        isCameraInitializing = false
        return false
      }
      
      // Determine camera position for orientation calculations
      if camera.position == .front {
        currentCameraPosition = .front
        print("Detected front camera")
      } else if camera.position == .back {
        currentCameraPosition = .back
        print("Detected back camera")
      } else {
        currentCameraPosition = .back // Default to back for external cameras
        print("Detected external camera, defaulting to back camera orientation")
      }
      
      // Create session
      let session = AVCaptureSession()
      session.beginConfiguration()
      session.sessionPreset = .high
      
      let input = try AVCaptureDeviceInput(device: camera)
      if session.canAddInput(input) {
        session.addInput(input)
      } else {
        print("Cannot add camera input")
        isCameraInitializing = false
        return false
      }
      
      // Add audio input for recording
      if let audioDevice = AVCaptureDevice.default(for: .audio) {
        let audioInput = try AVCaptureDeviceInput(device: audioDevice)
        if session.canAddInput(audioInput) {
          session.addInput(audioInput)
          print("Added audio input")
        } else {
          print("Cannot add audio input")
        }
      } else {
        print("No audio device found")
      }
      
      // Add video output for real-time frame processing
      let videoOutput = AVCaptureVideoDataOutput()
      videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue.global(qos: .userInitiated))
      videoOutput.alwaysDiscardsLateVideoFrames = true
      if session.canAddOutput(videoOutput) {
        session.addOutput(videoOutput)
        self.videoOutput = videoOutput
        print("Added video data output")
        
        // Configure video orientation for preview
        if let connection = videoOutput.connection(with: .video) {
          let orientationHint = getVideoOrientationHint()
          print("Setting video connection orientation to: \(orientationHint) degrees")
          
          // Apply the same orientation logic as recording
          if orientationHint == 270 {
            // Front camera in portrait - rotate 90 degrees clockwise
            connection.videoOrientation = .portrait
            print("Set video connection to portrait for front camera")
          } else if orientationHint == 90 {
            // Back camera in portrait - rotate 90 degrees clockwise
            connection.videoOrientation = .portrait
            print("Set video connection to portrait for back camera")
          } else if orientationHint == 180 {
            connection.videoOrientation = .landscapeRight
            print("Set video connection to landscapeRight")
          } else {
            connection.videoOrientation = .landscapeLeft
            print("Set video connection to landscapeLeft")
          }
          
          // For front camera, also set mirroring
          if currentCameraPosition == .front {
            connection.isVideoMirrored = false // No mirroring - handle in Flutter
            print("Disabled video mirroring for front camera (will handle in Flutter)")
          } else {
            connection.isVideoMirrored = false
            print("Disabled video mirroring for back camera")
          }
        }
      } else {
        print("Cannot add video data output")
        isCameraInitializing = false
        return false
      }

      // Add audio output for real-time audio processing
      let audioOutput = AVCaptureAudioDataOutput()
      audioOutput.setSampleBufferDelegate(nil, queue: DispatchQueue.global(qos: .userInitiated))
      if session.canAddOutput(audioOutput) {
        session.addOutput(audioOutput)
        self.audioOutput = audioOutput
        print("Added audio data output")
      } else {
        print("Cannot add audio data output")
      }
      
      session.commitConfiguration()
      captureSession = session
      videoInput = input
      isInitialized = true
      
      // Start the capture session on a background queue
      DispatchQueue.global(qos: .userInitiated).async {
        session.startRunning()
        
        DispatchQueue.main.async {
          self.isCameraInitializing = false
          print("Camera initialized successfully with ID: \(cameraId) and session is running")
        }
      }
      
      print("Camera initialization completed")
      return true
    } catch {
      print("Camera initialization error: \(error)")
      isCameraInitializing = false
      return false
    }
  }

  private func initializeCameraWithDirection(_ direction: String) -> Bool {
    print("iOS: Camera initialization with direction: \(direction)")
    
    if isCameraInitializing {
      print("Camera is already initializing")
      return false
    }
    
    isCameraInitializing = true
    
    let position: AVCaptureDevice.Position
    switch direction {
    case "front":
      position = .front
      print("iOS: Using front camera position")
    case "back":
      position = .back
      print("iOS: Using back camera position")
    default:
      print("iOS: Unsupported direction: \(direction)")
      isCameraInitializing = false
      return false
    }
    
    // Store the camera position for orientation calculations
    currentCameraPosition = position
    
    do {
      // Create session
      let session = AVCaptureSession()
      session.beginConfiguration()
      session.sessionPreset = .high
      
      // Find camera with specified position
      guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
        print("No camera found with direction: \(direction)")
        isCameraInitializing = false
        return false
      }
      
      let input = try AVCaptureDeviceInput(device: camera)
      if session.canAddInput(input) {
        session.addInput(input)
      } else {
        print("Cannot add camera input")
        isCameraInitializing = false
        return false
      }
      
      // Add audio input for recording
      if let audioDevice = AVCaptureDevice.default(for: .audio) {
        let audioInput = try AVCaptureDeviceInput(device: audioDevice)
        if session.canAddInput(audioInput) {
          session.addInput(audioInput)
          print("Added audio input")
        } else {
          print("Cannot add audio input")
        }
      } else {
        print("No audio device found")
      }
      
      // Add video output for real-time frame processing
      let videoOutput = AVCaptureVideoDataOutput()
      videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue.global(qos: .userInitiated))
      videoOutput.alwaysDiscardsLateVideoFrames = true
      if session.canAddOutput(videoOutput) {
        session.addOutput(videoOutput)
        self.videoOutput = videoOutput
        print("Added video data output")
        
        // Configure video orientation for preview
        if let connection = videoOutput.connection(with: .video) {
          let orientationHint = getVideoOrientationHint()
          print("Setting video connection orientation to: \(orientationHint) degrees")
          
          // Apply the same orientation logic as recording
          if orientationHint == 270 {
            // Front camera in portrait - rotate 90 degrees clockwise
            connection.videoOrientation = .portrait
            print("Set video connection to portrait for front camera")
          } else if orientationHint == 90 {
            // Back camera in portrait - rotate 90 degrees clockwise
            connection.videoOrientation = .portrait
            print("Set video connection to portrait for back camera")
          } else if orientationHint == 180 {
            connection.videoOrientation = .landscapeRight
            print("Set video connection to landscapeRight")
          } else {
            connection.videoOrientation = .landscapeLeft
            print("Set video connection to landscapeLeft")
          }
          
          // For front camera, also set mirroring
          if currentCameraPosition == .front {
            connection.isVideoMirrored = false // No mirroring - handle in Flutter
            print("Disabled video mirroring for front camera (will handle in Flutter)")
          } else {
            connection.isVideoMirrored = false
            print("Disabled video mirroring for back camera")
          }
        }
      } else {
        print("Cannot add video data output")
        isCameraInitializing = false
        return false
      }

      // Add audio output for real-time audio processing
      let audioOutput = AVCaptureAudioDataOutput()
      audioOutput.setSampleBufferDelegate(nil, queue: DispatchQueue.global(qos: .userInitiated))
      if session.canAddOutput(audioOutput) {
        session.addOutput(audioOutput)
        self.audioOutput = audioOutput
        print("Added audio data output")
      } else {
        print("Cannot add audio data output")
      }
      
      session.commitConfiguration()
      captureSession = session
      videoInput = input
      isInitialized = true
      
      // Start the capture session on a background queue
      DispatchQueue.global(qos: .userInitiated).async {
        session.startRunning()
        
        DispatchQueue.main.async {
          self.isCameraInitializing = false
          print("Camera initialized successfully with direction: \(direction) and session is running")
        }
      }
      
      print("Camera initialization completed")
      return true
    } catch {
      print("Camera initialization error: \(error)")
      isCameraInitializing = false
      return false
    }
  }

  private func disposeCamera() {
    print("Camera disposal started")
    
    // Stop recording if active
    if isRecording {
      videoOutput?.setSampleBufferDelegate(nil, queue: nil)
      audioOutput?.setSampleBufferDelegate(nil, queue: nil)
      isRecording = false
    }
    
    // Stop the capture session
    captureSession?.stopRunning()
    
    captureSession = nil
    videoInput = nil
    videoOutput = nil
    audioInput = nil
    audioOutput = nil
    isInitialized = false
    isCameraInitializing = false
    
    // Clean up watermark resources
    watermarkImage = nil
    watermarkSize = CGSize.zero
    watermarkPosition = CGPoint.zero
    ciContext = nil
    
    print("Camera disposal completed")
  }

  private func startVideoRecording() -> Bool {
    guard let videoOutput = videoOutput, !isRecording else {
      print("Cannot start recording: videoOutput is nil or already recording")
      return false
    }
    
    // Wait for camera initialization to complete
    if isCameraInitializing {
      print("Camera is still initializing, waiting...")
      // Wait up to 3 seconds for camera to initialize
      let startTime = Date()
      while isCameraInitializing && Date().timeIntervalSince(startTime) < 3.0 {
        Thread.sleep(forTimeInterval: 0.1)
      }
      if isCameraInitializing {
        print("Camera initialization timeout")
        return false
      }
      print("Camera initialization completed after waiting")
    }
    
    // Check if capture session is running
    guard let session = captureSession, session.isRunning else {
      print("Cannot start recording: capture session is not running")
      print("Camera state: isCameraInitializing=\(isCameraInitializing), session=\(captureSession != nil), isRunning=\(captureSession?.isRunning ?? false)")
      return false
    }
    
    print("Starting video recording with existing capture session (preview active: \(isPreviewActive))")
    
    // Check if videoOutput is connected
    guard !videoOutput.connections.isEmpty else {
      print("Video output has no connections")
      return false
    }
    
    // Create video file path
    let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let timestamp = Int(Date().timeIntervalSince1970)
    let fileName = "workout_\(timestamp).mov"
    let videoURL = documentsPath.appendingPathComponent(fileName)
    
    print("About to start recording to: \(videoURL.path)")
    print("Video output connections: \(videoOutput.connections.count)")
    print("Capture session is running: \(session.isRunning)")
    
    // Store the URL for later setup
    pendingVideoURL = videoURL
    currentVideoPath = videoURL.path
    
    // Reset frame counters
    videoFrameCount = 0
    audioSampleCount = 0
    
    // Start recording by setting delegates
    videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue.global(qos: .userInitiated))
    audioOutput?.setSampleBufferDelegate(self, queue: DispatchQueue.global(qos: .userInitiated))
    
    isRecording = true
    print("Started video recording to: \(videoURL.path)")
    return true
  }

  private func stopVideoRecording() -> String? {
    guard let videoOutput = videoOutput, isRecording else {
      print("Cannot stop recording: videoOutput is nil or not recording")
      return nil
    }
    
    // Store the current path before stopping
    let videoPath = currentVideoPath
    pendingVideoPath = videoPath
    
    // Stop recording by clearing delegates
    videoOutput.setSampleBufferDelegate(nil, queue: nil)
    audioOutput?.setSampleBufferDelegate(nil, queue: nil)
    
    isRecording = false
    currentVideoPath = nil
    pendingVideoURL = nil
    isSettingUpWriter = false
    
    // Finish writing the file
    if let videoWriter = videoWriter {
      videoWriterInput?.markAsFinished()
      audioWriterInput?.markAsFinished()
      
      videoWriter.finishWriting { [weak self] in
        DispatchQueue.main.async {
          if videoWriter.status == .completed {
            print("Video recording completed successfully")
            if let path = videoPath {
              let fileExists = FileManager.default.fileExists(atPath: path)
              print("Video file exists: \(fileExists)")
              if fileExists {
                do {
                  let attributes = try FileManager.default.attributesOfItem(atPath: path)
                  let fileSize = attributes[.size] as? Int64 ?? 0
                  print("Video file size: \(fileSize) bytes")
                } catch {
                  print("Error getting file attributes: \(error)")
                }
              }
            }
          } else {
            print("Video recording failed: \(videoWriter.error?.localizedDescription ?? "Unknown error")")
          }
        }
      }
    }
    
    // Clean up
    videoWriter = nil
    videoWriterInput = nil
    audioWriterInput = nil
    pixelBufferAdaptor = nil
    
    print("Stopped video recording")
    return videoPath
  }

  private func saveVideoToGallery(_ videoPath: String) -> Bool {
    let videoURL = URL(fileURLWithPath: videoPath)
    
    print("Attempting to save video to gallery: \(videoPath)")
    
    // Check if file exists
    guard FileManager.default.fileExists(atPath: videoPath) else {
      print("Video file does not exist: \(videoPath)")
      
      // Let's check what files are in the documents directory
      let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      do {
        let files = try FileManager.default.contentsOfDirectory(at: documentsPath, includingPropertiesForKeys: nil)
        print("Files in documents directory:")
        for file in files {
          print("  - \(file.lastPathComponent)")
        }
      } catch {
        print("Error listing documents directory: \(error)")
      }
      
      return false
    }
    
    // Check file size
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: videoPath)
      let fileSize = attributes[.size] as? Int64 ?? 0
      print("Video file size before saving: \(fileSize) bytes")
    } catch {
      print("Error getting file attributes: \(error)")
    }
    
    // Save to photo library
    PHPhotoLibrary.requestAuthorization { status in
      if status == .authorized {
        PHPhotoLibrary.shared().performChanges({
          PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
        }) { success, error in
          if success {
            print("Video saved to gallery successfully")
          } else {
            print("Failed to save video to gallery: \(error?.localizedDescription ?? "Unknown error")")
          }
        }
      } else {
        print("Photo library access denied")
      }
    }
    
    return true
  }

  private func setWatermarkImage(_ path: String?) {
    watermarkImagePath = path
    print("Set watermark image path: \(path ?? "nil")")
    
    // Load watermark image
    if let path = path {
      loadWatermarkImage(path: path)
    } else {
      watermarkImage = nil
      watermarkSize = CGSize.zero
      watermarkPosition = CGPoint.zero
    }
  }
  
  private func loadWatermarkImage(path: String) {
    print("Loading watermark image from: \(path)")
    
    guard let image = UIImage(contentsOfFile: path) else {
      print("Failed to load watermark image from path: \(path)")
      return
    }
    
    // Convert to CIImage for Core Image processing
    guard let ciImage = CIImage(image: image) else {
      print("Failed to convert watermark to CIImage")
      return
    }
    
    watermarkImage = ciImage
    watermarkSize = image.size
    print("Watermark loaded successfully: \(watermarkSize.width)x\(watermarkSize.height)")
    
    // Initialize CIContext if needed
    if ciContext == nil {
      ciContext = CIContext(options: [.useSoftwareRenderer: false])
    }
  }
  
  private func calculateWatermarkSize(for videoSize: CGSize) -> CGSize {
    // Use 25% of the video width for the watermark
    let scale: CGFloat = 0.25
    let watermarkWidth = videoSize.width * scale
    
    // Get the original watermark image dimensions for aspect ratio
    guard let watermarkImage = watermarkImage else {
      return CGSize(width: watermarkWidth, height: watermarkWidth)
    }
    
    let originalWatermarkSize = watermarkImage.extent.size
    let watermarkHeight = watermarkWidth * (originalWatermarkSize.height / originalWatermarkSize.width)
    
    print("Watermark size calculated: \(watermarkWidth)x\(watermarkHeight) for video size: \(videoSize.width)x\(videoSize.height)")
    return CGSize(width: watermarkWidth, height: watermarkHeight)
  }
  
  private func calculateWatermarkPosition(for videoSize: CGSize, watermarkSize: CGSize) -> CGPoint {
    // Use a 24px margin from the bottom and right
    let margin: CGFloat = 24
    let x: CGFloat
    let y: CGFloat
    
    // For portrait orientation, position in bottom-right
    x = videoSize.width - watermarkSize.width - margin
    y = margin
    
    print("Watermark position: bottom-right at \(x),\(y)")
    return CGPoint(x: x, y: y)
  }
  
  private func applyWatermarkToExistingFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
    guard let watermarkImage = watermarkImage,
          let ciContext = ciContext else {
      print("Watermark or CIContext not available")
      return false
    }
    
    // Get the pixel buffer from the sample buffer
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
      print("Failed to get pixel buffer from sample buffer")
      return false
    }
    
    // Lock the pixel buffer for modification
    CVPixelBufferLockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: 0))
    defer {
      CVPixelBufferUnlockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: 0))
    }
    
    // Create CIImage from pixel buffer
    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    
    // Get video dimensions
    let videoSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                          height: CVPixelBufferGetHeight(pixelBuffer))
    
    // Calculate watermark size
    let watermarkSize = calculateWatermarkSize(for: videoSize)
    
    // Calculate watermark position
    let watermarkPos = calculateWatermarkPosition(for: videoSize, watermarkSize: watermarkSize)
    
    // Scale watermark to desired size
    // Get the original watermark image dimensions
    let originalWatermarkSize = watermarkImage.extent.size
    let scaleX = watermarkSize.width / originalWatermarkSize.width
    let scaleY = watermarkSize.height / originalWatermarkSize.height
    var scaledWatermark = watermarkImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
    
    print("Watermark scaling: original=\(originalWatermarkSize), target=\(watermarkSize), scale=\(scaleX)x\(scaleY)")
    
    // Apply correct rotation and flip for each camera type
    let isFrontCamera = currentCameraPosition == .front
    
    print("Applying watermark transformations: front=\(isFrontCamera)")
    
    // Since we're now using connection.videoOrientation = .portrait,
    // the video frames are already in portrait orientation
    // No mirroring needed for recording - recordings should never be mirrored
    print("No watermark transforms needed - connection handles video orientation")
    
    // Position watermark
    let positionedWatermark = scaledWatermark.transformed(by: CGAffineTransform(translationX: watermarkPos.x, y: watermarkPos.y))
    
    // Composite watermark over video frame
    let compositeFilter = CIFilter(name: "CISourceOverCompositing")
    compositeFilter?.setValue(ciImage, forKey: kCIInputBackgroundImageKey)
    compositeFilter?.setValue(positionedWatermark, forKey: kCIInputImageKey)
    
    guard let outputImage = compositeFilter?.outputImage else {
      print("Failed to create composite image")
      return false
    }
    
    // Render the composite image to the pixel buffer
    ciContext.render(outputImage, to: pixelBuffer)
    
    return true
  }
  
  private func setupAVAssetWriter(with videoFormat: CMFormatDescription) {
    guard let videoURL = pendingVideoURL else { 
      print("setupAVAssetWriter: No pending video URL")
      return 
    }
    
    if isSettingUpWriter {
      print("setupAVAssetWriter: Already setting up writer, skipping...")
      return
    }
    
    isSettingUpWriter = true
    print("setupAVAssetWriter: Starting setup...")
    print("setupAVAssetWriter: Video URL: \(videoURL.path)")
    
    do {
      videoWriter = try AVAssetWriter(url: videoURL, fileType: .mp4)
      
      // Get video dimensions from the format
      let dimensions = CMVideoFormatDescriptionGetDimensions(videoFormat)
      print("setupAVAssetWriter: Video dimensions: \(dimensions.width)x\(dimensions.height)")
      
      // Get more format info
      let pixelFormat = CMFormatDescriptionGetMediaSubType(videoFormat)
      print("setupAVAssetWriter: Pixel format: \(pixelFormat)")
      
      // Get orientation hint based on device orientation and camera position
      let orientationHint = getVideoOrientationHint()
      print("setupAVAssetWriter: Orientation hint: \(orientationHint) degrees")
      
      // Use more complete video settings that match the input format
      let videoSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: dimensions.width,
        AVVideoHeightKey: dimensions.height
        // Removed compression properties to use defaults
      ]
      
      print("setupAVAssetWriter: Video settings: \(videoSettings)")
      
      videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
      videoWriterInput?.expectsMediaDataInRealTime = true
      
      // Apply orientation transform to fix video orientation
      let transformOrientation = getVideoOrientationHint()
      print("setupAVAssetWriter: Applying orientation transform: \(transformOrientation) degrees")
      
      // Since we're now setting videoOrientation on the connection,
      // we don't need any additional transforms for recording
      let transform = CGAffineTransform.identity
      
      // Note: Front camera mirroring is handled by connection.isVideoMirrored for preview only
      // Recordings should not be mirrored (like most camera apps)
      print("setupAVAssetWriter: No transforms needed - connection handles orientation")
      
      // Apply the transform to the video writer input
      videoWriterInput?.transform = transform
      print("setupAVAssetWriter: Applied final transform: \(transform)")
      
      if let videoWriterInput = videoWriterInput, videoWriter!.canAdd(videoWriterInput) {
        videoWriter!.add(videoWriterInput)
        print("setupAVAssetWriter: Added video writer input successfully")
      } else {
        print("setupAVAssetWriter: Cannot add video writer input")
        isSettingUpWriter = false
        return
      }
      
      // Configure audio writer input
      let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 44100,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 128000
      ]
      
      audioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
      audioWriterInput?.expectsMediaDataInRealTime = true
      
      if let audioWriterInput = audioWriterInput, videoWriter!.canAdd(audioWriterInput) {
        videoWriter!.add(audioWriterInput)
        print("setupAVAssetWriter: Added audio writer input successfully")
      } else {
        print("setupAVAssetWriter: Cannot add audio writer input")
        isSettingUpWriter = false
        return
      }
      
      // Start writing but don't start session yet - we'll do that with the first frame
      videoWriter!.startWriting()
      print("setupAVAssetWriter: Started AVAssetWriter successfully (session will start with first frame)")
      
      // Reset the flag after successful setup
      isSettingUpWriter = false
      
    } catch {
      print("setupAVAssetWriter: Failed to set up AVAssetWriter: \(error)")
      isSettingUpWriter = false
    }
  }
  
  // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate & AVCaptureAudioDataOutputSampleBufferDelegate
  
  public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    // Process video frames for preview even when not recording
    // Only process recording-specific logic when recording
    
    // Check media type and handle accordingly
    guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
      print("No format description available")
      return
    }
    
    let mediaType = CMFormatDescriptionGetMediaType(formatDescription)
    
    // Debug: Log when we receive frames
    totalFrameCount += 1
    if totalFrameCount % 30 == 0 {
      print("captureOutput: Received frame #\(totalFrameCount), mediaType: \(mediaType == kCMMediaType_Video ? "video" : "audio"), isPreviewActive: \(isPreviewActive), isRecording: \(isRecording)")
    }
    
    if mediaType == kCMMediaType_Video {
      // Update preview texture if active (always do this)
      if isPreviewActive, let previewTexture = previewTexture {
        print("captureOutput: Preview is active, checking for pixel buffer")
        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
          print("captureOutput: Got pixel buffer, updating texture")
          
          // Log frame dimensions for debugging
          let width = CVPixelBufferGetWidth(pixelBuffer)
          let height = CVPixelBufferGetHeight(pixelBuffer)
          if previewFrameCount % 30 == 0 {
            print("Frame dimensions: \(width)x\(height)")
          }
          
          // Apply orientation correction for preview (same logic as recording)
          let orientationHint = getVideoOrientationHint()
          print("Preview orientation hint: \(orientationHint) degrees")
          
          // For now, just pass the original buffer
          // TODO: Apply orientation correction to the pixel buffer
          previewTexture.updatePixelBuffer(pixelBuffer)
          
          // Notify Flutter to repaint the texture
          if let textureId = previewTextureId {
            textureRegistry?.textureFrameAvailable(textureId)
          }
          // Debug logging for texture updates
          previewFrameCount += 1
          if previewFrameCount % 30 == 0 { // Log every 30 frames
            print("Updated preview texture with frame #\(previewFrameCount)")
          }
        } else {
          print("captureOutput: Failed to get pixel buffer from sample buffer")
        }
      } else {
        if totalFrameCount % 30 == 0 {
          print("captureOutput: Preview not active - isPreviewActive: \(isPreviewActive), previewTexture: \(previewTexture != nil)")
        }
      }
      
      // Only process recording logic when actually recording
      guard isRecording else { return }
      
      // Handle video frames for recording
      videoFrameCount += 1
      if videoFrameCount == 1 { // Log format info on first frame
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        print("Video format: \(dimensions.width)x\(dimensions.height)")
        
        // Set up AVAssetWriter on first frame with correct format
        setupAVAssetWriter(with: formatDescription)
        
        // Start the session with the first frame's timestamp
        if let videoWriter = videoWriter, videoWriter.status == .writing {
          let startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
          videoWriter.startSession(atSourceTime: startTime)
          print("Started video session at time: \(startTime.seconds)")
        }
      }
      
      if videoFrameCount % 30 == 0 { // Log every 30 frames (about once per second)
        print("Processing video frame #\(videoFrameCount)")
      }
      
      // Check if writer is in correct state
      if let videoWriter = videoWriter, videoWriter.status != .writing {
        if videoFrameCount % 30 == 0 {
          print("Writer not in writing state: \(videoWriter.status.rawValue)")
        }
        return
      }
      
      // Write video frame to file (simplified approach)
      if let videoWriterInput = videoWriterInput, 
         videoWriterInput.isReadyForMoreMediaData, 
         videoWriter != nil {
        
        // Debug sample buffer properties on first frame
        if videoFrameCount == 1 {
          let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
          let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription!)
          let pixelFormat = CMFormatDescriptionGetMediaSubType(formatDescription!)
          print("Sample buffer properties - Width: \(dimensions.width), Height: \(dimensions.height), Format: \(pixelFormat)")
        }
        
        // Apply watermark overlay if watermark is available
        let processedSampleBuffer: CMSampleBuffer
        if watermarkImage != nil {
          // Try to apply watermark by modifying the pixel buffer in place
          if applyWatermarkToExistingFrame(sampleBuffer) {
            // Use the original sample buffer (modified in place)
            processedSampleBuffer = sampleBuffer
            if videoFrameCount % 30 == 0 {
              print("Successfully applied watermark to frame #\(videoFrameCount)")
            }
          } else {
            print("Failed to apply watermark to frame #\(videoFrameCount), using original frame")
            processedSampleBuffer = sampleBuffer
          }
        } else {
          processedSampleBuffer = sampleBuffer
        }
        
        // Append the processed sample buffer
        let success = videoWriterInput.append(processedSampleBuffer)
        if !success {
          print("Failed to append video frame #\(videoFrameCount)")
          if let writer = videoWriter {
            print("  - Writer status: \(writer.status.rawValue)")
            print("  - Writer error: \(writer.error?.localizedDescription ?? "none")")
            
            // If writer failed, stop trying to append frames
            if writer.status == .failed {
              print("AVAssetWriter failed, stopping frame processing")
              return
            }
          }
        } else if videoFrameCount % 30 == 0 {
          print("Successfully appended video frame #\(videoFrameCount)")
        }
      } else {
        if videoFrameCount % 30 == 0 { // Log every 30 frames
          print("Video writer not ready for frame #\(videoFrameCount)")
          print("  - videoWriterInput exists: \(videoWriterInput != nil)")
          print("  - isReadyForMoreMediaData: \(videoWriterInput?.isReadyForMoreMediaData ?? false)")
          print("  - videoWriter exists: \(videoWriter != nil)")
          if let writer = videoWriter {
            print("  - videoWriter status: \(writer.status.rawValue)")
          }
        }
      }
      
    } else if mediaType == kCMMediaType_Audio {
      // Handle audio samples
      audioSampleCount += 1
      if audioSampleCount == 1 { // Log audio info on first sample
        print("Audio format: \(formatDescription)")
      }
      if audioSampleCount % 100 == 0 { // Log every 100 audio samples
        print("Processing audio sample #\(audioSampleCount)")
      }
      
      // Write audio sample to file (only if writer is ready)
      if let audioWriterInput = audioWriterInput, audioWriterInput.isReadyForMoreMediaData, videoWriter != nil {
        let success = audioWriterInput.append(sampleBuffer)
        if !success {
          print("Failed to append audio sample #\(audioSampleCount)")
        } else if audioSampleCount % 100 == 0 {
          print("Successfully appended audio sample #\(audioSampleCount)")
        }
      } else {
        if audioSampleCount % 100 == 0 { // Log every 100 samples
          print("Audio writer not ready for sample #\(audioSampleCount)")
          print("  - audioWriterInput exists: \(audioWriterInput != nil)")
          print("  - isReadyForMoreMediaData: \(audioWriterInput?.isReadyForMoreMediaData ?? false)")
          print("  - videoWriter exists: \(videoWriter != nil)")
        }
      }
    }
  }
  
  // MARK: - Orientation Helpers
  
  private func getDeviceOrientation() -> UIDeviceOrientation {
    return UIDevice.current.orientation
  }
  
  private func getDeviceRotation() -> Int {
    let orientation = getDeviceOrientation()
    switch orientation {
    case .portrait:
      return 0
    case .landscapeLeft:
      return 90
    case .landscapeRight:
      return 270
    case .portraitUpsideDown:
      return 180
    default:
      return 0
    }
  }
  
  private func getVideoOrientationHint() -> Int {
    let deviceRotation = getDeviceRotation()
    let isFrontCamera = currentCameraPosition == .front
    
    // Calculate orientation hint based on device rotation and camera type
    // This matches the Android implementation logic
    let orientationHint: Int
    switch deviceRotation {
    case 0: // Portrait
      orientationHint = isFrontCamera ? 270 : 90
    case 90: // Landscape Left
      orientationHint = isFrontCamera ? 180 : 0
    case 180: // Portrait Upside Down
      orientationHint = isFrontCamera ? 90 : 270
    case 270: // Landscape Right
      orientationHint = isFrontCamera ? 0 : 180
    default:
      orientationHint = isFrontCamera ? 270 : 90 // Default to portrait
    }
    
    return orientationHint
  }
  
  private func isFrontCamera() -> Bool {
    return currentCameraPosition == .front
  }

  // MARK: - Preview Methods

  private func startCameraPreview(direction: String) -> Int64? {
    print("startCameraPreview called with direction: \(direction)")
    
    // If camera is already initialized and running, just create preview texture
    if let captureSession = captureSession, captureSession.isRunning {
      print("Camera already running, creating preview texture only")
      return createPreviewTexture()
    }
    
    // Stop any existing preview
    stopCameraPreview()
    
    // Initialize camera with the specified direction
    let success = initializeCameraWithDirection(direction)
    if !success {
      print("Failed to initialize camera for preview")
      return nil
    }
    
    // Create preview layer
    guard let captureSession = captureSession else {
      print("Capture session is nil")
      return nil
    }
    
    // Create and register texture
    guard let textureRegistry = textureRegistry else {
      print("Texture registry is nil")
      return nil
    }
    
    let previewTexture = CameraPreviewTexture()
    let textureId = textureRegistry.register(previewTexture)
    
    // Store references
    self.previewTexture = previewTexture
    self.previewTextureId = textureId
    self.isPreviewActive = true
    
    // Start the capture session
    DispatchQueue.global(qos: .userInitiated).async {
      captureSession.startRunning()
    }
    
    print("Camera preview started successfully with texture ID: \(textureId)")
    return textureId
  }
  
  private func createPreviewTexture() -> Int64? {
    print("createPreviewTexture called")
    
    // Create and register texture
    guard let textureRegistry = textureRegistry else {
      print("Texture registry is nil")
      return nil
    }
    
    let previewTexture = CameraPreviewTexture()
    let textureId = textureRegistry.register(previewTexture)
    
    // Store references
    self.previewTexture = previewTexture
    self.previewTextureId = textureId
    self.isPreviewActive = true
    
    print("Preview texture created with ID: \(textureId)")
    return textureId
  }

  private func startPreviewWithWatermark(watermarkPath: String, direction: String) -> Int64? {
    print("startPreviewWithWatermark called with watermark: \(watermarkPath), direction: \(direction)")
    
    // Set watermark first
    setWatermarkImage(watermarkPath)
    
    // Start preview (this will handle the watermark overlay)
    return startCameraPreview(direction: direction)
  }

  private func stopCameraPreview() {
    print("stopCameraPreview called")
    
    isPreviewActive = false
    
    // Stop the capture session
    captureSession?.stopRunning()
    
    // Unregister texture
    if let textureId = previewTextureId, let textureRegistry = textureRegistry {
      textureRegistry.unregisterTexture(textureId)
    }
    
    // Release references
    previewTexture = nil
    previewTextureId = nil
    previewLayer = nil
    
    print("Camera preview stopped successfully")
  }
}
