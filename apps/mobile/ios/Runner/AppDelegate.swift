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

  private struct FineWindowResult {
    let response: [String: Any]
    let processed: Int
    let inferenceNanos: UInt64
  }

  // Keep the iOS analysis contract aligned with Android's AnalysisTaskManager.
  private let coarseFps = 5.0
  private let coarseMaxDimension = 960
  private let fineWindowMs = 1_500
  private let coarseCropScale = 4.0
  private let runtimeIntraThreads = 2

  private let progressStream = AnalysisProgressStreamHandler()
  private let analysisCancellationLock = NSLock()
  private var analysisCancelled = false
  private var analysisRunning = false
  private var analysisState: [String: Any] = ["status": "idle"]
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
      case "getAnalysisState":
        result(self.currentAnalysisState())
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

  private func currentAnalysisState() -> [String: Any] {
    analysisCancellationLock.lock()
    defer { analysisCancellationLock.unlock() }
    return analysisState
  }

  private func setAnalysisState(_ state: [String: Any]) {
    analysisCancellationLock.lock()
    analysisState = state
    analysisCancellationLock.unlock()
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
    let values = "\(sourcePath)|\(resourceValues?.fileSize ?? 0)|\(resourceValues?.contentModificationDate ?? Date.distantPast)|\(startMs)|\(endMs)|960|540|4"
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
    guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset960x540) else {
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

  private func fullRoi() -> [String: Any] {
    ["left": 0.0, "top": 0.0, "right": 1.0, "bottom": 1.0]
  }

  private func jsonCandidates(_ value: Any?) -> [[String: Any]] {
    (value as? [[String: Any]]) ?? []
  }

  private func candidateEventMs(_ candidate: [String: Any]) -> Int? {
    if let value = candidate["event_ms"] as? Int { return value }
    if let value = candidate["event_ms"] as? NSNumber { return value.intValue }
    return nil
  }

  private func candidatePriority(_ candidate: [String: Any]) -> Double {
    if let value = candidate["composite_score"] as? NSNumber { return value.doubleValue }
    if let value = candidate["confidence"] as? NSNumber { return value.doubleValue }
    return 0.0
  }

  private func dedupeCandidates(
    _ candidates: [[String: Any]],
    dedupeMs: Int
  ) -> [[String: Any]] {
    let sorted = candidates.compactMap { candidate -> (Int, [String: Any])? in
      guard let eventMs = candidateEventMs(candidate) else { return nil }
      return (eventMs, candidate)
    }.sorted { $0.0 < $1.0 }
    var result = [[String: Any]]()
    var clusterStart: Int?
    var winner: (Int, [String: Any])?
    for item in sorted {
      if winner == nil || item.0 - (clusterStart ?? item.0) <= dedupeMs {
        if winner == nil { clusterStart = item.0 }
        if winner == nil || candidatePriority(item.1) > candidatePriority(winner!.1) {
          winner = item
        }
      } else {
        if let winner { result.append(winner.1) }
        clusterStart = item.0
        winner = item
      }
    }
    if let winner { result.append(winner.1) }
    return result
  }

  private func reviewFallbackCandidate(
    eventMs: Int,
    startMs: Int,
    endMs: Int,
    beforeMs: Int,
    afterMs: Int
  ) -> [String: Any] {
    let clipStart = max(startMs, eventMs - beforeMs)
    let clipEnd = min(endMs, eventMs + afterMs)
    return [
      "id": "coarse_review_\(eventMs)",
      "track_id": -1,
      "start_ms": clipStart,
      "end_ms": clipEnd,
      "default_start_ms": clipStart,
      "default_end_ms": clipEnd,
      "event_ms": eventMs,
      "confidence": 0.0,
      "confidence_label": "review",
      "verdict": "ambiguous",
      "reason": "coarse_crossing_fine_review",
      "selection": "included",
      "trajectory": [],
      "algorithm_version": "analysis-contract-v1",
      "evidence_source": "ios_coarse_crossing",
    ]
  }

  private func runSession(
    asset: AVAsset,
    startMs: Int,
    endMs: Int,
    sampleTimes: [Int],
    config: [String: Any],
    maxDimension: Int? = nil,
    onProgress: ((Int, Int) -> Void)? = nil,
    onFrame: (([String: Any], Int, Int) -> Void)? = nil
  ) throws -> FineWindowResult {
    guard !sampleTimes.isEmpty else {
      return FineWindowResult(response: ["candidates": []], processed: 0, inferenceNanos: 0)
    }
    let configData = try JSONSerialization.data(withJSONObject: config)
    let configString = String(decoding: configData, as: UTF8.self)
    guard let session = configString.withCString({ bhe_runtime_create_session($0) }) else {
      throw NSError(domain: "BHERuntime", code: 1, userInfo: [NSLocalizedDescriptionKey: "Rust Runtime 无法加载模型或 ONNX Runtime"])
    }
    defer { bhe_runtime_free_session(session) }

    var processed = 0
    var inferenceNanos: UInt64 = 0
    if let candidateReader = try? makeVideoReader(asset: asset, startMs: startMs, endMs: endMs, maxDimension: maxDimension),
       let output = candidateReader.outputs.first {
      while let sampleBuffer = output.copyNextSampleBuffer() {
        defer { CMSampleBufferInvalidate(sampleBuffer) }
        if isAnalysisCancelled() { throw CancellationError() }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
        let pts = Int(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1000.0)
        guard processed < sampleTimes.count && sampleTimes[processed] <= pts else { continue }
        let timeMs = sampleTimes[processed]
        let started = DispatchTime.now().uptimeNanoseconds
        guard let responsePointer = try pushPixelBuffer(session: session, pixelBuffer: imageBuffer, timeMs: timeMs) else {
          throw NSError(domain: "BHERuntime", code: 2, userInfo: [NSLocalizedDescriptionKey: "Rust Runtime 未返回结果"])
        }
        let responseData = Data(bytes: responsePointer, count: strlen(responsePointer))
        bhe_runtime_free_string(responsePointer)
        guard let response = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
          throw NSError(domain: "BHERuntime", code: 3, userInfo: [NSLocalizedDescriptionKey: "Rust Runtime 返回结果无效"])
        }
        if let error = response["error"] as? String {
          throw NSError(domain: "BHERuntime", code: 4, userInfo: [NSLocalizedDescriptionKey: error])
        }
        onFrame?(response, CVPixelBufferGetWidth(imageBuffer), CVPixelBufferGetHeight(imageBuffer))
        inferenceNanos += DispatchTime.now().uptimeNanoseconds - started
        processed += 1
        onProgress?(processed, sampleTimes.count)
      }
      if candidateReader.status != .failed && processed < sampleTimes.count {
        // AVAssetReader can finish before a target that falls between the last
        // decoded PTS and the requested end. Match Android's EOS fallback by
        // recovering the remaining targets with AVAssetImageGenerator.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        while processed < sampleTimes.count {
          if isAnalysisCancelled() { throw CancellationError() }
          let timeMs = sampleTimes[processed]
          var actualTime = CMTime.invalid
          let image = try generator.copyCGImage(
            at: CMTime(value: CMTimeValue(timeMs), timescale: 1000),
            actualTime: &actualTime
          )
          let started = DispatchTime.now().uptimeNanoseconds
          guard let responsePointer = try pushRawFrame(session: session, image: image, timeMs: timeMs) else {
            throw NSError(domain: "BHERuntime", code: 13, userInfo: [NSLocalizedDescriptionKey: "Rust Runtime 未返回补帧结果"])
          }
          let responseData = Data(bytes: responsePointer, count: strlen(responsePointer))
          bhe_runtime_free_string(responsePointer)
          guard let response = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw NSError(domain: "BHERuntime", code: 14, userInfo: [NSLocalizedDescriptionKey: "Rust Runtime 补帧结果无效"])
          }
          if let error = response["error"] as? String {
            throw NSError(domain: "BHERuntime", code: 15, userInfo: [NSLocalizedDescriptionKey: error])
          }
          onFrame?(response, image.width, image.height)
          inferenceNanos += DispatchTime.now().uptimeNanoseconds - started
          processed += 1
          onProgress?(processed, sampleTimes.count)
        }
      }
      if candidateReader.status == .failed || processed != sampleTimes.count {
        throw NSError(domain: "BHERuntime", code: 5, userInfo: [NSLocalizedDescriptionKey: "视频解码不完整：\(processed)/\(sampleTimes.count) 帧"])
      }
      candidateReader.cancelReading()
    } else {
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      for timeMs in sampleTimes {
        if isAnalysisCancelled() { throw CancellationError() }
        var actualTime = CMTime.invalid
        let image = try generator.copyCGImage(
          at: CMTime(value: CMTimeValue(timeMs), timescale: 1000),
          actualTime: &actualTime
        )
        let started = DispatchTime.now().uptimeNanoseconds
        guard let responsePointer = try pushRawFrame(session: session, image: image, timeMs: timeMs) else {
          throw NSError(domain: "BHERuntime", code: 6, userInfo: [NSLocalizedDescriptionKey: "Rust Runtime 未返回结果"])
        }
        let responseData = Data(bytes: responsePointer, count: strlen(responsePointer))
        bhe_runtime_free_string(responsePointer)
        guard let response = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
          throw NSError(domain: "BHERuntime", code: 7, userInfo: [NSLocalizedDescriptionKey: "Rust Runtime 返回结果无效"])
        }
        if let error = response["error"] as? String {
          throw NSError(domain: "BHERuntime", code: 8, userInfo: [NSLocalizedDescriptionKey: error])
        }
        onFrame?(response, image.width, image.height)
        inferenceNanos += DispatchTime.now().uptimeNanoseconds - started
        processed += 1
        onProgress?(processed, sampleTimes.count)
      }
    }
    guard let responsePointer = bhe_runtime_finish_session(session) else {
      throw NSError(domain: "BHERuntime", code: 9, userInfo: [NSLocalizedDescriptionKey: "Rust Runtime 未返回最终结果"])
    }
    let responseData = Data(bytes: responsePointer, count: strlen(responsePointer))
    bhe_runtime_free_string(responsePointer)
    guard let response = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
      throw NSError(domain: "BHERuntime", code: 10, userInfo: [NSLocalizedDescriptionKey: "Rust Runtime 最终结果无效"])
    }
    if let error = response["error"] as? String {
      throw NSError(domain: "BHERuntime", code: 11, userInfo: [NSLocalizedDescriptionKey: error])
    }
    return FineWindowResult(response: response, processed: processed, inferenceNanos: inferenceNanos)
  }

  private func medianCoarseRim(_ observations: [[String: Double]]) -> [String: Any]? {
    guard !observations.isEmpty else { return nil }
    func median(_ values: [Double]) -> Double {
      let sorted = values.sorted()
      guard !sorted.isEmpty else { return 0.0 }
      if sorted.count.isMultiple(of: 2) {
        return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2.0
      }
      return sorted[sorted.count / 2]
    }
    func clamp(_ value: Double) -> Double { min(max(value, 0.0), 1.0) }
    return [
      "left": clamp(median(observations.map { $0["left"] ?? 0.0 })),
      "top": clamp(median(observations.map { $0["top"] ?? 0.0 })),
      "right": clamp(median(observations.map { $0["right"] ?? 1.0 })),
      "bottom": clamp(median(observations.map { $0["bottom"] ?? 1.0 })),
    ]
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
      defer { self.finishAnalysis() }
      let asset = AVAsset(url: URL(fileURLWithPath: videoPath))
      do {
        let durationMs = Int(CMTimeGetSeconds(asset.duration) * 1000)
        guard durationMs > 0, startMs >= 0, startMs < durationMs else {
          throw NSError(domain: "BHERuntime", code: 12, userInfo: [NSLocalizedDescriptionKey: "分析范围超出视频时长"])
        }
        let actualEndMs = min(endMs, durationMs)
        let fps = max(1.0, min((arguments["fps"] as? Double) ?? 10.0, 10.0))
        let confidenceThreshold = max(0.0, min((arguments["confidenceThreshold"] as? Double) ?? 0.10, 1.0))
        let modelSize = max(320, ((arguments["modelSize"] as? Int) ?? 640) / 32 * 32)
        let beforeMs = (arguments["beforeMs"] as? Int) ?? 6_000
        let afterMs = (arguments["afterMs"] as? Int) ?? 3_000
        let cropScale = max(1.0, min((arguments["cropScale"] as? Double) ?? 2.0, 8.0))
        let maxCrossGapMs = max(1, (arguments["maxCrossGapMs"] as? Int) ?? 1_800)
        let dedupeMs = max(0, (arguments["dedupeMs"] as? Int) ?? 2_000)
        let executionProvider = (arguments["executionProvider"] as? String) ?? "coreml"
        let inferenceBatchSize = max(1, min((arguments["inferenceBatchSize"] as? Int) ?? 4, 8))
        let optimizedModelPath = (arguments["optimizedModelPath"] as? String)
          .flatMap { $0.isEmpty ? nil : $0 }

        let full = self.fullRoi()
        let originalTimes = self.sampleTimes(startMs: startMs, endMs: actualEndMs, fps: fps)
        var candidateTimes = [Int]()
        var effectiveRimRoi: [String: Any] = full

        // Match Android's coarse discovery: scan a 5fps low-resolution proxy
        // with the Rust coarse-crossing contract, then refine each crossing in
        // its own +/-1.5s native-resolution session.
        if fps > 0.5 {
          self.emitProgress(stage: "prepareProxy", progress: 0.05, processed: 0, total: max(1, originalTimes.count), message: "正在生成低分辨率代理视频")
          let coarseAsset: AVAsset
          let coarseStartMs: Int
          let coarseEndMs: Int
          let coarseSourceOffsetMs: Int
          do {
            let proxy = try self.createOrGetProxy(asset: asset, sourcePath: videoPath, startMs: startMs, endMs: actualEndMs)
            coarseAsset = AVAsset(url: proxy)
            coarseStartMs = 0
            coarseEndMs = Int(CMTimeGetSeconds(coarseAsset.duration) * 1000)
            coarseSourceOffsetMs = startMs
          } catch {
            // Match Android's fallback when hardware proxy encoding is not
            // available for a particular codec or video container.
            NSLog("[BHE-AnalysisTask] iOS proxy unavailable, falling back to source scan: %@", error.localizedDescription)
            coarseAsset = asset
            coarseStartMs = startMs
            coarseEndMs = actualEndMs
            coarseSourceOffsetMs = 0
          }
          let coarseTimes = self.sampleTimes(startMs: coarseStartMs, endMs: coarseEndMs, fps: self.coarseFps)
          var rimObservations = [[String: Double]]()
          let coarseConfig: [String: Any] = [
            "model_path": modelPath,
            "hoop_roi": full,
            "analysis_roi": hoopRoi,
            "net_roi": full,
            "duration_ms": coarseEndMs,
            "confidence_threshold": confidenceThreshold,
            "model_size": 640,
            "crop_scale": self.coarseCropScale,
            "input_max_dimension": self.coarseMaxDimension,
            "detection_only": false,
            "coarse_mode": true,
            "intra_threads": self.runtimeIntraThreads,
            "execution_provider": executionProvider,
            "inference_batch_size": inferenceBatchSize,
          ]
          let coarse = try self.runSession(
            asset: coarseAsset,
            startMs: coarseStartMs,
            endMs: coarseEndMs,
            sampleTimes: coarseTimes,
            config: coarseConfig,
            maxDimension: self.coarseMaxDimension,
            onProgress: { processed, total in
              self.emitProgress(stage: "coarseScan", progress: 0.18 + Double(processed) / Double(max(1, total)) * 0.30, processed: processed, total: total, message: "正在快速扫描视频")
            },
            onFrame: { response, width, height in
              guard let detections = response["detections"] as? [[String: Any]] else { return }
              for detection in detections where (detection["class_id"] as? NSNumber)?.intValue == 1 {
                guard
                  let x1 = (detection["x1"] as? NSNumber)?.doubleValue,
                  let y1 = (detection["y1"] as? NSNumber)?.doubleValue,
                  let x2 = (detection["x2"] as? NSNumber)?.doubleValue,
                  let y2 = (detection["y2"] as? NSNumber)?.doubleValue
                else { continue }
                rimObservations.append([
                  "left": x1 / Double(max(1, width)),
                  "top": y1 / Double(max(1, height)),
                  "right": x2 / Double(max(1, width)),
                  "bottom": y2 / Double(max(1, height)),
                ])
              }
            }
          )
          candidateTimes = self.jsonCandidates(coarse.response["candidates"])
            .compactMap(self.candidateEventMs)
            .map { $0 + coarseSourceOffsetMs }
            .sorted()
          effectiveRimRoi = self.medianCoarseRim(rimObservations) ?? (arguments["rimRoi"] as? [String: Any] ?? full)
          if candidateTimes.isEmpty {
            self.emitProgress(stage: "coarseScan", progress: 0.48, processed: coarse.processed, total: coarse.processed, message: "快速扫描完成，未发现候选")
            var empty = coarse.response
            empty["candidates"] = [[String: Any]]()
            empty["processed_frames"] = 0
            empty["total_frames"] = 0
            self.setAnalysisState(["status": "completed", "stage": "completed", "progress": 1.0, "message": "分析完成", "result": empty])
            DispatchQueue.main.async { result(empty) }
            return
          }
        } else {
          candidateTimes = originalTimes
          effectiveRimRoi = (arguments["rimRoi"] as? [String: Any]) ?? full
        }

        let fineTimes = Array(Set(candidateTimes)).sorted()
        let fineTotal = fineTimes.reduce(0) { total, eventMs in
          total + self.sampleTimes(
            startMs: max(startMs, eventMs - self.fineWindowMs),
            endMs: min(actualEndMs, eventMs + self.fineWindowMs),
            fps: fps
          ).count
        }
        var aggregateCandidates = [[String: Any]]()
        var completedFrames = 0
        var inferenceNanos: UInt64 = 0
        for (index, eventMs) in fineTimes.enumerated() {
          if self.isAnalysisCancelled() { throw CancellationError() }
          let windowStart = max(startMs, eventMs - self.fineWindowMs)
          let windowEnd = min(actualEndMs, eventMs + self.fineWindowMs)
          let windowTimes = self.sampleTimes(startMs: windowStart, endMs: windowEnd, fps: fps)
          var fineConfig: [String: Any] = [
            "model_path": modelPath,
            "hoop_roi": effectiveRimRoi,
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
            "intra_threads": self.runtimeIntraThreads,
            "execution_provider": executionProvider,
            "inference_batch_size": inferenceBatchSize,
            "rim": effectiveRimRoi,
          ]
          if let optimizedModelPath { fineConfig["optimized_model_path"] = optimizedModelPath }
          let window = try self.runSession(
            asset: asset,
            startMs: windowStart,
            endMs: windowEnd,
            sampleTimes: windowTimes,
            config: fineConfig,
            maxDimension: self.coarseMaxDimension,
            onProgress: { processed, _ in
              self.emitProgress(
                stage: "refineCandidates",
                progress: 0.52 + Double(completedFrames + processed) / Double(max(1, fineTotal)) * 0.44,
                processed: completedFrames + processed,
                total: fineTotal,
                message: "正在分析候选 \(index + 1)/\(fineTimes.count)"
              )
            }
          )
          completedFrames += window.processed
          inferenceNanos += window.inferenceNanos
          aggregateCandidates.append(contentsOf: self.jsonCandidates(window.response["candidates"]))
        }

        var finalCandidates = self.dedupeCandidates(aggregateCandidates, dedupeMs: dedupeMs)
        if finalCandidates.isEmpty, !candidateTimes.isEmpty {
          finalCandidates = candidateTimes.map {
            self.reviewFallbackCandidate(eventMs: $0, startMs: startMs, endMs: actualEndMs, beforeMs: beforeMs, afterMs: afterMs)
          }
        }
        var finalResponse: [String: Any] = ["candidates": finalCandidates]
        finalResponse["processed_frames"] = completedFrames
        finalResponse["total_frames"] = fineTotal
        self.emitProgress(stage: "persistCandidates", progress: 0.98, processed: completedFrames, total: fineTotal, message: "正在写入分析结果")
        self.setAnalysisState(["status": "completed", "stage": "completed", "progress": 1.0, "message": "分析完成", "result": finalResponse])
        NSLog("[BHE-AnalysisTask] iOS fine summary frames=%d/%d candidates=%d inferenceMs=%llu", completedFrames, fineTotal, finalCandidates.count, inferenceNanos / 1_000_000)
        DispatchQueue.main.async { result(finalResponse) }
      } catch is CancellationError {
        self.setAnalysisState(["status": "cancelled", "stage": "cancelled", "progress": 0.0, "message": "分析已取消"])
        DispatchQueue.main.async { result(FlutterError(code: "ANALYSIS_CANCELLED", message: "分析已取消", details: nil)) }
      } catch {
        self.setAnalysisState(["status": "failed", "stage": "failed", "progress": 1.0, "message": error.localizedDescription, "errorMessage": error.localizedDescription])
        DispatchQueue.main.async { result(FlutterError(code: "ANALYSIS_FAILED", message: error.localizedDescription, details: nil)) }
      }
    }
  }
  private func makeVideoReader(asset: AVAsset, startMs: Int, endMs: Int, maxDimension: Int? = nil) throws -> AVAssetReader {
    let reader = try AVAssetReader(asset: asset)
    guard let track = asset.tracks(withMediaType: .video).first else { throw NSError(domain: "BHERuntime", code: 10, userInfo: [NSLocalizedDescriptionKey: "视频没有视频轨道"]) }
    let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ])
    output.alwaysCopiesSampleData = false
    let transformedRect = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
    let sourceWidth = abs(transformedRect.width)
    let sourceHeight = abs(transformedRect.height)
    let longestSide = max(Double(sourceWidth), Double(sourceHeight))
    let scale = maxDimension.map { min(1.0, Double($0) / longestSide) } ?? 1.0
    let renderSize = CGSize(width: sourceWidth * CGFloat(scale), height: sourceHeight * CGFloat(scale))
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
    if scale < 1.0 {
      displayTransform = CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)).concatenating(displayTransform)
    }
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
    analysisState = ["status": "running", "stage": "validateInput", "progress": 0.0]
    DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = true }
    return true
  }

  private func finishAnalysis() {
    analysisCancellationLock.lock()
    analysisRunning = false
    analysisCancellationLock.unlock()
    DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = false }
  }

  private func isAnalysisCancelled() -> Bool {
    analysisCancellationLock.lock()
    defer { analysisCancellationLock.unlock() }
    return analysisCancelled
  }

  private func emitProgress(stage: String, progress: Double, processed: Int, total: Int, message: String) {
    analysisCancellationLock.lock()
    analysisState = [
      "status": "running",
      "stage": stage,
      "progress": min(max(progress, 0), 1),
      "processed": processed,
      "total": total,
      "message": message,
    ]
    analysisCancellationLock.unlock()
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
