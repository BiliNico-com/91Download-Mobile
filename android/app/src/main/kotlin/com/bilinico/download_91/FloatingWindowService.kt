package com.bilinico.download_91

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.graphics.PixelFormat
import android.media.AudioAttributes
import android.media.MediaMetadataRetriever
import android.media.MediaPlayer
import android.os.Build
import android.os.IBinder
import android.view.*
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.SeekBar
import android.widget.TextView
import androidx.annotation.RequiresApi
import androidx.core.app.NotificationCompat

/**
 * 原生悬浮窗视频播放服务
 * 使用 WindowManager + SurfaceView + MediaPlayer 实现
 * 参考 VLC Android 的 PopupPlayer 方案，不走 Flutter Engine
 */
class FloatingWindowService : Service() {

    companion object {
        const val ACTION_START = "ACTION_START"
        const val ACTION_STOP = "ACTION_STOP"
        const val ACTION_PAUSE = "ACTION_PAUSE"
        const val ACTION_PLAY = "ACTION_PLAY"
        const val ACTION_SEEK = "ACTION_SEEK"
        const val ACTION_SWITCH_VIDEO = "ACTION_SWITCH_VIDEO"
        const val EXTRA_VIDEO_PATH = "extra_video_path"
        const val EXTRA_TITLE = "extra_title"
        const val EXTRA_WIDTH = "extra_width"
        const val EXTRA_HEIGHT = "extra_height"
        const val EXTRA_SEEK_POS = "extra_seek_pos"

        private const val NOTIFICATION_CHANNEL_ID = "floating_window_channel"
        private const val NOTIFICATION_CHANNEL_NAME = "悬浮窗播放"
        private const val NOTIFICATION_ID = 1001

        // 缩放范围常量
        private const val MIN_WIDTH = 480
        private const val MIN_HEIGHT = 270
        private const val MAX_WIDTH_RATIO = 0.85f
        private const val MAX_HEIGHT_RATIO = 0.8f
        // 初始窗口大小为屏幕宽度的60%
        private const val INITIAL_WIDTH_RATIO = 0.6f

        var instance: FloatingWindowService? = null
            private set

        fun isRunning(): Boolean = instance != null
    }

    private var windowManager: WindowManager? = null
    private var floatingView: View? = null
    private var surfaceView: SurfaceView? = null
    private var mediaPlayer: MediaPlayer? = null
    private var controlOverlay: View? = null
    private var btnClose: ImageView? = null
    private var btnPlay: ImageView? = null
    private var seekBar: SeekBar? = null
    private var timeText: TextView? = null

    // 拖拽相关
    private var initialX = 0
    private var initialY = 0
    private var initialTouchX = 0f
    private var initialTouchY = 0f
    private var isDragging = false
    private var lastTapTime = 0L

    // 缩放相关
    private var scaleDetector: ScaleGestureDetector? = null
    private var currentScaleFactor = 1.0f
    private var isScaling = false

    // 窗口参数
    private var windowWidth = 800
    private var windowHeight = 450
    private var params: WindowManager.LayoutParams? = null

    // 控件自动隐藏
    private var controlsVisible = true
    private val hideControlsRunnable = Runnable { hideControls() }

