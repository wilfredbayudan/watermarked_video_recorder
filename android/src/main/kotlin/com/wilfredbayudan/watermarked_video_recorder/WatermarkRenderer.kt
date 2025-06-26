package com.wilfredbayudan.watermarked_video_recorder

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES20
import android.opengl.GLES11Ext
import android.util.Log
import android.view.Surface
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

class WatermarkRenderer(
    private val context: Context,
    private val outputSurface: Surface,
    private val watermarkImagePath: String?,
    private val deviceOrientation: Int = 0, // Pass device orientation from plugin
    private val isFrontCamera: Boolean = false // Pass camera type for proper positioning
) : SurfaceTexture.OnFrameAvailableListener {
    companion object {
        private const val TAG = "WatermarkRenderer"
    }

    private var eglDisplay: EGLDisplay? = null
    private var eglContext: EGLContext? = null
    private var eglSurface: EGLSurface? = null
    private var surfaceTexture: SurfaceTexture? = null
    private var cameraSurface: Surface? = null
    private var cameraTextureId: Int = 0
    private var watermarkTextureId: Int = 0
    private var watermarkBitmap: Bitmap? = null
    private var isRunning = false
    private var frameCount = 0

    // Vertex shader for both camera and watermark
    private val vertexShaderCode = """
        attribute vec4 aPosition;
        attribute vec2 aTexCoord;
        varying vec2 vTexCoord;
        void main() {
            gl_Position = aPosition;
            vTexCoord = aTexCoord;
        }
    """

    // Fragment shader for camera (external OES texture)
    private val cameraFragmentShaderCode = """
        #extension GL_OES_EGL_image_external : require
        precision mediump float;
        varying vec2 vTexCoord;
        uniform samplerExternalOES sTexture;
        void main() {
            gl_FragColor = texture2D(sTexture, vTexCoord);
        }
    """

    // Fragment shader for watermark (2D texture)
    private val watermarkFragmentShaderCode = """
        precision mediump float;
        varying vec2 vTexCoord;
        uniform sampler2D sTexture;
        void main() {
            vec4 color = texture2D(sTexture, vTexCoord);
            // Premultiplied alpha for watermark
            gl_FragColor = vec4(color.rgb * color.a, color.a);
        }
    """

    // Fullscreen quad for camera
    private val fullScreenCoords = floatArrayOf(
        -1f,  1f, 0f, 0f, 0f,
        -1f, -1f, 0f, 0f, 1f,
         1f,  1f, 0f, 1f, 0f,
         1f, -1f, 0f, 1f, 1f
    )
    private val vertexStride = 5 * 4 // 5 floats per vertex, 4 bytes per float
    private val vertexBuffer: FloatBuffer = ByteBuffer.allocateDirect(fullScreenCoords.size * 4)
        .order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
            put(fullScreenCoords)
            position(0)
        }

    // Watermark quad (bottom-right, 25% size) - positioned based on camera type
    private val watermarkCoords = floatArrayOf(
        0.5f, -0.5f, 0f, 1f, 1f,  // Bottom-right corner
        0.5f, -1f,   0f, 1f, 0f,  // Bottom-left corner  
        1f,   -0.5f, 0f, 0f, 1f,  // Top-right corner
        1f,   -1f,   0f, 0f, 0f   // Top-left corner
    )
    private val watermarkBuffer: FloatBuffer = ByteBuffer.allocateDirect(watermarkCoords.size * 4)
        .order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
            put(watermarkCoords)
            position(0)
        }

    // Helper to rotate a quad by degrees (around Z axis)
    private fun rotateQuad(coords: FloatArray, degrees: Int): FloatArray {
        val rad = Math.toRadians(degrees.toDouble())
        val cos = Math.cos(rad).toFloat()
        val sin = Math.sin(rad).toFloat()
        val rotated = FloatArray(coords.size)
        for (i in 0 until 4) {
            val x = coords[i * 5]
            val y = coords[i * 5 + 1]
            rotated[i * 5] = x * cos - y * sin
            rotated[i * 5 + 1] = x * sin + y * cos
            // z, u, v unchanged
            rotated[i * 5 + 2] = coords[i * 5 + 2]
            rotated[i * 5 + 3] = coords[i * 5 + 3]
            rotated[i * 5 + 4] = coords[i * 5 + 4]
        }
        return rotated
    }

    // Get watermark coordinates: bottom right, upright, preserve aspect ratio, mirror for front camera, rotate +90°
    private fun getWatermarkCoords(): FloatArray {
        // Output surface size
        val surfaceWidth = outputSurface?.let {
            try {
                val clazz = it.javaClass
                val getWidth = clazz.getMethod("getWidth")
                (getWidth.invoke(it) as? Int) ?: 1280
            } catch (e: Exception) { 1280 }
        } ?: 1280
        val surfaceHeight = outputSurface?.let {
            try {
                val clazz = it.javaClass
                val getHeight = clazz.getMethod("getHeight")
                (getHeight.invoke(it) as? Int) ?: 720
            } catch (e: Exception) { 720 }
        } ?: 720

        // Watermark bitmap size
        val wmWidth = watermarkBitmap?.width?.toFloat() ?: 200f
        val wmHeight = watermarkBitmap?.height?.toFloat() ?: 100f

        // Watermark width in NDC (35% of video width)
        val ndcW = 0.25f * 2f
        // Watermark height in NDC, preserving aspect ratio
        val ndcH = ndcW * (wmHeight / wmWidth) * (surfaceHeight.toFloat() / surfaceWidth.toFloat())

        val (left, right, bottom, top) = if (isFrontCamera) {
            // Place in top left for front camera (so after +90° rotation, it ends up in bottom right)
            val l = -1f + 0.05f
            val r = l + ndcW
            val t = 1f - 0.05f
            val b = t - ndcH
            listOf(l, r, b, t)
        } else {
            // Place in bottom right for rear camera
            val r = 1f - 0.05f
            val l = r - ndcW
            val b = -1f + 0.05f
            val t = b + ndcH
            listOf(l, r, b, t)
        }

        val base = if (isFrontCamera) {
            floatArrayOf(
                right,  bottom, 0f, 0f, 0f,
                left,   bottom, 0f, 1f, 0f,
                right,  top,    0f, 0f, 1f,
                left,   top,    0f, 1f, 1f
            )
        } else {
            floatArrayOf(
                right,  bottom, 0f, 1f, 1f,
                left,   bottom, 0f, 0f, 1f,
                right,  top,    0f, 1f, 0f,
                left,   top,    0f, 0f, 0f
            )
        }
        return rotateQuad(base, 90)
    }

    private var cameraProgram = 0
    private var watermarkProgram = 0
    private var oesTextureHandle = 0
    private var tex2DHandle = 0

    fun start() {
        Log.d(TAG, "Starting OpenGL renderer...")
        isRunning = true
        setupEGL()
        setupSurfaceTexture()
        loadWatermarkTexture()
        cameraProgram = createProgram(vertexShaderCode, cameraFragmentShaderCode)
        watermarkProgram = createProgram(vertexShaderCode, watermarkFragmentShaderCode)
        oesTextureHandle = GLES20.glGetUniformLocation(cameraProgram, "sTexture")
        tex2DHandle = GLES20.glGetUniformLocation(watermarkProgram, "sTexture")
        Log.d(TAG, "OpenGL renderer started successfully")
    }

    fun stop() {
        Log.d(TAG, "Stopping OpenGL renderer...")
        isRunning = false
        
        // Remove frame listener before releasing SurfaceTexture
        surfaceTexture?.setOnFrameAvailableListener(null)
        
        // Release resources in correct order
        surfaceTexture?.release()
        cameraSurface?.release()
        watermarkBitmap?.recycle()
        
        // Delete OpenGL textures
        if (watermarkTextureId != 0) {
            GLES20.glDeleteTextures(1, intArrayOf(watermarkTextureId), 0)
            watermarkTextureId = 0
        }
        if (cameraTextureId != 0) {
            GLES20.glDeleteTextures(1, intArrayOf(cameraTextureId), 0)
            cameraTextureId = 0
        }
        
        // Clean up EGL resources
        eglSurface?.let { surface ->
            eglDisplay?.let { display ->
                EGL14.eglDestroySurface(display, surface)
            }
        }
        eglContext?.let { context ->
            eglDisplay?.let { display ->
                EGL14.eglDestroyContext(display, context)
            }
        }
        eglDisplay?.let { display ->
            EGL14.eglTerminate(display)
        }
        
        // Clear references
        eglSurface = null
        eglContext = null
        eglDisplay = null
        surfaceTexture = null
        cameraSurface = null
        watermarkBitmap = null
        
        Log.d(TAG, "OpenGL renderer stopped successfully")
    }

    fun getInputSurface(): Surface? {
        return cameraSurface
    }

    private fun setupEGL() {
        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        if (eglDisplay == EGL14.EGL_NO_DISPLAY) {
            throw RuntimeException("Unable to get EGL14 display")
        }
        val version = IntArray(2)
        if (!EGL14.eglInitialize(eglDisplay, version, 0, version, 1)) {
            throw RuntimeException("Unable to initialize EGL14")
        }
        
        // Configure EGL for MediaRecorder compatibility
        val attribList = intArrayOf(
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT,
            EGL14.EGL_NONE
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val numConfigs = IntArray(1)
        if (!EGL14.eglChooseConfig(eglDisplay, attribList, 0, configs, 0, configs.size, numConfigs, 0)) {
            throw RuntimeException("Unable to choose EGL config")
        }
        
        val attrib_list = intArrayOf(
            EGL14.EGL_CONTEXT_CLIENT_VERSION, 2,
            EGL14.EGL_NONE
        )
        eglContext = EGL14.eglCreateContext(eglDisplay, configs[0], EGL14.EGL_NO_CONTEXT, attrib_list, 0)
        if (eglContext == EGL14.EGL_NO_CONTEXT) {
            throw RuntimeException("Unable to create EGL context")
        }
        
        val surfaceAttribs = intArrayOf(EGL14.EGL_NONE)
        eglSurface = EGL14.eglCreateWindowSurface(eglDisplay, configs[0], outputSurface, surfaceAttribs, 0)
        if (eglSurface == EGL14.EGL_NO_SURFACE) {
            throw RuntimeException("Unable to create EGL surface")
        }
        
        if (!EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) {
            throw RuntimeException("Unable to make EGL context current")
        }
        
        Log.d(TAG, "EGL context and surface set up successfully")
    }

    private fun setupSurfaceTexture() {
        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        cameraTextureId = textures[0]
        surfaceTexture = SurfaceTexture(cameraTextureId)
        
        // Set the surface texture to the expected video size
        surfaceTexture?.setDefaultBufferSize(1920, 1080)
        
        surfaceTexture?.setOnFrameAvailableListener(this)
        cameraSurface = Surface(surfaceTexture)
        Log.d(TAG, "Camera SurfaceTexture and Surface set up at 1920x1080")
    }

    private fun loadWatermarkTexture() {
        // Load watermark image as a Bitmap
        Log.d(TAG, "Loading watermark from path: $watermarkImagePath")
        watermarkBitmap = loadBitmapFromPath(watermarkImagePath)
        if (watermarkBitmap == null) {
            Log.e(TAG, "Failed to load watermark bitmap - continuing without watermark")
            return
        }
        
        // Upload bitmap as OpenGL texture
        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        watermarkTextureId = textures[0]
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, watermarkTextureId)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        android.opengl.GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, watermarkBitmap, 0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)
        Log.d(TAG, "Watermark texture loaded successfully: $watermarkTextureId")
    }

    private fun loadBitmapFromPath(path: String?): Bitmap? {
        if (path == null) {
            Log.w(TAG, "Watermark path is null")
            return null
        }
        
        return try {
            Log.d(TAG, "Attempting to load bitmap from: $path")
            val file = File(path)
            if (!file.exists()) {
                Log.e(TAG, "Watermark file does not exist: $path")
                return null
            }
            
            val bitmap = BitmapFactory.decodeFile(path)
            if (bitmap == null) {
                Log.e(TAG, "Failed to decode bitmap from file: $path")
                return null
            }
            
            Log.d(TAG, "Successfully loaded watermark bitmap: ${bitmap.width}x${bitmap.height}")
            bitmap
        } catch (e: Exception) {
            Log.e(TAG, "Exception loading bitmap from path: $path", e)
            null
        }
    }

    override fun onFrameAvailable(surfaceTexture: SurfaceTexture?) {
        if (!isRunning) {
            Log.w(TAG, "Frame available but renderer is not running")
            return
        }
        
        frameCount++
        if (frameCount % 30 == 0) { // Log every 30 frames (about once per second)
            Log.d(TAG, "Processing frame #$frameCount")
        }
        
        try {
            // Update the texture with the new camera frame
            surfaceTexture?.updateTexImage()
            
            // Clear the framebuffer
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
            
            // Set viewport to match the surface texture size
            GLES20.glViewport(0, 0, 1920, 1080)
            
            // Always draw camera frame first
            GLES20.glUseProgram(cameraProgram)
            drawQuad(vertexBuffer, cameraTextureId, oes = true)
            
            // Draw watermark if available
            if (watermarkTextureId != -1) {
                GLES20.glEnable(GLES20.GL_BLEND)
                GLES20.glBlendFunc(GLES20.GL_ONE, GLES20.GL_ONE_MINUS_SRC_ALPHA)
                GLES20.glUseProgram(watermarkProgram)
                
                // Get watermark coordinates based on camera type
                val watermarkCoords = getWatermarkCoords()
                val watermarkBuffer = ByteBuffer.allocateDirect(watermarkCoords.size * 4)
                    .order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
                        put(watermarkCoords)
                        position(0)
                    }
                
                // Set up watermark attributes
                val positionHandle = GLES20.glGetAttribLocation(watermarkProgram, "aPosition")
                val texCoordHandle = GLES20.glGetAttribLocation(watermarkProgram, "aTexCoord")
                
                GLES20.glEnableVertexAttribArray(positionHandle)
                GLES20.glEnableVertexAttribArray(texCoordHandle)
                
                GLES20.glVertexAttribPointer(positionHandle, 3, GLES20.GL_FLOAT, false, 20, watermarkBuffer)
                watermarkBuffer.position(3) // Move to texture coordinates
                GLES20.glVertexAttribPointer(texCoordHandle, 2, GLES20.GL_FLOAT, false, 20, watermarkBuffer)
                
                // Bind watermark texture
                GLES20.glActiveTexture(GLES20.GL_TEXTURE1)
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, watermarkTextureId)
                GLES20.glUniform1i(GLES20.glGetUniformLocation(watermarkProgram, "sTexture"), 1)
                
                // Draw watermark
                GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
                
                GLES20.glDisableVertexAttribArray(positionHandle)
                GLES20.glDisableVertexAttribArray(texCoordHandle)
                GLES20.glDisable(GLES20.GL_BLEND)
            }
            
            // Swap buffers to send the frame to MediaRecorder
            EGL14.eglSwapBuffers(eglDisplay, eglSurface)
            
            // Log successful frame rendering occasionally
            if (frameCount % 30 == 0) {
                Log.d(TAG, "Frame #$frameCount rendered successfully")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error in onFrameAvailable for frame #$frameCount", e)
        }
    }

    private fun drawQuad(buffer: FloatBuffer, textureId: Int, oes: Boolean) {
        try {
            buffer.position(0)
            val aPosition = GLES20.glGetAttribLocation(if (oes) cameraProgram else watermarkProgram, "aPosition")
            GLES20.glEnableVertexAttribArray(aPosition)
            GLES20.glVertexAttribPointer(aPosition, 3, GLES20.GL_FLOAT, false, vertexStride, buffer)
            
            buffer.position(3)
            val aTexCoord = GLES20.glGetAttribLocation(if (oes) cameraProgram else watermarkProgram, "aTexCoord")
            GLES20.glEnableVertexAttribArray(aTexCoord)
            GLES20.glVertexAttribPointer(aTexCoord, 2, GLES20.GL_FLOAT, false, vertexStride, buffer)
            
            if (oes) {
                GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
                GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId)
                GLES20.glUniform1i(oesTextureHandle, 0)
            } else {
                GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, textureId)
                GLES20.glUniform1i(tex2DHandle, 0)
            }
            
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
            
            // Clean up
            GLES20.glDisableVertexAttribArray(aPosition)
            GLES20.glDisableVertexAttribArray(aTexCoord)
        } catch (e: Exception) {
            Log.e(TAG, "Error in drawQuad", e)
        }
    }

    private fun loadShader(type: Int, shaderCode: String): Int {
        val shader = GLES20.glCreateShader(type)
        GLES20.glShaderSource(shader, shaderCode)
        GLES20.glCompileShader(shader)
        return shader
    }

    private fun createProgram(vertexCode: String, fragmentCode: String): Int {
        val vertexShader = loadShader(GLES20.GL_VERTEX_SHADER, vertexCode)
        val fragmentShader = loadShader(GLES20.GL_FRAGMENT_SHADER, fragmentCode)
        val program = GLES20.glCreateProgram()
        GLES20.glAttachShader(program, vertexShader)
        GLES20.glAttachShader(program, fragmentShader)
        GLES20.glLinkProgram(program)
        return program
    }
} 