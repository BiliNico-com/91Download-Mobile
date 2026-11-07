package com.bilinico.download_91

import android.app.Activity
import android.app.PictureInPictureParams
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.util.Rational
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler

class PipPlugin private constructor(
    private val activity: Activity
) : MethodCallHandler {
    
    companion object {
        const val CHANNEL = "com.bilinico.download_91/pip"
        
        fun registerWith(messenger: io.flutter.plugin.common.BinaryMessenger, activity: Activity) {
            val channel = MethodChannel(messenger, CHANNEL)
            channel.setMethodCallHandler(PipPlugin(activity))
        }
    }
    
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "enterPip" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    val aspectRatio = call.argument<Double>("aspectRatio") ?: (16.0 / 9.0)
                    try {
                        // aspectRatio = width/height，例如 16/9 = 1.778
                        // Rational 需要 width 和 height 两个整数
                        val width = (aspectRatio * 100).toInt()
                        val height = 100
                        val params = PictureInPictureParams.Builder()
                            .setAspectRatio(Rational(width, height))
                            .build()
                        val success = activity.enterPictureInPictureMode(params)
                        result.success(success)
                    } catch (e: Exception) {
                        result.error("PIP_ERROR", e.message, null)
                    }
                } else {
                    result.success(false)
                }
            }
            "isPipAvailable" -> {
                result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            }
            "isInPipMode" -> {
                result.success(activity.isInPictureInPictureMode)
            }
            "updatePipParams" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && activity.isInPictureInPictureMode) {
                    val aspectRatio = call.argument<Double>("aspectRatio") ?: 16.0 / 9.0
                    try {
                        // 修复：使用与 enterPip 相同的宽高比转换方式，避免 toInt 截断丢失精度
                        val width = (aspectRatio * 100).toInt()
                        val height = 100
                        val params = PictureInPictureParams.Builder()
                            .setAspectRatio(Rational(width, height))
                            .build()
                        activity.setPictureInPictureParams(params)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("PIP_ERROR", e.message, null)
                    }
                } else {
                    result.success(false)
                }
            }
            else -> result.notImplemented()
        }
    }
}
