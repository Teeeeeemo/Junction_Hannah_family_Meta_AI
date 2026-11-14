import Foundation
import CoreGraphics
import Vision
import CoreML

/// Camera-frame tracking only. This conservative bounding-box baseline does not
/// estimate perspective, depth, or camera-to-eye optical alignment.
struct TrackingSnapshot: Sendable {
  let status: String
  let artworkBox: [Double]?
  let detailBox: [Double]?
  let frameToken: Int
  let confidence: Float
}

/// A short delivery gap hides stale geometry while preserving the tracker.
/// Longer gaps require identifying the work again before resuming its details.
enum TrackingFreshnessPolicy {
  enum Action { case fresh, hide, rescan }
  static func evaluate(frameAge: TimeInterval, resultAge: TimeInterval) -> Action {
    if frameAge > 1 { return .rescan }
    if frameAge > 0.3 || resultAge > 0.3 { return .hide }
    return .fresh
  }
}

actor ArtworkTracker {
  private var worker: ArtworkTrackingWorker?
  private var busy = false
  private var generation = 0
  private var lastFrameToken = -1

  func reset() {
    generation += 1; worker = nil; lastFrameToken = -1
  }

  func start(cgImage: CGImage, artworkBox: [Double], frameToken: Int) async -> TrackingSnapshot {
    generation += 1; let run = generation
    worker = nil; lastFrameToken = frameToken
    guard let region = ArtworkTrackingWorker.rect(artworkBox) else {
      return TrackingSnapshot(status: "lost", artworkBox: nil, detailBox: nil, frameToken: frameToken, confidence: 0)
    }
    let value = ArtworkTrackingWorker(reference: region)
    let seeded = await Task.detached(priority: .userInitiated) { value.track(cgImage, detailBox: nil, frameToken: frameToken) }.value
    guard run == generation, seeded.status == "tracking" else {
      return TrackingSnapshot(status: "lost", artworkBox: nil, detailBox: nil, frameToken: frameToken, confidence: 0)
    }
    worker = value
    return TrackingSnapshot(status: "ready", artworkBox: seeded.artworkBox, detailBox: nil, frameToken: frameToken, confidence: seeded.confidence)
  }

  /// Single in-flight Vision request. Frames arriving while busy are discarded;
  /// the camera does not accumulate a stale tracking queue.
  func update(cgImage: CGImage, detailBox: [Double]?, frameToken: Int) async -> TrackingSnapshot? {
    guard frameToken > lastFrameToken else { return nil }
    lastFrameToken = frameToken
    guard !busy else { return nil }
    guard let worker else { return TrackingSnapshot(status: "lost", artworkBox: nil, detailBox: nil, frameToken: frameToken, confidence: 0) }
    busy = true; let run = generation
    let value = await Task.detached(priority: .userInitiated) { worker.track(cgImage, detailBox: detailBox, frameToken: frameToken) }.value
    busy = false
    guard run == generation else { return nil }
    if value.status == "lost" { self.worker = nil }
    return value
  }
}

/// Accessed only by one bounded task at a time; reset replaces the worker rather
/// than mutating Vision requests that may still be in flight.
private final class ArtworkTrackingWorker: @unchecked Sendable {
  private let sequence = VNSequenceRequestHandler()
  private var observation: VNDetectedObjectObservation
  private let reference: CGRect
  private var previous: CGRect
  init(reference: CGRect) {
    self.reference = reference; previous = reference
    observation = VNDetectedObjectObservation(boundingBox: Self.visionRect(reference))
  }
  static func rect(_ values: [Double]) -> CGRect? {
    guard values.count == 4, values.allSatisfy({ $0.isFinite }), values[0] >= 0, values[1] >= 0,
      values[2] > 0, values[3] > 0, values[0] + values[2] <= 1.001, values[1] + values[3] <= 1.001 else { return nil }
    return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
  }
  private static func visionRect(_ value: CGRect) -> CGRect {
    CGRect(x: value.minX, y: 1 - value.maxY, width: value.width, height: value.height)
  }
  private static func box(_ value: CGRect) -> [Double] { [value.minX, value.minY, value.width, value.height] }
  func track(_ image: CGImage, detailBox: [Double]?, frameToken: Int) -> TrackingSnapshot {
    let lost = TrackingSnapshot(status: "lost", artworkBox: nil, detailBox: nil, frameToken: frameToken, confidence: 0)
    let request = VNTrackObjectRequest(detectedObjectObservation: observation)
    request.trackingLevel = .accurate
    #if targetEnvironment(simulator) || os(macOS)
    // Desktop/simulator ANE models may be unavailable; select a public CPU
    // compute device rather than silently treating inference errors as tracking.
    if #available(macOS 14.0, iOS 17.0, *), let stages = try? request.supportedComputeStageDevices {
      for (stage, devices) in stages {
        if let cpu = devices.first(where: { if case .cpu = $0 { return true }; return false }) { request.setComputeDevice(cpu, for: stage) }
      }
    }
    #endif
    do { try sequence.perform([request], on: image, orientation: .up) } catch { return lost }
    guard let result = request.results?.first as? VNDetectedObjectObservation, result.confidence >= 0.65 else { return lost }
    let tracked = Self.visionRect(result.boundingBox)
    guard Self.rect(Self.box(tracked)) != nil,
      abs(tracked.midX - previous.midX) < 0.25, abs(tracked.midY - previous.midY) < 0.25,
      tracked.width / reference.width > 0.45, tracked.width / reference.width < 2.2,
      tracked.height / reference.height > 0.45, tracked.height / reference.height < 2.2 else { return lost }
    observation = result; previous = tracked
    var mapped: [Double]?
    if let detailBox, let detail = Self.rect(detailBox), reference.contains(detail) {
      let referencePlacement = CGAffineTransform(translationX: reference.minX, y: reference.minY).scaledBy(x: reference.width, y: reference.height)
      let trackedPlacement = CGAffineTransform(translationX: tracked.minX, y: tracked.minY).scaledBy(x: tracked.width, y: tracked.height)
      let region = detail.applying(referencePlacement.inverted()).applying(trackedPlacement)
      if Self.rect(Self.box(region)) != nil { mapped = Self.box(region) }
    }
    return TrackingSnapshot(status: "tracking", artworkBox: Self.box(tracked), detailBox: mapped, frameToken: frameToken, confidence: result.confidence)
  }
}
