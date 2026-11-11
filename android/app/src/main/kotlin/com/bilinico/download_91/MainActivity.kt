package com.bilinico.download_91

import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.text.TextUtils
import java.net.Inet4Address
import java.net.NetworkInterface
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val FLOATING_CHANNEL = "com.bilinico.download_91/floating_video"
    private val OPEN_DIR_CHANNEL = "com.bilinico.download_91/open_directory"
    private val BRIGHTNESS_CHANNEL = "com.bilinico.download_91/brightness"
    private val NETWORK_CHANNEL = "com.bilinico.download_91/network_info"

    /** 进入播放页前的窗口亮度（-1f = 跟随系统），用于退出时还原 */
    private var savedWindowBrightness: Float = -1f
    private var hasSavedWindowBrightness = false
    
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        // 注册 PiP 插件
        PipPlugin.registerWith(flutterEngine.dartExecutor.binaryMessenger, this)
        
        // 注册播放器亮度通道（仅调整本 App 窗口亮度，不改系统设置）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BRIGHTNESS_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getBrightness" -> {
                    result.success(currentWindowBrightness())
                }
                "setBrightness" -> {
                    val value = (call.argument<Double>("brightness") ?: 0.5).toFloat()
                    setWindowBrightness(value)
                    result.success(true)
                }
                "saveBrightness" -> {
                    // 仅在首次进入时记录，避免同一会话内反复覆盖
                    if (!hasSavedWindowBrightness) {
                        savedWindowBrightness = window?.attributes?.screenBrightness ?: -1f
                        hasSavedWindowBrightness = true
                    }
                    result.success(true)
                }
                "restoreBrightness" -> {
                    if (hasSavedWindowBrightness) {
                        setWindowBrightnessRaw(savedWindowBrightness)
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                "resetBrightness" -> {
                    setWindowBrightnessRaw(-1f)
                    hasSavedWindowBrightness = false
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        
        // 注册网络环境通道：日志里记录「走的是 WiFi 还是流量、有没有配代理、本机内网 IP」
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NETWORK_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getNetworkInfo" -> result.success(collectNetworkInfo())
                else -> result.notImplemented()
            }
        }

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
                    // 内置播放器传入的当前进度，悬浮窗据此接着播
                    val initialPos = call.argument<Int>("initialPositionMs") ?: 0
                    startNativeFloating(path, title, width, height, initialPos)
                    result.success(true)
                }
                "getFloatingPosition" -> {
                    // 读取悬浮窗关闭时记录的进度，供内置播放器恢复。
                    // 不清零，可安全重复读取（Flutter 有多条恢复路径）。
                    result.success(FloatingWindowService.getLastPosition())
                }
                "wasFloatingPlaying" -> {
                    result.success(FloatingWindowService.lastWasPlaying)
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
                    startFloatingService(intent)
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
    private fun startNativeFloating(
        path: String,
        title: String,
        width: Int,
        height: Int,
        initialPositionMs: Int = 0
    ) {
        val intent = Intent(this, FloatingWindowService::class.java).apply {
            action = FloatingWindowService.ACTION_START
            putExtra(FloatingWindowService.EXTRA_VIDEO_PATH, path)
            putExtra(FloatingWindowService.EXTRA_TITLE, title)
            putExtra(FloatingWindowService.EXTRA_WIDTH, width)
            putExtra(FloatingWindowService.EXTRA_HEIGHT, height)
            putExtra(FloatingWindowService.EXTRA_INITIAL_POS, initialPositionMs)
        }
        startFloatingService(intent)
    }

    /**
     * 启动悬浮窗服务（统一入口）
     *
     * FloatingWindowService 在 onCreate 里调用 startForeground，
     * Android 8+ 必须走 startForegroundService，否则前台服务无法提权；
     * Android 12+ 在 App 处于后台时用 startService 会直接抛
     * ForegroundServiceStartNotAllowedException 导致闪退。
     */
    private fun startFloatingService(intent: Intent) {
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
        startFloatingService(intent)
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
        startFloatingService(intent)
    }

    /**
     * 发送命令到悬浮窗服务
     */
    private fun sendCommandToService(action: String) {
        val intent = Intent(this, FloatingWindowService::class.java).apply {
            this.action = action
        }
        startFloatingService(intent)
    }
    
    /**
     * 读取当前窗口亮度；-1 表示跟随系统，此时回退到系统亮度值。
     */
    private fun currentWindowBrightness(): Double {
        val attr = window?.attributes ?: return 0.5
        if (attr.screenBrightness >= 0f) return attr.screenBrightness.toDouble()
        // screenBrightness 为 -1 时跟随系统，读取系统设置用于初始化滑块位置
        val system = try {
            Settings.System.getInt(contentResolver, Settings.System.SCREEN_BRIGHTNESS)
        } catch (e: Exception) {
            -1
        }
        return if (system in 0..255) system / 255.0 else 0.5
    }

    /**
     * 设置窗口亮度，入参 0.0 - 1.0。
     * 仅作用于本 App 的窗口，不需要 WRITE_SETTINGS 权限，
     * 退出 App 后系统自动还原，不会污染用户的系统亮度设置。
     */
    private fun setWindowBrightness(value: Float) {
        setWindowBrightnessRaw(value.coerceIn(0.02f, 1f))
    }

    private fun setWindowBrightnessRaw(value: Float) {
        runOnUiThread {
            val attr = window?.attributes ?: return@runOnUiThread
            attr.screenBrightness = value
            window?.attributes = attr
        }
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
    /**
     * 采集当前网络环境，供日志判断「直连还是走了代理」。
     *
     * 说明：App 自身不读系统代理设置（Dio 走的是 Dart 的 HttpClient，
     * 默认不跟随 Android 的 http_proxy），所以这里只报事实：
     *  - transports：WiFi / 移动网络 / 有线 / VPN
     *  - proxyInfo：系统代理（WiFi 高级设置里的代理）或全局代理
     *  - vpnActive：是否有 VPN 类型的网络在跑（代理软件「VPN 模式」）
     *  - localIpv4：本机在该网络下的内网地址，配合日志里的公网 IP 可判断出口
     */
    private fun collectNetworkInfo(): Map<String, Any?> {
        val info = HashMap<String, Any?>()
        info["sdkInt"] = Build.VERSION.SDK_INT
        var wifi = false
        var cellular = false
        var ethernet = false
        var vpn = false
        var validated = false
        var metered: Boolean? = null
        var httpProxy: String? = null
        var localIpv4: String? = null

        try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            if (cm != null) {
                val active = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) cm.activeNetwork else null
                val caps = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && active != null)
                    cm.getNetworkCapabilities(active) else null
                if (caps != null) {
                    wifi = caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
                    cellular = caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)
                    ethernet = caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
                    vpn = caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        validated = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
                    }
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    try {
                        metered = cm.isActiveNetworkMetered
                    } catch (_: Exception) {
                    }
                }
                // 任何一条网络带 VPN 传输都算，代理软件常见就是建一条 VPN
                try {
                    for (n in cm.allNetworks) {
                        val c = cm.getNetworkCapabilities(n) ?: continue
                        if (c.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) {
                            vpn = true
                        }
                    }
                } catch (_: Exception) {
                }
            }
        } catch (_: Exception) {
        }

        // 系统代理：AndroidManifest 里没开 usesCleartextTraffic 之外的限制，
        // getDefaultProxy 在 4.0+ 可直接读取 WiFi 高级代理配置。
        try {
            val proxy = java.net.ProxySelector.getDefault()?.select(java.net.URI("https://example.com"))
            val first = proxy?.firstOrNull()
            if (first != null && first != java.net.Proxy.NO_PROXY) {
                val addr = first.address()
                if (addr is java.net.InetSocketAddress && addr.port > 0) {
                    httpProxy = addr.hostString + ":" + addr.port
                }
            }
        } catch (_: Exception) {
        }
        if (httpProxy == null) {
            try {
                val host = System.getProperty("http.proxyHost")
                val port = System.getProperty("http.proxyPort")
                if (!TextUtils.isEmpty(host)) {
                    httpProxy = host + ":" + (port ?: "?")
                }
            } catch (_: Exception) {
            }
        }

        localIpv4 = findLocalIpv4()

        info["wifi"] = wifi
        info["cellular"] = cellular
        info["ethernet"] = ethernet
        info["vpn"] = vpn
        info["validated"] = validated
        info["metered"] = metered
        info["httpProxy"] = httpProxy
        info["localIpv4"] = localIpv4
        return info
    }

    /** 本机在当前网络下的 IPv4 内网地址（去掉回环） */
    private fun findLocalIpv4(): String? {
        try {
            for (nif in NetworkInterface.getNetworkInterfaces() ?: return null) {
                if (!nif.isUp || nif.isLoopback) continue
                for (addr in nif.inetAddresses) {
                    if (addr is Inet4Address && !addr.isLoopbackAddress && !addr.isLinkLocalAddress) {
                        return addr.hostAddress
                    }
                }
            }
        } catch (_: Exception) {
        }
        return null
    }

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
