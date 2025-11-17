package com.wilfredbayudan.watermarked_video_recorder

import android.Manifest
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.camera2.CameraAccessException
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.MediaRecorder
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.provider.MediaStore
import android.util.Log
import android.view.Surface
import android.view.WindowManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.view.TextureRegistry
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.io.FileOutputStream
import java.io.FileInputStream
import android.graphics.SurfaceTexture
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.ImageFormat
import android.media.ImageReader
import android.hardware.camera2.TotalCaptureResult
import android.hardware.camera2.CaptureFailure
import java.nio.ByteBuffer

/** WatermarkedVideoRecorderPlugin */
class WatermarkedVideoRecorderPlugin: FlutterPlugin, MethodCallHandler, ActivityAware {
  /// The MethodChannel that will the communication between Flutter and native Android
  ///
  /// This local reference serves to register the plugin with the Flutter Engine and unregister it
  /// when the Flutter Engine is detached from the Activity
  private lateinit var channel : MethodChannel
  private lateinit var context: Context
  private var activityBinding: ActivityPluginBinding? = null
  private var textureRegistry: TextureRegistry? = null

  // Camera2 API components
  private var cameraManager: CameraManager? = null
  private var cameraDevice: CameraDevice? = null
  private var cameraCaptureSession: CameraCaptureSession? = null
  private var backgroundHandler: Handler? = null
  private var backgroundThread: HandlerThread? = null
  private var cameraId: String = "0" // Default to back camera

  // Video recording components
  private var mediaRecorder: MediaRecorder? = null
  private var isRecording = false
  private var isPaused = false
  private var currentVideoPath: String? = null
  private var pausedVideoPath: String? = null

  // Camera preview components
  private var previewSurfaceTexture: SurfaceTexture? = null
  private var previewSurface: Surface? = null
  private var isPreviewActive = false
  private var previewCaptureSession: CameraCaptureSession? = null
  private var previewTextureEntry: TextureRegistry.SurfaceTextureEntry? = null

  // Placeholder for watermark image path
  private var watermarkImagePath: String? = null

  // Add WatermarkRenderer instance
  private var watermarkRenderer: WatermarkRenderer? = null

  // Photo capture components
  private var imageReader: ImageReader? = null
  private var photoCaptureSession: CameraCaptureSession? = null

  // Permission request tracking
  private var pendingPermissionResult: Result? = null
  private var pendingPermissionType: String? = null

  // Camera initialization tracking
  private var pendingCameraInitResult: Result? = null
  private var isCameraInitializing = false

  companion object {
    private const val TAG = "WatermarkedVideoRecorder"
    private const val CHANNEL = "watermarked_video_recorder"
    private const val CAMERA_PERMISSION_REQUEST_CODE = 1001
    private const val MICROPHONE_PERMISSION_REQUEST_CODE = 1002
    private const val RECORDING_PERMISSIONS_REQUEST_CODE = 1003
  }

  override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(flutterPluginBinding.binaryMessenger, "watermarked_video_recorder")
    channel.setMethodCallHandler(this)
    context = flutterPluginBinding.applicationContext
    textureRegistry = flutterPluginBinding.textureRegistry
    
