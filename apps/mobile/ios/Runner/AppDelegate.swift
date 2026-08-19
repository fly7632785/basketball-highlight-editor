import Flutter
import UIKit
import AVFoundation
import Photos
import Foundation

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
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
    progressChannel.setStreamHandler(AnalysisProgressStreamHandler())
    analysisChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "analyzeVideo":
        result(FlutterError(code: "NATIVE_RUNTIME_UNAVAILABLE", message: "当前 iOS 包尚未包含 Rust/ONNX Runtime 原生库", details: nil))
      case "cancelAnalysis":
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
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    nil
  }
}
