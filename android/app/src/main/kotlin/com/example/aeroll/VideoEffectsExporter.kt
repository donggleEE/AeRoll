package com.example.aeroll

import android.content.Context
import android.graphics.Matrix
import android.media.MediaMetadataRetriever
import android.os.Build
import android.media.MediaFormat
import android.opengl.GLES20
import androidx.media3.common.VideoFrameProcessingException
import androidx.media3.common.util.GlProgram
import androidx.media3.common.util.GlUtil
import androidx.media3.effect.BaseGlShaderProgram
import androidx.media3.effect.GlEffect
import androidx.media3.effect.DefaultVideoFrameProcessor
import android.net.Uri
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.MatrixTransformation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

@androidx.annotation.OptIn(UnstableApi::class)
class VideoEffectsExporter(private val context: Context) {
    private var transformer: Transformer? = null
    private var pending: MethodChannel.Result? = null
    private var output: File? = null

    fun export(call: MethodCall, result: MethodChannel.Result) {
        if (pending != null) {
            result.error("video_export_busy", "이미 영상 처리 중입니다.", null)
            return
        }
        try {
            val input = File(requireNotNull(call.argument<String>("inputPath"))).canonicalFile
            val target = File(requireNotNull(call.argument<String>("outputPath"))).canonicalFile
            require(input.isFile && input.length() > 0 && input != target && !target.exists())
            val frames = call.argument<List<Map<String, Any>>>("zoomKeyframes").orEmpty()
                .map { frame ->
                    val time = (frame["timeMs"] as Number).toLong()
                    val scale = (frame["digitalScale"] as Number).toFloat()
                    require(time >= 0 && scale.isFinite() && scale >= 1f)
                    time * 1000L to scale
                }.sortedBy { it.first }
            val effects = mutableListOf<Effect>()
            effects.add(object : MatrixTransformation {
                override fun configure(inputWidth: Int, inputHeight: Int) = Size(inputWidth, inputHeight)
                override fun getMatrix(presentationTimeUs: Long): Matrix {
                    var low = 0
                    var high = frames.size
                    while (low < high) {
                        val mid = (low + high) ushr 1
                        if (frames[mid].first <= presentationTimeUs) low = mid + 1 else high = mid
                    }
                    val scale = if (low == 0) 1f else frames[low - 1].second
                    return Matrix().apply { setScale(scale, scale) }
                }
            })
            val transform = call.argument<Map<String, Any>>("rgbTransform")
            if (transform != null) {
                val slope = (transform["slope"] as Number).toDouble()
                val offsets = (transform["offsets"] as List<*>).map { (it as Number).toDouble() }
                val intensity = (transform["intensity"] as? Number)?.toDouble() ?: 1.0
                require(slope.isFinite() && offsets.size == 3 && offsets.all { it.isFinite() } &&
                    intensity.isFinite() && intensity in 0.0..1.0)
                if (Build.VERSION.SDK_INT >= 30) {
                    val metadata = MediaMetadataRetriever()
                    try {
                        metadata.setDataSource(input.path)
                        val transfer = metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_COLOR_TRANSFER)?.toInt()
                        require(transfer != MediaFormat.COLOR_TRANSFER_ST2084 && transfer != MediaFormat.COLOR_TRANSFER_HLG) {
                            "HDR 영상의 RGB 필터 처리는 지원하지 않습니다. SDR로 촬영해 주세요."
                        }
                    } finally { metadata.release() }
                }
                effects.add(GlEffect { _, useHdr ->
                    require(!useHdr) { "HDR 영상의 RGB 필터 처리는 지원하지 않습니다." }
                    FilmRgbShader(slope.toFloat(), offsets.map { it.toFloat() }.toFloatArray(), intensity.toFloat())
                })
            }
            target.parentFile?.mkdirs()
            output = target
            pending = result
            val worker = Transformer.Builder(context)
                // Media3 1.9.2 SDR 전기 RGB를 명시한다. 선형광으로 필터를 계산하지 않는다.
                .setVideoFrameProcessorFactory(DefaultVideoFrameProcessor.Factory.Builder()
                    .setSdrWorkingColorSpace(DefaultVideoFrameProcessor.WORKING_COLOR_SPACE_DEFAULT).build())
                .setVideoMimeType(MimeTypes.VIDEO_H264)
                .setAudioMimeType(MimeTypes.AUDIO_AAC)
                .setEncoderFactory(DefaultEncoderFactory.Builder(context).setEnableFallback(true).build())
                .addListener(object : Transformer.Listener {
                    override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                        if (target.isFile && target.length() > 0) finish(null)
                        else finish("출력 영상이 비어 있습니다.")
                    }
                    override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) {
                        finish(exportException.message ?: "영상 처리에 실패했습니다.")
                    }
                }).build()
            transformer = worker
            worker.start(EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(input)))
                .setEffects(Effects(emptyList(), effects)).build(), target.path)
        } catch (error: Exception) {
            if (pending != null) {
                transformer?.cancel()
                finish(error.message ?: "영상 처리에 실패했습니다.")
            }
            else {
                result.error("video_export_failed", error.message, null)
            }
        }
    }

    private fun finish(error: String?) {
        val callback = pending ?: return
        pending = null
        transformer = null
        val target = output
        output = null
        if (error == null) callback.success(target!!.path)
        else {
            target?.delete()
            callback.error("video_export_failed", error, null)
        }
    }

    fun close() {
        transformer?.cancel()
        finish("화면이 종료되어 영상 처리가 취소되었습니다.")
    }
}

/** Dart가 보낸 RGB 식만 실행하며 플랫폼별 필터 상수를 중복 보관하지 않는다. */
@androidx.annotation.OptIn(UnstableApi::class)
private class FilmRgbShader(slope: Float, offsets: FloatArray, intensity: Float) : BaseGlShaderProgram(false, 1) {
    private val program = GlProgram(
        """
        attribute vec4 aPosition;
        varying vec2 vUv;
        void main() { gl_Position = aPosition; vUv = aPosition.xy * 0.5 + 0.5; }
        """.trimIndent(),
        """
        precision highp float;
        uniform sampler2D uTexSampler;
        uniform float uSlope;
        uniform vec3 uOffsets;
        uniform float uIntensity;
        varying vec2 vUv;
        void main() {
            vec4 pixel = texture2D(uTexSampler, vUv);
            // 영상 디코더 입력은 불투명 RGB이다. 알파는 그대로 전달한다.
            vec3 rgb = clamp(pixel.rgb * uSlope + uOffsets, 0.0, 1.0);
            rgb = mix(pixel.rgb, rgb, uIntensity);
            rgb = floor(rgb * 255.0 + 0.5) / 255.0;
            gl_FragColor = vec4(rgb, pixel.a);
        }
        """.trimIndent()
    ).apply {
        setBufferAttribute("aPosition", GlUtil.getNormalizedCoordinateBounds(), 4)
        setFloatUniform("uSlope", slope)
        setFloatsUniform("uOffsets", offsets)
        setFloatUniform("uIntensity", intensity)
    }

    override fun configure(inputWidth: Int, inputHeight: Int) = Size(inputWidth, inputHeight)

    override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
        try {
            program.use()
            program.setSamplerTexIdUniform("uTexSampler", inputTexId, 0)
            program.bindAttributesAndUniforms()
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
            GlUtil.checkGlError()
        } catch (error: GlUtil.GlException) {
            throw VideoFrameProcessingException(error, presentationTimeUs)
        }
    }

    override fun release() {
        super.release()
        try { program.delete() }
        catch (error: GlUtil.GlException) { throw VideoFrameProcessingException(error) }
    }
}
