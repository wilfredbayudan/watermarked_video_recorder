import Flutter
import UIKit
import AVFoundation
import Photos
import CoreImage
import VideoToolbox

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
  private var watermarkMode: String = "bottomRight" // "bottomRight" or "fullScreen"

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

  // Add property to track session start
  private var hasStartedSession = false

  // Add segmented recording support
  private var segmentPaths: [String] = []
  private var isPaused = false

  // Add property for snapshot frame handler
  private var snapshotFrameHandler: ((CMSampleBuffer) -> Void)?

  // Add this with other private vars at the top of the class
  private var latestVideoSampleBuffer: CMSampleBuffer?
  
  // Audio engine for mixing background audio with recording
  private var audioEngine: AVAudioEngine?
  private var audioPlayerNode: AVAudioPlayerNode?
  
  // Simple recording properties (separate from complex watermarked recording)
  private var simpleRecordingSession: AVCaptureSession?
  private var simpleVideoInput: AVCaptureDeviceInput?
  private var simpleAudioInput: AVCaptureDeviceInput?
  private var simpleMovieOutput: AVCaptureMovieFileOutput?
  private var simpleVideoPath: String?

  // MARK: - Audio Session Configuration
  
  private func configureAudioSessionForBackgroundMusic() {
    do {
      let audioSession = AVAudioSession.sharedInstance()
      
      // Check if other audio is currently playing
      let isOtherAudioPlaying = audioSession.isOtherAudioPlaying
      print("🎵 Other audio playing: \(isOtherAudioPlaying)")
      
      // CRITICAL: First try .ambient to allow background music to continue
      // Then we'll switch to .playAndRecord only when we actually need recording
      try audioSession.setCategory(.ambient, 
                                   mode: .default, 
                                   options: [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP])
      
      // Don't activate yet - let the background audio continue
      print("🎵 Audio session configured for background music preservation")
      print("🎵 Category: \(audioSession.category)")
      print("🎵 Mode: \(audioSession.mode)")
      print("🎵 Options: \(audioSession.categoryOptions)")
      print("🎵 Other audio still playing: \(audioSession.isOtherAudioPlaying)")
    } catch {
      print("❌ Failed to configure audio session: \(error)")
    }
  }
  
  private func configureAudioSessionForRecording() {
    do {
      let audioSession = AVAudioSession.sharedInstance()
      
      print("🎵 Configuring audio session for MIXED recording (microphone + background music)...")
      print("🎵 Other audio playing before: \(audioSession.isOtherAudioPlaying)")
      
      // Use ADVANCED options specifically for background music mixing
      if #available(iOS 14.5, *) {
        try audioSession.setCategory(.playAndRecord, 
                                   options: [.mixWithOthers, .allowAirPlay, .overrideMutedMicrophoneInterruption])
      } else {
        try audioSession.setCategory(.playAndRecord, 
                                   options: [.mixWithOthers, .allowAirPlay])
      }
      
      try audioSession.setMode(.videoRecording)
      
      // Try activating without interrupting other audio
      try audioSession.setActive(true, options: [])
      
      print("🎵 ✅ Audio session configured for MIXED recording")
      print("🎵 Category: \(audioSession.category.rawValue)")
      print("🎵 Mode: \(audioSession.mode.rawValue)")
      print("🎵 Options: \(audioSession.categoryOptions.rawValue)")
      print("🎵 Other audio still playing: \(audioSession.isOtherAudioPlaying)")
    } catch {
      print("❌ Failed to configure audio session for recording: \(error)")
    }
  }
  
  private func addAudioInputForRecording() -> Bool {
    guard let session = captureSession else {
      print("❌ No capture session available for adding audio input")
      return false
    }
    
    do {
      if let audioDevice = AVCaptureDevice.default(for: .audio) {
        let audioInput = try AVCaptureDeviceInput(device: audioDevice)
        if session.canAddInput(audioInput) {
          session.beginConfiguration()
          session.addInput(audioInput)
          self.audioInput = audioInput
          session.commitConfiguration()
          print("🎵 Added audio input for recording WITH background music mixing")
          return true
        } else {
          print("❌ Cannot add audio input to session")
          return false
        }
      } else {
        print("❌ No audio device found")
        return false
      }
    } catch {
      print("❌ Failed to add audio input: \(error)")
      return false
    }
  }

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
    case "pauseRecording":
      let success = pauseRecording()
      result(success)
    case "resumeRecording":
      let success = resumeRecording()
      result(success)
    case "stopVideoRecording":
      stopVideoRecording { videoPath in
        // After stopping, merge segments if needed
        self.mergeSegmentsIfNeeded { mergedPath in
          result(mergedPath)
        }
      }
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
      let mode = args?["mode"] as? String
      setWatermarkImage(path, mode: mode)
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
        "audioOutput": audioOutput != nil,
        "currentCameraPosition": currentCameraPosition == .front ? "front" : "back"
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
      print("getPreviewTextureId: textureRegistry=\(textureRegistry != nil), previewTexture=\(previewTexture != nil)")
      result(textureId)
    case "startPreviewWithWatermark":
      let args = call.arguments as? [String: Any]
      let watermarkPath = args?["watermarkPath"] as? String
      let direction = args?["direction"] as? String
      let mode = args?["mode"] as? String
      let textureId: Int64? = if let watermarkPath = watermarkPath, let direction = direction {
        startPreviewWithWatermark(watermarkPath: watermarkPath, direction: direction, mode: mode)
      } else { nil }
      result(textureId)
    case "capturePhotoWithWatermark":
      capturePhotoWithWatermark { imagePath in
        result(imagePath)
      }
    case "startSimpleVideoRecording":
      let args = call.arguments as? [String: Any]
      let direction = args?["direction"] as? String ?? "back"
      let success = startSimpleVideoRecording(direction: direction)
      result(success)
    case "stopSimpleVideoRecording":
      stopSimpleVideoRecording { videoPath in
        result(videoPath)
      }
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
    
    // Configure audio session BEFORE creating capture session (StackOverflow approach)
    do {
      let audioSession = AVAudioSession.sharedInstance()
      print("🎵 Other audio playing before StackOverflow config: \(audioSession.isOtherAudioPlaying)")
      
      // First deactivate current session
      try audioSession.setActive(false)
      
      // Set category with options that allow background music mixing
      try audioSession.setCategory(.playAndRecord, options: [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP, .allowAirPlay])
      try audioSession.setMode(.videoRecording)
      try audioSession.setActive(true)
      
      print("🎵 ✅ StackOverflow-style audio session configured")
      print("🎵 Other audio still playing: \(audioSession.isOtherAudioPlaying)")
    } catch {
      print("❌ Failed StackOverflow audio session config: \(error)")
      return false
    }
    
    do {
      // Create session
      let session = AVCaptureSession()
      
      // CRITICAL: Tell the session NOT to automatically manage audio session
      // This prevents it from overriding our audio session configuration
      session.automaticallyConfiguresApplicationAudioSession = false
      session.usesApplicationAudioSession = true
      
      session.beginConfiguration()
      // Set session preset to 1080p if available, else fallback to .high
      if session.canSetSessionPreset(.hd1920x1080) {
        session.sessionPreset = .hd1920x1080
      } else {
      session.sessionPreset = .high
      }

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

      // DON'T add audio input yet - we'll add it dynamically when starting recording
      // This is the StackOverflow approach
      if let audioDevice = AVCaptureDevice.default(for: .audio) {
        self.audioInput = try AVCaptureDeviceInput(device: audioDevice)
        print("✅ Created audio input (will add it when starting recording)")
      } else {
        print("❌ No audio device found for main recording")
        isCameraInitializing = false
        return false
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
          
          // Mirror for fullScreen mode with front camera (WYSIWYG selfie view)
          if watermarkMode == "fullScreen" && currentCameraPosition == .front {
            connection.isVideoMirrored = true
            print("Enabled video mirroring for fullScreen mode + front camera")
          } else {
            connection.isVideoMirrored = false
            print("Video mirroring disabled")
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
          
          // Keep .ambient category to preserve background music until we actually start recording
          print("🎵 Keeping .ambient category to preserve background music")
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
    
    // SKIP audio session configuration during camera init to preserve background music
    print("🎵 Skipping audio session config during camera init - background music preserved")
    
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
      // Set session preset to 1080p if available, else fallback to .high
      if session.canSetSessionPreset(.hd1920x1080) {
        session.sessionPreset = .hd1920x1080
      } else {
      session.sessionPreset = .high
      }
      
      let input = try AVCaptureDeviceInput(device: camera)
      if session.canAddInput(input) {
        session.addInput(input)
      } else {
        print("Cannot add camera input")
        isCameraInitializing = false
        return false
      }
      
      // DON'T add audio input yet - we'll add it dynamically when starting recording
      // This is the StackOverflow approach  
      if let audioDevice = AVCaptureDevice.default(for: .audio) {
        self.audioInput = try AVCaptureDeviceInput(device: audioDevice)
        print("✅ Created audio input (will add it when starting recording)")
      } else {
        print("❌ No audio device found for direction recording")
        isCameraInitializing = false
        return false
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
          
          // Mirror for fullScreen mode with front camera (WYSIWYG selfie view)
          if watermarkMode == "fullScreen" && currentCameraPosition == .front {
            connection.isVideoMirrored = true
            print("Enabled video mirroring for fullScreen mode + front camera")
          } else {
            connection.isVideoMirrored = false
            print("Video mirroring disabled")
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
          
          // Keep .ambient category to preserve background music until we actually start recording
          print("🎵 Keeping .ambient category to preserve background music")
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
    
    // Configure audio session BEFORE creating capture session (StackOverflow approach)
    do {
      let audioSession = AVAudioSession.sharedInstance()
      print("🎵 Other audio playing before StackOverflow config: \(audioSession.isOtherAudioPlaying)")
      
      // First deactivate current session
      try audioSession.setActive(false)
      
      // Set category with options that allow background music mixing
      try audioSession.setCategory(.playAndRecord, options: [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP, .allowAirPlay])
      try audioSession.setMode(.videoRecording)
      try audioSession.setActive(true)
      
      print("🎵 ✅ StackOverflow-style audio session configured")
      print("🎵 Other audio still playing: \(audioSession.isOtherAudioPlaying)")
    } catch {
      print("❌ Failed StackOverflow audio session config: \(error)")
      isCameraInitializing = false
      return false
    }
    
    do {
      // Create session
      let session = AVCaptureSession()
      
      // CRITICAL: Tell the session NOT to automatically manage audio session
      // This prevents it from overriding our audio session configuration
      session.automaticallyConfiguresApplicationAudioSession = false
      session.usesApplicationAudioSession = true
      
      session.beginConfiguration()
      // Set session preset to 1080p if available, else fallback to .high
      if session.canSetSessionPreset(.hd1920x1080) {
        session.sessionPreset = .hd1920x1080
      } else {
      session.sessionPreset = .high
      }
      
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
      
      // DON'T add audio input yet - we'll add it dynamically when starting recording
      // This is the StackOverflow approach  
      if let audioDevice = AVCaptureDevice.default(for: .audio) {
        self.audioInput = try AVCaptureDeviceInput(device: audioDevice)
        print("✅ Created audio input (will add it when starting recording)")
      } else {
        print("❌ No audio device found for direction recording")
        isCameraInitializing = false
        return false
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
          
          // Mirror for fullScreen mode with front camera (WYSIWYG selfie view)
          if watermarkMode == "fullScreen" && currentCameraPosition == .front {
            connection.isVideoMirrored = true
            print("Enabled video mirroring for fullScreen mode + front camera")
          } else {
            connection.isVideoMirrored = false
            print("Video mirroring disabled")
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
          
          // Keep .ambient category to preserve background music until we actually start recording
          print("🎵 Keeping .ambient category to preserve background music")
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
    print("[DEBUG] disposeCamera called. isRecording: \(isRecording), videoWriter: \(videoWriter != nil)")
    print("Camera disposal started")
    
    // Stop recording if active
    if isRecording {
      videoOutput?.setSampleBufferDelegate(nil, queue: nil)
      audioOutput?.setSampleBufferDelegate(nil, queue: nil)
      isRecording = false
    }
    
    // Remove audio input from capture session if it's attached
    if let session = captureSession, let audioInput = self.audioInput {
      session.beginConfiguration()
      if session.inputs.contains(audioInput) {
        session.removeInput(audioInput)
        print("✅ Removed audio input from capture session during disposal")
      }
      session.commitConfiguration()
    }
    
    // Reset audio session category and deactivate
    do {
      let audioSession = AVAudioSession.sharedInstance()
      
      print("🎵 Resetting audio session during disposal...")
      
      // Reset to .ambient category to clear any .playAndRecord audio processing
      try audioSession.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
      print("🎵 ✅ Category reset to .ambient")
      
      // Deactivate and notify other apps
      try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
      print("🎵 ✅ Audio session deactivated, other apps notified")
    } catch {
      print("❌ Failed to reset audio session during disposal: \(error)")
    }
    
    // Stop the capture session
    captureSession?.stopRunning()
    
    // Clean up preview texture
    if let textureId = previewTextureId, let textureRegistry = textureRegistry {
      textureRegistry.unregisterTexture(textureId)
    }
    previewTexture = nil
    previewTextureId = nil
    isPreviewActive = false
    
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
    
    // Create preview texture if not already created (similar to Android implementation)
    if !isPreviewActive {
      print("Creating preview texture for recording")
      if let textureId = createPreviewTexture() {
        print("Created preview texture with ID: \(textureId) for recording")
      } else {
        print("Failed to create preview texture for recording")
      }
    } else {
      print("Preview texture already active, skipping creation")
    }
    
    // Start video recording first
    videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue.global(qos: .userInitiated))
    
    // Add audio input dynamically RIGHT before recording (StackOverflow approach)
    session.beginConfiguration()
    if let audioInput = self.audioInput, session.canAddInput(audioInput) {
      session.addInput(audioInput)
      print("✅ Added audio input dynamically for watermarked recording")
      
      // Start audio recording immediately
      audioOutput?.setSampleBufferDelegate(self, queue: DispatchQueue.global(qos: .userInitiated))
      print("🎵 Audio recording started with watermarked video")
    } else {
      print("❌ Cannot add audio input dynamically for watermarked recording")
      // Continue without audio - this allows video-only recording
    }
    session.commitConfiguration()
    
    isRecording = true
    hasStartedSession = false // Reset session flag
    if videoWriter == nil {
      print("[ERROR] startVideoRecording: videoWriter is nil after setup!")
    } else {
      print("[DEBUG] startVideoRecording: videoWriter is set and ready.")
    }
    print("Started video recording to: \(videoURL.path)")
    return true
  }

  // Change stopVideoRecording to async with completion handler
  private func stopVideoRecording(completion: @escaping (String?) -> Void) {
    hasStartedSession = false // Reset session flag
    if videoWriter == nil {
      print("[ERROR] stopVideoRecording: videoWriter is nil at the start!")
    }
    guard let videoOutput = videoOutput, isRecording else {
      print("Cannot stop recording: videoOutput is nil or not recording")
      completion(nil)
      return
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
    
    // CRITICAL: Remove audio input from capture session
    // This allows it to be added cleanly on the next recording
    if let session = captureSession, let audioInput = self.audioInput {
      session.beginConfiguration()
      session.removeInput(audioInput)
      print("✅ Removed audio input from capture session after recording")
      session.commitConfiguration()
    }
    
    // CRITICAL: Reset audio session category back to .ambient BEFORE deactivating
    // This prevents VideoPlayer or other audio from inheriting .playAndRecord settings
    do {
      let audioSession = AVAudioSession.sharedInstance()
      
      print("🎵 Resetting audio session after recording...")
      print("  - Current category: \(audioSession.category.rawValue)")
      print("  - Current mode: \(audioSession.mode.rawValue)")
      
      // First, reset to .ambient category to clear .playAndRecord audio processing
      try audioSession.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
      print("🎵 ✅ Category reset to .ambient")
      
      // Now deactivate and notify other apps to resume
      try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
      print("🎵 ✅ Audio session deactivated, other apps notified")
    } catch {
      print("❌ Failed to reset audio session after recording: \(error)")
    }
    // Finish writing the file
    if let videoWriter = videoWriter {
      videoWriterInput?.markAsFinished()
      audioWriterInput?.markAsFinished()
      print("Waiting for AVAssetWriter to finish writing...")
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
                completion(path)
                return
              } else {
                print("Video file does not exist after finishWriting")
              }
            }
          } else {
            print("Video recording failed: \(videoWriter.error?.localizedDescription ?? "Unknown error")")
          }
          completion(nil)
        }
      }
    } else {
      print("No videoWriter to finish writing")
      completion(nil)
    }
    // Clean up
    videoWriter = nil
    videoWriterInput = nil
    audioWriterInput = nil
    pixelBufferAdaptor = nil
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

  private func setWatermarkImage(_ path: String?, mode: String? = nil) {
    watermarkImagePath = path
    // If mode is explicitly provided, use it. Otherwise, reset to default "bottomRight"
    // This prevents mode from persisting across different recording sessions
    if let mode = mode {
      watermarkMode = mode
      print("Set watermark mode: \(mode)")
    } else {
      watermarkMode = "bottomRight"
      print("Mode not specified, defaulting to: bottomRight")
    }
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
    if watermarkMode == "fullScreen" {
      // Full-screen mode: use entire video dimensions
      return videoSize
    } else {
      // bottomRight mode: Use 25% of the video width for the watermark
      let scale: CGFloat = 0.25
      let watermarkWidth = videoSize.width * scale
      
      // Get the original watermark image dimensions for aspect ratio
      guard let watermarkImage = watermarkImage else {
        return CGSize(width: watermarkWidth, height: watermarkWidth)
      }
      
      let originalWatermarkSize = watermarkImage.extent.size
      let watermarkHeight = watermarkWidth * (originalWatermarkSize.height / originalWatermarkSize.width)
      
      // Watermark size calculated: \(watermarkWidth)x\(watermarkHeight) for video size: \(videoSize.width)x\(videoSize.height) - removed to reduce log spam
      return CGSize(width: watermarkWidth, height: watermarkHeight)
    }
  }
  
  private func calculateWatermarkPosition(for videoSize: CGSize, watermarkSize: CGSize) -> CGPoint {
    if watermarkMode == "fullScreen" {
      // Full-screen mode: position at top-left (0, 0)
      return CGPoint(x: 0, y: 0)
    } else {
      // bottomRight mode: Use a 24px margin from the bottom and right
      let margin: CGFloat = 24
      let x: CGFloat
      let y: CGFloat
      
      // For portrait orientation, position in bottom-right
      x = videoSize.width - watermarkSize.width - margin
      y = margin
      
      // Watermark position: bottom-right at \(x),\(y) - removed to reduce log spam
      return CGPoint(x: x, y: y)
    }
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
    
    // Watermark scaling: original=\(originalWatermarkSize), target=\(watermarkSize), scale=\(scaleX)x\(scaleY) - removed to reduce log spam
    
    // Apply correct rotation and flip for each camera type
    let isFrontCamera = currentCameraPosition == .front
    
    // Applying watermark transformations: front=\(isFrontCamera) - removed to reduce log spam
    
    // Since we're now using connection.videoOrientation = .portrait,
    // the video frames are already in portrait orientation
    // Mirroring is handled by connection.isVideoMirrored, not manual transforms
    
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
    let outBuffer = pixelBuffer
    // Defensive: Only render if session is running
    if captureSession?.isRunning != true {
      print("[WARN] Tried to render while session is not running")
      return false
    }
    CVPixelBufferLockBaseAddress(outBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(outBuffer, []) }
    do {
      try autoreleasepool {
        ciContext.render(outputImage, to: outBuffer)
      }
    } catch {
      print("[ERROR] ciContext.render failed: \(error)")
      return false
    }
    return true
  }
  
  // Helper: Copy pixel buffer and apply watermark, return new CMSampleBuffer
  private func copyAndApplyWatermark(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    var newPixelBuffer: CVPixelBuffer?
    let attrs = [
      kCVPixelBufferCGImageCompatibilityKey: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey: true
    ] as CFDictionary
    let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, CVPixelBufferGetPixelFormatType(pixelBuffer), attrs, &newPixelBuffer)
    guard status == kCVReturnSuccess, let outBuffer = newPixelBuffer else {
      print("[ERROR] copyAndApplyWatermark: Failed to create new pixel buffer")
      return nil
    }
    // Copy pixel data
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    CVPixelBufferLockBaseAddress(outBuffer, [])
    for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
      let src = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane)
      let dst = CVPixelBufferGetBaseAddressOfPlane(outBuffer, plane)
      let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
      let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
      memcpy(dst, src, height * bytesPerRow)
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
    // Apply watermark to the copy
    let ciImage = CIImage(cvPixelBuffer: outBuffer)
    guard let watermarkImage = watermarkImage, let ciContext = ciContext else {
      CVPixelBufferUnlockBaseAddress(outBuffer, [])
      return nil
    }
    let videoSize = CGSize(width: width, height: height)
    let watermarkSize = calculateWatermarkSize(for: videoSize)
    let watermarkPos = calculateWatermarkPosition(for: videoSize, watermarkSize: watermarkSize)
    let originalWatermarkSize = watermarkImage.extent.size
    let scaleX = watermarkSize.width / originalWatermarkSize.width
    let scaleY = watermarkSize.height / originalWatermarkSize.height
    let scaledWatermark = watermarkImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
    let positionedWatermark = scaledWatermark.transformed(by: CGAffineTransform(translationX: watermarkPos.x, y: watermarkPos.y))
    let compositeFilter = CIFilter(name: "CISourceOverCompositing")
    compositeFilter?.setValue(ciImage, forKey: kCIInputBackgroundImageKey)
    compositeFilter?.setValue(positionedWatermark, forKey: kCIInputImageKey)
    guard let outputImage = compositeFilter?.outputImage else {
      CVPixelBufferUnlockBaseAddress(outBuffer, [])
      return nil
    }
    ciContext.render(outputImage, to: outBuffer)
    CVPixelBufferUnlockBaseAddress(outBuffer, [])
    // Create new CMSampleBuffer
    var newSampleBuffer: CMSampleBuffer?
    var timingInfo = CMSampleTimingInfo()
    let status2 = CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timingInfo)
    if status2 != noErr {
      print("[ERROR] copyAndApplyWatermark: Failed to get timing info")
      return nil
    }
    var formatDesc: CMFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: outBuffer, formatDescriptionOut: &formatDesc)
    if let formatDesc = formatDesc {
      CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: outBuffer, formatDescription: formatDesc, sampleTiming: &timingInfo, sampleBufferOut: &newSampleBuffer)
    }
    return newSampleBuffer
  }
  
  private func setupAVAssetWriter(with videoFormat: CMFormatDescription) {
    print("[DEBUG] Entered setupAVAssetWriter")
    print("[DEBUG] pendingVideoURL: \(pendingVideoURL?.path ?? "nil")")
    guard let videoURL = pendingVideoURL else {
      print("[ERROR] setupAVAssetWriter: pendingVideoURL is nil!")
      return
    }
    if isSettingUpWriter {
      print("[ERROR] setupAVAssetWriter: Already setting up writer, skipping...")
      return
    }
    isSettingUpWriter = true
    print("[DEBUG] setupAVAssetWriter: Starting setup...")
    print("[DEBUG] setupAVAssetWriter: Video URL: \(videoURL.path)")
    let dimensions = CMVideoFormatDescriptionGetDimensions(videoFormat)
    print("[DEBUG] setupAVAssetWriter: Video dimensions: \(dimensions.width)x\(dimensions.height)")
    if dimensions.width == 0 || dimensions.height == 0 {
      print("[ERROR] setupAVAssetWriter: Invalid video dimensions: \(dimensions.width)x\(dimensions.height)")
      isSettingUpWriter = false
      return
    }
    do {
      videoWriter = try AVAssetWriter(url: videoURL, fileType: .mp4)
      print("[DEBUG] setupAVAssetWriter: AVAssetWriter created at: \(videoURL.path)")
      let videoSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: dimensions.width,
        AVVideoHeightKey: dimensions.height,
        AVVideoCompressionPropertiesKey: [
          AVVideoAverageBitRateKey: 12_000_000, // 12 Mbps for high quality
          AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
        ]
      ]
      videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
      videoWriterInput?.expectsMediaDataInRealTime = true
      // Pixel buffer adaptor for compatibility
      pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: videoWriterInput!,
        sourcePixelBufferAttributes: [
          kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
          kCVPixelBufferWidthKey as String: dimensions.width,
          kCVPixelBufferHeightKey as String: dimensions.height
        ]
      )
      if let videoWriterInput = videoWriterInput, videoWriter!.canAdd(videoWriterInput) {
        videoWriter!.add(videoWriterInput)
        print("setupAVAssetWriter: Added video writer input successfully")
      } else {
        print("setupAVAssetWriter: Cannot add video writer input")
        isSettingUpWriter = false
        return
      }
      // Configure audio writer input for mixed audio (microphone + background music)
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
        print("setupAVAssetWriter: Added audio writer input for mixed recording")
      } else {
        print("setupAVAssetWriter: Cannot add audio writer input")
        isSettingUpWriter = false
        return
      }
      videoWriter!.startWriting()
      print("setupAVAssetWriter: Started AVAssetWriter successfully (session will start with first frame)")
      isSettingUpWriter = false
    } catch {
      print("[ERROR] setupAVAssetWriter: Failed to set up AVAssetWriter: \(error)")
      isSettingUpWriter = false
    }
  }

  // Helper: Render watermark into a pixel buffer from the adaptor pool
  private func renderWatermarkToPixelBuffer(from sampleBuffer: CMSampleBuffer) -> CVPixelBuffer? {
    guard let adaptor = pixelBufferAdaptor else { return nil }
    var newPixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &newPixelBuffer)
    guard status == kCVReturnSuccess, let outBuffer = newPixelBuffer else {
      print("[ERROR] renderWatermarkToPixelBuffer: Failed to get buffer from pool")
      return nil
    }
    // Copy original image to new buffer
    guard let srcBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
    CVPixelBufferLockBaseAddress(srcBuffer, .readOnly)
    CVPixelBufferLockBaseAddress(outBuffer, [])
    for plane in 0..<CVPixelBufferGetPlaneCount(srcBuffer) {
      let src = CVPixelBufferGetBaseAddressOfPlane(srcBuffer, plane)
      let dst = CVPixelBufferGetBaseAddressOfPlane(outBuffer, plane)
      let height = CVPixelBufferGetHeightOfPlane(srcBuffer, plane)
      let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(srcBuffer, plane)
      memcpy(dst, src, height * bytesPerRow)
    }
    CVPixelBufferUnlockBaseAddress(srcBuffer, .readOnly)
    // Apply watermark
    let width = CVPixelBufferGetWidth(outBuffer)
    let height = CVPixelBufferGetHeight(outBuffer)
    let ciImage = CIImage(cvPixelBuffer: outBuffer)
    guard let watermarkImage = watermarkImage, let ciContext = ciContext else {
      CVPixelBufferUnlockBaseAddress(outBuffer, [])
      return outBuffer
    }
    let videoSize = CGSize(width: width, height: height)
    let watermarkSize = calculateWatermarkSize(for: videoSize)
    let watermarkPos = calculateWatermarkPosition(for: videoSize, watermarkSize: watermarkSize)
    let originalWatermarkSize = watermarkImage.extent.size
    let scaleX = watermarkSize.width / originalWatermarkSize.width
    let scaleY = watermarkSize.height / originalWatermarkSize.height
    let scaledWatermark = watermarkImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
    let positionedWatermark = scaledWatermark.transformed(by: CGAffineTransform(translationX: watermarkPos.x, y: watermarkPos.y))
    let compositeFilter = CIFilter(name: "CISourceOverCompositing")
    compositeFilter?.setValue(ciImage, forKey: kCIInputBackgroundImageKey)
    compositeFilter?.setValue(positionedWatermark, forKey: kCIInputImageKey)
    guard let outputImage = compositeFilter?.outputImage else {
      CVPixelBufferUnlockBaseAddress(outBuffer, [])
      return outBuffer
    }
    ciContext.render(outputImage, to: outBuffer)
    CVPixelBufferUnlockBaseAddress(outBuffer, [])
    return outBuffer
  }
  
  // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate & AVCaptureAudioDataOutputSampleBufferDelegate
  
  public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    // Handle snapshot frame if requested
    if let handler = snapshotFrameHandler {
      snapshotFrameHandler = nil
      handler(sampleBuffer)
      return
    }
    // Process video frames for preview even when not recording
    // Only process recording-specific logic when recording
    guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
      print("No format description available")
      return
    }
    let mediaType = CMFormatDescriptionGetMediaType(formatDescription)
    if mediaType == kCMMediaType_Video {
      // Cache the latest video frame
      latestVideoSampleBuffer = sampleBuffer
    }
    // Debug: Log when we receive frames
    totalFrameCount += 1
    if totalFrameCount % 30 == 0 {
      print("captureOutput: Received frame #\(totalFrameCount), mediaType: \(mediaType == kCMMediaType_Video ? "video" : "audio"), isPreviewActive: \(isPreviewActive), isRecording: \(isRecording)")
    }
    
    if mediaType == kCMMediaType_Video {
      // PREVIEW: Always use the original pixelBuffer for preview, never apply watermark
      if isPreviewActive, let previewTexture = previewTexture {
        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
          previewTexture.updatePixelBuffer(pixelBuffer);
          if let textureId = previewTextureId {
            textureRegistry?.textureFrameAvailable(textureId);
          }
          previewFrameCount += 1;
        }
      }
      // RECORDING: Only apply watermark to frames written to file
      guard isRecording else { return };
      videoFrameCount += 1;
      // Only set up AVAssetWriter when we have a valid frame
      if videoWriter == nil {
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        if dimensions.width > 0 && dimensions.height > 0 {
          print("[DEBUG] captureOutput: Setting up AVAssetWriter with dimensions: \(dimensions.width)x\(dimensions.height)")
          setupAVAssetWriter(with: formatDescription)
        } else {
          print("[DEBUG] captureOutput: Skipping setupAVAssetWriter due to invalid dimensions: \(dimensions.width)x\(dimensions.height)")
          return
        }
      }
      // Ensure AVAssetWriter session is started before appending
      if let videoWriter = videoWriter, videoWriter.status == .writing, !hasStartedSession {
        let startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        videoWriter.startSession(atSourceTime: startTime)
        hasStartedSession = true
        print("[DEBUG] AVAssetWriter session started at: \(startTime.seconds)")
      }
      if let videoWriterInput = videoWriterInput, 
         videoWriterInput.isReadyForMoreMediaData, 
         videoWriter != nil {
        let processedPixelBuffer: CVPixelBuffer?
        if watermarkImage != nil {
          processedPixelBuffer = renderWatermarkToPixelBuffer(from: sampleBuffer)
        } else {
          processedPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        }
        // Log pixel buffer format - removed to reduce log spam
        // if let pb = processedPixelBuffer {
        //   let pixelFormat = CVPixelBufferGetPixelFormatType(pb)
        //   print("[DEBUG] Pixel buffer format: \(pixelFormat)")
        // }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let success = pixelBufferAdaptor?.append(processedPixelBuffer!, withPresentationTime: presentationTime) ?? false
        if !success {
          print("Failed to append video frame #\(videoFrameCount)");
          if let writer = videoWriter {
            print("  - Writer status: \(writer.status.rawValue)")
            print("  - Writer error: \(writer.error?.localizedDescription ?? "none")")
          }
        }
      }
    } else if mediaType == kCMMediaType_Audio {
      audioSampleCount += 1;
      if let audioWriterInput = audioWriterInput, audioWriterInput.isReadyForMoreMediaData, videoWriter != nil {
        let success = audioWriterInput.append(sampleBuffer);
        if !success {
          print("Failed to append audio sample #\(audioSampleCount)");
          if let writer = videoWriter {
            print("  - Writer status: \(writer.status.rawValue)")
            print("  - Writer error: \(writer.error?.localizedDescription ?? "none")")
          }
        } else if audioSampleCount % 100 == 0 {
          print("🎵 Recording mixed audio frame #\(audioSampleCount) (microphone + background music)")
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
    
    print("Creating CameraPreviewTexture...")
    let previewTexture = CameraPreviewTexture()
    print("Registering texture with registry...")
    let textureId = textureRegistry.register(previewTexture)
    print("Texture registered with ID: \(textureId)")
    
    // Store references
    self.previewTexture = previewTexture
    self.previewTextureId = textureId
    self.isPreviewActive = true
    
    print("Preview texture created with ID: \(textureId)")
    return textureId
  }

  private func startPreviewWithWatermark(watermarkPath: String, direction: String, mode: String? = nil) -> Int64? {
    print("startPreviewWithWatermark called with watermark: \(watermarkPath), direction: \(direction), mode: \(mode ?? "default")")
    
    // Set watermark first with mode
    setWatermarkImage(watermarkPath, mode: mode)
    
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

  // MARK: - Segmented Recording Methods
  private func pauseRecording() -> Bool {
    guard isRecording else { return false }
    isPaused = true
    // Stop current segment
    if let videoWriter = videoWriter {
      videoWriterInput?.markAsFinished()
      audioWriterInput?.markAsFinished()
      let currentPath = currentVideoPath
      videoWriter.finishWriting { [weak self] in
        if let path = currentPath {
          self?.segmentPaths.append(path)
        }
      }
    }
    // Clean up writer
    videoWriter = nil
    videoWriterInput = nil
    audioWriterInput = nil
    pixelBufferAdaptor = nil
    isRecording = false
    currentVideoPath = nil
    pendingVideoURL = nil
    return true
  }

  private func resumeRecording() -> Bool {
    guard !isRecording else { return false }
    isPaused = false
    // Start a new segment
    return startVideoRecording()
  }

  private func mergeSegmentsIfNeeded(completion: @escaping (String?) -> Void) {
    if segmentPaths.isEmpty {
      // No segments, just return the last video path
      completion(pendingVideoPath)
      return
    }
    // If only one segment, return it
    if segmentPaths.count == 1 {
      completion(segmentPaths.first)
      segmentPaths.removeAll()
      return
    }
    // Merge segments
    let composition = AVMutableComposition()
    guard let firstAsset = AVAsset(url: URL(fileURLWithPath: segmentPaths[0])) as? AVAsset else {
      completion(nil)
      return
    }
    guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
          let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
      completion(nil)
      return
    }
    var currentTime = CMTime.zero
    for path in segmentPaths {
      let asset = AVAsset(url: URL(fileURLWithPath: path))
      if let assetVideoTrack = asset.tracks(withMediaType: .video).first {
        try? videoTrack.insertTimeRange(CMTimeRangeMake(start: .zero, duration: asset.duration), of: assetVideoTrack, at: currentTime)
      }
      if let assetAudioTrack = asset.tracks(withMediaType: .audio).first {
        try? audioTrack.insertTimeRange(CMTimeRangeMake(start: .zero, duration: asset.duration), of: assetAudioTrack, at: currentTime)
      }
      currentTime = CMTimeAdd(currentTime, asset.duration)
    }
    // Export merged file
    let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("merged_\(Int(Date().timeIntervalSince1970)).mov")
    if FileManager.default.fileExists(atPath: outputURL.path) {
      try? FileManager.default.removeItem(at: outputURL)
    }
    guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
      completion(nil)
      return
    }
    exportSession.outputURL = outputURL
    exportSession.outputFileType = .mov
    exportSession.shouldOptimizeForNetworkUse = true
    exportSession.exportAsynchronously {
      if exportSession.status == .completed {
        completion(outputURL.path)
      } else {
        completion(nil)
      }
      // Clean up segments
      for path in self.segmentPaths {
        try? FileManager.default.removeItem(atPath: path)
      }
      self.segmentPaths.removeAll()
    }
  }

  // MARK: - Capture Photo With Watermark
  private func capturePhotoWithWatermark(completion: @escaping (String?) -> Void) {
    // Use the latest cached video frame
    guard let sampleBuffer = latestVideoSampleBuffer else {
      print("No video frame available for snapshot")
      completion(nil)
      return
    }
    let imagePath = saveSampleBufferAsImageWithWatermark(sampleBuffer)
    completion(imagePath)
  }

  // Helper to save a sample buffer as an image with watermark
  private func saveSampleBufferAsImageWithWatermark(_ sampleBuffer: CMSampleBuffer) -> String? {
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    let videoSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
    // Apply watermark if available
    let finalImage: CIImage
    if let watermarkImage = watermarkImage, let ciContext = ciContext {
      let watermarkSize = calculateWatermarkSize(for: videoSize)
      let watermarkPos = calculateWatermarkPosition(for: videoSize, watermarkSize: watermarkSize)
      let originalWatermarkSize = watermarkImage.extent.size
      let scaleX = watermarkSize.width / originalWatermarkSize.width
      let scaleY = watermarkSize.height / originalWatermarkSize.height
      let scaledWatermark = watermarkImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
      let positionedWatermark = scaledWatermark.transformed(by: CGAffineTransform(translationX: watermarkPos.x, y: watermarkPos.y))
      let compositeFilter = CIFilter(name: "CISourceOverCompositing")
      compositeFilter?.setValue(ciImage, forKey: kCIInputBackgroundImageKey)
      compositeFilter?.setValue(positionedWatermark, forKey: kCIInputImageKey)
      if let outputImage = compositeFilter?.outputImage {
        finalImage = outputImage
      } else {
        finalImage = ciImage
      }
    } else {
      finalImage = ciImage
    }
    // Render to UIImage
    let context = ciContext ?? CIContext()
    guard let cgImage = context.createCGImage(finalImage, from: finalImage.extent) else { return nil }
    let uiImage = UIImage(cgImage: cgImage)
    // Save to temporary file
    let tempDir = NSTemporaryDirectory()
    let fileName = "snapshot_\(Int(Date().timeIntervalSince1970)).jpg"
    let filePath = (tempDir as NSString).appendingPathComponent(fileName)
    guard let jpegData = uiImage.jpegData(compressionQuality: 1.0) else { return nil } // Use max quality
    do {
      try jpegData.write(to: URL(fileURLWithPath: filePath))
    } catch {
      print("Failed to write snapshot image: \(error)")
      return nil
    }
    // Save to camera roll
    PHPhotoLibrary.requestAuthorization { status in
      if status == .authorized {
        PHPhotoLibrary.shared().performChanges({
          PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: URL(fileURLWithPath: filePath))
        }) { success, error in
          if success {
            print("Snapshot image saved to gallery")
          } else {
            print("Failed to save snapshot to gallery: \(error?.localizedDescription ?? "Unknown error")")
          }
        }
      } else {
        print("Photo library access denied for snapshot")
      }
    }
    return filePath
  }
  
  // MARK: - Simple Video Recording (No Watermarks, No Complex Audio Session Management)
  
  private func startSimpleVideoRecording(direction: String) -> Bool {
    print("🎬 Starting SIMPLE video recording with direction: \(direction)")
    
    // Don't touch existing sessions if they're running
    if simpleRecordingSession?.isRunning == true {
      print("❌ Simple recording session already running")
      return false
    }
    
    // Configure audio session BEFORE creating capture session (StackOverflow approach)
    do {
      let audioSession = AVAudioSession.sharedInstance()
      print("🎵 Other audio playing before StackOverflow config: \(audioSession.isOtherAudioPlaying)")
      
      // First deactivate current session
      try audioSession.setActive(false)
      
      // Set category with options that allow background music mixing
      try audioSession.setCategory(.playAndRecord, options: [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP, .allowAirPlay])
      try audioSession.setMode(.videoRecording)
      try audioSession.setActive(true)
      
      print("🎵 ✅ StackOverflow-style audio session configured")
      print("🎵 Other audio still playing: \(audioSession.isOtherAudioPlaying)")
    } catch {
      print("❌ Failed StackOverflow audio session config: \(error)")
      return false
    }
    
    do {
      // Create a completely separate, clean capture session
      let session = AVCaptureSession()
      
      // CRITICAL: Tell the session NOT to automatically manage audio session
      // This prevents it from overriding our audio session configuration
      session.automaticallyConfiguresApplicationAudioSession = false
      session.usesApplicationAudioSession = true
      
      session.sessionPreset = .high
      
      // Determine camera position
      let position: AVCaptureDevice.Position = direction == "front" ? .front : .back
      
      // Add video input
      guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
        print("❌ Camera not found for direction: \(direction)")
        return false
      }
      
      let videoInput = try AVCaptureDeviceInput(device: camera)
      if session.canAddInput(videoInput) {
        session.addInput(videoInput)
        self.simpleVideoInput = videoInput
        print("✅ Added video input")
      } else {
        print("❌ Cannot add video input")
        return false
      }
      
      // DON'T add audio input yet - we'll add it dynamically when starting recording
      // This is the StackOverflow approach
      if let audioDevice = AVCaptureDevice.default(for: .audio) {
        self.simpleAudioInput = try AVCaptureDeviceInput(device: audioDevice)
        print("✅ Created audio input (will add it when starting recording)")
      } else {
        print("❌ No audio device found")
        return false
      }
      
      // Add movie file output
      let movieOutput = AVCaptureMovieFileOutput()
      if session.canAddOutput(movieOutput) {
        session.addOutput(movieOutput)
        self.simpleMovieOutput = movieOutput
        print("✅ Added movie output")
      } else {
        print("❌ Cannot add movie output")
        return false
      }
      
      // Create output file
      let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      let timestamp = Int(Date().timeIntervalSince1970)
      let fileName = "simple_video_\(timestamp).mov"
      let videoURL = documentsPath.appendingPathComponent(fileName)
      
      self.simpleVideoPath = videoURL.path
      self.simpleRecordingSession = session
      
      // Start session first
      session.startRunning()
      
      // Add audio input dynamically RIGHT before recording (StackOverflow approach)
      session.beginConfiguration()
      if let audioInput = self.simpleAudioInput, session.canAddInput(audioInput) {
        session.addInput(audioInput)
        print("✅ Added audio input dynamically for recording")
      } else {
        print("❌ Cannot add audio input dynamically")
        return false
      }
      session.commitConfiguration()
      
      // Now start recording
      movieOutput.startRecording(to: videoURL, recordingDelegate: self)
      
      print("🎬 Simple recording started to: \(videoURL.path)")
      return true
      
    } catch {
      print("❌ Simple recording setup failed: \(error)")
      return false
    }
  }
  
  private func stopSimpleVideoRecording(completion: @escaping (String?) -> Void) {
    print("🎬 Stopping simple video recording")
    
    guard let movieOutput = simpleMovieOutput else {
      print("❌ No movie output to stop")
      completion(nil)
      return
    }
    
    // Stop recording
    movieOutput.stopRecording()
    
    // Remove audio input from simple recording session if attached
    if let session = simpleRecordingSession, let audioInput = simpleAudioInput {
      session.beginConfiguration()
      if session.inputs.contains(audioInput) {
        session.removeInput(audioInput)
        print("✅ Removed audio input from simple recording session")
      }
      session.commitConfiguration()
    }
    
    // Reset audio session category and deactivate
    do {
      let audioSession = AVAudioSession.sharedInstance()
      
      print("🎵 Resetting audio session after simple recording...")
      
      // Reset to .ambient category to clear .playAndRecord audio processing
      try audioSession.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
      print("🎵 ✅ Category reset to .ambient")
      
      // Deactivate and notify other apps
      try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
      print("🎵 ✅ Audio session deactivated, other apps notified")
    } catch {
      print("❌ Failed to reset audio session after simple recording: \(error)")
    }
    
    // Clean up session
    simpleRecordingSession?.stopRunning()
    simpleRecordingSession = nil
    simpleVideoInput = nil
    simpleAudioInput = nil
    simpleMovieOutput = nil
    
    // Return the video path
    completion(simpleVideoPath)
  }
}

// MARK: - AVCaptureFileOutputRecordingDelegate for Simple Recording

extension WatermarkedVideoRecorderPlugin: AVCaptureFileOutputRecordingDelegate {
  public func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
    if let error = error {
      print("❌ Simple recording finished with error: \(error)")
    } else {
      print("✅ Simple recording finished successfully: \(outputFileURL.path)")
      
      // Auto-save to gallery for verification
      DispatchQueue.main.async {
        self.saveVideoToGallery(outputFileURL.path)
      }
    }
  }
}
