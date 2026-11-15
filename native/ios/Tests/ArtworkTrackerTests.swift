import Foundation
import CoreGraphics

@main struct ArtworkTrackerTests {
  static func main() async {
    precondition(TrackingFreshnessPolicy.evaluate(frameAge: 0.1, resultAge: 0.1) == .fresh)
    precondition(TrackingFreshnessPolicy.evaluate(frameAge: 0.31, resultAge: 0.1) == .hide, "Brief input gaps hide geometry without invalidating the tracker")
    precondition(TrackingFreshnessPolicy.evaluate(frameAge: 0.1, resultAge: 0.31) == .hide, "Stale tracking results never keep geometry visible")
    precondition(TrackingFreshnessPolicy.evaluate(frameAge: 0.9, resultAge: 0.9) == .hide, "A short gap can recover only through a fresh Vision result")
    precondition(TrackingFreshnessPolicy.evaluate(frameAge: 1.01, resultAge: 0.1) == .rescan, "A long input gap requires a fresh artwork identification")
    precondition(TrackingFreshnessPolicy.evaluate(frameAge: 0.1, resultAge: 3) == .hide, "Slow Vision results hide geometry without pretending the camera stopped")
    let tracker = ArtworkTracker()
    let referenceBox = [0.15, 0.2, 0.5, 0.5]
    let detail = [0.25, 0.3, 0.1, 0.1]
    let reference = image(offset: 0, blank: false)
    let started = await tracker.start(cgImage: reference, artworkBox: referenceBox, frameToken: 1)
    precondition(started.status == "ready" && started.detailBox == nil)
    let seeded = await tracker.update(cgImage: reference, detailBox: detail, frameToken: 2)
    precondition(seeded?.status == "tracking", "Vision must track actual reference pixels")
    let moved = await tracker.update(cgImage: image(offset: 12, blank: false), detailBox: detail, frameToken: 3)
    precondition(moved?.status == "tracking", "Vision must recover a real translated artwork")
    precondition(abs((moved?.artworkBox?[0] ?? -1) - 0.18) < 0.025, "Tracked artwork must move with the rendered image")
    precondition(abs((moved?.detailBox?[0] ?? -1) - 0.28) < 0.025, "Same stable detail must map through tracked artwork")
    let scaleTracker = ArtworkTracker()
    _ = await scaleTracker.start(cgImage: reference, artworkBox: referenceBox, frameToken: 1)
    let context = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 1600, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 0.96, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
    context.draw(reference, in: CGRect(x: -20, y: -15, width: 440, height: 330))
    let scaled = await scaleTracker.update(cgImage: context.makeImage()!, detailBox: detail, frameToken: 2)
    precondition(scaled?.status == "tracking" && (scaled?.artworkBox?[2] ?? 0) > 0.51, "Vision must measure changed object scale, not only replay its seed box")
    let miss = await tracker.update(cgImage: image(offset: 0, blank: true), detailBox: detail, frameToken: 4)
    precondition(miss?.status == "reacquiring" && miss?.detailBox == nil && miss?.artworkBox == nil, "A brief occlusion clears all regions but keeps the tracker")
    let stale = await tracker.update(cgImage: reference, detailBox: detail, frameToken: 3)
    precondition(stale == nil, "Late frames cannot restore old boxes")
    let reacquired = await tracker.update(cgImage: reference, detailBox: detail, frameToken: 5)
    precondition(reacquired?.status == "tracking" && reacquired?.detailBox != nil, "The artwork reappearing after a brief miss is tracked again without a rescan")
    var token = 6
    var lost: TrackingSnapshot?
    for _ in 0..<ArtworkTracker.maxConsecutiveMisses {
      lost = await tracker.update(cgImage: image(offset: 0, blank: true), detailBox: detail, frameToken: token); token += 1
    }
    precondition(lost?.status == "lost" && lost?.detailBox == nil && lost?.artworkBox == nil, "Sustained occlusion reports lost and clears all regions")
    let after = await tracker.update(cgImage: reference, detailBox: detail, frameToken: token)
    precondition(after?.status == "lost", "After sustained loss the worker is discarded until a new seed")
    await tracker.reset()
    let reset = await tracker.update(cgImage: reference, detailBox: detail, frameToken: token + 1)
    precondition(reset?.status == "lost" && reset?.detailBox == nil)
    print("Passed 6 tracking freshness policy checks and 12 actual Vision artwork tracking/translation/brief-miss/sustained-loss/reset checks. Axis-aligned baseline; perspective, video and glasses still require validation.")
  }

  static func image(offset: Int, blank: Bool) -> CGImage {
    let width = 400, height = 300
    var data = [UInt8](repeating: 245, count: width * height * 4)
    var seed: UInt32 = 17
    for y in 0..<height { for x in 0..<width {
      let i = (y * width + x) * 4
      if !blank && x >= 60 + offset && x < 260 + offset && y >= 60 && y < 210 {
        seed = 1664525 &* seed &+ 1013904223
        data[i] = UInt8(truncatingIfNeeded: seed >> 24); data[i+1] = UInt8(truncatingIfNeeded: seed >> 16); data[i+2] = UInt8(truncatingIfNeeded: seed >> 8)
      }
      data[i+3] = 255
    } }
    let provider = CGDataProvider(data: Data(data) as CFData)!
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
  }
}
