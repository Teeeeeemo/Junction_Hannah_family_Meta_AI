import Foundation
import UIKit
@preconcurrency import AVFoundation
import MWDATCore
import MWDATMockDevice

/// Owns one process-local simulated Display device. Mock feeds enter exactly
/// the same DAT session/camera pipeline as hardware; no prepared frames are
/// silently substituted for phone-camera or video input.
@MainActor
final class DebugDeviceController {
  private var device: (any MockGlasses)?
  private var generation = 0
  private(set) var preview: UIView?

  func prepare(mode: DebugInputMode, video: URL?) async throws -> SpecificDeviceSelector {
    guard mode.isMock else { throw failure("Real glasses cannot be started through the simulated-device controller.") }
    stop(); let run = generation
    if mode == .phoneCamera {
      #if targetEnvironment(simulator)
      throw failure("The iOS Simulator has no iPhone camera. Choose Video replay instead.")
      #else
      guard AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil else {
        throw failure("No back camera is available. Choose Video replay instead.")
      }
      guard await AVCaptureDevice.requestAccess(for: .video) else {
        throw failure("Allow Camera access for Museum Companion in iPhone Settings, or choose Video replay.")
      }
      #endif
    }
    guard run == generation, !Task.isCancelled else { throw CancellationError() }
    MockDeviceKit.shared.enable()
    let mock = try MockDeviceKit.shared.pairGlasses(model: .metaRayBanDisplay)
    device = mock
    do {
      switch mode {
      case .phoneCamera: mock.services.camera.setCameraFeed(cameraFacing: .back)
      case .video:
        guard let video else { throw failure("Choose a local MP4 or MOV video first.") }
        mock.services.camera.setCameraFeed(fileURL: video)
      case .glasses: throw failure("A real glasses session must not use the mock controller.")
      }
      preview = mock.services.display.createPreviewView()
      mock.powerOn(); mock.unfold(); mock.don()
      let wearables = Wearables.shared
      let deadline = Date().addingTimeInterval(6)
      while true {
        guard run == generation, !Task.isCancelled else { throw CancellationError() }
        if let found = wearables.deviceForIdentifier(mock.deviceIdentifier),
          found.linkState == .connected, found.compatibility() == .compatible { break }
        guard Date() < deadline else { throw failure("The simulated Display device did not become ready. Stop and start the preview again.") }
        try await Task.sleep(for: .milliseconds(50))
      }
      return SpecificDeviceSelector(device: mock.deviceIdentifier)
    } catch { if run == generation { stop() }; throw error }
  }
  func stop() {
    generation += 1; preview = nil
    if let device { device.powerOff(); MockDeviceKit.shared.unpairDevice(device) }
    device = nil
  }
  func disable() async {
    stop()
    if MockDeviceKit.shared.isEnabled { await MockDeviceKit.shared.disable() }
  }
  private func failure(_ message: String) -> NSError {
    NSError(domain: "MuseumDebugInput", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}

/// Materialize Files/iCloud selections while their security scope is held.
/// Only app-owned copies are retained or deleted. Never retain provider URLs.
struct DebugVideoStore: Sendable {
  private var directory: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("MuseumDebugVideos", isDirectory: true)
  }
  func importVideo(from url: URL) async throws -> URL {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= 500_000_000 else { throw failure("Choose a short video below 500 MB.") }
    let folder = directory
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let target = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
    do {
      try FileManager.default.copyItem(at: url, to: target)
      let copiedSize = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard copiedSize > 0, copiedSize <= 500_000_000 else { throw failure("The video is empty or larger than 500 MB.") }
      let asset = AVURLAsset(url: target)
      let tracks = try await asset.loadTracks(withMediaType: .video)
      guard !tracks.isEmpty, try await asset.load(.isPlayable) else { throw failure("The selected file has no playable video track.") }
      return target
    } catch { try? FileManager.default.removeItem(at: target); throw error }
  }
  func remove(_ url: URL) async {
    guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { return }
    try? FileManager.default.removeItem(at: url)
  }
  private func failure(_ message: String) -> NSError {
    NSError(domain: "MuseumDebugVideo", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
