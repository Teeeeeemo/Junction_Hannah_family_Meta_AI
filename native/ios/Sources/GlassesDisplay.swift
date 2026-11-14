import Foundation
import MWDATCore
import MWDATDisplay

/// A transparent, sparse HUD. Full narration stays in speech/the phone;
/// only three short point labels and an optional bounded caption go on-glasses.
@MainActor
final class GlassesDisplay {
  private var display: Display?
  private let listeners = ListenerTokenBag()
  private var ready = false
  private var snapshot = TourSnapshot()
  private var page = 0
  private var pending = false
  private var renderTask: Task<Void, Never>?
  private var generation = 0
  var onError: ((String) -> Void)?
  var onSelect: ((Int?) -> Void)?
  var onTogglePlayback: (() -> Void)?
  var onNext: (() -> Void)?
  var onCycleRate: (() -> Void)?

  func attach(to session: DeviceSession) throws {
    generation += 1; let run = generation
    let capability = try session.addDisplay(); display = capability
    capability.statePublisher.listen { [weak self] state in
      let started = state == .started
      Task { @MainActor [weak self] in
        guard let self, self.generation == run else { return }
        self.ready = started
        if started { self.render() }
      }
    }.store(in: listeners)
    capability.start()
  }
  func show(_ value: TourSnapshot) {
    if value.selectedNumber != snapshot.selectedNumber || value.artworkTitle != snapshot.artworkTitle {
      page = HUDLayout.page(containing: value.selectedNumber, points: value.points)
    }
    snapshot = value; render()
  }
  func stop() {
    generation += 1
    ready = false; pending = false; renderTask?.cancel(); renderTask = nil
    listeners.clear(); display?.stop(); display = nil; snapshot = TourSnapshot(); page = 0
  }
  private func render() {
    pending = true
    guard ready, renderTask == nil, let display else { return }
    // Coalesce and serialize sends: an old caption must never overwrite
    // the UI after a user selects a different point.
    renderTask = Task { [weak self] in
      guard let self else { return }
      while self.ready && self.pending && !Task.isCancelled {
        self.pending = false
        let view = self.view()
        do { try await display.send(view) }
        catch { if !Task.isCancelled { self.onError?(error.localizedDescription) } }
      }
      if !Task.isCancelled { self.renderTask = nil }
    }
  }
  private func view() -> FlexBox {
    let value = snapshot, zh = value.language == "zh"
    let points = HUDLayout.points(on: page, from: value.points)
    return FlexBox(direction: .row, spacing: 18, crossAlignment: .stretch) {
      FlexBox(direction: .column, spacing: 8) {
        Text("MUSE.  ·  \(value.rateLabel)", style: .meta, color: .secondary)
        Text(HUDLayout.compact(value.artworkTitle.isEmpty ? (zh ? "请对准作品" : "Aim at an artwork") : value.artworkTitle,
          latin: 38, cjk: 16), style: .meta)
        FlexBox { }.flexGrow(1)
        if value.subtitles && !value.sentence.isEmpty {
          Text(HUDLayout.compact(value.sentence, latin: 88, cjk: 32), style: .meta)
        }
      }.flexGrow(7)
      if !value.points.isEmpty {
        FlexBox(direction: .column, spacing: 6) {
          Text(zh ? "细节探索" : "LOOK CLOSER", style: .meta, color: .secondary)
          for point in points {
            ButtonGroup {
              Button(label: "\(point.number). \(HUDLayout.compact(point.title, latin: 16, cjk: 7))",
                style: value.selectedNumber == point.number ? .primary : .secondary,
                onClick: { [weak self] in Task { @MainActor in self?.onSelect?(point.number) } })
            }
          }
          if value.points.count > HUDLayout.pointsPerPage {
            ButtonGroup {
              Button(label: zh ? "更多细节 ›" : "More points ›", style: .secondary, onClick: { [weak self] in
                Task { @MainActor in
                  guard let self else { return }
                  let count = (self.snapshot.points.count + HUDLayout.pointsPerPage - 1) / HUDLayout.pointsPerPage
                  self.page = (self.page + 1) % count; self.render()
                }
              })
            }
          }
          ButtonGroup {
            Button(label: value.playing ? (zh ? "暂停" : "Pause") : (zh ? "播放" : "Play"), style: .secondary,
              onClick: { [weak self] in Task { @MainActor in self?.onTogglePlayback?() } })
            Button(label: zh ? "下一处" : "Next", style: .secondary,
              onClick: { [weak self] in Task { @MainActor in self?.onNext?() } })
          }
          ButtonGroup {
            Button(label: value.rateLabel, style: .secondary,
              onClick: { [weak self] in Task { @MainActor in self?.onCycleRate?() } })
            Button(label: zh ? "总览" : "Intro", style: .secondary,
              onClick: { [weak self] in Task { @MainActor in self?.onSelect?(nil) } })
          }
        }.flexGrow(3)
      }
    }.padding(12).background(.none)
  }
}
