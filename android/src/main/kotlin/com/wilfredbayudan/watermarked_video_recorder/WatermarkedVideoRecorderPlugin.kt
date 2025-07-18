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
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream

/** WatermarkedVideoRecorderPlugin */
class WatermarkedVideoRecorderPlugin: FlutterPlugin, MethodCallHandler, ActivityAware {
  /// The MethodChannel that will the communication between Flutter and native Android
  ///
  /// This local reference serves to register the plugin with the Flutter Engine and unregister it
  /// when the Flutter Engine is detached from the Activity
  private lateinit var channel : MethodChannel
  private lateinit var context: Context
  private var activityBinding: ActivityPluginBinding? = null

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
  private var currentVideoPath: String? = null

  // Placeholder for watermark image path
  private var watermarkImagePath: String? = null

  // Add WatermarkRenderer instance
  private var watermarkRenderer: WatermarkRenderer? = null

  // Permission request tracking
  private var pendingPermissionResult: Result? = null
  private var pendingPermissionType: String? = null

  // Camera initialization tracking
  private var pendingCameraInitResult: Result? = null
  private var isCameraInitializing = false

  // Preview-related properties
  private var isPreviewActive = false
  private var previewTextureId: Int? = null
  private var previewSurfaceTexture: SurfaceTexture? = null
  private var previewSurface: Surface? = null

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
      "saveVideoToGallery" -> {
        val videoPath = call.argument<String>("videoPath")
        val success = if (videoPath != null) saveVideoToGallery(videoPath) else false
        result.success(success)
      }
      "setWatermarkImage" -> {
        val path = call.argument<String>("path")
        setWatermarkImage(path)
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
          "cameraId" to cameraId
        )
        result.success(state)
      }
      "startCameraPreview" -> {
        val direction = call.argument<String>("direction")
        val textureId = if (direction != null) startCameraPreview(direction) else null
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
        result.success(previewTextureId)
      }
      "startPreviewWithWatermark" -> {
        val watermarkPath = call.argument<String>("watermarkPath")
        val direction = call.argument<String>("direction")
        val textureId = if (watermarkPath != null && direction != null) {
          startPreviewWithWatermark(watermarkPath, direction)
        } else null
        result.success(textureId)
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

      // This is just a placeholder - we'll create the real session when recording
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
      
      // Stop and clean up WatermarkRenderer
      watermarkRenderer?.stop()
      watermarkRenderer = null
      
      Log.d(TAG, "Camera disposal completed")
    } catch (e: Exception) {
      Log.e(TAG, "Failed to dispose camera", e)
    }
  }

  private fun startVideoRecording(): Boolean {
    return try {
      if (isRecording) {
        Log.w(TAG, "Already recording")
        return false
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

      // Initialize MediaRecorder (output surface will be set up by WatermarkRenderer)
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

      // Set up WatermarkRenderer
      val deviceRotation = getDeviceRotation() // Get actual device rotation
      val isFront = isFrontCamera() // Determine if current camera is front-facing
      watermarkRenderer = WatermarkRenderer(
        context = context,
        outputSurface = mediaRecorder!!.surface,
        watermarkImagePath = watermarkImagePath,
        deviceOrientation = deviceRotation, // Pass actual device rotation for watermark positioning
        isFrontCamera = isFront // Pass camera type for proper watermark positioning
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

      // Create capture session with WatermarkRenderer input surface
      cameraDevice!!.createCaptureSession(
        listOf(rendererInputSurface),
        object : CameraCaptureSession.StateCallback() {
          override fun onConfigured(session: CameraCaptureSession) {
            Log.d(TAG, "Recording capture session configured successfully (with WatermarkRenderer)")
            cameraCaptureSession = session
            val captureRequestBuilder = cameraDevice!!.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
            captureRequestBuilder.addTarget(rendererInputSurface)
            captureRequestBuilder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
            captureRequestBuilder.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
            captureRequestBuilder.set(CaptureRequest.CONTROL_AWB_MODE, CaptureRequest.CONTROL_AWB_MODE_AUTO)
            try {
              Log.d(TAG, "Starting repeating capture request...")
              session.setRepeatingRequest(captureRequestBuilder.build(), null, backgroundHandler)
              Log.d(TAG, "Video recording started successfully: $currentVideoPath (with WatermarkRenderer)")
            } catch (e: Exception) {
              Log.e(TAG, "Failed to start recording session", e)
            }
          }
          override fun onConfigureFailed(session: CameraCaptureSession) {
            Log.e(TAG, "Failed to configure recording capture session (with WatermarkRenderer)")
          }
        },
        backgroundHandler
      )
      true
    } catch (e: Exception) {
      Log.e(TAG, "Failed to start video recording", e)
      false
    }
  }

  private fun stopVideoRecording(): String? {
    return try {
      if (!isRecording) {
        Log.w(TAG, "Not recording")
        return null
      }

      Log.d(TAG, "Stopping video recording")

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
      val videoPath = currentVideoPath
      currentVideoPath = null

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

      // Stop and clean up WatermarkRenderer
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
        currentVideoPath = null
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
        val inputStream = file.inputStream()
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
        val inputStream = file.inputStream()
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
        val inputStream = file.inputStream()
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

  private fun setWatermarkImage(path: String?) {
    watermarkImagePath = path
    Log.d(TAG, "Set watermark image path: $path")
    // TODO: Implement actual watermark loading and OpenGL pipeline
  }

  // Preview methods
  private fun startCameraPreview(direction: String): Int? {
    return try {
      Log.d(TAG, "startCameraPreview called with direction: $direction")
      
      // Stop any existing preview
      stopCameraPreview()
      
      // Initialize camera with the specified direction
      val success = initializeCameraWithDirection(direction)
      if (!success) {
        Log.e(TAG, "Failed to initialize camera for preview")
        return null
      }
      
      // Create SurfaceTexture for preview
      val textureId = createPreviewTexture()
      if (textureId == null) {
        Log.e(TAG, "Failed to create preview texture")
        return null
      }
      
      // Create camera capture session for preview
      createPreviewCaptureSession()
      
      isPreviewActive = true
      Log.d(TAG, "Camera preview started successfully with texture ID: $textureId")
      textureId
    } catch (e: Exception) {
      Log.e(TAG, "Error starting camera preview", e)
      null
    }
  }

  private fun startPreviewWithWatermark(watermarkPath: String, direction: String): Int? {
    return try {
      Log.d(TAG, "startPreviewWithWatermark called with watermark: $watermarkPath, direction: $direction")
      
      // Set watermark first
      setWatermarkImage(watermarkPath)
      
      // Start preview (this will handle the watermark overlay)
      startCameraPreview(direction)
    } catch (e: Exception) {
      Log.e(TAG, "Error starting preview with watermark", e)
      null
    }
  }

  private fun stopCameraPreview() {
    try {
      Log.d(TAG, "stopCameraPreview called")
      
      isPreviewActive = false
      
      // Stop the capture session
      cameraCaptureSession?.close()
      cameraCaptureSession = null
      
      // Release preview surface
      previewSurface?.release()
      previewSurface = null
      
      // Release SurfaceTexture
      previewSurfaceTexture?.release()
      previewSurfaceTexture = null
      
      // Clear texture ID
      previewTextureId = null
      
      Log.d(TAG, "Camera preview stopped successfully")
    } catch (e: Exception) {
      Log.e(TAG, "Error stopping camera preview", e)
    }
  }

  private fun createPreviewTexture(): Int? {
    return try {
      // Create a new texture ID
      val textureIds = IntArray(1)
      android.opengl.GLES20.glGenTextures(1, textureIds, 0)
      val textureId = textureIds[0]
      
      // Create SurfaceTexture
      val surfaceTexture = SurfaceTexture(textureId)
      surfaceTexture.setDefaultBufferSize(1920, 1080) // Set default size
      
      // Create Surface from SurfaceTexture
      val surface = Surface(surfaceTexture)
      
      // Store references
      previewTextureId = textureId
      previewSurfaceTexture = surfaceTexture
      previewSurface = surface
      
      Log.d(TAG, "Created preview texture with ID: $textureId")
      textureId
    } catch (e: Exception) {
      Log.e(TAG, "Error creating preview texture", e)
      null
    }
  }

  private fun createPreviewCaptureSession() {
    try {
      if (cameraDevice == null || previewSurface == null) {
        Log.e(TAG, "Camera device or preview surface is null")
        return
      }
      
      // Create a list of surfaces for the capture session
      val surfaces = listOf(previewSurface!!)
      
      // Create capture session
      cameraDevice!!.createCaptureSession(surfaces, object : CameraCaptureSession.StateCallback() {
        override fun onConfigured(session: CameraCaptureSession) {
          Log.d(TAG, "Preview capture session configured")
          cameraCaptureSession = session
          
          // Start preview by setting repeating request
          startPreviewCapture()
        }
        
        override fun onConfigureFailed(session: CameraCaptureSession) {
          Log.e(TAG, "Failed to configure preview capture session")
        }
      }, backgroundHandler)
    } catch (e: Exception) {
      Log.e(TAG, "Error creating preview capture session", e)
    }
  }

  private fun startPreviewCapture() {
    try {
      if (cameraCaptureSession == null || previewSurface == null) {
        Log.e(TAG, "Capture session or preview surface is null")
        return
      }
      
      // Create capture request for preview
      val captureRequestBuilder = cameraDevice!!.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
      captureRequestBuilder.addTarget(previewSurface!!)
      
      // Set auto-focus and auto-exposure
      captureRequestBuilder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
      captureRequestBuilder.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
      
      // Start repeating request for preview
      cameraCaptureSession!!.setRepeatingRequest(
        captureRequestBuilder.build(),
        null,
        backgroundHandler
      )
      
      Log.d(TAG, "Preview capture started")
    } catch (e: Exception) {
      Log.e(TAG, "Error starting preview capture", e)
    }
  }
}
