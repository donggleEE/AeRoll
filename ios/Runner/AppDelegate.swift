import Flutter
import UIKit
import AVFoundation
import CoreImage

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let videoExporter = VideoEffectsExporter()
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "aeroll/video_effects",
      binaryMessenger: engineBridge.applicationRegistrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "exportVideo" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.videoExporter.export(call, result: result)
    }
    // 선택한 카메라 ID로 실제 플래시 장치를 조회한다. 시험 발광은 하지 않는다.
    let capabilities = FlutterMethodChannel(
      name: "aeroll/camera_capabilities",
      binaryMessenger: engineBridge.applicationRegistrar.messenger())
    capabilities.setMethodCallHandler { call, result in
      guard call.method == "hasFlash" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let args = call.arguments as? [String: Any],
        let cameraName = args["cameraName"] as? String,
        let device = AVCaptureDevice(uniqueID: cameraName) else {
        result(FlutterError(code: "camera_capabilities_failed",
          message: "플래시 지원 정보를 읽지 못했습니다.", details: nil))
        return
      }
      result(device.hasFlash && device.isFlashAvailable)
    }
  }
}

private final class VideoEffectsExporter {
  private var session: AVAssetExportSession?
  private var pending: FlutterResult?
  private var outputURL: URL?

  func export(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard pending == nil else {
      result(FlutterError(code: "video_export_busy", message: "이미 영상 처리 중입니다.", details: nil))
      return
    }
    guard let args = call.arguments as? [String: Any],
      let inputPath = args["inputPath"] as? String,
      let outputPath = args["outputPath"] as? String else {
      result(FlutterError(code: "video_export_failed", message: "영상 경로가 없습니다.", details: nil))
      return
    }
    let input = URL(fileURLWithPath: inputPath).standardizedFileURL
    let output = URL(fileURLWithPath: outputPath).standardizedFileURL
    guard input != output, FileManager.default.fileExists(atPath: input.path),
      !FileManager.default.fileExists(atPath: output.path) else {
      result(FlutterError(code: "video_export_failed", message: "영상 경로를 확인해 주세요.", details: nil))
      return
    }
    let rawFrames = args["zoomKeyframes"] as? [[String: Any]] ?? []
    var frames: [(Double, CGFloat)] = []
    for frame in rawFrames {
      guard let time = frame["timeMs"] as? NSNumber,
        let zoom = frame["digitalScale"] as? NSNumber,
        time.doubleValue.isFinite, time.doubleValue >= 0,
        zoom.doubleValue.isFinite, zoom.doubleValue >= 1 else {
        result(FlutterError(code: "video_export_failed", message: "확대 정보가 올바르지 않습니다.", details: nil))
        return
      }
      frames.append((time.doubleValue / 1000, CGFloat(zoom.doubleValue)))
    }
    frames.sort { $0.0 < $1.0 }
    var rgbSlope: Double?
    var rgbOffsets: [Double] = []
    var rgbIntensity = 1.0
    if let transform = args["rgbTransform"] as? [String: Any] {
      guard let slope = transform["slope"] as? NSNumber,
        let offsets = transform["offsets"] as? [NSNumber], offsets.count == 3,
        slope.doubleValue.isFinite, offsets.allSatisfy({ $0.doubleValue.isFinite }) else {
        result(FlutterError(code: "video_export_failed", message: "RGB 필터 수식이 올바르지 않습니다.", details: nil))
        return
      }
      rgbSlope = slope.doubleValue
      rgbOffsets = offsets.map { $0.doubleValue }
      rgbIntensity = (transform["intensity"] as? NSNumber)?.doubleValue ?? 1.0
      guard rgbIntensity.isFinite, rgbIntensity >= 0, rgbIntensity <= 1 else {
        result(FlutterError(code: "video_export_failed", message: "필터 강도가 올바르지 않습니다.", details: nil))
        return
      }
    }
    let asset = AVURLAsset(url: input)
    if rgbSlope != nil {
      for track in asset.tracks(withMediaType: .video) {
        for description in track.formatDescriptions {
          let extensions = CMFormatDescriptionGetExtensions(description as! CMFormatDescription) as NSDictionary
          let transfer = extensions[kCVImageBufferTransferFunctionKey] as? String
          if transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String ||
            transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String {
            result(FlutterError(code: "video_export_failed", message: "HDR 영상의 RGB 필터 처리는 지원하지 않습니다. SDR로 촬영해 주세요.", details: nil))
            return
          }
        }
      }
    }
    guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality),
      exporter.supportedFileTypes.contains(.mp4) else {
      result(FlutterError(code: "video_export_failed", message: "이 영상의 MP4 처리를 지원하지 않습니다.", details: nil))
      return
    }
    // AVFoundation이 preferredTransform을 적용한 프레임을 전달하므로 별도 회전하지 않는다.
    let keyframes = frames
    // CI의 기본 선형광 대신 감마 인코딩 sRGB에서 RGB 식을 계산한다.
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb])
    let slope = rgbSlope
    let offsets = rgbOffsets
    let intensity = rgbIntensity
    exporter.videoComposition = AVVideoComposition(asset: asset) { request in
      let source = request.sourceImage
      let bounds = source.extent
      let time = CMTimeGetSeconds(request.compositionTime)
      var low = 0
      var high = keyframes.count
      while low < high {
        let mid = (low + high) / 2
        if keyframes[mid].0 <= time { low = mid + 1 } else { high = mid }
      }
      let scale: CGFloat = low == 0 ? 1 : keyframes[low - 1].1
      let transform = CGAffineTransform(translationX: bounds.midX, y: bounds.midY)
        .scaledBy(x: scale, y: scale)
        .translatedBy(x: -bounds.midX, y: -bounds.midY)
      var image = source.transformed(by: transform).cropped(to: bounds)
      if let slope = slope {
        let original = image
        // CIColorMatrix는 unpremultiplied RGB에 적용하며 알파 벡터는 항등이다.
        image = image.applyingFilter("CIColorMatrix", parameters: [
          "inputRVector": CIVector(x: CGFloat(slope), y: 0, z: 0, w: 0),
          "inputGVector": CIVector(x: 0, y: CGFloat(slope), z: 0, w: 0),
          "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(slope), w: 0),
          "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
          "inputBiasVector": CIVector(x: CGFloat(offsets[0]), y: CGFloat(offsets[1]), z: CGFloat(offsets[2]), w: 0)
        ]).applyingFilter("CIColorClamp", parameters: [
          "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
          "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
        ])
        if intensity < 1 {
          // 작업 sRGB에서 클리핑된 필터와 원본을 혼합하며 알파도 보존한다.
          image = original.applyingFilter("CIDissolveTransition", parameters: [
            "inputTargetImage": image,
            "inputTime": intensity
          ]).cropped(to: bounds)
        }
      }
      request.finish(with: image, context: context)
    }
    do {
      try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    } catch {
      result(FlutterError(code: "video_export_failed", message: error.localizedDescription, details: nil))
      return
    }
    pending = result
    session = exporter
    outputURL = output
    exporter.outputURL = output
    exporter.outputFileType = .mp4
    exporter.shouldOptimizeForNetworkUse = false
    exporter.exportAsynchronously { [weak self] in
      DispatchQueue.main.async {
        guard let self = self, let callback = self.pending else { return }
        let attributes = try? FileManager.default.attributesOfItem(atPath: output.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        self.pending = nil
        self.session = nil
        self.outputURL = nil
        if exporter.status == .completed && size > 0 {
          callback(output.path)
        } else {
          try? FileManager.default.removeItem(at: output)
          callback(FlutterError(code: "video_export_failed",
            message: exporter.error?.localizedDescription ?? "영상 처리에 실패했습니다.", details: nil))
        }
      }
    }
  }

  deinit {
    session?.cancelExport()
    if let output = outputURL { try? FileManager.default.removeItem(at: output) }
    pending?(FlutterError(code: "video_export_failed", message: "영상 처리가 취소되었습니다.", details: nil))
  }
}
