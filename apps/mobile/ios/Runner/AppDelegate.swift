import Flutter
import UIKit
import AVFoundation
import Photos
import Foundation
import ImageIO

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let progressStream = AnalysisProgressStreamHandler()
  private var analysisCancelled = false
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let analysisChannel = FlutterMethodChannel(
      name: "com.bhe.bhe/mobile_analysis",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    let progressChannel = FlutterEventChannel(
      name: "com.bhe.bhe/mobile_analysis_progress",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    progressChannel.setStreamHandler(progressStream)
    analysisChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "analyzeVideo":
        self.analyzeVideo(call.arguments as? [String: Any], result: result)
      case "cancelAnalysis":
        self.analysisCancelled = true
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    let channel = FlutterMethodChannel(
      name: "com.bhe.bhe/mobile_media",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "isAvailable":
        result(true)
      case "exportClip":
        self.exportClip(call.arguments as? [String: Any], result: result)
      case "saveToLibrary":
        self.saveToLibrary(call.arguments as? [String: Any], result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func analyzeVideo(_ arguments: [String: Any]?, result: @escaping FlutterResult) {
    guard
      let arguments,
      let videoPath = arguments["videoPath"] as? String,
      let modelPath = arguments["modelPath"] as? String,
      let hoopRoi = arguments["hoopRoi"] as? [String: Any],
      let netRoi = arguments["netRoi"] as? [String: Any],
      let startMs = arguments["startMs"] as? Int,
      let endMs = arguments["endMs"] as? Int,
      endMs > startMs
    else {
      result(FlutterError(code: "INVALID_ARGUMENT", message: "分析参数无效", details: nil))
      return
    }

    analysisCancelled = false
    DispatchQueue.global(qos: .userInitiated).async {
      var session: OpaquePointer?
      let asset = AVAsset(url: URL(fileURLWithPath: videoPath))
      let durationMs = Int(CMTimeGetSeconds(asset.duration) * 1000)
      let fps = max(1.0, min((arguments["fps"] as? Double) ?? 3.0, 10.0))
      let intervalMs = max(1, Int(1000.0 / fps))
      let actualEndMs = min(endMs, durationMs > 0 ? durationMs : endMs)
      let totalFrames = max(1, (actualEndMs - startMs + intervalMs - 1) / intervalMs)
      let beforeMs = (arguments["beforeMs"] as? Int) ?? 6_000
      let afterMs = (arguments["afterMs"] as? Int) ?? 3_000

      do {
        let config: [String: Any] = [
          "model_path": modelPath,
          "hoop_roi": hoopRoi,
          "net_roi": netRoi,
          "duration_ms": durationMs,
          "confidence_threshold": 0.10,
          "clip_before_ms": beforeMs,
          "clip_after_ms": afterMs,
        ]
        let configData = try JSONSerialization.data(withJSONObject: config)
        let configString = String(decoding: configData, as: UTF8.self)
        session = configString.withCString { bhe_runtime_create_session($0) }
        guard let session else {
          throw NSError(domain: "BHERuntime", code: 1, userInfo: [NSLocalizedDescriptionKey: "Rust Runtime 无法加载模型或 ONNX Runtime"])
        }

        self.emitProgress(stage: "prepareProxy", progress: 0.05, processed: 0, total: totalFrames, message: "正在准备本地分析")
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)
        var lastResponse: [String: Any] = ["candidates": []]
        var processed = 0
        var timeMs = startMs
        while timeMs < actualEndMs {
          if self.analysisCancelled { throw CancellationError() }
          let image = try generator.copyCGImage(at: CMTime(value: CMTimeValue(timeMs), timescale: 1000), actualTime: nil)
          // Fast path: extract raw RGBA pixels and send directly to Rust.
          // Eliminates JPEG compress + base64 encode + JSON serialize overhead.
          let responseString = try self.pushRawFrame(session: session, image: image, timeMs: timeMs)
          guard let responseString else { throw NSError(domain: "BHERuntime", code: 2, userInfo: [NSLocalizedDescriptionKey: "Rust Runtime 未返回结果"]) }
          let responseData = Data(bytes: responseString, count: strlen(responseString))
          bhe_runtime_free_string(responseString)
          let value = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
          if let error = value?["error"] as? String { throw NSError(domain: "BHERuntime", code: 3, userInfo: [NSLocalizedDescriptionKey: error]) }
          if let value { lastResponse = value }
          processed += 1
          self.emitProgress(stage: "refineCandidates", progress: 0.05 + Double(processed) / Double(totalFrames) * 0.90, processed: processed, total: totalFrames, message: "正在分析视频帧")
          timeMs += intervalMs
        }
        self.emitProgress(stage: "persistCandidates", progress: 0.98, processed: processed, total: totalFrames, message: "正在写入分析结果")
        DispatchQueue.main.async { result(lastResponse) }
      } catch is CancellationError {
        DispatchQueue.main.async { result(FlutterError(code: "ANALYSIS_CANCELLED", message: "分析已取消", details: nil)) }
      } catch {
        DispatchQueue.main.async { result(FlutterError(code: "ANALYSIS_FAILED", message: error.localizedDescription, details: nil)) }
      }
      if let session { bhe_runtime_free_session(session) }
    }
  }

  /// Extracts raw RGBA pixels from a CGImage and pushes directly to Rust.
  /// This avoids JPEG compression → base64 encoding → JSON serialization.
  private func pushRawFrame(session: OpaquePointer?, image: CGImage, timeMs: Int) throws -> UnsafeMutablePointer<CChar>? {
    let width = image.width
    let height = image.height
    let bytesPerRow = width * 4
    var rgbaData = Data(capacity: bytesPerRow * height)

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
      data: nil, width: width, height: height,
      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue // RGBA
    )
    guard let context else {
      throw NSError(domain: "BHERuntime", code: 4, userInfo: [NSLocalizedDescriptionKey: "无法创建图像上下文"])
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let pixelBuffer = context.data else {
      throw NSError(domain: "BHERuntime", code: 5, userInfo: [NSLocalizedDescriptionKey: "无法读取像素数据"])
    }

    let buffer = pixelBuffer.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
    rgbaData.append(buffer, count: bytesPerRow * height)

    let result = rgbaData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UnsafeMutablePointer<CChar>? in
      guard let base = raw.baseAddress else { return nil }
      return base.assumingMemoryBound(to: UInt8.self).withMemoryRebound(to: Int8.self, capacity: raw.count) { bytes in
        bhe_runtime_push_frame_raw(
          session,
          Int64(timeMs),
          UInt32(width),
          UInt32(height),
          unsafeBitCast(bytes, to: UnsafePointer<UInt8>.self),
          Int64(raw.count)
        )
      }
    }
    return result
  }

  private func emitProgress(stage: String, progress: Double, processed: Int, total: Int, message: String) {
    progressStream.emit([
      "stage": stage,
      "progress": min(max(progress, 0), 1),
      "processedFrames": processed,
      "totalFrames": total,
      "message": message,
    ])
  }

  private func exportClip(_ arguments: [String: Any]?, result: @escaping FlutterResult) {
    guard
      let arguments,
      let inputPath = arguments["inputPath"] as? String,
      let outputPath = arguments["outputPath"] as? String,
      let startMs = arguments["startMs"] as? Int,
      let endMs = arguments["endMs"] as? Int,
      endMs > startMs
    else {
      result(FlutterError(code: "INVALID_ARGUMENT", message: "视频片段参数无效", details: nil))
      return
    }

    let inputURL = URL(fileURLWithPath: inputPath)
    let outputURL = URL(fileURLWithPath: outputPath)
    try? FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try? FileManager.default.removeItem(at: outputURL)

    let asset = AVAsset(url: inputURL)
    guard let exporter = AVAssetExportSession(
      asset: asset,
      presetName: AVAssetExportPresetPassthrough
    ) else {
      result(FlutterError(code: "EXPORT_UNAVAILABLE", message: "当前视频无法导出", details: nil))
      return
    }
    exporter.outputURL = outputURL
    exporter.outputFileType = .mp4
    exporter.timeRange = CMTimeRange(
      start: CMTime(value: CMTimeValue(startMs), timescale: 1000),
      duration: CMTime(value: CMTimeValue(endMs - startMs), timescale: 1000)
    )
    exporter.exportAsynchronously {
      DispatchQueue.main.async {
        switch exporter.status {
        case .completed:
          result(outputPath)
        case .cancelled:
          result(FlutterError(code: "EXPORT_CANCELLED", message: "导出已取消", details: nil))
        default:
          result(FlutterError(code: "EXPORT_FAILED", message: exporter.error?.localizedDescription ?? "导出失败", details: nil))
        }
      }
    }
  }

  private func saveToLibrary(_ arguments: [String: Any]?, result: @escaping FlutterResult) {
    guard let path = arguments?["path"] as? String else {
      result(FlutterError(code: "INVALID_ARGUMENT", message: "媒体路径无效", details: nil))
      return
    }
    let url = URL(fileURLWithPath: path)
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      guard status == .authorized || status == .limited else {
        DispatchQueue.main.async { result(FlutterError(code: "PHOTO_PERMISSION_DENIED", message: "没有保存到相册的权限", details: nil)) }
        return
      }
      PHPhotoLibrary.shared().performChanges({
        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
      }) { success, error in
        DispatchQueue.main.async {
          if success {
            result(nil)
          } else {
            result(FlutterError(code: "PHOTO_SAVE_FAILED", message: error?.localizedDescription ?? "保存到相册失败", details: nil))
          }
        }
      }
    }
  }
}

private final class AnalysisProgressStreamHandler: NSObject, FlutterStreamHandler {
  private var sink: FlutterEventSink?

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  func emit(_ event: [String: Any]) {
    DispatchQueue.main.async { self.sink?(event) }
  }
}
