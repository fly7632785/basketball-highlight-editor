import AVFoundation
import CoreVideo
import Foundation

enum PortraitVideoError: String, LocalizedError {
  case invalidRange = "The clip range is outside the video track."
  case invalidKeyframes = "The crop keyframes must be ordered and inside the clip."
  case missingVideo = "The input has no video track."
  case unsupportedAspect = "The source is narrower than the portrait crop."
  case invalidOutputSize = "The portrait encoder did not produce a 1080 by 1920 picture."
  case invalidOutputColor = "The portrait encoder did not produce H.264 Rec.709 video."
  case exporterUnavailable = "The video export session could not be created."
  case readerFailed = "The video reader did not complete."
  case noFrames = "The video reader returned no frames in the clip range."
  case modelUnavailable = "The bundled ball model could not be loaded."
  case detectionFailed = "The ball detector returned an invalid response."

  var errorDescription: String? { rawValue }
}

struct PortraitGeometry {
  let size: CGSize
  let displayTransform: CGAffineTransform

  init(size: CGSize, preferredTransform: CGAffineTransform) {
    let bounds = CGRect(origin: .zero, size: size).applying(preferredTransform)
    self.size = bounds.size
    // Transform into upright display space, then move its origin to (0, 0).
    displayTransform = preferredTransform.concatenating(
      CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
    )
  }

  func detectionBox(_ box: CGRect, sampledSize: CGSize) -> CGRect {
    box.applying(CGAffineTransform(
      scaleX: size.width / sampledSize.width,
      y: size.height / sampledSize.height
    ))
  }
}

struct PortraitSamplingSchedule {
  static let frequency = 10
  let startMs: Int
  let endMs: Int
  private var lastSlot = -1

  init(startMs: Int, endMs: Int) {
    self.startMs = startMs
    self.endMs = endMs
  }

  mutating func accepts(_ ptsMs: Int) -> Bool {
    guard ptsMs >= startMs && ptsMs < endMs else { return false }
    let slot = (ptsMs - startMs) / (1000 / Self.frequency)
    guard slot > lastSlot else { return false }
    lastSlot = slot
    return true
  }
}

struct PortraitKeyframe {
  let tMs: Int
  let cxNorm: Double
}

struct PortraitClipPlan {
  static let renderSize = CGSize(width: 1080, height: 1920)

  struct Ramp {
    let range: CMTimeRange
    let from: CGAffineTransform
    let to: CGAffineTransform
  }

  let range: CMTimeRange
  private let keyframes: [PortraitKeyframe]

  init(startMs: Int, endMs: Int, keyframes: [PortraitKeyframe]) throws {
    guard startMs >= 0, endMs > startMs else { throw PortraitVideoError.invalidRange }
    let start = CMTime(value: Int64(startMs), timescale: 1000)
    let end = CMTime(value: Int64(endMs), timescale: 1000)
    range = CMTimeRange(start: start, end: end)
    guard let first = keyframes.first, let last = keyframes.last,
          first.tMs >= startMs, last.tMs <= endMs,
          keyframes.allSatisfy({ (0...1).contains($0.cxNorm) }),
          zip(keyframes, keyframes.dropFirst()).allSatisfy({ $0.0.tMs < $0.1.tMs })
    else { throw PortraitVideoError.invalidKeyframes }

    // Hold the first and last centers over any unsampled ends of the clip.
    self.keyframes =
      (first.tMs > startMs ? [PortraitKeyframe(tMs: startMs, cxNorm: first.cxNorm)] : [])
      + keyframes
      + (last.tMs < endMs ? [PortraitKeyframe(tMs: endMs, cxNorm: last.cxNorm)] : [])
  }

  func ramps(in geometry: PortraitGeometry) throws -> [Ramp] {
    let size = geometry.size
    let cropWidth = size.height * Self.renderSize.width / Self.renderSize.height
    guard cropWidth > 0, size.width >= cropWidth else { throw PortraitVideoError.unsupportedAspect }
    let scale = Self.renderSize.height / size.height
    let halfCrop = cropWidth / 2

    func transform(_ keyframe: PortraitKeyframe) -> CGAffineTransform {
      let center = min(size.width - halfCrop, max(halfCrop, size.width * CGFloat(keyframe.cxNorm)))
      let crop = CGAffineTransform(translationX: halfCrop - center, y: 0)
      return geometry.displayTransform.concatenating(crop).concatenating(
        CGAffineTransform(scaleX: scale, y: scale)
      )
    }

    return zip(keyframes, keyframes.dropFirst()).map { from, to in
      Ramp(
        range: CMTimeRange(
          start: CMTime(value: Int64(from.tMs), timescale: 1000),
          end: CMTime(value: Int64(to.tMs), timescale: 1000)
        ),
        from: transform(from),
        to: transform(to)
      )
    }
  }
}

