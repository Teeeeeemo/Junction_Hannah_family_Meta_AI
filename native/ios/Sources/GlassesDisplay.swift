import Foundation
import MWDATCore
import MWDATDisplay

/// Device-session display output for the camera bring-up. No world-space box
/// is drawn: camera-to-eye calibration and continuous tracking remain separate.
@MainActor
final class GlassesDisplay {
  private var display: Display?
  private let listeners = ListenerTokenBag()
  private var ready = false
  private var guide: MuseumGuide?
  private var selected: Int?
  var onError: ((String) -> Void)?

  func attach(to session: DeviceSession) throws {
    let capability = try session.addDisplay(); display = capability
    capability.statePublisher.listen { [weak self] state in
      let started = state == .started
      Task { @MainActor [weak self] in
        self?.ready = started
        if started { self?.render() }
      }
    }.store(in: listeners)
    capability.start()
  }
  func show(_ guide: MuseumGuide) { self.guide = guide; selected = nil; render() }
  func stop() { listeners.clear(); display?.stop(); display = nil; ready = false; guide = nil }
  private func render() {
    guard ready, let display else { return }
    let guide = guide
    let detail = guide?.details.first(where: { $0.number == selected })
    Task { [weak self] in
      do {
        try await display.send(
          FlexBox(direction: .column, spacing: 10) {
            Text("MUSE · GLASSES CAMERA", style: .body)
            Text(guide?.artwork.title ?? "Aim at an artwork", style: .heading)
            Text(String((detail?.description ?? guide?.overview ?? "Waiting for live frames from the paired phone.").prefix(260)), style: .body)
            if let guide {
              ButtonGroup {
                for point in guide.details {
                  Button(label: "\(point.number). \(point.title)", style: .secondary, onClick: { [weak self] in
                    Task { @MainActor in self?.selected = point.number; self?.render() }
                  })
                }
              }
            }
          }.padding(20)
        )
      } catch { self?.onError?(error.localizedDescription) }
    }
  }
}
