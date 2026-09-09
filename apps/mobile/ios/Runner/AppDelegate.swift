import Flutter
import UIKit
import AVFoundation
import Photos
import Foundation
import ImageIO

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private struct HoopObservation {
    let bbox: [Double]
    let confidence: Double
    let timeMs: Int
  }

  private struct StableHoop {
    let bbox: [Double]
    let confidence: Double
    let previewTimeMs: Int
    let samples: Int
    let stability: Double
  }

  private let progressStream = AnalysisProgressStreamHandler()
  private let analysisCancellationLock = NSLock()
  private var analysisCancelled = false
  private var analysisRunning = false
  private let exportLock = NSLock()
  private var activeExporters = [String: AVAssetExportSession]()
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
      case "suggestRoi":
        self.suggestRoi(call.arguments as? [String: Any], result: result)
      case "cancelAnalysis":
        self.setAnalysisCancelled(true)
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
      case "mergeClips":
        self.mergeClips(call.arguments as? [String: Any], result: result)
      case "cancelExport":
        self.cancelExport(call.arguments as? [String: Any], result: result)
      case "saveToLibrary":
        self.saveToLibrary(call.arguments as? [String: Any], result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func suggestRoi(_ arguments: [String: Any]?, result: @escaping FlutterResult) {
    guard
      let arguments,
      let videoPath = arguments["videoPath"] as? String,
      let modelPath = arguments["modelPath"] as? String
    else {
      result(FlutterError(code: "INVALID_ARGUMENT", message: "自动识别参数无效", details: nil))
      return
    }
    let startMs = (arguments["startMs"] as? Int) ?? 0
    let durationHint = (arguments["durationMs"] as? Int) ?? 0
    let sampleFps = max(0.5, min((arguments["sampleFps"] as? Double) ?? 1.0, 2.0))
    let maxSamples = max(2, min((arguments["maxSamples"] as? Int) ?? 12, 12))
    let modelSize = max(320, ((arguments["modelSize"] as? Int) ?? 640) / 32 * 32)

    DispatchQueue.global(qos: .userInitiated).async {
      var session: OpaquePointer?
      let asset = AVAsset(url: URL(fileURLWithPath: videoPath))
      do {
        let duration = Int(CMTimeGetSeconds(asset.duration) * 1000)
        let usableDuration = duration > 0 ? duration : durationHint
        let safeStartMs = max(0, min(startMs, usableDuration))
        let scanDurationMs = durationHint > 0
          ? min(durationHint, 20_000)
          : min(20_000, max(0, usableDuration - safeStartMs))
        let requestedEndMs = min(safeStartMs + scanDurationMs, usableDuration)
        let times = (0..<maxSamples)
          .map { index in safeStartMs + Int(floor(Double(index) * 1000.0 / sampleFps + 0.5)) }
          .filter { $0 < requestedEndMs }
        guard !times.isEmpty else { throw NSError(domain: "BHE", code: 1, userInfo: [NSLocalizedDescriptionKey: "视频没有可采样帧"]) }

        let fullRoi: [String: Any] = ["left": 0.0, "top": 0.0, "right": 1.0, "bottom": 1.0]
        let config: [String: Any] = [
          "model_path": modelPath,
          "hoop_roi": fullRoi,
          "analysis_roi": fullRoi,
          "net_roi": fullRoi,
          "duration_ms": usableDuration,
          "confidence_threshold": 0.05,
          "model_size": modelSize,
          // Auto ROI scans the full frame, matching Python
          // detect_auto_roi.py. Crop scaling is only for ball analysis.
          "crop_scale": 1.0,
        ]
        let configData = try JSONSerialization.data(withJSONObject: config)
        let configString = String(decoding: configData, as: UTF8.self)
        session = configString.withCString { bhe_runtime_create_session($0) }
        guard let session else {
          throw NSError(domain: "BHE", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法创建自动识别会话"])
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        var observations = [HoopObservation]()
        var frameWidth = 1.0
        var frameHeight = 1.0
        for time in times {
          var actualTime = CMTime.invalid
          if let image = try? generator.copyCGImage(
            at: CMTime(value: CMTimeValue(time), timescale: 1000),
            actualTime: &actualTime
          ) {
            frameWidth = Double(image.width)
            frameHeight = Double(image.height)
            guard let responsePointer = try self.pushRawFrame(session: session, image: image, timeMs: time) else { continue }
            let responseData = Data(bytes: responsePointer, count: strlen(responsePointer))
            bhe_runtime_free_string(responsePointer)
            guard
              let response = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let detections = response["detections"] as? [[String: Any]]
            else { continue }
            for detection in detections where (detection["class_id"] as? Int) == 1 {
              guard let x1 = detection["x1"] as? Double,
                    let y1 = detection["y1"] as? Double,
                    let x2 = detection["x2"] as? Double,
                    let y2 = detection["y2"] as? Double else { continue }
              observations.append(HoopObservation(
                bbox: [x1, y1, x2, y2],
                confidence: (detection["confidence"] as? NSNumber)?.doubleValue ?? 0.0,
                timeMs: time
              ))
            }
            if observations.count >= 5 { break }
          }
        }
        guard let stable = self.selectStableHoop(observations, width: frameWidth, height: frameHeight) else {
          throw NSError(domain: "BHE", code: 3, userInfo: [NSLocalizedDescriptionKey: "未识别到稳定的篮筐"])
        }
        let bbox = stable.bbox
        let roi = self.expandedRoi(bbox, width: frameWidth, height: frameHeight)
        let rimRoi = self.physicalRimRoi(bbox, width: frameWidth, height: frameHeight)
        DispatchQueue.main.async {
          result([
            "success": true,
            "roi": roi,
            "rim_roi": rimRoi,
            "hoop_bbox": bbox,
            "samples": stable.samples,
            "stability": stable.stability,
            "preview_time_ms": stable.previewTimeMs,
                            "model_input_size": modelSize,
            "source": "ios_onnx_hoop_model",
          ])
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "AUTO_ROI_FAILED", message: error.localizedDescription, details: nil))
        }
      }
      if let session { bhe_runtime_free_session(session) }
    }
  }

  private func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    if sorted.count % 2 == 0 {
      return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2.0
    }
    return sorted[sorted.count / 2]
  }

  private func selectStableHoop(
    _ observations: [HoopObservation],
    width: Double,
    height: Double
  ) -> StableHoop? {
    guard observations.count >= 2, width > 0, height > 0 else { return nil }
    let radius = max(60.0, width * 0.10)
    var clusters = [[HoopObservation]]()
    for observation in observations {
      let centerX = (observation.bbox[0] + observation.bbox[2]) / 2.0
      let centerY = (observation.bbox[1] + observation.bbox[3]) / 2.0
      var bestIndex: Int?
      var bestDistance = Double.greatestFiniteMagnitude
      for index in clusters.indices {
        let cluster = clusters[index]
        let clusterX = median(cluster.map { ($0.bbox[0] + $0.bbox[2]) / 2.0 })
        let clusterY = median(cluster.map { ($0.bbox[1] + $0.bbox[3]) / 2.0 })
        let distance = hypot(centerX - clusterX, centerY - clusterY)
        if distance <= radius && distance < bestDistance {
          bestIndex = index
          bestDistance = distance
        }
      }
      if let bestIndex {
        clusters[bestIndex].append(observation)
      } else {
        clusters.append([observation])
      }
    }
    let stableClusters = clusters.filter { $0.count >= 2 }
    guard let selected = stableClusters.max(by: { left, right in
      if left.count != right.count { return left.count < right.count }
      let leftConfidence = median(left.map(\.confidence))
      let rightConfidence = median(right.map(\.confidence))
      if leftConfidence != rightConfidence { return leftConfidence < rightConfidence }
      let leftArea = median(left.map { ($0.bbox[2] - $0.bbox[0]) * ($0.bbox[3] - $0.bbox[1]) })
      let rightArea = median(right.map { ($0.bbox[2] - $0.bbox[0]) * ($0.bbox[3] - $0.bbox[1]) })
      return leftArea < rightArea
    }) else { return nil }
    let bbox = (0..<4).map { index in median(selected.map { $0.bbox[index] }) }
    let bestConfidence = selected.max { $0.confidence < $1.confidence }!
    return StableHoop(
      bbox: bbox,
      confidence: median(selected.map(\.confidence)),
      previewTimeMs: bestConfidence.timeMs,
      samples: selected.count,
      stability: Double(selected.count) / Double(observations.count)
    )
  }

  private func expandedRoi(_ bbox: [Double], width: Double, height: Double) -> [String: Double] {
    let boxWidth = max(4.0, bbox[2] - bbox[0])
    let boxHeight = max(4.0, bbox[3] - bbox[1])
    let centerX = (bbox[0] + bbox[2]) / 2.0
    let centerY = (bbox[1] + bbox[3]) / 2.0
    let roiWidth = min(max(boxWidth * 12.0, width * 0.14), width * 0.65)
    let roiHeight = min(max(boxHeight * 20.0, height * 0.28), height * 0.75)
    var topExtent = max(boxHeight * 8.0, roiHeight * 0.44)
    var bottomExtent = max(boxHeight * 12.0, roiHeight * 0.56)
    let totalHeight = topExtent + bottomExtent
    if totalHeight > height * 0.75 {
      let scale = height * 0.75 / totalHeight
      topExtent *= scale
      bottomExtent *= scale
    }
    return [
      "left": max(0.0, min(1.0, (centerX - roiWidth / 2.0) / width)),
      "top": max(0.0, min(1.0, (centerY - topExtent) / height)),
      "right": max(0.0, min(1.0, (centerX + roiWidth / 2.0) / width)),
      "bottom": max(0.0, min(1.0, (centerY + bottomExtent) / height)),
    ]
  }

  private func physicalRimRoi(_ bbox: [Double], width: Double, height: Double) -> [String: Double] {
    let boxWidth = max(1.0, bbox[2] - bbox[0])
    let boxHeight = max(1.0, bbox[3] - bbox[1])
    let centerX = (bbox[0] + bbox[2]) / 2.0
    let centerY = (bbox[1] + bbox[3]) / 2.0
    let rimY = centerY - boxHeight * 0.28
    // Match Python refine's `scale_rim`: shift the plane by 28% and keep 45%
    // of the detector-box height for the corrected rim ROI.
    let rimHeight = boxHeight * 0.45
    return [
      "left": max(0.0, min(1.0, (centerX - boxWidth / 2.0) / width)),
      "top": max(0.0, min(1.0, (rimY - rimHeight / 2.0) / height)),
      "right": max(0.0, min(1.0, (centerX + boxWidth / 2.0) / width)),
      "bottom": max(0.0, min(1.0, (rimY + rimHeight / 2.0) / height)),
    ]
  }

  private func proxyURL(sourcePath: String, startMs: Int, endMs: Int) -> URL {
    let sourceURL = URL(fileURLWithPath: sourcePath)
    let resourceValues = try? sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    let values = "\(sourcePath)|\(resourceValues?.fileSize ?? 0)|\(resourceValues?.contentModificationDate ?? Date.distantPast)|\(startMs)|\(endMs)|640|480|3"
    let key = values.data(using: .utf8)!.map { String(format: "%02x", $0) }.joined()
    let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("bhe/analysis/proxies", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.appendingPathComponent("\(key).mp4")
  }

  private func createOrGetProxy(asset: AVAsset, sourcePath: String, startMs: Int, endMs: Int) throws -> URL {
    let outputURL = proxyURL(sourcePath: sourcePath, startMs: startMs, endMs: endMs)
    let cachedSize = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    if FileManager.default.fileExists(atPath: outputURL.path), cachedSize > 0 {
      return outputURL
    }
    let temporaryURL = outputURL.deletingPathExtension().appendingPathExtension("part.mp4")
    try? FileManager.default.removeItem(at: temporaryURL)
    guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset640x480) else {
      throw NSError(domain: "BHERuntime", code: 20, userInfo: [NSLocalizedDescriptionKey: "无法创建代理视频导出器"])
    }
    exporter.outputURL = temporaryURL
    exporter.outputFileType = .mp4
    exporter.shouldOptimizeForNetworkUse = false
    exporter.timeRange = CMTimeRange(
      start: CMTime(value: CMTimeValue(startMs), timescale: 1000),
      duration: CMTime(value: CMTimeValue(endMs - startMs), timescale: 1000)
    )
    let semaphore = DispatchSemaphore(value: 0)
    exporter.exportAsynchronously { semaphore.signal() }
    semaphore.wait()
    guard exporter.status == .completed else {
      try? FileManager.default.removeItem(at: temporaryURL)
      throw exporter.error ?? NSError(domain: "BHERuntime", code: 21, userInfo: [NSLocalizedDescriptionKey: "代理视频生成失败"])
    }
    try? FileManager.default.removeItem(at: outputURL)
    try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
    return outputURL
  }

  private func hasBallNearHoop(_ value: [String: Any], width: Int, height: Int, hoop: [String: Any]) -> Bool {
    guard let detections = value["detections"] as? [[String: Any]] else { return false }
    let left = ((hoop["left"] as? Double ?? 0) - 0.16) * Double(width)
    let top = ((hoop["top"] as? Double ?? 0) - 0.22) * Double(height)
    let right = ((hoop["right"] as? Double ?? 1) + 0.16) * Double(width)
    let bottom = ((hoop["bottom"] as? Double ?? 1) + 0.22) * Double(height)
    return detections.contains { detection in
      guard (detection["name"] as? String) == "ball",
            let center = detection["center"] as? [Double], center.count >= 2 else { return false }
      return center[0] >= left && center[0] <= right && center[1] >= top && center[1] <= bottom
    }
  }

  private func coarseRoi(_ hoop: [String: Any]) -> [String: Double] {
    let left = max(0.0, min(1.0, (hoop["left"] as? Double ?? 0.0) - 0.20))
    let top = max(0.0, min(1.0, (hoop["top"] as? Double ?? 0.0) - 0.30))
    let right = max(0.0, min(1.0, (hoop["right"] as? Double ?? 1.0) + 0.20))
    let bottom = max(0.0, min(1.0, (hoop["bottom"] as? Double ?? 1.0) + 0.30))
    return ["left": left, "top": top, "right": right, "bottom": bottom]
  }

  private func sampleTimes(startMs: Int, endMs: Int, fps: Double) -> [Int] {
    guard endMs > startMs, fps > 0 else { return [] }
    let count = max(1, Int(ceil(Double(endMs - startMs) * fps / 1000.0 - 1e-9)))
    return (0..<count)
      .map { startMs + Int((Double($0) * 1000.0 / fps).rounded()) }
      .filter { $0 < endMs }
      .reduce(into: [Int]()) { values, time in
        if values.last != time { values.append(time) }
      }
  }

  private func refineTimes(around seeds: [Int], startMs: Int, endMs: Int, fps: Double) -> [Int] {
    return Array(Set(seeds.flatMap { seed in
      sampleTimes(startMs: max(startMs, seed - 4000), endMs: min(endMs, seed + 4000), fps: fps)
    })).sorted()
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

    guard beginAnalysis() else {
      result(FlutterError(code: "ANALYSIS_BUSY", message: "已有分析任务正在运行", details: nil))
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      var session: OpaquePointer?
      defer {
        if let session { bhe_runtime_free_session(session) }
        self.finishAnalysis()
      }
      let asset = AVAsset(url: URL(fileURLWithPath: videoPath))
      let durationMs = Int(CMTimeGetSeconds(asset.duration) * 1000)
      let fps = max(1.0, min((arguments["fps"] as? Double) ?? 10.0, 10.0))
      let confidenceThreshold = max(0.0, min((arguments["confidenceThreshold"] as? Double) ?? 0.10, 1.0))
      let modelSize = max(320, ((arguments["modelSize"] as? Int) ?? 640) / 32 * 32)
      let actualEndMs = min(endMs, durationMs > 0 ? durationMs : endMs)
      let originalSampleTimes = sequence(first: 0, next: { $0 + 1 })
        .map { index in startMs + Int((Double(index) * 1000.0 / fps).rounded()) }
        .prefix(while: { $0 < actualEndMs })
      var sampleTimes = Array(originalSampleTimes)
      var totalFrames = max(1, sampleTimes.count)
      let beforeMs = (arguments["beforeMs"] as? Int) ?? 6_000
      let afterMs = (arguments["afterMs"] as? Int) ?? 3_000
      let cropScale = max(1.0, min((arguments["cropScale"] as? Double) ?? 2.0, 8.0))
      let maxCrossGapMs = max(1, (arguments["maxCrossGapMs"] as? Int) ?? 1_800)
      let dedupeMs = max(0, (arguments["dedupeMs"] as? Int) ?? 2_000)
      let optimizedModelPath = (arguments["optimizedModelPath"] as? String) ?? "\(modelPath).optimized.onnx"
      let executionProvider = (arguments["executionProvider"] as? String) ?? "cpu"

      do {
        if durationMs <= 0 || startMs < 0 || startMs >= durationMs || endMs <= startMs {
          throw NSError(domain: "BHERuntime", code: 9, userInfo: [NSLocalizedDescriptionKey: "分析范围超出视频时长"])
        }
        self.emitProgress(stage: "prepareProxy", progress: 0.05, processed: 0, total: totalFrames, message: "正在生成或复用代理视频")
        let proxy = try self.createOrGetProxy(asset: asset, sourcePath: videoPath, startMs: startMs, endMs: actualEndMs)
        let proxyAsset = AVAsset(url: proxy)
        let proxyDurationMs = Int(CMTimeGetSeconds(proxyAsset.duration) * 1000)
        let coarseTimes = self.sampleTimes(startMs: 0, endMs: proxyDurationMs, fps: 0.5)
        let fullRoi: [String: Any] = ["left": 0.0, "top": 0.0, "right": 1.0, "bottom": 1.0]
        var coarseSession: OpaquePointer?
        let coarseConfig: [String: Any] = [
          "model_path": modelPath,
          "hoop_roi": fullRoi,
          "analysis_roi": self.coarseRoi(hoopRoi),
          "net_roi": fullRoi,
          "confidence_threshold": confidenceThreshold,
          "model_size": 640,
          "input_max_dimension": 320,
          "detection_only": true,
          "execution_provider": executionProvider,
        ]
        let coarseData = try JSONSerialization.data(withJSONObject: coarseConfig)
        let coarseConfigString = String(decoding: coarseData, as: UTF8.self)
        coarseSession = coarseConfigString.withCString { bhe_runtime_create_session($0) }
        guard let coarseHandle = coarseSession else {
          throw NSError(domain: "BHERuntime", code: 22, userInfo: [NSLocalizedDescriptionKey: "无法创建代理粗扫会话"])
        }
        var coarseSeeds = [Int]()
        if let reader = try? self.makeVideoReader(asset: proxyAsset, startMs: 0, endMs: proxyDurationMs),
           let output = reader.outputs.first {
          var coarseIndex = 0
          while let sampleBuffer = output.copyNextSampleBuffer(), coarseIndex < coarseTimes.count {
            if self.isAnalysisCancelled() { throw CancellationError() }
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
            let pts = Int(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1000.0)
            if coarseTimes[coarseIndex] <= pts {
              let coarseTime = coarseTimes[coarseIndex]
              let responseString = try self.pushPixelBuffer(session: coarseHandle, pixelBuffer: imageBuffer, timeMs: coarseTime)
              guard let responseString else { throw NSError(domain: "BHERuntime", code: 23, userInfo: [NSLocalizedDescriptionKey: "代理粗扫无返回结果"]) }
              let responseData = Data(bytes: responseString, count: strlen(responseString))
              bhe_runtime_free_string(responseString)
              if let value = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                 self.hasBallNearHoop(value, width: CVPixelBufferGetWidth(imageBuffer), height: CVPixelBufferGetHeight(imageBuffer), hoop: hoopRoi) {
                coarseSeeds.append(startMs + coarseTime)
              }
              coarseIndex += 1
              self.emitProgress(stage: "coarseScan", progress: 0.08 + Double(coarseIndex) / Double(max(1, coarseTimes.count)) * 0.10, processed: coarseIndex, total: coarseTimes.count, message: "正在快速扫描视频")
            }
            CMSampleBufferInvalidate(sampleBuffer)
          }
          reader.cancelReading()
        }
        if let coarseResult = bhe_runtime_finish_session(coarseHandle) {
          bhe_runtime_free_string(coarseResult)
        }
        bhe_runtime_free_session(coarseHandle)
        coarseSession = nil
        sampleTimes = coarseSeeds.isEmpty
          ? Array(originalSampleTimes)
          : self.refineTimes(around: coarseSeeds, startMs: startMs, endMs: actualEndMs, fps: fps)
        totalFrames = max(1, sampleTimes.count)

        var config: [String: Any] = [
          "model_path": modelPath,
          "hoop_roi": hoopRoi,
          "analysis_roi": hoopRoi,
          "net_roi": netRoi,
          "duration_ms": durationMs,
          "confidence_threshold": confidenceThreshold,
          "clip_before_ms": beforeMs,
          "clip_after_ms": afterMs,
          "model_size": modelSize,
          "crop_scale": cropScale,
          "max_cross_gap_ms": maxCrossGapMs,
          "dedupe_ms": dedupeMs,
          "execution_provider": executionProvider,
          "optimized_model_path": optimizedModelPath,
        ]
        if let rimRoi = arguments["rimRoi"] as? [String: Any] {
          config["rim"] = rimRoi
        }
        let configData = try JSONSerialization.data(withJSONObject: config)
        let configString = String(decoding: configData, as: UTF8.self)
        session = configString.withCString { bhe_runtime_create_session($0) }
        guard let session else {
          throw NSError(domain: "BHERuntime", code: 1, userInfo: [NSLocalizedDescriptionKey: "Rust Runtime 无法加载模型或 ONNX Runtime"])
        }

        self.emitProgress(stage: "prepareProxy", progress: 0.05, processed: 0, total: totalFrames, message: "正在准备本地分析")
            var lastResponse: [String: Any] = ["candidates": []]
        var processed = 0
        if let reader = try? self.makeVideoReader(asset: asset, startMs: startMs, endMs: actualEndMs),
           let output = reader.outputs.first {
          while let sampleBuffer = output.copyNextSampleBuffer() {
            if self.isAnalysisCancelled() { throw CancellationError() }
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
            let pts = Int(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1000.0)
            if processed < sampleTimes.count && sampleTimes[processed] <= pts {
              let timeMs = sampleTimes[processed]
              let responseString = try self.pushPixelBuffer(session: session, pixelBuffer: imageBuffer, timeMs: timeMs)
              guard let responseString else { throw NSError(domain: "BHERuntime", code: 2, userInfo: [NSLocalizedDescriptionKey: "Rust Runtime 未返回结果"]) }
              let responseData = Data(bytes: responseString, count: strlen(responseString))
              bhe_runtime_free_string(responseString)
              let value = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
              if let error = value?["error"] as? String { throw NSError(domain: "BHERuntime", code: 3, userInfo: [NSLocalizedDescriptionKey: error]) }
              if let value { lastResponse = value }
              processed += 1
              self.emitProgress(stage: "refineCandidates", progress: 0.05 + Double(processed) / Double(totalFrames) * 0.90, processed: processed, total: totalFrames, message: "正在分析视频帧")
            }
            CMSampleBufferInvalidate(sampleBuffer)
            if processed >= sampleTimes.count { break }
          }
          if reader.status != .failed && processed < sampleTimes.count {
            // AVAssetReader can end before the final canonical target when
            // the target is between the last decoded PTS and the duration.
            // Recover those tail samples with the same closest-frame policy
            // used by Android's MediaCodec pipeline.
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            while processed < sampleTimes.count {
              if self.isAnalysisCancelled() { throw CancellationError() }
              let timeMs = sampleTimes[processed]
              var actualTime = CMTime.invalid
              let image = try generator.copyCGImage(
                at: CMTime(value: CMTimeValue(timeMs), timescale: 1000),
                actualTime: &actualTime
              )
              guard let responseString = try self.pushRawFrame(
                session: session,
                image: image,
                timeMs: timeMs
              ) else {
                throw NSError(domain: "BHERuntime", code: 4, userInfo: [
                  NSLocalizedDescriptionKey: "Rust Runtime 未返回补帧结果"
                ])
              }
              let responseData = Data(bytes: responseString, count: strlen(responseString))
              bhe_runtime_free_string(responseString)
              let value = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
              if let error = value?["error"] as? String {
                throw NSError(domain: "BHERuntime", code: 5, userInfo: [NSLocalizedDescriptionKey: error])
              }
              if let value { lastResponse = value }
              processed += 1
              NSLog("[BHE-AnalysisTask] recovered tail frame targetMs=%d actualMs=%d", timeMs, Int(CMTimeGetSeconds(actualTime) * 1000.0))
              self.emitProgress(stage: "refineCandidates", progress: 0.05 + Double(processed) / Double(totalFrames) * 0.90, processed: processed, total: totalFrames, message: "正在分析视频帧")
            }
          }
          if reader.status == .failed || processed != sampleTimes.count {
            throw NSError(
              domain: "BHERuntime",
              code: 13,
              userInfo: [NSLocalizedDescriptionKey: "视频解码不完整：\(processed)/\(sampleTimes.count) 帧\(reader.error.map { "（\($0.localizedDescription)）" } ?? "")"]
            )
          }
          reader.cancelReading()
        } else {
          let generator = AVAssetImageGenerator(asset: asset)
          generator.appliesPreferredTrackTransform = true
          for timeMs in sampleTimes {
            if self.isAnalysisCancelled() { throw CancellationError() }
            var actualTime = CMTime.invalid
            let image = try generator.copyCGImage(
              at: CMTime(value: CMTimeValue(timeMs), timescale: 1000),
              actualTime: &actualTime
            )
            let responseString = try self.pushRawFrame(session: session, image: image, timeMs: timeMs)
            guard let responseString else { throw NSError(domain: "BHERuntime", code: 2, userInfo: [NSLocalizedDescriptionKey: "Rust Runtime 未返回结果"]) }
            let responseData = Data(bytes: responseString, count: strlen(responseString))
            bhe_runtime_free_string(responseString)
            let value = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
            if let error = value?["error"] as? String { throw NSError(domain: "BHERuntime", code: 3, userInfo: [NSLocalizedDescriptionKey: error]) }
            if let value { lastResponse = value }
            processed += 1
            self.emitProgress(stage: "refineCandidates", progress: 0.05 + Double(processed) / Double(totalFrames) * 0.90, processed: processed, total: totalFrames, message: "正在分析视频帧")
          }
        }
        if processed != sampleTimes.count {
          throw NSError(domain: "BHERuntime", code: 14, userInfo: [NSLocalizedDescriptionKey: "视频解码不完整：\(processed)/\(sampleTimes.count) 帧"])
        }
        let finalResponsePointer = bhe_runtime_finish_session(session)
        guard let finalResponsePointer else {
          throw NSError(domain: "BHERuntime", code: 6, userInfo: [NSLocalizedDescriptionKey: "Rust Runtime 未返回最终结果"])
        }
        let finalResponseData = Data(bytes: finalResponsePointer, count: strlen(finalResponsePointer))
        bhe_runtime_free_string(finalResponsePointer)
        guard let finalValue = try JSONSerialization.jsonObject(with: finalResponseData) as? [String: Any] else {
          throw NSError(domain: "BHERuntime", code: 7, userInfo: [NSLocalizedDescriptionKey: "Rust Runtime 最终结果无效"])
        }
        if let error = finalValue["error"] as? String { throw NSError(domain: "BHERuntime", code: 8, userInfo: [NSLocalizedDescriptionKey: error]) }
        lastResponse = finalValue
        self.emitProgress(stage: "persistCandidates", progress: 0.98, processed: processed, total: totalFrames, message: "正在写入分析结果")
        lastResponse["processed_frames"] = processed
        lastResponse["total_frames"] = totalFrames
        DispatchQueue.main.async { result(lastResponse) }
      } catch is CancellationError {
        DispatchQueue.main.async { result(FlutterError(code: "ANALYSIS_CANCELLED", message: "分析已取消", details: nil)) }
      } catch {
        DispatchQueue.main.async { result(FlutterError(code: "ANALYSIS_FAILED", message: error.localizedDescription, details: nil)) }
      }
    }
  }

  private func makeVideoReader(asset: AVAsset, startMs: Int, endMs: Int) throws -> AVAssetReader {
    let reader = try AVAssetReader(asset: asset)
    guard let track = asset.tracks(withMediaType: .video).first else { throw NSError(domain: "BHERuntime", code: 10, userInfo: [NSLocalizedDescriptionKey: "视频没有视频轨道"]) }
    let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ])
    output.alwaysCopiesSampleData = false
    let transformedRect = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
    let renderSize = CGSize(width: abs(transformedRect.width), height: abs(transformedRect.height))
    let videoComposition = AVMutableVideoComposition()
    videoComposition.renderSize = renderSize
    videoComposition.frameDuration = track.minFrameDuration.isValid
      ? track.minFrameDuration
      : CMTime(value: 1, timescale: 30)
    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
    let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
    var displayTransform = track.preferredTransform
    displayTransform.tx -= transformedRect.minX
    displayTransform.ty -= transformedRect.minY
    layerInstruction.setTransform(displayTransform, at: .zero)
    instruction.layerInstructions = [layerInstruction]
    videoComposition.instructions = [instruction]
    output.videoComposition = videoComposition
    reader.timeRange = CMTimeRange(
      start: CMTime(value: CMTimeValue(startMs), timescale: 1000),
      duration: CMTime(value: CMTimeValue(endMs - startMs), timescale: 1000)
    )
    guard reader.canAdd(output) else { throw NSError(domain: "BHERuntime", code: 11, userInfo: [NSLocalizedDescriptionKey: "无法创建视频读取器"]) }
    reader.add(output)
    reader.startReading()
    return reader
  }

  private func pushPixelBuffer(session: OpaquePointer?, pixelBuffer: CVPixelBuffer, timeMs: Int) throws -> UnsafeMutablePointer<CChar>? {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { throw NSError(domain: "BHERuntime", code: 12, userInfo: [NSLocalizedDescriptionKey: "无法读取视频像素"]) }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
    return bhe_runtime_push_frame_bgra_strided(
      session,
      Int64(timeMs),
      UInt32(width),
      UInt32(height),
      stride,
      baseAddress.assumingMemoryBound(to: UInt8.self),
      Int64(stride * height),
      0
    )
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
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    )
    guard let context else {
      throw NSError(domain: "BHERuntime", code: 4, userInfo: [NSLocalizedDescriptionKey: "无法创建图像上下文"])
    }
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let pixelBuffer = context.data else {
      throw NSError(domain: "BHERuntime", code: 5, userInfo: [NSLocalizedDescriptionKey: "无法读取像素数据"])
    }

    let buffer = pixelBuffer.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
    rgbaData.append(buffer, count: bytesPerRow * height)

    let result = rgbaData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UnsafeMutablePointer<CChar>? in
      guard let base = raw.baseAddress else { return nil }
      return bhe_runtime_push_frame_raw(
        session,
        Int64(timeMs),
        UInt32(width),
        UInt32(height),
        base.assumingMemoryBound(to: UInt8.self),
        Int64(raw.count)
      )
    }
    return result
  }

  private func setAnalysisCancelled(_ cancelled: Bool) {
    analysisCancellationLock.lock()
    analysisCancelled = cancelled
    analysisCancellationLock.unlock()
  }

  private func beginAnalysis() -> Bool {
    analysisCancellationLock.lock()
    defer { analysisCancellationLock.unlock() }
    guard !analysisRunning else { return false }
    analysisRunning = true
    analysisCancelled = false
    return true
  }

  private func finishAnalysis() {
    analysisCancellationLock.lock()
    analysisRunning = false
    analysisCancellationLock.unlock()
  }

  private func isAnalysisCancelled() -> Bool {
    analysisCancellationLock.lock()
    defer { analysisCancellationLock.unlock() }
    return analysisCancelled
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
    let exportId = (arguments["exportId"] as? String) ?? outputPath

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
    exportLock.lock()
    activeExporters[exportId] = exporter
    exportLock.unlock()
    exporter.exportAsynchronously {
      DispatchQueue.main.async {
        self.exportLock.lock()
        self.activeExporters.removeValue(forKey: exportId)
        self.exportLock.unlock()
        switch exporter.status {
        case .completed:
          result(outputPath)
        case .cancelled:
          try? FileManager.default.removeItem(at: outputURL)
          result(FlutterError(code: "EXPORT_CANCELLED", message: "导出已取消", details: nil))
        default:
          try? FileManager.default.removeItem(at: outputURL)
          result(FlutterError(code: "EXPORT_FAILED", message: exporter.error?.localizedDescription ?? "导出失败", details: nil))
        }
      }
    }
  }

  private func cancelExport(_ arguments: [String: Any]?, result: @escaping FlutterResult) {
    exportLock.lock()
    let exportId = arguments?["exportId"] as? String
    let exporters = exportId.flatMap { activeExporters[$0] }.map { [$0] } ?? Array(activeExporters.values)
    exportLock.unlock()
    exporters.forEach { $0.cancelExport() }
    result(nil)
  }

  private func mergeClips(_ arguments: [String: Any]?, result: @escaping FlutterResult) {
    guard
      let arguments,
      let inputPath = arguments["inputPath"] as? String,
      let outputPath = arguments["outputPath"] as? String,
      let rawClips = arguments["clips"] as? [[String: Any]]
    else {
      result(FlutterError(code: "INVALID_ARGUMENT", message: "合并导出参数无效", details: nil))
      return
    }
    let sortedClips = rawClips.compactMap { clip -> (Int, Int)? in
      guard let start = clip["startMs"] as? Int,
            let end = clip["endMs"] as? Int,
            end > start else { return nil }
      return (start, end)
    }.sorted { $0.0 < $1.0 }
    var clips = [(Int, Int)]()
    for clip in sortedClips {
      if let previous = clips.last, clip.0 <= previous.1 {
        clips[clips.count - 1] = (previous.0, max(previous.1, clip.1))
      } else {
        clips.append(clip)
      }
    }
    guard !clips.isEmpty else {
      result(FlutterError(code: "INVALID_ARGUMENT", message: "没有可合并的片段", details: nil))
      return
    }
    let exportId = (arguments["exportId"] as? String) ?? outputPath
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let inputURL = URL(fileURLWithPath: inputPath)
        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
          at: outputURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: outputURL)
        let asset = AVAsset(url: inputURL)
        guard let sourceVideo = asset.tracks(withMediaType: .video).first else {
          throw NSError(domain: "BHE", code: 1, userInfo: [NSLocalizedDescriptionKey: "视频没有视频轨道"])
        }
        let sourceAudio = asset.tracks(withMediaType: .audio).first
        let composition = AVMutableComposition()
        guard let compositionVideo = composition.addMutableTrack(
          withMediaType: .video,
          preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
          throw NSError(domain: "BHE", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法创建合并视频轨道"])
        }
        compositionVideo.preferredTransform = sourceVideo.preferredTransform
        let compositionAudio = sourceAudio.flatMap { _ in
          composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
          )
        }
        var cursor = CMTime.zero
        for (startMs, endMs) in clips {
          let range = CMTimeRange(
            start: CMTime(value: CMTimeValue(startMs), timescale: 1000),
            duration: CMTime(value: CMTimeValue(endMs - startMs), timescale: 1000)
          )
          try compositionVideo.insertTimeRange(range, of: sourceVideo, at: cursor)
          if let sourceAudio, let compositionAudio {
            try compositionAudio.insertTimeRange(range, of: sourceAudio, at: cursor)
          }
          cursor = cursor + range.duration
        }
        guard let exporter = AVAssetExportSession(
          asset: composition,
          presetName: AVAssetExportPresetHighestQuality
        ) else {
          throw NSError(domain: "BHE", code: 3, userInfo: [NSLocalizedDescriptionKey: "当前视频无法合并导出"])
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = false
        self.exportLock.lock()
        self.activeExporters[exportId] = exporter
        self.exportLock.unlock()
        exporter.exportAsynchronously {
          DispatchQueue.main.async {
            self.exportLock.lock()
            self.activeExporters.removeValue(forKey: exportId)
            self.exportLock.unlock()
            switch exporter.status {
            case .completed:
              result(outputPath)
            case .cancelled:
              try? FileManager.default.removeItem(at: outputURL)
              result(FlutterError(code: "EXPORT_CANCELLED", message: "合并导出已取消", details: nil))
            default:
              try? FileManager.default.removeItem(at: outputURL)
              result(FlutterError(code: "EXPORT_FAILED", message: exporter.error?.localizedDescription ?? "合并导出失败", details: nil))
            }
          }
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "EXPORT_FAILED", message: error.localizedDescription, details: nil))
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