enum PortraitVideoFormat {
  static func codec(subtype: String?, hasDolbyConfig: Bool) -> String? {
    if hasDolbyConfig { return "video/dolby-vision" }
    switch subtype {
    case "dvh1", "dvhe", "dva1", "dvav": return "video/dolby-vision"
    case "hvc1", "hev1": return "video/hevc"
    case "avc1": return "video/avc"
    default: return subtype
    }
  }

  static func codec(_ description: CMFormatDescription) -> String? {
    let subtype = CMFormatDescriptionGetMediaSubType(description)
    let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: subtype >> $0) }
    let atoms = CMFormatDescriptionGetExtension(
      description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
    ) as? [String: Any]
    return codec(
      subtype: String(bytes: bytes, encoding: .ascii),
      hasDolbyConfig: atoms?["dvcC"] != nil || atoms?["dvvC"] != nil
    )
  }

  static func isHDR(codec: String?, transfer: String?) -> Bool {
    codec == "video/dolby-vision"
      || transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
      || transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
  }

  static func isHDR(_ description: CMFormatDescription) -> Bool {
    let transfer = CMFormatDescriptionGetExtension(
      description, extensionKey: kCMFormatDescriptionExtension_TransferFunction
    ) as? String
    return isHDR(codec: codec(description), transfer: transfer)
  }
}

enum PortraitVideo {
  static func configureSDR(_ composition: AVMutableVideoComposition) {
    // The built-in compositor converts HDR pixels into the requested working
    // space before compositing, including when the output buffers are 8-bit.
    composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
    composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
    composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
  }

  static func sourceTrack(in asset: AVAsset, range: CMTimeRange) throws -> AVAssetTrack {
    guard let track = asset.tracks(withMediaType: .video).first else {
      throw PortraitVideoError.missingVideo
    }
    // The channel range is in whole milliseconds and can include a short
    // audio tail after the final video sample.
    let durationMs = CMTimeConvertScale(asset.duration, timescale: 1000, method: .roundHalfAwayFromZero)
    guard durationMs.isNumeric,
          CMTimeCompare(range.start, track.timeRange.start) >= 0,
          CMTimeCompare(range.start, track.timeRange.end) < 0,
          CMTimeCompare(range.end, durationMs) <= 0
    else { throw PortraitVideoError.invalidRange }
    return track
  }

  static func makeExporter(asset: AVAsset, output: URL, plan: PortraitClipPlan) throws -> AVAssetExportSession {
    let track = try sourceTrack(in: asset, range: plan.range)
    let geometry = PortraitGeometry(size: track.naturalSize, preferredTransform: track.preferredTransform)
    let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
    for ramp in try plan.ramps(in: geometry) {
      layer.setTransformRamp(fromStart: ramp.from, toEnd: ramp.to, timeRange: ramp.range)
    }
    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = plan.range
    instruction.layerInstructions = [layer]
    let composition = AVMutableVideoComposition()
    composition.renderSize = PortraitClipPlan.renderSize
    composition.frameDuration = CMTime(value: 1, timescale: 30)
    composition.instructions = [instruction]
    configureSDR(composition)

    // A video composition requires re-encoding. The source asset supplies audio unchanged
    // in timeline, including when the trim starts at a non-zero source timestamp.
    guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1920x1080)
    else { throw PortraitVideoError.exporterUnavailable }
    exporter.outputURL = output
    exporter.outputFileType = .mp4
    exporter.timeRange = plan.range
    exporter.videoComposition = composition
    return exporter
  }

  static func validateOutput(_ url: URL) throws {
    let asset = AVURLAsset(url: url)
    guard let track = asset.tracks(withMediaType: .video).first,
          let descriptions = track.formatDescriptions as? [CMFormatDescription],
          !descriptions.isEmpty,
          descriptions.allSatisfy({ description in
            CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_H264
              && !PortraitVideoFormat.isHDR(description)
              && (CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String)
                == AVVideoColorPrimaries_ITU_R_709_2
              && (CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String)
                == AVVideoTransferFunction_ITU_R_709_2
              && (CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String)
                == AVVideoYCbCrMatrix_ITU_R_709_2
          })
    else { throw PortraitVideoError.invalidOutputColor }
    let size = PortraitGeometry(size: track.naturalSize, preferredTransform: track.preferredTransform).size
    guard size == PortraitClipPlan.renderSize else { throw PortraitVideoError.invalidOutputSize }
  }
}
