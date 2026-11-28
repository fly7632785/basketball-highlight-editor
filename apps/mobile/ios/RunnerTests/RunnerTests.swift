import AVFoundation
import XCTest
#if os(iOS)
@testable import Runner
#endif

class RunnerTests: XCTestCase {

  func testExample() {
    // If you add code to the Runner application, consider adding tests here.
    // See https://developer.apple.com/documentation/xctest for more information about using XCTest.
  }

}

final class PortraitVideoTests: XCTestCase {
  func testExporterFollowsSourceCadenceUpTo60FPS() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let plan = try PortraitClipPlan(startMs: 0, endMs: 50, keyframes: [
      PortraitKeyframe(tMs: 0, cxNorm: 0.5),
    ])
    for (ticks, expected) in [(2500, 2500), (2000, 2000), (1001, 1001), (1000, 1000), (500, 1000)] {
      let url = directory.appendingPathComponent("source-\(ticks).mov")
      let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
      let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 64,
        AVVideoHeightKey: 36,
      ])
      input.mediaTimeScale = 60_000
      let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 64,
        kCVPixelBufferHeightKey as String: 36,
      ])
      writer.movieTimeScale = 60_000
      writer.add(input)
      XCTAssertTrue(writer.startWriting())
      writer.startSession(atSourceTime: .zero)
      let pool = try XCTUnwrap(adaptor.pixelBufferPool)
      var pixelBuffer: CVPixelBuffer?
      XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer), kCVReturnSuccess)
      let frame = try XCTUnwrap(pixelBuffer)
      let deadline = Date().addingTimeInterval(10)
      for index in 0..<8 {
        while !input.isReadyForMoreMediaData && writer.status == .writing && Date() < deadline {
          Thread.sleep(forTimeInterval: 0.001)
        }
        let presentationTime = CMTime(value: Int64(index * ticks), timescale: 60_000)
        XCTAssertTrue(adaptor.append(frame, withPresentationTime: presentationTime))
      }
      input.markAsFinished()
      let written = expectation(description: "Wrote \(ticks)-tick fixture")
      writer.finishWriting { written.fulfill() }
      wait(for: [written], timeout: 10)
      XCTAssertEqual(writer.status, .completed)
      let exporter = try PortraitVideo.makeExporter(
        asset: AVURLAsset(url: url), output: directory.appendingPathComponent("portrait-\(ticks).mp4"), plan: plan
      )
      let actual = try XCTUnwrap(exporter.videoComposition?.frameDuration)
      XCTAssertEqual(CMTimeCompare(actual, CMTime(value: Int64(expected), timescale: 60_000)), 0, "Source cadence \(ticks)")
    }
  }

  func testRotatedGeometryRescalesDetectorBoxesToDisplayPixels() {
    let geometry = PortraitGeometry(
      size: CGSize(width: 3840, height: 2160),
      preferredTransform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)
    )
    XCTAssertEqual(geometry.size, CGSize(width: 2160, height: 3840))
    let bounds = CGRect(x: 0, y: 0, width: 3840, height: 2160).applying(geometry.displayTransform)
    XCTAssertEqual(bounds, CGRect(x: 0, y: 0, width: 2160, height: 3840))
    let box = geometry.detectionBox(
      CGRect(x: 100, y: 200, width: 30, height: 50),
      sampledSize: CGSize(width: 540, height: 960)
    )
    XCTAssertEqual(box, CGRect(x: 400, y: 800, width: 120, height: 200))
  }

  func testCropRampsUseSourceTimeAndHoldBothEndpoints() throws {
    let plan = try PortraitClipPlan(startMs: 1000, endMs: 3000, keyframes: [
      PortraitKeyframe(tMs: 1200, cxNorm: 0.25),
      PortraitKeyframe(tMs: 2200, cxNorm: 0.75),
    ])
    let geometry = PortraitGeometry(size: CGSize(width: 1920, height: 1080), preferredTransform: .identity)
    let ramps = try plan.ramps(in: geometry)
    XCTAssertEqual(ramps.map { CMTimeGetSeconds($0.range.start) }, [1, 1.2, 2.2])
    XCTAssertEqual(ramps.map { CMTimeGetSeconds($0.range.end) }, [1.2, 2.2, 3])
    XCTAssertEqual(ramps[0].from, ramps[0].to)
    XCTAssertEqual(ramps[2].from, ramps[2].to)
    let midpointTranslation = (ramps[1].from.tx + ramps[1].to.tx) / 2
    XCTAssertEqual(960 * ramps[1].from.a + midpointTranslation, 540, accuracy: 1e-6)
  }

  func testCropDoesNotLeaveImageAtEdges() throws {
    let geometry = PortraitGeometry(size: CGSize(width: 1920, height: 1080), preferredTransform: .identity)
    let plan = try PortraitClipPlan(startMs: 0, endMs: 1000, keyframes: [
      PortraitKeyframe(tMs: 0, cxNorm: 0),
      PortraitKeyframe(tMs: 1000, cxNorm: 1),
    ])
    let ramp = try XCTUnwrap(plan.ramps(in: geometry).first)
    XCTAssertEqual(ramp.from.tx, 0, accuracy: 1e-6)
    XCTAssertEqual(1920 * ramp.to.a + ramp.to.tx, 1080, accuracy: 1e-6)
  }

  func testCropRejectsExactlyPortraitAfterRotationAndNarrower() throws {
    let plan = try PortraitClipPlan(startMs: 0, endMs: 1000, keyframes: [
      PortraitKeyframe(tMs: 0, cxNorm: 0.5),
    ])
    let rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)
    for geometry in [
      PortraitGeometry(size: CGSize(width: 3840, height: 2160), preferredTransform: rotation),
      PortraitGeometry(size: CGSize(width: 900, height: 1920), preferredTransform: .identity),
    ] {
      XCTAssertThrowsError(try plan.ramps(in: geometry)) {
        XCTAssertEqual($0 as? PortraitVideoError, .unsupportedAspect)
      }
    }
    let wider = PortraitGeometry(size: CGSize(width: 2161, height: 3840), preferredTransform: .identity)
    XCTAssertNoThrow(try plan.ramps(in: wider))
  }

  func testPlanRejectsUnorderedOrNonFiniteCenters() {
    XCTAssertThrowsError(try PortraitClipPlan(startMs: 0, endMs: 1000, keyframes: [
      PortraitKeyframe(tMs: 500, cxNorm: 0.5),
      PortraitKeyframe(tMs: 500, cxNorm: 0.6),
    ]))
    XCTAssertThrowsError(try PortraitClipPlan(startMs: 0, endMs: 1000, keyframes: [
      PortraitKeyframe(tMs: 0, cxNorm: .nan),
    ]))
  }

  func testHdrSignalsIncludeDolbyConfigHLGAndPQ() {
    XCTAssertTrue(PortraitVideoFormat.isHDR(codec: "video/dolby-vision", transfer: nil))
    XCTAssertTrue(PortraitVideoFormat.isHDR(codec: "video/hevc", transfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG as String))
    XCTAssertTrue(PortraitVideoFormat.isHDR(codec: "video/hevc", transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String))
    XCTAssertFalse(PortraitVideoFormat.isHDR(codec: "video/avc", transfer: kCVImageBufferTransferFunction_ITU_R_709_2 as String))
    XCTAssertEqual(PortraitVideoFormat.codec(subtype: "hvc1", hasDolbyConfig: true), "video/dolby-vision")
    XCTAssertEqual(PortraitVideoFormat.codec(subtype: "dvh1", hasDolbyConfig: false), "video/dolby-vision")
  }

  func testSamplingUsesOriginalTimestampsWithoutDuplicatingLowFpsFrames() {
    var schedule = PortraitSamplingSchedule(startMs: 1050, endMs: 1450)
    let pts = [1040, 1067, 1100, 1300, 1316, 1416, 1450]
    XCTAssertEqual(pts.filter { schedule.accepts($0) }, [1067, 1300, 1416])
  }
}

final class PortraitMergeTests: XCTestCase {
  func testRenderedClipKeepsDeclaredPathAndDuration() throws {
    let clip = try PortraitMergeClip(arguments: [
      "inputPath": "/tmp/portrait-1.mp4", "startMs": 0, "endMs": 1275,
    ])
    XCTAssertEqual(clip.url.lastPathComponent, "portrait-1.mp4")
    XCTAssertEqual(CMTimeGetSeconds(clip.expectedDuration), 1.275, accuracy: 1e-9)
  }

  func testRenderedClipRejectsMissingFilePathAndNonzeroTrim() {
    XCTAssertThrowsError(try PortraitMergeClip(arguments: ["startMs": 0, "endMs": 1000]))
    XCTAssertThrowsError(try PortraitMergeClip(arguments: [
      "inputPath": "/tmp/portrait-1.mp4", "startMs": 1, "endMs": 1000,
    ]))
  }
}
