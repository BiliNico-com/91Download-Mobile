package com.example.download_91

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private lateinit var brightnessPlugin: BrightnessPlugin

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        brightnessPlugin = BrightnessPlugin(this)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BrightnessPlugin.CHANNEL_NAME)
            .setMethodCallHandler { call, result ->
                brightnessPlugin.handleMethodCall(call, result)
            }
    }
}
