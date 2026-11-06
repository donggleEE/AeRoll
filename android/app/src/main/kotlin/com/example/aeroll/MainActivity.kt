package com.example.aeroll

import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var exporter: VideoEffectsExporter? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val worker = VideoEffectsExporter(this)
        exporter = worker
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aeroll/video_effects")
            .setMethodCallHandler { call, result ->
                if (call.method == "exportVideo") worker.export(call, result)
                else result.notImplemented()
            }
        // 플래시를 켜 보지 않고 선택한 실제 카메라의 발광 장치 지원을 조회한다.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aeroll/camera_capabilities")
            .setMethodCallHandler { call, result ->
                if (call.method != "hasFlash") {
                    result.notImplemented()
                } else {
                    try {
                        val cameraName = requireNotNull(call.argument<String>("cameraName"))
                        val manager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
                        val characteristics = manager.getCameraCharacteristics(cameraName)
                        result.success(characteristics.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true)
                    } catch (error: Exception) {
                        result.error("camera_capabilities_failed", "플래시 지원 정보를 읽지 못했습니다.", null)
                    }
                }
            }
    }

    override fun onDestroy() {
        exporter?.close()
        exporter = null
        super.onDestroy()
    }
}
