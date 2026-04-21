package com.example.download_91

import android.app.Activity
import android.content.Context
import android.view.WindowManager
import io.flutter.plugin.common.MethodChannel

class BrightnessPlugin(private val activity: Activity) {
    companion object {
        const val CHANNEL_NAME = "com.example.download_91/brightness"
    }

    private var savedBrightness: Float? = null

    fun handleMethodCall(call: MethodChannel.MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getBrightness" -> {
                try {
                    val window = activity.window
                    val brightness = window.attributes.screenBrightness
                    result.success(brightness)
                } catch (e: Exception) {
                    result.error("ERROR", e.message, null)
                }
            }
            "setBrightness" -> {
                try {
                    val brightness = call.argument<Double>("brightness")?.toFloat() ?: 0.5f
                    val window = activity.window
                    val params = window.attributes
                    params.screenBrightness = brightness.coerceIn(0f, 1f)
                    window.attributes = params
                    result.success(null)
                } catch (e: Exception) {
                    result.error("ERROR", e.message, null)
                }
            }
            "resetBrightness" -> {
                try {
                    val window = activity.window
                    val params = window.attributes
                    // 恢复系统默认亮度
                    params.screenBrightness = WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                    window.attributes = params
                    result.success(null)
                } catch (e: Exception) {
                    result.error("ERROR", e.message, null)
                }
            }
            "saveBrightness" -> {
                try {
                    val window = activity.window
                    savedBrightness = window.attributes.screenBrightness
                    result.success(null)
                } catch (e: Exception) {
                    result.error("ERROR", e.message, null)
                }
            }
            "restoreBrightness" -> {
                try {
                    val brightness = savedBrightness ?: WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                    val window = activity.window
                    val params = window.attributes
                    params.screenBrightness = brightness
                    window.attributes = params
                    result.success(null)
                } catch (e: Exception) {
                    result.error("ERROR", e.message, null)
                }
            }
            else -> result.notImplemented()
        }
    }
}