    override fun onCreate() {
        super.onCreate()
        instance = this
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification("悬浮窗播放服务运行中"))
    }

    /**
     * 创建通知渠道（Android 8.0+ 必须）
     */
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                NOTIFICATION_CHANNEL_NAME,
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "视频悬浮窗播放时显示的通知"
                setShowBadge(false)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    /**
     * 构建前台服务通知
     */
    private fun buildNotification(contentText: String): Notification {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_NEW_TASK
        }
        val pendingIntent = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle("91Download 悬浮窗播放")
            .setContentText(contentText)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val path = intent.getStringExtra(EXTRA_VIDEO_PATH) ?: return START_NOT_STICKY
                val title = intent.getStringExtra(EXTRA_TITLE) ?: ""
                windowWidth = intent.getIntExtra(EXTRA_WIDTH, 800)
                windowHeight = intent.getIntExtra(EXTRA_HEIGHT, 450)
                showFloatingWindow(path, title)
            }
            ACTION_STOP -> stopFloating()
            ACTION_PAUSE -> pauseVideo()
            ACTION_PLAY -> playVideo()
            ACTION_SEEK -> {
                val pos = intent.getIntExtra(EXTRA_SEEK_POS, 0)
                seekTo(pos)
            }
            ACTION_SWITCH_VIDEO -> {
                val path = intent.getStringExtra(EXTRA_VIDEO_PATH) ?: return START_NOT_STICKY
                val title = intent.getStringExtra(EXTRA_TITLE) ?: ""
                switchToVideo(path, title)
            }
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
        cleanup()
        instance = null
    }

    /**
     * 显示悬浮窗
     */
    private fun showFloatingWindow(videoPath: String, title: String) {
        // 如果已有悬浮窗先移除
        if (floatingView != null) {
            try {
                windowManager?.removeView(floatingView)
            } catch (_: Exception) {}
        }

        releaseMediaPlayer()

        // 基于视频原始分辨率计算窗口大小（等比缩放，不超过屏幕 80% 宽度）
        resolveVideoSize(videoPath)

        // 创建根布局
        val layoutFlag = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_SYSTEM_ALERT
        }

        params = WindowManager.LayoutParams(
            windowWidth,
            windowHeight,
            layoutFlag,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
                    WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = getScreenWidth() - windowWidth - 20
            y = 100
        }

        floatingView = createFloatingLayout(videoPath)

        try {
            windowManager?.addView(floatingView, params)
            initAndPlayVideo(videoPath)
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    /**
     * 创建悬浮窗布局
     */
    private fun createFloatingLayout(videoPath: String): View {
        val rootLayout = FrameLayout(this).apply {
            setBackgroundColor(0xFF000000.toInt())
        }

        // 视频渲染 SurfaceView
        surfaceView = SurfaceView(this).apply {
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
            holder.setFormat(PixelFormat.TRANSPARENT)
            holder.addCallback(object : SurfaceHolder.Callback {
                override fun surfaceCreated(holder: SurfaceHolder) {
                    mediaPlayer?.setDisplay(holder)
                }
                override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}
                override fun surfaceDestroyed(holder: SurfaceHolder) {
                    mediaPlayer?.setDisplay(null)
                }
            })
        }
        rootLayout.addView(surfaceView)

        // 控制层（半透明覆盖）
        controlOverlay = createControlOverlay(rootLayout)
        rootLayout.addView(controlOverlay)

        // 初始化缩放手势检测器
        scaleDetector = ScaleGestureDetector(this, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
            override fun onScaleBegin(detector: ScaleGestureDetector): Boolean {
                isScaling = true
                return true
            }

            override fun onScale(detector: ScaleGestureDetector): Boolean {
                // 应用缩放因子
                currentScaleFactor *= detector.scaleFactor
                currentScaleFactor = currentScaleFactor.coerceIn(0.5f, 2.0f)

                // 计算新的窗口尺寸
                val baseWidth = windowWidth
                val baseHeight = windowHeight
                var newWidth = (baseWidth * currentScaleFactor).toInt()
                var newHeight = (baseHeight * currentScaleFactor).toInt()

                // 限制尺寸范围
                val maxWidth = (getScreenWidth() * MAX_WIDTH_RATIO).toInt()
                val maxHeight = (getScreenHeight() * MAX_HEIGHT_RATIO).toInt()

                newWidth = newWidth.coerceIn(MIN_WIDTH, maxWidth)
                newHeight = (newWidth * 9 / 16).coerceIn(MIN_HEIGHT, maxHeight) // 保持 16:9 比例

                // 更新窗口大小
                if (params != null && floatingView != null) {
                    params!!.width = newWidth
                    params!!.height = newHeight
                    windowWidth = newWidth
                    windowHeight = newHeight
                    windowManager?.updateViewLayout(floatingView, params)
                }

                return true
            }

            override fun onScaleEnd(detector: ScaleGestureDetector) {
                isScaling = false
            }
        })

        // 设置触摸监听（拖拽 + 点击 + 双指缩放）
        rootLayout.setOnTouchListener { view, event ->
            // 优先处理缩放手势
            scaleDetector?.onTouchEvent(event)

            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    initialX = params!!.x
                    initialY = params!!.y
                    initialTouchX = event.rawX
                    initialTouchY = event.rawY
                    isDragging = false
                    currentScaleFactor = 1.0f
                    true
                }
                MotionEvent.ACTION_POINTER_DOWN -> {
                    // 第二个手指按下，开始缩放模式
                    isScaling = true
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    // 只有单指时才处理拖拽
                    if (event.pointerCount == 1 && !isScaling) {
                        val dx = (event.rawX - initialTouchX).toInt()
                        val dy = (event.rawY - initialTouchY).toInt()

                        if (Math.abs(dx) > 5 || Math.abs(dy) > 5) {
                            isDragging = true
                            params!!.x = initialX + dx
                            params!!.y = initialY + dy
                            windowManager?.updateViewLayout(floatingView, params)
                        }
                    }
                    true
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    if (!isScaling && !isDragging) {
                        // 点击事件（双击关闭）
                        val now = System.currentTimeMillis()
                        if (now - lastTapTime < 300) {
                            closeAndReturnToApp()
                        } else {
                            toggleControls()
                            lastTapTime = now
                        }
                    } else if (!isScaling && isDragging) {
                        // 拖动结束 → 边缘吸附
                        snapToEdge()
                    }
                    isDragging = false
                    isScaling = false
                    currentScaleFactor = 1.0f
                    true
                }
                MotionEvent.ACTION_POINTER_UP -> {
                    // 缩放模式结束
                    if (event.pointerCount <= 2) {
                        isScaling = false
                    }
                    true
                }
                else -> false
            }
        }

        return rootLayout
    }

    /**
     * 创建控制层 UI
     */
    private fun createControlOverlay(parent: FrameLayout): View {
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
            setBackgroundColor(0x00000000) // 透明背景，渐变通过子 View 实现
            setPadding(8, 8, 8, 8)

            // 顶部栏（关闭按钮）
            val topBar = LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.END
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                )

                btnClose = ImageView(context).apply {
                    setImageResource(android.R.drawable.ic_menu_close_clear_cancel)
                    setColorFilter(0xFFFFFFFF.toInt())
                    setPadding(12, 12, 12, 12)
                    setBackgroundResource(android.R.drawable.btn_default)
                    setOnClickListener { stopFloating() }
                }
                addView(btnClose)
            }
            addView(topBar)

            // 弹性空间
            val space = View(context).apply {
                layoutParams = LinearLayout.LayoutParams(
                    0,
                    0,
                    1f
                )
            }
            addView(space)

            // 底部控制栏
            val bottomBar = LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                )

                // 后退10秒
                val btnBack = ImageView(context).apply {
                    setImageResource(android.R.drawable.ic_media_previous)
                    setColorFilter(0xFFFFFFFF.toInt())
                    setPadding(16, 16, 16, 16)
                    setOnClickListener {
                        val pos = mediaPlayer?.currentPosition ?: 0
                        seekTo((pos - 10000).coerceAtLeast(0))
                    }
                }
                addView(btnBack)

                // 播放/暂停
                btnPlay = ImageView(context).apply {
                    setImageResource(android.R.drawable.ic_media_pause)
                    setColorFilter(0xFFFFFFFF.toInt())
                    setPadding(20, 20, 20, 20)
                    setOnClickListener { togglePlayPause() }
                }
                addView(btnPlay)

                // 前进10秒
                val btnForward = ImageView(context).apply {
                    setImageResource(android.R.drawable.ic_media_ff)
                    setColorFilter(0xFFFFFFFF.toInt())
                    setPadding(16, 16, 16, 16)
                    setOnClickListener {
                        val pos = mediaPlayer?.currentPosition ?: 0
                        val duration = mediaPlayer?.duration ?: 0
                        seekTo((pos + 10000).coerceAtMost(duration))
                    }
                }
                addView(btnForward)
            }
            addView(bottomBar)

            // 进度条
            seekBar = SeekBar(context).apply {
                max = 100
                progress = 0
                setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                    override fun onProgressChanged(seekBar: SeekBar?, progress: Int, fromUser: Boolean) {
                        if (fromUser && mediaPlayer != null) {
                            val duration = mediaPlayer!!.duration
                            if (duration > 0) {
                                val pos = (duration * progress / 100).toLong().toInt()
                                // 不在这里 seek，只在停止拖动时 seek
                            }
                        }
                    }
                    override fun onStartTrackingTouch(seekBar: SeekBar?) {}
                    override fun onStopTrackingTouch(seekBar: SeekBar?) {
                        if (mediaPlayer != null) {
                            val duration = mediaPlayer!!.duration
                            if (duration > 0) {
                                val pos = (duration * seekBar!!.progress / 100).toLong().toInt()
                                seekTo(pos)
                            }
                        }
                    }
                })
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                ).also { it.topMargin = 4 }
            }
            addView(seekBar)

            // 时间显示 (XX:XX:XX / XX:XX:XX)
            timeText = TextView(context).apply {
                textSize = 11f
                setTextColor(0xFFFFFFFF.toInt())
                text = "00:00:00 / 00:00:00"
                gravity = Gravity.CENTER
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                ).also { it.topMargin = 2; it.bottomMargin = 2 }
            }
            addView(timeText)
        }
    }

    /**
     * 初始化并播放视频
     */
    private fun initAndPlayVideo(videoPath: String) {
        try {
            mediaPlayer = MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .build()
                )
                setDataSource(videoPath)
                prepareAsync()
                setOnPreparedListener { mp ->
                    mp.start()
                    updatePlayButton(true)
                    startProgressUpdate()
                    // 更新进度条最大值
                    seekBar?.max = 100
                }
                setOnCompletionListener {
                    // 循环播放
                    it.start()
                    updatePlayButton(true)
                }
                setOnErrorListener { _, _, _ ->
                    false
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    /**
     * 定时更新进度条
     */
    private fun startProgressUpdate() {
        val handler = android.os.Handler(mainLooper)
        object : Runnable {
            override fun run() {
                if (mediaPlayer == null || !mediaPlayer!!.isPlaying) return
                val pos = mediaPlayer!!.currentPosition
                val duration = mediaPlayer!!.duration
                if (duration > 0) {
                    seekBar?.progress = (pos * 100 / duration)
                    // 更新时间显示
                    timeText?.text = "${formatTime(pos)} / ${formatTime(duration)}"
                }
                handler.postDelayed(this, 500)
            }
        }.run()
    }

    /**
     * 格式化毫秒为 HH:MM:SS
     */
    private fun formatTime(ms: Int): String {
        val totalSeconds = ms / 1000
        val hours = totalSeconds / 3600
        val minutes = (totalSeconds % 3600) / 60
        val seconds = totalSeconds % 60
        return if (hours > 0)
            String.format("%02d:%02d:%02d", hours, minutes, seconds)
        else
            String.format("%02d:%02d", minutes, seconds)
    }

    // ====== 操作方法 =======

    private fun playVideo() {
        mediaPlayer?.start()
        updatePlayButton(true)
    }

    private fun pauseVideo() {
        mediaPlayer?.pause()
        updatePlayButton(false)
    }

    private fun togglePlayPause() {
        if (mediaPlayer?.isPlaying == true) {
            pauseVideo()
        } else {
            playVideo()
        }
        resetHideControlsTimer()
    }

    private fun seekTo(positionMs: Int) {
        mediaPlayer?.seekTo(positionMs)
    }

    private fun updatePlayButton(isPlaying: Boolean) {
        btnPlay?.setImageResource(
            if (isPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play
        )
    }

    // ====== 显示/隐藏控件 ======

    private fun toggleControls() {
        if (controlsVisible) {
            hideControls()
        } else {
            showControls()
        }
    }

    private fun showControls() {
        controlOverlay?.visibility = View.VISIBLE
        controlsVisible = true
        resetHideControlsTimer()
    }

    private fun hideControls() {
        controlOverlay?.visibility = View.GONE
        controlsVisible = false
    }

    private fun resetHideControlsTimer() {
        controlOverlay?.removeCallbacks(hideControlsRunnable)
        controlOverlay?.postDelayed(hideControlsRunnable, 4000)
    }

    // ====== 边缘吸附 ======

    private fun snapToEdge() {
        val screenWidth = getScreenWidth()
        val centerX = params!!.x + windowWidth / 2

        if (centerX < screenWidth / 2) {
            // 吸附到左边
            params!!.x = 0
        } else {
            // 吸附到右边
            params!!.x = screenWidth - windowWidth
        }
        windowManager?.updateViewLayout(floatingView, params)
    }

    // ====== 关闭和清理 ======

    /**
     * 切换到新的视频（不关闭悬浮窗）
     */
    private fun switchToVideo(videoPath: String, title: String) {
        // 保存当前窗口位置和大小
        val savedX = params?.x ?: 0
        val savedY = params?.y ?: 0
        val savedWidth = windowWidth
        val savedHeight = windowHeight

        // 释放旧的播放器
        releaseMediaPlayer()

        // 重新初始化并播放新视频
        try {
            mediaPlayer = MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .build()
                )
                setDataSource(videoPath)
                prepareAsync()
                setOnPreparedListener { mp ->
                    mp.start()
                    updatePlayButton(true)
                    startProgressUpdate()
                    seekBar?.max = 100
                }
                setOnCompletionListener {
                    it.start()
                    updatePlayButton(true)
                }
                setOnErrorListener { _, _, _ ->
                    false
                }
            }

            // 更新当前视频路径信息
            windowWidth = savedWidth
            windowHeight = savedHeight

            // 更新通知
            updateNotification("正在播放: $title")
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    /**
     * 更新前台通知内容
     */
    private fun updateNotification(contentText: String) {
        try {
            val notificationManager = getSystemService(NotificationManager::class.java)
            notificationManager.notify(NOTIFICATION_ID, buildNotification(contentText))
        } catch (_: Exception) {}
    }

    private fun closeAndReturnToApp() {
        // 发送消息给 Flutter 层
        try {
            val intent = Intent("com.bilinico.download_91.FLOATING_CLOSED")
            sendBroadcast(intent)
        } catch (_: Exception) {}

        stopFloating()
    }

    private fun stopFloating() {
        releaseMediaPlayer()
        try {
            if (floatingView != null && floatingView?.windowToken != null) {
                windowManager?.removeView(floatingView)
            }
        } catch (_: Exception) {}

        floatingView = null
        surfaceView = null
        controlOverlay = null
        stopSelf()
    }

    private fun releaseMediaPlayer() {
        try {
            mediaPlayer?.stop()
            mediaPlayer?.release()
        } catch (_: Exception) {}
        mediaPlayer = null
    }

    private fun cleanup() {
        releaseMediaPlayer()
        try {
            if (floatingView != null && floatingView?.isAttachedToWindow == true) {
                windowManager?.removeView(floatingView)
            }
        } catch (_: Exception) {}
        floatingView = null
        instance = null
    }

    // ====== 工具方法 ======

    private fun getScreenWidth(): Int {
        return resources.displayMetrics.widthPixels.coerceAtLeast(1080)
    }

    private fun getScreenHeight(): Int {
        return resources.displayMetrics.heightPixels.coerceAtLeast(1920)
    }

    /**
     * 基于视频原始分辨率，按屏幕上限做等比缩放
     * 视频分辨率优先，最大不超过屏幕宽 85% / 高 70%，最小 480x270
     * 默认初始大小为屏幕宽度的60%
     */
    private fun resolveVideoSize(videoPath: String) {
        try {
            val retriever = MediaMetadataRetriever()
            retriever.setDataSource(videoPath)
            val videoWidth = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toInt() ?: 0
            val videoHeight = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toInt() ?: 0
            retriever.release()

            if (videoWidth > 0 && videoHeight > 0) {
                val maxWidth = (getScreenWidth() * MAX_WIDTH_RATIO).toInt()
                val maxHeight = (getScreenHeight() * MAX_HEIGHT_RATIO).toInt()

                // 等比缩放：以宽度为主轴适配屏幕上限
                var w = videoWidth
                var h = videoHeight

                if (w > maxWidth) {
                    val ratio = maxWidth.toFloat() / w
                    w = maxWidth
                    h = (h * ratio).toInt()
                }
                if (h > maxHeight) {
                    val ratio = maxHeight.toFloat() / h
                    h = maxHeight
                    w = (w * ratio).toInt()
                }
                // 最小尺寸保护（适配高分辨率屏幕，2K+）
                w = w.coerceAtLeast(MIN_WIDTH)
                h = h.coerceAtLeast(MIN_HEIGHT)

                windowWidth = w
                windowHeight = h
            } else {
                // 无法获取视频分辨率时，使用屏幕宽度的60%作为默认大小
                val defaultWidth = (getScreenWidth() * INITIAL_WIDTH_RATIO).toInt()
                windowWidth = defaultWidth.coerceAtLeast(MIN_WIDTH)
                windowHeight = (windowWidth * 9 / 16).coerceAtLeast(MIN_HEIGHT)
            }
        } catch (_: Exception) {
            // 获取失败时使用屏幕宽度的60%作为默认大小
            val defaultWidth = (getScreenWidth() * INITIAL_WIDTH_RATIO).toInt()
            windowWidth = defaultWidth.coerceAtLeast(MIN_WIDTH)
            windowHeight = (windowWidth * 9 / 16).coerceAtLeast(MIN_HEIGHT)
        }
    }
}
