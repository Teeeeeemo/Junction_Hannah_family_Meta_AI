import Foundation
import AVFoundation
import CoreGraphics
import CoreVideo

// Synthetic moving color pattern for SDK transport tests, never recognition.
// Usage on a Mac with Xcode: swift scripts/make-ios-test-video.swift /tmp/fixture.mp4
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
  AVVideoCodecKey: AVVideoCodecType.hevc,
  AVVideoWidthKey: 640, AVVideoHeightKey: 480,
  AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 300_000]
])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
  kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
  kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 480,
  kCVPixelBufferCGImageCompatibilityKey as String: true,
  kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
])
writer.add(input)
guard writer.startWriting() else { fatalError(String(describing: writer.error)) }
writer.startSession(atSourceTime: .zero)
for frame in 0..<1800 {
  while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
  var optional: CVPixelBuffer?
  CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &optional)
  let buffer = optional!
  CVPixelBufferLockBaseAddress(buffer, [])
  let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 640, height: 480,
    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
  context.setFillColor(CGColor(red: 0.05, green: 0.15, blue: 0.1, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
  context.setFillColor(CGColor(red: 0.88, green: 0.77, blue: 0.5, alpha: 1))
  context.fill(CGRect(x: (frame * 3) % 500, y: 160, width: 140, height: 160))
  CVPixelBufferUnlockBaseAddress(buffer, [])
  guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 15)) else {
    fatalError(String(describing: writer.error))
  }
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
guard writer.status == .completed else { fatalError(String(describing: writer.error)) }
print("Generated 120-second HEVC moving-pattern fixture: \(output.lastPathComponent)")
