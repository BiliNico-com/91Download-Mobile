package com.bilinico.download_91

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val FLOATING_CHANNEL = "com.bilinico.download_91/floating_video"
    private val OPEN_DIR_CHANNEL = "com.bilinico.download_91/open_directory"
    
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        // 注册 PiP 插件
        PipPlugin.registerWith(flutterEngine.dartExecutor.binaryMessenger, this)
        
        // 注册"打开下载目录"通道
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, OPEN_DIR_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "openDirectory" -> {
                    val path = call.argument<String>("path") ?: ""
                    result.success(openDirectory(path))
                }
                else -> result.notImplemented()
            }
        }
        
        // 注册悬浮窗通信通道
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FLOATING_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "openSettings" -> {
                    openOverlaySettings()
                    result.success(true)
                }
                "getOverlayPermission" -> {
                    result.success(canDrawOverlays())
                }
                "requestOverlayPermission" -> {
                    requestOverlayPermission()
                    result.success(true)
                }
                "startFloating" -> {
                    val path = call.argument<String>("path") ?: ""
                    val title = call.argument<String>("title") ?: ""
                    val width = call.argument<Int>("width") ?: 400
                    val height = call.argument<Int>("height") ?: 250
                    startNativeFloating(path, title, width, height)
                    result.success(true)
                }
                "stopFloating" -> {
                    stopNativeFloating()
                    result.success(true)
                }
                "pauseVideo" -> {
                    sendCommandToService(FloatingWindowService.ACTION_PAUSE)
                    result.success(true)
                }
                "playVideo" -> {
                    sendCommandToService(FloatingWindowService.ACTION_PLAY)
                    result.success(true)
                }
                "seekTo" -> {
                    val pos = call.argument<Int>("position") ?: 0
                    val intent = Intent(this, FloatingWindowService::class.java).apply {
                        action = FloatingWindowService.ACTION_SEEK
                        putExtra(FloatingWindowService.EXTRA_SEEK_POS, pos)
                    }
                    startService(intent)
                    result.success(true)
                }
                "switchVideo" -> {
                    val path = call.argument<String>("path") ?: ""
                    val title = call.argument<String>("title") ?: ""
                    switchFloatingVideo(path, title)
                    result.success(true)
                }
                "isFloatingRunning" -> {
                    result.success(FloatingWindowService.isRunning())
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * 启动原生悬浮窗服务
     */
    private fun startNativeFloating(path: String, title: String, width: Int, height: Int) {
        val intent = Intent(this, FloatingWindowService::class.java).apply {
            action = FloatingWindowService.ACTION_START
            putExtra(FloatingWindowService.EXTRA_VIDEO_PATH, path)
            putExtra(FloatingWindowService.EXTRA_TITLE, title)
            putExtra(FloatingWindowService.EXTRA_WIDTH, width)
            putExtra(FloatingWindowService.EXTRA_HEIGHT, height)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            @Suppress("DEPRECATION")
            startService(intent)
        }
    }

    /**
     * 停止原生悬浮窗服务
     */
    private fun stopNativeFloating() {
        val intent = Intent(this, FloatingWindowService::class.java).apply {
            action = FloatingWindowService.ACTION_STOP
        }
        startService(intent)
    }

    /**
     * 切换悬浮窗视频
     */
    private fun switchFloatingVideo(path: String, title: String) {
        val intent = Intent(this, FloatingWindowService::class.java).apply {
            action = FloatingWindowService.ACTION_SWITCH_VIDEO
            putExtra(FloatingWindowService.EXTRA_VIDEO_PATH, path)
            putExtra(FloatingWindowService.EXTRA_TITLE, title)
        }
        startService(intent)
    }

    /**
     * 发送命令到悬浮窗服务
     */
    private fun sendCommandToService(action: String) {
        val intent = Intent(this, FloatingWindowService::class.java).apply {
            this.action = action
        }
        startService(intent)
    }
    
    /**
     * 检查是否有悬浮窗权限
     */
    private fun canDrawOverlays(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Settings.canDrawOverlays(this)
        } else {
            true
        }
    }
    
    /**
     * 请求悬浮窗权限
     */
    private fun requestOverlayPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val intent = Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:$packageName")
            )
            intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
            startActivity(intent)
        }
    }
    
    /**
     * 打开悬浮窗设置页面
     */
    private fun openOverlaySettings() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val intent = Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:$packageName")
            )
            intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
            startActivity(intent)
        }
    }
    
    /**
     * 在系统文件管理器中打开指定目录
     *
     * 要点：
     * - Android 7.0+ 用 file:// 会抛 FileUriExposedException，不能直传路径。
     * - 想让文件管理器**定位到具体目录**，需要用 DocumentsContract 构造
     *   externalstorage 的 document URI：documentId 形如
     *   "primary:Download/91Download"。
     *
     * 按优先级尝试，返回 true 表示成功调起了界面。
     */
    private fun openDirectory(path: String): Boolean {
        if (path.isEmpty()) return false

        val dir = java.io.File(path)
        if (!dir.exists()) {
            dir.mkdirs()
        }

        // 绝对路径 -> DocumentsUI 的 documentId
        //   /storage/emulated/0/Download/91Download -> "primary:Download/91Download"
        val documentId = try {
            val rel = path
                .removePrefix("/storage/emulated/0/")
                .removePrefix("/sdcard/")
                .trim('/')
            if (rel.isEmpty()) "primary:" else "primary:$rel"
        } catch (_: Exception) {
            "primary:"
        }

        // 方式 1：DocumentsUI 精确定位到该目录
        try {
            val uri = android.provider.DocumentsContract.buildDocumentUri(
                "com.android.externalstorage.documents",
                documentId
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "vnd.android.document/directory")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            return true
        } catch (_: Exception) {
            // 继续尝试下一种方式
        }

        // 方式 2：打开主存储根目录，让用户自行导航
        try {
            val uri = android.provider.DocumentsContract.buildRootUri(
                "com.android.externalstorage.documents",
                "primary"
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "vnd.android.document/root")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            return true
        } catch (_: Exception) {
            // 继续尝试下一种方式
        }

        // 方式 3：无 DocumentsUI 的设备，交给系统选择器兜底
        try {
            val intent = Intent(Intent.ACTION_GET_CONTENT).apply {
                setType("*/*")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            return true
        } catch (_: Exception) {
            return false
        }
    }
    
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // 用户按 Home 键时，可以通知 Flutter 进入 PiP 模式
        // 由 Flutter 端处理
    }
}
