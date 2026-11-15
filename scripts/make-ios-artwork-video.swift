import Foundation
import AVFoundation
import AppKit
import CoreGraphics
import CoreVideo
import ImageIO

// Public-domain Met image in a synthetic exhibition layout. This is a video
// decoding/recognition fixture, never claimed to be footage from real glasses.
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil)!
let painting = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)!
let durationText = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "240"
guard let seconds = Int(durationText), (1...600).contains(seconds) else {
  fatalError("Artwork fixture duration must be an integer from 1 to 600 seconds")
}
let width = 960, height = 720, fps = 15
let frames = fps * seconds
let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 450_000]])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height, kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
writer.add(input); guard writer.startWriting() else { fatalError("Could not begin artwork fixture") }
writer.startSession(atSourceTime: .zero)
for frame in 0..<frames {
  while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
  var optional: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &optional)
  let buffer = optional!; CVPixelBufferLockBaseAddress(buffer, [])
  let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
  context.setFillColor(CGColor(gray: 0.84, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  let drift = sin(Double(frame) / 45) * 2
  let rect = CGRect(x: 140 + drift, y: 160, width: 599, height: 477)
  context.setFillColor(CGColor(red: 0.25, green: 0.18, blue: 0.12, alpha: 1)); context.fill(rect.insetBy(dx: -12, dy: -12)); context.draw(painting, in: rect)
  context.setFillColor(CGColor(gray: 0.97, alpha: 1)); context.fill(CGRect(x: 140, y: 55, width: 660, height: 72))
  NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
  let label = "Vincent van Gogh · Wheat Field with Cypresses (1889)\nThe Metropolitan Museum of Art · Public Domain · Test fixture"
  (label as NSString).draw(in: CGRect(x: 155, y: 70, width: 630, height: 48), withAttributes: [.font: NSFont.systemFont(ofSize: 19), .foregroundColor: NSColor.black])
  NSGraphicsContext.restoreGraphicsState(); CVPixelBufferUnlockBaseAddress(buffer, [])
  guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(fps))) else { fatalError("Could not encode artwork frame") }
}
input.markAsFinished(); let done = DispatchSemaphore(value: 0); writer.finishWriting { done.signal() }; done.wait()
guard writer.status == .completed else { fatalError("Artwork fixture did not finish") }
print("Generated \(seconds)-second HEVC public-artwork fixture.")