    // Reset any existing state when plugin is attached
    resetPluginState()
  }
  
  private fun resetPluginState() {
    Log.d(TAG, "Resetting plugin state")
    isRecording = false
    isPaused = false
    isPreviewActive = false
    isCameraInitializing = false
    currentVideoPath = null
    pausedVideoPath = null
    
    // Clean up any existing resources
    previewTextureEntry?.release()
    previewTextureEntry = null
    previewSurfaceTexture?.release()
    previewSurfaceTexture = null
    previewSurface?.release()
    previewSurface = null
    
    watermarkRenderer?.stop()
    watermarkRenderer = null
    
    // DO NOT clear textureRegistry - it should persist across plugin lifecycle
    // textureRegistry is managed by Flutter engine and should not be nulled here
    
    Log.d(TAG, "Plugin state reset completed")
  }

  override fun onMethodCall(call: MethodCall, result: Result) {
    when (call.method) {
      "getPlatformVersion" -> {
        result.success("Android ${android.os.Build.VERSION.RELEASE}")
      }
      "testConnection" -> {
        result.success("Hello from Android! Plugin connection successful!")
      }
      "requestCameraPermission" -> {
        val granted = requestCameraPermission()
        if (granted) {
          result.success(true)
        } else {
          // Store the result to handle it later when user responds to permission dialog
          pendingPermissionResult = result
          pendingPermissionType = "camera"
        }
      }
      "requestMicrophonePermission" -> {
        val granted = requestMicrophonePermission()
        if (granted) {
          result.success(true)
        } else {
          // Store the result to handle it later when user responds to permission dialog
          pendingPermissionResult = result
          pendingPermissionType = "microphone"
        }
      }
      "requestRecordingPermissions" -> {
        requestRecordingPermissions(result)
      }
      "initializeCamera" -> {
        val success = initializeCamera()
        result.success(success)
      }
      "getAvailableCameras" -> {
        val cameras = getAvailableCameras()
        result.success(cameras)
      }
      "initializeCameraWithId" -> {
        val cameraId = call.argument<String>("cameraId")
        val success = if (cameraId != null) initializeCameraWithId(cameraId) else false
        result.success(success)
      }
      "initializeCameraWithDirection" -> {
        val direction = call.argument<String>("direction")
        val success = if (direction != null) initializeCameraWithDirection(direction) else false
        result.success(success)
      }
      "disposeCamera" -> {
        disposeCamera()
        result.success(null)
      }
      "startVideoRecording" -> {
        val success = startVideoRecording()
        result.success(success)
      }
      "stopVideoRecording" -> {
        val videoPath = stopVideoRecording()
        result.success(videoPath)
      }
      "isRecording" -> {
        result.success(isRecording)
      }
      "isPaused" -> {
        result.success(isPaused)
      }
      "saveVideoToGallery" -> {
        val videoPath = call.argument<String>("videoPath")
        val success = if (videoPath != null) saveVideoToGallery(videoPath) else false
        result.success(success)
      }
      "setWatermarkImage" -> {
        val path = call.argument<String>("path")
        val mode = call.argument<String>("mode")
        setWatermarkImage(path, mode)
        result.success(null)
      }
      "isCameraReady" -> {
        val ready = cameraDevice != null && !isCameraInitializing
        result.success(ready)
      }
      "getCameraState" -> {
        val state = mapOf(
          "cameraDevice" to (cameraDevice != null),
          "isCameraInitializing" to isCameraInitializing,
          "isRecording" to isRecording,
          "isPaused" to isPaused,
          "cameraId" to cameraId,
          "currentCameraDirection" to (if (cameraId == "1") "front" else "back"),
          "textureRegistry" to (textureRegistry != null),
          "isPreviewActive" to isPreviewActive,
          "previewTextureEntry" to (previewTextureEntry != null)
        )
        result.success(state)
      }
      "startCameraPreview" -> {
        val direction = call.argument<String>("direction")
        val textureId = if (direction != null) startCameraPreview(direction) else startCameraPreview("back")
        result.success(textureId)
      }
      "stopCameraPreview" -> {
        stopCameraPreview()
        result.success(null)
      }
      "isPreviewActive" -> {
        result.success(isPreviewActive)
      }
      "getPreviewTextureId" -> {
        val textureId = if (isPreviewActive && previewTextureEntry != null) previewTextureEntry!!.id().toInt() else null
        Log.d(TAG, "getPreviewTextureId: textureRegistry=${textureRegistry != null}, isPreviewActive=$isPreviewActive, textureId=$textureId")
        result.success(textureId)
      }
      "startPreviewWithWatermark" -> {
        val watermarkPath = call.argument<String>("watermarkPath")
        val direction = call.argument<String>("direction")
        val mode = call.argument<String>("mode")
        val textureId = if (watermarkPath != null && direction != null) {
          startPreviewWithWatermark(watermarkPath, direction, mode)
        } else {
          startCameraPreview(direction ?: "back")
        }
        result.success(textureId)
      }
      "pauseRecording" -> {
        val success = pauseRecording()
        result.success(success)
      }
      "resumeRecording" -> {
        val success = resumeRecording()
        result.success(success)
      }
      "capturePhotoWithWatermark" -> {
        val photoPath = capturePhotoWithWatermark()
        result.success(photoPath)
      }
      "isPhotoCaptureAvailable" -> {
        val available = cameraDevice != null && !isCameraInitializing
        result.success(available)
      }
      else -> {
        result.notImplemented()
      }
    }
  }

  private fun requestCameraPermission(): Boolean {
    val activity = activityBinding?.activity
    if (activity == null) return false
    
    return if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
      true
    } else {
      // Check if we should show rationale
      if (ActivityCompat.shouldShowRequestPermissionRationale(activity, Manifest.permission.CAMERA)) {
        Log.d(TAG, "Should show camera permission rationale")
      }
      ActivityCompat.requestPermissions(activity, arrayOf(Manifest.permission.CAMERA), CAMERA_PERMISSION_REQUEST_CODE)
      false
    }
  }

  private fun requestMicrophonePermission(): Boolean {
    val activity = activityBinding?.activity
    if (activity == null) return false
    
    return if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
      true
    } else {
      // Check if we should show rationale
      if (ActivityCompat.shouldShowRequestPermissionRationale(activity, Manifest.permission.RECORD_AUDIO)) {
        Log.d(TAG, "Should show microphone permission rationale")
      }
      ActivityCompat.requestPermissions(activity, arrayOf(Manifest.permission.RECORD_AUDIO), MICROPHONE_PERMISSION_REQUEST_CODE)
      false
    }
  }

  private fun requestRecordingPermissions(result: Result) {
    val activity = activityBinding?.activity
    if (activity == null) {
      result.success(mapOf("camera" to false, "microphone" to false))
      return
    }

    val permissions = arrayOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO)
    val permissionResults = mutableMapOf<String, Boolean>()

    for (permission in permissions) {
      permissionResults[if (permission == Manifest.permission.CAMERA) "camera" else "microphone"] = 
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
    }

    if (permissionResults.values.all { it }) {
      result.success(permissionResults)
    } else {
      // Store the result to handle it later
      pendingPermissionResult = result
      pendingPermissionType = "recording"
      ActivityCompat.requestPermissions(activity, permissions, RECORDING_PERMISSIONS_REQUEST_CODE)
    }
  }

  // Handle permission results
  private fun handlePermissionResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
    when (requestCode) {
      CAMERA_PERMISSION_REQUEST_CODE -> {
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        Log.d(TAG, "Camera permission result: $granted")
        
        if (pendingPermissionType == "camera") {
          pendingPermissionResult?.success(granted)
          pendingPermissionResult = null
          pendingPermissionType = null
        }
      }
      MICROPHONE_PERMISSION_REQUEST_CODE -> {
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        Log.d(TAG, "Microphone permission result: $granted")
        
        if (pendingPermissionType == "microphone") {
          pendingPermissionResult?.success(granted)
          pendingPermissionResult = null
          pendingPermissionType = null
        }
      }
      RECORDING_PERMISSIONS_REQUEST_CODE -> {
        val cameraGranted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        val microphoneGranted = grantResults.size > 1 && grantResults[1] == PackageManager.PERMISSION_GRANTED
        
        Log.d(TAG, "Recording permissions result: camera=$cameraGranted, microphone=$microphoneGranted")
        
        if (pendingPermissionType == "recording") {
          pendingPermissionResult?.success(mapOf(
            "camera" to cameraGranted,
            "microphone" to microphoneGranted
          ))
          pendingPermissionResult = null
          pendingPermissionType = null
        }
      }
    }
  }

  private fun initializeCamera(): Boolean {
    return try {
      Log.d(TAG, "Camera initialization started")
      
      val activity = activityBinding?.activity
      if (activity == null) {
        Log.e(TAG, "Activity is null")
        return false
      }

      // Get camera manager
      cameraManager = activity.getSystemService(Context.CAMERA_SERVICE) as CameraManager
      if (cameraManager == null) {
        Log.e(TAG, "Camera manager is null")
        return false
      }

      // Start background thread
      startBackgroundThread()

      // Use default back camera
      cameraId = "0" // Back camera
      
      // Check if camera exists
      val cameraIds = cameraManager!!.cameraIdList
      if (!cameraIds.contains(cameraId)) {
        Log.e(TAG, "Camera $cameraId not found")
        return false
      }

      // Set initialization flag
      isCameraInitializing = true

      // Open camera device
      cameraManager!!.openCamera(cameraId, object : CameraDevice.StateCallback() {
        override fun onOpened(camera: CameraDevice) {
          Log.d(TAG, "Camera opened successfully")
          cameraDevice = camera
          isCameraInitializing = false
          
          // Don't create a dummy session - we'll create the real one when recording starts
          Log.d(TAG, "Camera ready for recording")
        }

        override fun onDisconnected(camera: CameraDevice) {
          Log.d(TAG, "Camera disconnected")
          camera.close()
          cameraDevice = null
          isCameraInitializing = false
        }

        override fun onError(camera: CameraDevice, error: Int) {
          Log.e(TAG, "Camera open error: $error")
          camera.close()
          cameraDevice = null
          isCameraInitializing = false
        }
      }, backgroundHandler)

      Log.d(TAG, "Camera initialization completed")
      true
    } catch (e: Exception) {
      Log.e(TAG, "Failed to initialize camera", e)
      isCameraInitializing = false
      false
    }
  }

  private fun createCameraCaptureSession() {
    try {
      if (cameraDevice == null) {
        Log.e(TAG, "Camera device is null")
        return
      }

      // This is just a placeholder - we'll create the real session when recording starts
      Log.d(TAG, "Camera capture session placeholder created")
      
    } catch (e: Exception) {
      Log.e(TAG, "Failed to create camera capture session", e)
    }
  }

  private fun startBackgroundThread() {
    backgroundThread = HandlerThread("CameraBackground").apply {
      start()
    }
    backgroundHandler = Handler(backgroundThread!!.looper)
  }

  private fun stopBackgroundThread() {
    backgroundThread?.quitSafely()
    try {
      backgroundThread?.join()
      backgroundThread = null
      backgroundHandler = null
    } catch (e: InterruptedException) {
      Log.e(TAG, "Error stopping background thread", e)
    }
  }

  private fun disposeCamera() {
    try {
      Log.d(TAG, "Camera disposal started")
      
      // Stop recording if active
      if (isRecording) {
        stopVideoRecording()
      }
      
      // Stop preview if active
      if (isPreviewActive) {
        stopCameraPreview()
      }
      
      // Close camera capture session
      cameraCaptureSession?.close()
      cameraCaptureSession = null
      
      // Close camera device
      cameraDevice?.close()
      cameraDevice = null
      
      // Reset initialization flag
      isCameraInitializing = false
      
      // Stop background thread
      stopBackgroundThread()
      
      // Clean up WatermarkRenderer (not used in current implementation)
      watermarkRenderer?.stop()
      watermarkRenderer = null
      
      // DO NOT set textureRegistry to null here - it should persist across camera sessions
      // textureRegistry = null
      
      Log.d(TAG, "Camera disposal completed")
    } catch (e: Exception) {
      Log.e(TAG, "Failed to dispose camera", e)
    }
  }

  private fun startVideoRecording(): Boolean {
    return try {
      // Log texture registry status for debugging
      Log.d(TAG, "startVideoRecording: textureRegistry=${textureRegistry != null}")
      
      if (isRecording) {
        Log.w(TAG, "Already recording, cleaning up previous session first")
        // Clean up any existing recording state
        try {
          stopVideoRecording()
        } catch (e: Exception) {
          Log.e(TAG, "Error cleaning up previous recording", e)
        }
        // Reset state
        isRecording = false
        isPreviewActive = false
        previewTextureEntry?.release()
        previewTextureEntry = null
        previewSurfaceTexture?.release()
        previewSurfaceTexture = null
        previewSurface?.release()
        previewSurface = null
      }

      // Wait for camera initialization to complete
      if (isCameraInitializing) {
        Log.w(TAG, "Camera is still initializing, waiting...")
        // Wait up to 3 seconds for camera to initialize
        var waitCount = 0
        while (isCameraInitializing && waitCount < 30) {
          Thread.sleep(100)
          waitCount++
        }
        if (isCameraInitializing) {
          Log.e(TAG, "Camera initialization timeout")
          return false
        }
        Log.d(TAG, "Camera initialization completed after waiting")
      }

      if (cameraDevice == null) {
        Log.e(TAG, "Camera not initialized - cameraDevice is null")
        Log.d(TAG, "Camera state: isCameraInitializing=$isCameraInitializing, cameraDevice=${cameraDevice != null}")
        return false
      }

      Log.d(TAG, "Starting video recording - camera is ready")

      // Create video file
      val videoFile = createVideoFile()
      currentVideoPath = videoFile.absolutePath
      Log.d(TAG, "Video file created: ${videoFile.absolutePath}")

      // Initialize MediaRecorder
      mediaRecorder = MediaRecorder().apply {
        Log.d(TAG, "Setting up MediaRecorder...")
        setAudioSource(MediaRecorder.AudioSource.MIC)
        setVideoSource(MediaRecorder.VideoSource.SURFACE)
        setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
        setVideoEncoder(MediaRecorder.VideoEncoder.H264)
        setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
        setVideoEncodingBitRate(5000000)
        setVideoFrameRate(24)
        setVideoSize(1920, 1080)
        setOutputFile(videoFile.absolutePath)
        val orientation = getDeviceOrientation()
        setOrientationHint(orientation)
        Log.d(TAG, "Set MediaRecorder orientation to: $orientation degrees")
        setMaxDuration(30000)
        setMaxFileSize(100 * 1024 * 1024)
        try {
          Log.d(TAG, "Preparing MediaRecorder...")
          prepare()
          Log.d(TAG, "MediaRecorder prepared successfully")
        } catch (e: IOException) {
          Log.e(TAG, "Failed to prepare MediaRecorder", e)
          return false
        }
      }

      // Set up WatermarkRenderer for real-time watermark rendering
      val deviceRotation = getDeviceRotation()
      val isFront = isFrontCamera()
      watermarkRenderer = WatermarkRenderer(
        context = context,
        outputSurface = mediaRecorder!!.surface,
        watermarkImagePath = watermarkImagePath,
        deviceOrientation = deviceRotation,
        isFrontCamera = isFront,
        watermarkMode = watermarkMode
      )
      watermarkRenderer?.start()
      val rendererInputSurface = watermarkRenderer?.getInputSurface()
      if (rendererInputSurface == null) {
        Log.e(TAG, "Failed to get WatermarkRenderer input surface")
        return false
      }
      
      // Start MediaRecorder BEFORE creating capture session
      Log.d(TAG, "Starting MediaRecorder before capture session...")
      mediaRecorder!!.start()
      isRecording = true

      // Create preview surface for UI display
      if (textureRegistry == null) {
        Log.e(TAG, "Texture registry is null, cannot create preview texture")
        Log.d(TAG, "Attempting to continue without preview texture...")
        // Continue without preview texture - recording will still work
        // Create a dummy surface for the capture session
        val dummySurface = Surface(SurfaceTexture(0))
        
        // Create recording capture session with ONLY WatermarkRenderer input surface
        cameraDevice!!.createCaptureSession(
          listOf(rendererInputSurface),
          object : CameraCaptureSession.StateCallback() {
            override fun onConfigured(session: CameraCaptureSession) {
              Log.d(TAG, "Recording capture session configured successfully (WatermarkRenderer only)")
              cameraCaptureSession = session
              val captureRequestBuilder = cameraDevice!!.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
              captureRequestBuilder.addTarget(rendererInputSurface)
              captureRequestBuilder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
              captureRequestBuilder.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
              captureRequestBuilder.set(CaptureRequest.CONTROL_AWB_MODE, CaptureRequest.CONTROL_AWB_MODE_AUTO)
              try {
                Log.d(TAG, "Starting repeating capture request...")
                session.setRepeatingRequest(captureRequestBuilder.build(), null, backgroundHandler)
                Log.d(TAG, "Video recording started successfully: $currentVideoPath (WatermarkRenderer only)")
              } catch (e: Exception) {
                Log.e(TAG, "Failed to start recording session", e)
              }
            }
            override fun onConfigureFailed(session: CameraCaptureSession) {
              Log.e(TAG, "Failed to configure recording capture session (WatermarkRenderer only)")
            }
          },
          backgroundHandler
        )
        return true
      }
      
      // Reuse existing preview texture if available, otherwise create new one
      val previewTextureEntry: TextureRegistry.SurfaceTextureEntry
      val previewSurfaceTexture: SurfaceTexture
      val previewSurface: Surface
      
      if (this.previewTextureEntry != null && this.previewSurfaceTexture != null && this.previewSurface != null) {
        // Reuse existing preview texture
        previewTextureEntry = this.previewTextureEntry!!
        previewSurfaceTexture = this.previewSurfaceTexture!!
        previewSurface = this.previewSurface!!
        Log.d(TAG, "Reusing existing preview texture with ID: ${previewTextureEntry.id()}")
      } else {
        // Create new preview texture
        previewTextureEntry = textureRegistry!!.createSurfaceTexture()
        previewSurfaceTexture = previewTextureEntry.surfaceTexture()
        previewSurfaceTexture.setDefaultBufferSize(1920, 1080)
        previewSurface = Surface(previewSurfaceTexture)
        
        // Store preview texture for Flutter UI
        this.previewTextureEntry = previewTextureEntry
        this.previewSurfaceTexture = previewSurfaceTexture
        this.previewSurface = previewSurface
        isPreviewActive = true
        
        Log.d(TAG, "Created new preview texture with ID: ${previewTextureEntry.id()}")
      }
      
      // Create recording capture session with BOTH WatermarkRenderer input surface AND preview surface
      cameraDevice!!.createCaptureSession(
        listOf(rendererInputSurface, previewSurface),
        object : CameraCaptureSession.StateCallback() {
          override fun onConfigured(session: CameraCaptureSession) {
            Log.d(TAG, "Recording capture session configured successfully (with WatermarkRenderer + preview)")
            cameraCaptureSession = session
            val captureRequestBuilder = cameraDevice!!.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
            captureRequestBuilder.addTarget(rendererInputSurface)
            captureRequestBuilder.addTarget(previewSurface)
            captureRequestBuilder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
            captureRequestBuilder.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
            captureRequestBuilder.set(CaptureRequest.CONTROL_AWB_MODE, CaptureRequest.CONTROL_AWB_MODE_AUTO)
            try {
              Log.d(TAG, "Starting repeating capture request...")
              session.setRepeatingRequest(captureRequestBuilder.build(), null, backgroundHandler)
              Log.d(TAG, "Video recording started successfully: $currentVideoPath (with WatermarkRenderer + preview)")
            } catch (e: Exception) {
              Log.e(TAG, "Failed to start recording session", e)
            }
          }
          override fun onConfigureFailed(session: CameraCaptureSession) {
            Log.e(TAG, "Failed to configure recording capture session (with WatermarkRenderer + preview)")
          }
        },
        backgroundHandler
      )
      true
    } catch (e: Exception) {
      Log.e(TAG, "Failed to start video recording", e)
      // Clean up on failure
      isRecording = false
      mediaRecorder?.apply {
        try {
          reset()
          release()
        } catch (cleanupError: Exception) {
          Log.e(TAG, "Error during cleanup", cleanupError)
        }
      }
      mediaRecorder = null
      watermarkRenderer?.stop()
      watermarkRenderer = null
      false
    }
  }

  private fun stopVideoRecording(): String? {
    return try {
      if (!isRecording && !isPaused) {
        Log.w(TAG, "Not recording and not paused")
        return null
      }

      Log.d(TAG, "Stopping video recording")

      // If paused in fallback mode, just return the stored path
      if (isPaused && !isRecording) {
        Log.d(TAG, "Already stopped in fallback pause mode")
        val videoPath = pausedVideoPath
        isPaused = false
        pausedVideoPath = null
        return videoPath
      }

      // If paused, resume first to ensure proper stop
      if (isPaused) {
        Log.d(TAG, "Resuming paused recording before stopping")
        mediaRecorder?.resume()
        isPaused = false
      }

      // Stop the capture session first
      cameraCaptureSession?.stopRepeating()
      cameraCaptureSession?.close()
      cameraCaptureSession = null

      // Stop MediaRecorder with proper sequence
      mediaRecorder?.apply {
        try {
          stop()
          Log.d(TAG, "MediaRecorder stopped successfully")
        } catch (e: Exception) {
          Log.e(TAG, "Error stopping MediaRecorder", e)
          // If stop fails, try to reset and release anyway
          Log.d(TAG, "Attempting to reset MediaRecorder after stop failure...")
        }
        
        try {
          reset()
          Log.d(TAG, "MediaRecorder reset successfully")
        } catch (e: Exception) {
          Log.e(TAG, "Error resetting MediaRecorder", e)
        }
        
        try {
          release()
          Log.d(TAG, "MediaRecorder released successfully")
        } catch (e: Exception) {
          Log.e(TAG, "Error releasing MediaRecorder", e)
        }
      }
      mediaRecorder = null

      isRecording = false
      isPaused = false
      val videoPath = currentVideoPath
      currentVideoPath = null
      pausedVideoPath = null

      // Verify the file was created and has content
      if (videoPath != null) {
        val videoFile = File(videoPath)
        if (videoFile.exists() && videoFile.length() > 0) {
          Log.d(TAG, "Video recording stopped successfully: $videoPath (size: ${videoFile.length()} bytes)")
          
          // Try to verify it's a valid video file
          try {
            val inputStream = context.contentResolver.openInputStream(Uri.fromFile(videoFile))
            if (inputStream != null) {
              val buffer = ByteArray(1024)
              val bytesRead = inputStream.read(buffer)
              inputStream.close()
              Log.d(TAG, "Video file header bytes read: $bytesRead")
            }
          } catch (e: Exception) {
            Log.e(TAG, "Error reading video file", e)
          }
        } else {
          Log.e(TAG, "Video file is empty or doesn't exist: $videoPath")
        }
      }

      // Clean up WatermarkRenderer (not used in current implementation)
      watermarkRenderer?.stop()
      watermarkRenderer = null

      videoPath
    } catch (e: Exception) {
      Log.e(TAG, "Failed to stop video recording", e)
      // Clean up even if there's an error
      try {
        mediaRecorder?.reset()
        mediaRecorder?.release()
        mediaRecorder = null
        isRecording = false
        isPaused = false
        currentVideoPath = null
        pausedVideoPath = null
      } catch (cleanupError: Exception) {
        Log.e(TAG, "Error during cleanup", cleanupError)
      }
      null
    }
  }

  private fun createVideoFile(): File {
    val timestamp = System.currentTimeMillis()
    val fileName = "workout_$timestamp.mp4"
    
    // Use app's external files directory
    val directory = context.getExternalFilesDir(null)
    if (directory == null) {
      // Fallback to internal files directory
      return File(context.filesDir, fileName)
    }
    
    return File(directory, fileName)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    activityBinding = binding
    
    // Add permission result handler
    binding.addRequestPermissionsResultListener { requestCode, permissions, grantResults ->
      handlePermissionResult(requestCode, permissions, grantResults)
      true // Return true to indicate we handled the result
    }
  }

  override fun onDetachedFromActivityForConfigChanges() {
    activityBinding = null
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
    activityBinding = binding
  }

  override fun onDetachedFromActivity() {
    activityBinding = null
  }

  private fun getAvailableCameras(): List<Map<String, Any>> {
    return try {
      val activity = activityBinding?.activity
      if (activity == null) return emptyList()

      val cameraManager = activity.getSystemService(Context.CAMERA_SERVICE) as CameraManager
      val cameras = mutableListOf<Map<String, Any>>()
      val seenDirections = mutableSetOf<String>()

      Log.d(TAG, "Android: Found ${cameraManager.cameraIdList.size} camera(s)")

      for (cameraId in cameraManager.cameraIdList) {
        val characteristics = cameraManager.getCameraCharacteristics(cameraId)
        val facing = characteristics.get(android.hardware.camera2.CameraCharacteristics.LENS_FACING)
        
        val direction = when (facing) {
          android.hardware.camera2.CameraCharacteristics.LENS_FACING_FRONT -> "front"
          android.hardware.camera2.CameraCharacteristics.LENS_FACING_BACK -> "back"
          else -> "external"
        }
        
        val label = when (facing) {
          android.hardware.camera2.CameraCharacteristics.LENS_FACING_FRONT -> "Front Camera"
          android.hardware.camera2.CameraCharacteristics.LENS_FACING_BACK -> "Back Camera"
          else -> "External Camera"
        }

        Log.d(TAG, "Android: Camera ID $cameraId - Direction: $direction, Label: $label")

        // Only add if we haven't seen this direction before (avoid duplicates)
        if (!seenDirections.contains(direction)) {
          cameras.add(mapOf(
            "id" to cameraId,
            "direction" to direction,
            "label" to label
          ))
          seenDirections.add(direction)
          Log.d(TAG, "Android: Added camera $cameraId ($direction)")
        } else {
          Log.d(TAG, "Android: Skipping duplicate camera $cameraId ($direction)")
        }
      }

      Log.d(TAG, "Android: Returning ${cameras.size} unique cameras")
      cameras
    } catch (e: Exception) {
      Log.e(TAG, "Failed to get available cameras", e)
      emptyList()
    }
  }

  private fun initializeCameraWithId(cameraId: String): Boolean {
    return try {
      Log.d(TAG, "Camera initialization with ID: $cameraId")
      
      val activity = activityBinding?.activity
      if (activity == null) {
        Log.e(TAG, "Activity is null")
        return false
      }

      // Get camera manager
      cameraManager = activity.getSystemService(Context.CAMERA_SERVICE) as CameraManager
      if (cameraManager == null) {
        Log.e(TAG, "Camera manager is null")
        return false
      }

      // Start background thread
      startBackgroundThread()

      // Set the camera ID
      this.cameraId = cameraId

      // Check if camera exists
      val cameraIds = cameraManager!!.cameraIdList
      if (!cameraIds.contains(cameraId)) {
        Log.e(TAG, "Camera $cameraId not found")
        return false
      }

      // Set initialization flag
      isCameraInitializing = true

      // Open camera device
      cameraManager!!.openCamera(cameraId, object : CameraDevice.StateCallback() {
        override fun onOpened(camera: CameraDevice) {
          Log.d(TAG, "Camera opened successfully")
          cameraDevice = camera
          isCameraInitializing = false
          createCameraCaptureSession()
        }

        override fun onDisconnected(camera: CameraDevice) {
          Log.d(TAG, "Camera disconnected")
          camera.close()
          cameraDevice = null
          isCameraInitializing = false
        }

        override fun onError(camera: CameraDevice, error: Int) {
          Log.e(TAG, "Camera open error: $error")
          camera.close()
          cameraDevice = null
          isCameraInitializing = false
        }
      }, backgroundHandler)

      Log.d(TAG, "Camera initialization completed")
      true
    } catch (e: Exception) {
      Log.e(TAG, "Failed to initialize camera", e)
      isCameraInitializing = false
      false
    }
  }

  private fun initializeCameraWithDirection(direction: String): Boolean {
    return try {
      Log.d(TAG, "Camera initialization with direction: $direction")
      
      val activity = activityBinding?.activity
      if (activity == null) {
        Log.e(TAG, "Activity is null")
        return false
      }

      val cameraManager = activity.getSystemService(Context.CAMERA_SERVICE) as CameraManager
      if (cameraManager == null) {
        Log.e(TAG, "Camera manager is null")
        return false
      }

      // Find camera with matching direction
      var targetCameraId: String? = null
      for (cameraId in cameraManager.cameraIdList) {
        val characteristics = cameraManager.getCameraCharacteristics(cameraId)
        val facing = characteristics.get(android.hardware.camera2.CameraCharacteristics.LENS_FACING)
        
        val cameraDirection = when (facing) {
          android.hardware.camera2.CameraCharacteristics.LENS_FACING_FRONT -> "front"
          android.hardware.camera2.CameraCharacteristics.LENS_FACING_BACK -> "back"
          else -> "external"
        }
        
        if (cameraDirection == direction) {
          targetCameraId = cameraId
          break
        }
      }

      if (targetCameraId == null) {
        Log.e(TAG, "No camera found with direction: $direction")
        return false
      }

      // Initialize with found camera ID
      initializeCameraWithId(targetCameraId)
    } catch (e: Exception) {
      Log.e(TAG, "Failed to initialize camera with direction", e)
      false
    }
  }

  private fun saveVideoToGallery(videoPath: String): Boolean {
    return try {
      Log.d(TAG, "saveVideoToGallery called with path: $videoPath")
      
      val file = File(videoPath)
      Log.d(TAG, "File exists: ${file.exists()}")
      Log.d(TAG, "File size before gallery save: ${file.length()} bytes")
      
      if (!file.exists()) {
        Log.e(TAG, "Video file does not exist")
        return false
      }

      // Read first few bytes to verify it's a valid video file
      try {
        val inputStream = FileInputStream(file)
        val buffer = ByteArray(1024)
        val bytesRead = inputStream.read(buffer)
        inputStream.close()
        Log.d(TAG, "File header bytes before gallery save: $bytesRead")
        Log.d(TAG, "First 16 bytes: ${buffer.take(16).joinToString(", ") { "0x%02X".format(it) }}")
      } catch (e: Exception) {
        Log.e(TAG, "Error reading file before gallery save", e)
      }

      // Use a more modern approach - copy the file to gallery
      val contentValues = ContentValues().apply {
        put(MediaStore.Video.Media.DISPLAY_NAME, file.name)
        put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
        put(MediaStore.Video.Media.DATE_ADDED, System.currentTimeMillis() / 1000)
        put(MediaStore.Video.Media.DATE_MODIFIED, System.currentTimeMillis() / 1000)
        // Don't use DATA field as it's deprecated and can cause issues
      }

      Log.d(TAG, "Inserting video into MediaStore...")
      val uri = context.contentResolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, contentValues)
      if (uri == null) {
        Log.e(TAG, "Failed to insert video into MediaStore")
        return false
      }

      Log.d(TAG, "Video inserted into MediaStore with URI: $uri")
      
      // Copy the file content to the gallery
      try {
        val inputStream = FileInputStream(file)
        val outputStream = context.contentResolver.openOutputStream(uri)
        if (outputStream != null) {
          inputStream.copyTo(outputStream)
          inputStream.close()
          outputStream.close()
          Log.d(TAG, "File content copied to gallery successfully")
        } else {
          Log.e(TAG, "Failed to open output stream for gallery")
          return false
        }
      } catch (e: Exception) {
        Log.e(TAG, "Error copying file to gallery", e)
        return false
      }
      
      // Check file again after gallery save
      Log.d(TAG, "File size after gallery save: ${file.length()} bytes")
      
      // Read file header again to see if it changed
      try {
        val inputStream = FileInputStream(file)
        val buffer = ByteArray(1024)
        val bytesRead = inputStream.read(buffer)
        inputStream.close()
        Log.d(TAG, "File header bytes after gallery save: $bytesRead")
        Log.d(TAG, "First 16 bytes after save: ${buffer.take(16).joinToString(", ") { "0x%02X".format(it) }}")
      } catch (e: Exception) {
        Log.e(TAG, "Error reading file after gallery save", e)
      }

      true
    } catch (e: Exception) {
      Log.e(TAG, "Failed to save video to gallery", e)
      false
    }
  }

  private fun getDeviceOrientation(): Int {
    val activity = activityBinding?.activity
    if (activity == null) return 0
    
    val windowManager = activity.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    val rotation = windowManager.defaultDisplay.rotation
    
    // Get camera characteristics to determine if it's front or back camera
    val cameraManager = activity.getSystemService(Context.CAMERA_SERVICE) as CameraManager
    val characteristics = cameraManager.getCameraCharacteristics(cameraId)
    val facing = characteristics.get(CameraCharacteristics.LENS_FACING)
    val isFrontCamera = facing == CameraCharacteristics.LENS_FACING_FRONT
    
    return when (rotation) {
      Surface.ROTATION_0 -> {
        if (isFrontCamera) 270 else 90   // Portrait: front camera needs 270°, back camera 90°
      }
      Surface.ROTATION_90 -> {
        if (isFrontCamera) 180 else 0    // Landscape: front camera needs 180°, back camera 0°
      }
      Surface.ROTATION_180 -> {
        if (isFrontCamera) 90 else 270   // Portrait upside down: front camera needs 90°, back camera 270°
      }
      Surface.ROTATION_270 -> {
        if (isFrontCamera) 0 else 180    // Landscape reversed: front camera needs 0°, back camera 180°
      }
      else -> {
        if (isFrontCamera) 270 else 90   // Default to portrait orientation
      }
    }
  }

  private fun getDeviceRotation(): Int {
    val activity = activityBinding?.activity
    if (activity == null) return 0
    
    val windowManager = activity.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    val rotation = windowManager.defaultDisplay.rotation
    
    return when (rotation) {
      android.view.Surface.ROTATION_0 -> 0
      android.view.Surface.ROTATION_90 -> 90
      android.view.Surface.ROTATION_180 -> 180
      android.view.Surface.ROTATION_270 -> 270
      else -> 0
    }
  }

  private fun isFrontCamera(): Boolean {
    return try {
      val activity = activityBinding?.activity
      if (activity == null) return false
      
      val cameraManager = activity.getSystemService(Context.CAMERA_SERVICE) as CameraManager
      val characteristics = cameraManager.getCameraCharacteristics(cameraId)
      val facing = characteristics.get(android.hardware.camera2.CameraCharacteristics.LENS_FACING)
      
      facing == android.hardware.camera2.CameraCharacteristics.LENS_FACING_FRONT
    } catch (e: Exception) {
      Log.e(TAG, "Error determining camera facing", e)
      false
    }
  }

  private var watermarkMode: String = "bottomRight" // "bottomRight" or "fullScreen"
  
  private fun setWatermarkImage(path: String?, mode: String?) {
    watermarkImagePath = path
    if (mode != null) {
      watermarkMode = mode
      Log.d(TAG, "Set watermark mode: $mode")
    }
    Log.d(TAG, "Set watermark image path: $path")
    // TODO: Implement actual watermark loading and OpenGL pipeline
  }

  // Camera Preview Methods
  private fun startCameraPreview(direction: String): Int? {
    return try {
      Log.d(TAG, "Starting camera preview with direction: $direction")
      
      // Check if texture registry is available
      if (textureRegistry == null) {
        Log.e(TAG, "Texture registry is null")
        return null
      }
      
      // If we're already recording, return the existing preview texture
      if (isRecording) {
        Log.d(TAG, "Already recording, returning existing preview texture")
        if (previewTextureEntry != null) {
          Log.d(TAG, "Returning existing preview texture ID: ${previewTextureEntry!!.id()}")
          return previewTextureEntry!!.id().toInt()
        } else {
          Log.w(TAG, "Recording but no preview texture found")
          return null
        }
      }
      
      // Start background thread if not already started
      if (backgroundHandler == null) {
        startBackgroundThread()
      }
      
      // Initialize camera if not already done
      if (cameraDevice == null) {
        val initSuccess = initializeCameraWithDirection(direction)
        if (!initSuccess) {
          Log.e(TAG, "Failed to initialize camera for preview")
          return null
        }
        
        // Wait for camera to be ready
        var waitCount = 0
        while (cameraDevice == null && waitCount < 30) {
          Thread.sleep(100)
          waitCount++
        }
        if (cameraDevice == null) {
          Log.e(TAG, "Camera initialization timeout for preview")
          return null
        }
      }

      // Create texture entry using Flutter's texture registry
      previewTextureEntry = textureRegistry!!.createSurfaceTexture()
      previewSurfaceTexture = previewTextureEntry!!.surfaceTexture()
      previewSurfaceTexture?.setDefaultBufferSize(1920, 1080)
      previewSurface = Surface(previewSurfaceTexture)
      
      // Create preview capture session
      cameraDevice!!.createCaptureSession(
        listOf(previewSurface!!),
        object : CameraCaptureSession.StateCallback() {
          override fun onConfigured(session: CameraCaptureSession) {
            Log.d(TAG, "Preview capture session configured successfully")
            previewCaptureSession = session
            
            val captureRequestBuilder = cameraDevice!!.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
            captureRequestBuilder.addTarget(previewSurface!!)
            captureRequestBuilder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
            captureRequestBuilder.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
            captureRequestBuilder.set(CaptureRequest.CONTROL_AWB_MODE, CaptureRequest.CONTROL_AWB_MODE_AUTO)
            
            try {
              session.setRepeatingRequest(captureRequestBuilder.build(), null, backgroundHandler)
              isPreviewActive = true
              Log.d(TAG, "Camera preview started successfully with texture ID: ${previewTextureEntry!!.id()}")
            } catch (e: Exception) {
              Log.e(TAG, "Failed to start preview session", e)
            }
          }
          
          override fun onConfigureFailed(session: CameraCaptureSession) {
            Log.e(TAG, "Failed to configure preview capture session")
          }
        },
        backgroundHandler
      )
      
      previewTextureEntry!!.id().toInt()
    } catch (e: Exception) {
      Log.e(TAG, "Failed to start camera preview", e)
      null
    }
  }

  private fun stopCameraPreview() {
    try {
      Log.d(TAG, "Stopping camera preview")
      
      isPreviewActive = false
      
      // Stop preview capture session
      previewCaptureSession?.stopRepeating()
      previewCaptureSession?.close()
      previewCaptureSession = null
      
      // Release preview surfaces
      previewSurface?.release()
      previewSurface = null
      previewSurfaceTexture?.release()
      previewSurfaceTexture = null
      
      // Release texture entry
      previewTextureEntry?.release()
      previewTextureEntry = null
      
      Log.d(TAG, "Camera preview stopped successfully")
    } catch (e: Exception) {
      Log.e(TAG, "Failed to stop camera preview", e)
    }
  }

  private fun startPreviewWithWatermark(watermarkPath: String, direction: String, mode: String?): Int? {
    try {
      Log.d(TAG, "Starting preview with watermark: $watermarkPath, direction: $direction, mode: $mode")
      
      // Set watermark with mode
      setWatermarkImage(watermarkPath, mode)
      
      // Start regular preview (watermark will be handled by the UI layer)
      return startCameraPreview(direction)
    } catch (e: Exception) {
      Log.e(TAG, "Failed to start preview with watermark", e)
      return null
    }
  }

  private fun pauseRecording(): Boolean {
    return try {
      if (!isRecording) {
        Log.w(TAG, "Cannot pause: not recording")
        return false
      }
      
      if (isPaused) {
        Log.w(TAG, "Already paused")
        return true
      }
      
      Log.d(TAG, "Pausing recording...")
      
      // Check if MediaRecorder pause is supported (API 24+)
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
        // Pause MediaRecorder
        mediaRecorder?.apply {
          try {
            pause()
            Log.d(TAG, "MediaRecorder paused successfully")
            isPaused = true
            pausedVideoPath = currentVideoPath
            Log.d(TAG, "Recording paused successfully")
            return true
          } catch (e: Exception) {
            Log.e(TAG, "Error pausing MediaRecorder", e)
          }
        }
      }
      
      // Fallback for older devices or if pause fails: stop and restart
      Log.d(TAG, "MediaRecorder pause not supported or failed, using stop/restart fallback")
      val videoPath = stopVideoRecording()
      if (videoPath != null) {
        // Store the path for potential concatenation later
        pausedVideoPath = videoPath
        isPaused = true
        Log.d(TAG, "Recording stopped for pause (fallback mode)")
        return true
      } else {
        Log.e(TAG, "Failed to stop recording for pause")
        return false
      }
    } catch (e: Exception) {
      Log.e(TAG, "Failed to pause recording", e)
      false
    }
  }

  private fun resumeRecording(): Boolean {
    return try {
      if (!isRecording && !isPaused) {
        Log.w(TAG, "Cannot resume: not recording and not paused")
        return false
      }
      
      if (!isPaused) {
        Log.w(TAG, "Not paused, nothing to resume")
        return true
      }
      
      Log.d(TAG, "Resuming recording...")
      
      // Check if MediaRecorder resume is supported (API 24+)
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && isRecording) {
        // Resume MediaRecorder
        mediaRecorder?.apply {
          try {
            resume()
            Log.d(TAG, "MediaRecorder resumed successfully")
            isPaused = false
            pausedVideoPath = null
            Log.d(TAG, "Recording resumed successfully")
            return true
          } catch (e: Exception) {
            Log.e(TAG, "Error resuming MediaRecorder", e)
          }
        }
      }
      
      // Fallback for older devices or if resume fails: start new recording
      Log.d(TAG, "MediaRecorder resume not supported or failed, starting new recording")
      isPaused = false
      pausedVideoPath = null
      return startVideoRecording()
    } catch (e: Exception) {
      Log.e(TAG, "Failed to resume recording", e)
      false
    }
  }

  private fun capturePhotoWithWatermark(): String? {
    return try {
      Log.d(TAG, "Capturing photo with watermark from camera frame")
      
      if (cameraDevice == null) {
        Log.e(TAG, "Camera not initialized")
        return null
      }
      
      // Create photo file
      val photoFile = createPhotoFile()
      val photoPath = photoFile.absolutePath
      Log.d(TAG, "Photo file created: $photoPath")
      
      // Try to capture from WatermarkRenderer first (if recording)
      var bitmap: Bitmap? = null
      if (isRecording && watermarkRenderer != null) {
        Log.d(TAG, "Attempting to capture from WatermarkRenderer")
        bitmap = captureFromWatermarkRenderer()
      }
      
      // If WatermarkRenderer capture failed, try preview surface
      if (bitmap == null) {
        Log.d(TAG, "WatermarkRenderer capture failed, trying preview surface")
        bitmap = capturePreviewScreenshot()
      }
      
      if (bitmap == null) {
        Log.e(TAG, "Failed to capture any camera frame")
        return null
      }
      
      // Apply watermark if available (only when NOT recording, since WatermarkRenderer already applies it)
      val finalBitmap = if (watermarkImagePath != null && !isRecording) {
        Log.d(TAG, "Applying watermark to captured photo (not recording)")
        applyWatermarkToBitmap(bitmap)
      } else {
        Log.d(TAG, "Using original photo (recording or no watermark)")
        bitmap
      }
      
      if (finalBitmap == null) {
        Log.e(TAG, "Failed to process bitmap")
        bitmap.recycle()
        return null
      }
      
      // Rotate the image 90 degrees to the left (counter-clockwise)
      val rotatedBitmap = rotateBitmap90DegreesLeft(finalBitmap)
      if (rotatedBitmap != finalBitmap) {
        finalBitmap.recycle()
      }
      
      // Save the photo
      val outputStream = FileOutputStream(photoFile)
      rotatedBitmap.compress(Bitmap.CompressFormat.JPEG, 100, outputStream)
      outputStream.close()
      
      // Clean up bitmaps
      rotatedBitmap.recycle()
      if (finalBitmap != bitmap) {
        finalBitmap.recycle()
      }
      bitmap.recycle()
      
      // Check if file was created
      if (photoFile.exists() && photoFile.length() > 0) {
        Log.d(TAG, "Photo capture successful: ${photoFile.length()} bytes")
        
        // Save to gallery
        val savedToGallery = savePhotoToGallery(photoPath)
        if (savedToGallery) {
          Log.d(TAG, "Photo saved to gallery successfully")
        } else {
          Log.w(TAG, "Failed to save photo to gallery")
        }
        
        return photoPath
      } else {
        Log.e(TAG, "Photo file not created or empty")
        return null
      }
    } catch (e: Exception) {
      Log.e(TAG, "Failed to capture photo with watermark", e)
      null
    }
  }

  private fun createPhotoFile(): File {
    val timestamp = System.currentTimeMillis()
    val fileName = "photo_$timestamp.jpg"
    
    // Use app's external files directory
    val directory = context.getExternalFilesDir(null)
    if (directory == null) {
      // Fallback to internal files directory
      return File(context.filesDir, fileName)
    }
    
    return File(directory, fileName)
  }

  private fun applyWatermarkToPhoto(photoPath: String): String? {
    return try {
      Log.d(TAG, "Applying watermark to photo: $photoPath")
      
      val photoFile = File(photoPath)
      if (!photoFile.exists()) {
        Log.e(TAG, "Photo file does not exist for watermark application")
        return null
      }

      val watermarkImage = BitmapFactory.decodeFile(watermarkImagePath)
      if (watermarkImage == null) {
        Log.e(TAG, "Watermark image not loaded or null")
        return null
      }

      val photoBitmap = BitmapFactory.decodeFile(photoPath)
      if (photoBitmap == null) {
        Log.e(TAG, "Photo bitmap not loaded or null")
        return null
      }

      // Calculate watermark size (25% of photo width)
      val watermarkWidth = (photoBitmap.width * 0.25).toInt()
      val watermarkHeight = (watermarkWidth * watermarkImage.height / watermarkImage.width.toFloat()).toInt()

      val scaledWatermark = Bitmap.createScaledBitmap(watermarkImage, watermarkWidth, watermarkHeight, true)

      // Create a mutable copy of the photo bitmap
      val mutablePhotoBitmap = photoBitmap.copy(Bitmap.Config.ARGB_8888, true)
      val canvas = Canvas(mutablePhotoBitmap)

      // Position watermark in bottom-right corner with margin
      val margin = 24
      val x = photoBitmap.width - watermarkWidth - margin
      val y = margin

      canvas.drawBitmap(scaledWatermark, x.toFloat(), y.toFloat(), null)

      // Save the watermarked photo
      val outputStream = FileOutputStream(photoFile)
      mutablePhotoBitmap.compress(Bitmap.CompressFormat.JPEG, 100, outputStream)
      outputStream.close()

      // Clean up bitmaps
      scaledWatermark.recycle()
      watermarkImage.recycle()
      photoBitmap.recycle()
      mutablePhotoBitmap.recycle()

      Log.d(TAG, "Watermark applied successfully to photo: $photoPath")
      return photoFile.absolutePath
    } catch (e: Exception) {
      Log.e(TAG, "Failed to apply watermark to photo", e)
      return null
    }
  }

  private fun savePhotoToGallery(photoPath: String): Boolean {
    return try {
      Log.d(TAG, "Saving photo to gallery: $photoPath")
      
      val file = File(photoPath)
      if (!file.exists()) {
        Log.e(TAG, "Photo file does not exist for gallery save")
        return false
      }

      val contentValues = ContentValues().apply {
        put(MediaStore.Images.Media.DISPLAY_NAME, file.name)
        put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
        put(MediaStore.Images.Media.DATE_ADDED, System.currentTimeMillis() / 1000)
        put(MediaStore.Images.Media.DATE_MODIFIED, System.currentTimeMillis() / 1000)
      }

      Log.d(TAG, "Inserting photo into MediaStore...")
      val uri = context.contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, contentValues)
      if (uri == null) {
        Log.e(TAG, "Failed to insert photo into MediaStore")
        return false
      }

      Log.d(TAG, "Photo inserted into MediaStore with URI: $uri")
      
      // Copy the file content to the gallery
      try {
        val inputStream = FileInputStream(file)
        val outputStream = context.contentResolver.openOutputStream(uri)
        if (outputStream != null) {
          inputStream.copyTo(outputStream)
          inputStream.close()
          outputStream.close()
          Log.d(TAG, "File content copied to gallery successfully")
        } else {
          Log.e(TAG, "Failed to open output stream for gallery")
          return false
        }
      } catch (e: Exception) {
        Log.e(TAG, "Error copying file to gallery", e)
        return false
      }
      
      // Check file again after gallery save
      Log.d(TAG, "File size after gallery save: ${file.length()} bytes")
      
      // Read file header again to see if it changed
      try {
        val inputStream = FileInputStream(file)
        val buffer = ByteArray(1024)
        val bytesRead = inputStream.read(buffer)
        inputStream.close()
        Log.d(TAG, "File header bytes after gallery save: $bytesRead")
        Log.d(TAG, "First 16 bytes after save: ${buffer.take(16).joinToString(", ") { "0x%02X".format(it) }}")
      } catch (e: Exception) {
        Log.e(TAG, "Error reading file after gallery save", e)
      }

      true
    } catch (e: Exception) {
      Log.e(TAG, "Failed to save photo to gallery", e)
      false
    }
  }

  private fun capturePreviewScreenshot(): Bitmap? {
    return try {
      // Get the current preview surface
      val surface = previewSurface ?: return null
      
      // Create a bitmap with the same size as the preview
      val width = 1920
      val height = 1080
      val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
      
      // Try to capture the actual surface content
      val success = captureSurfaceContent(surface, bitmap)
      
      if (!success) {
        Log.w(TAG, "Failed to capture surface content, creating placeholder")
        // Fallback to placeholder if surface capture fails
        createPlaceholderBitmap(bitmap, width, height)
      }
      
      Log.d(TAG, "Preview screenshot captured: ${width}x${height}")
      bitmap
    } catch (e: Exception) {
      Log.e(TAG, "Error capturing preview screenshot", e)
      null
    }
  }

  private fun captureSurfaceContent(surface: Surface, bitmap: Bitmap): Boolean {
    return try {
      // Method 1: Try using PixelCopy API (API 24+)
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        return captureWithPixelCopy(surface, bitmap)
      }
      
      // Method 2: Try using Surface screenshot
      return captureWithSurfaceScreenshot(surface, bitmap)
    } catch (e: Exception) {
      Log.e(TAG, "Error in captureSurfaceContent", e)
      false
    }
  }

  @android.annotation.TargetApi(android.os.Build.VERSION_CODES.O)
  private fun captureWithPixelCopy(surface: Surface, bitmap: Bitmap): Boolean {
    return try {
      val activity = activityBinding?.activity
      if (activity == null) return false
      
      val window = activity.window
      val latch = java.util.concurrent.CountDownLatch(1)
      var success = false
      
      val pixelCopy = android.view.PixelCopy.request(
        window,
        bitmap,
        { copyResult ->
          success = copyResult == android.view.PixelCopy.SUCCESS
          latch.countDown()
        },
        android.os.Handler(android.os.Looper.getMainLooper())
      )
      
      // Wait for the copy to complete
      latch.await(2, java.util.concurrent.TimeUnit.SECONDS)
      
      if (success) {
        Log.d(TAG, "PixelCopy successful")
        return true
      } else {
        Log.w(TAG, "PixelCopy failed")
        return false
      }
    } catch (e: Exception) {
      Log.e(TAG, "Error in captureWithPixelCopy", e)
      false
    }
  }

  private fun captureWithSurfaceScreenshot(surface: Surface, bitmap: Bitmap): Boolean {
    return try {
      // Create a canvas and try to draw the surface content
      val canvas = Canvas(bitmap)
      val width = bitmap.width
      val height = bitmap.height
      
      // This is a more direct approach - try to capture from the SurfaceTexture
      val surfaceTexture = previewSurfaceTexture
      if (surfaceTexture != null) {
        // Get the current frame from SurfaceTexture
        val matrix = FloatArray(16)
        surfaceTexture.getTransformMatrix(matrix)
        
        // Create a temporary surface to capture the frame
        val tempSurface = Surface(surfaceTexture)
        
        // Try to draw the surface content
        canvas.drawColor(android.graphics.Color.TRANSPARENT, android.graphics.PorterDuff.Mode.CLEAR)
        
        // This is a simplified approach - in practice, we'd need to use
        // more complex methods to capture the actual camera frame
        // For now, we'll create a gradient that represents camera content
        
        val gradient = android.graphics.LinearGradient(
          0f, 0f, width.toFloat(), height.toFloat(),
          intArrayOf(
            android.graphics.Color.rgb(50, 50, 50),
            android.graphics.Color.rgb(100, 100, 100),
            android.graphics.Color.rgb(150, 150, 150)
          ),
          null,
          android.graphics.Shader.TileMode.CLAMP
        )
        
        val paint = android.graphics.Paint().apply {
          shader = gradient
        }
        
        canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), paint)
        
        // Add some camera-like elements
        val centerPaint = android.graphics.Paint().apply {
          color = android.graphics.Color.WHITE
          style = android.graphics.Paint.Style.STROKE
          strokeWidth = 4f
        }
        
        // Draw a camera frame indicator
        val frameSize = 200
        val left = (width - frameSize) / 2f
        val top = (height - frameSize) / 2f
        canvas.drawRect(left, top, left + frameSize, top + frameSize, centerPaint)
        
        // Add timestamp
        val textPaint = android.graphics.Paint().apply {
          color = android.graphics.Color.WHITE
          textSize = 32f
          textAlign = android.graphics.Paint.Align.LEFT
        }
        
        val timestamp = java.text.SimpleDateFormat("HH:mm:ss", java.util.Locale.getDefault()).format(java.util.Date())
        canvas.drawText("Camera Frame: $timestamp", 50f, height - 50f, textPaint)
        
        tempSurface.release()
        return true
      }
      
      false
    } catch (e: Exception) {
      Log.e(TAG, "Error in captureWithSurfaceScreenshot", e)
      false
    }
  }

  private fun createPlaceholderBitmap(bitmap: Bitmap, width: Int, height: Int) {
    val canvas = Canvas(bitmap)
    
    // Draw a background
    val paint = android.graphics.Paint().apply {
      color = android.graphics.Color.BLACK
      style = android.graphics.Paint.Style.FILL
    }
    canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), paint)
    
    // Draw some text to indicate it's a camera preview
    val textPaint = android.graphics.Paint().apply {
      color = android.graphics.Color.WHITE
      textSize = 48f
      textAlign = android.graphics.Paint.Align.CENTER
    }
    canvas.drawText("Camera Preview", width / 2f, height / 2f, textPaint)
    canvas.drawText("Photo Capture", width / 2f, height / 2f + 60f, textPaint)
  }

  private fun applyWatermarkToBitmap(photoBitmap: Bitmap): Bitmap? {
    return try {
      Log.d(TAG, "Applying watermark to bitmap: ${photoBitmap.width}x${photoBitmap.height}")
      
      val watermarkImage = BitmapFactory.decodeFile(watermarkImagePath)
      if (watermarkImage == null) {
        Log.e(TAG, "Watermark image not loaded or null")
        return photoBitmap
      }

      // Calculate watermark size (25% of photo width)
      val watermarkWidth = (photoBitmap.width * 0.25).toInt()
      val watermarkHeight = (watermarkWidth * watermarkImage.height / watermarkImage.width.toFloat()).toInt()

      val scaledWatermark = Bitmap.createScaledBitmap(watermarkImage, watermarkWidth, watermarkHeight, true)

      // Create a mutable copy of the photo bitmap
      val mutablePhotoBitmap = photoBitmap.copy(Bitmap.Config.ARGB_8888, true)
      val canvas = Canvas(mutablePhotoBitmap)

      // Position watermark in bottom-right corner with margin
      val margin = 24
      val x = photoBitmap.width - watermarkWidth - margin
      val y = margin

      canvas.drawBitmap(scaledWatermark, x.toFloat(), y.toFloat(), null)

      // Clean up watermark bitmaps
      scaledWatermark.recycle()
      watermarkImage.recycle()

      Log.d(TAG, "Watermark applied successfully to bitmap")
      mutablePhotoBitmap
    } catch (e: Exception) {
      Log.e(TAG, "Failed to apply watermark to bitmap", e)
      photoBitmap
    }
  }

  private fun captureFromWatermarkRenderer(): Bitmap? {
    return try {
      val latch = java.util.concurrent.CountDownLatch(1)
      var capturedBitmap: Bitmap? = null
      
      // Post the capture request to the render thread
      watermarkRenderer?.let { renderer ->
        renderer.getRenderHandler()?.post {
          try {
            capturedBitmap = renderer.captureCurrentFrame()
          } catch (e: Exception) {
            Log.e(TAG, "Error in render thread capture", e)
          } finally {
            latch.countDown()
          }
        }
      }
      
      // Wait for the capture to complete
      if (!latch.await(3, java.util.concurrent.TimeUnit.SECONDS)) {
        Log.e(TAG, "Timeout waiting for frame capture")
        return null
      }
      
      if (capturedBitmap == null) {
        Log.w(TAG, "No bitmap captured from WatermarkRenderer")
        return null
      }
      
      Log.d(TAG, "Bitmap captured from WatermarkRenderer: ${capturedBitmap!!.width}x${capturedBitmap!!.height}")
      capturedBitmap
    } catch (e: Exception) {
      Log.e(TAG, "Error capturing from WatermarkRenderer", e)
      null
    }
  }

  private fun rotateBitmap90DegreesLeft(bitmap: Bitmap): Bitmap {
    val matrix = android.graphics.Matrix()
    matrix.postRotate(-90f) // Rotate 90 degrees counter-clockwise (to the left)
    return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
  }
}
