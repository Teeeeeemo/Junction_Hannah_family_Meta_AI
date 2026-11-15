import Foundation
import UIKit
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
  private var epoch = SessionEpoch()
  private var inspectionImage: UIImage?
  var onError: ((String) -> Void)?
  var onSelect: ((Int?) -> Void)?
  var onTogglePlayback: (() -> Void)?
  var onNext: (() -> Void)?
  var onCycleRate: (() -> Void)?
  var onSourcesVisibility: ((Bool) -> Void)?
  var onSourcePage: ((Int) -> Void)?

  func attach(to session: DeviceSession) throws {
    let run = epoch.begin()
    let capability = try session.addDisplay(); display = capability
    capability.statePublisher.listen { [weak self] state in
      let started = state == .started
      Task { @MainActor [weak self] in
        guard let self, self.epoch.accepts(run) else { return }
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
  func showInspection(_ image: UIImage?) { inspectionImage = image; render() }
  func stop() {
    epoch.invalidate()
    ready = false; pending = false; renderTask?.cancel(); renderTask = nil
    listeners.clear(); display?.stop(); display = nil; snapshot = TourSnapshot(); page = 0; inspectionImage = nil
  }
  private func render() {
    pending = true
    guard ready, renderTask == nil, let display, let run = epoch.current else { return }
    // Coalesce and serialize sends: an old caption must never overwrite
    // the UI after a user selects a different point.
    renderTask = Task { [weak self] in
      guard let self else { return }
      while self.epoch.accepts(run) && self.ready && self.pending && !Task.isCancelled {
        self.pending = false
        let view = self.view(run: run)
        do { try await display.send(view) }
        catch { if self.epoch.accepts(run) && !Task.isCancelled { self.onError?(error.localizedDescription) } }
      }
      if self.epoch.accepts(run) && !Task.isCancelled { self.renderTask = nil }
    }
  }
  nonisolated private func dispatch(run: SessionEpoch.Token,
    action: @escaping @MainActor @Sendable (GlassesDisplay) -> Void) {
    Task { @MainActor [weak self] in
      guard let self, self.ready, self.epoch.accepts(run) else { return }
      action(self)
    }
  }
  private func view(run: SessionEpoch.Token) -> FlexBox {
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
      }.flexGrow(inspectionImage == nil ? 7 : 1)
      if value.sourcesShown {
        sourcesView(run: run).flexGrow(inspectionImage == nil ? 3 : 1)
      } else if !value.points.isEmpty {
        FlexBox(direction: .column, spacing: 6) {
          if let inspectionImage {
            MWDATDisplay.Image(image: inspectionImage, sizePreset: .fill).flexGrow(1)
          }
          Text(zh ? "细节探索" : "LOOK CLOSER", style: .meta, color: .secondary)
          for point in points {
            ButtonGroup {
              Button(label: "\(point.number). \(HUDLayout.compact(point.title, latin: 16, cjk: 7))",
                style: value.selectedNumber == point.number ? .primary : .secondary,
                onClick: { [weak self] in self?.dispatch(run: run) { $0.onSelect?(point.number) } })
            }
          }
          if value.points.count > HUDLayout.pointsPerPage {
            ButtonGroup {
              Button(label: zh ? "更多细节 ›" : "More points ›", style: .secondary, onClick: { [weak self] in
                self?.dispatch(run: run) { display in
                  let count = (display.snapshot.points.count + HUDLayout.pointsPerPage - 1) / HUDLayout.pointsPerPage
                  guard count > 0 else { return }
                  display.page = (display.page + 1) % count; display.render()
                }
              })
            }
          }
          ButtonGroup {
            Button(label: value.playing ? (zh ? "暂停" : "Pause") : (zh ? "播放" : "Play"), style: .secondary,
              onClick: { [weak self] in self?.dispatch(run: run) { $0.onTogglePlayback?() } })
            Button(label: zh ? "下一处" : "Next", style: .secondary,
              onClick: { [weak self] in self?.dispatch(run: run) { $0.onNext?() } })
          }
          ButtonGroup {
            Button(label: value.rateLabel, style: .secondary,
              onClick: { [weak self] in self?.dispatch(run: run) { $0.onCycleRate?() } })
            Button(label: zh ? "总览" : "Intro", style: .secondary,
              onClick: { [weak self] in self?.dispatch(run: run) { $0.onSelect?(nil) } })
          }
          ButtonGroup {
            Button(label: zh ? "参考资料" : "References", style: .secondary,
              onClick: { [weak self] in self?.dispatch(run: run) { $0.onSourcesVisibility?(true) } })
          }
        }.flexGrow(inspectionImage == nil ? 3 : 1)
      }
    }.padding(12).background(.none)
  }
  private func sourcesView(run: SessionEpoch.Token) -> FlexBox {
    let value = snapshot, references = value.sourceReferences, zh = value.language == "zh"
    return FlexBox(direction: .column, spacing: 8) {
      Text(references.heading(language: value.language), style: .meta, color: .secondary)
      Text(HUDLayout.compact(references.subjectTitle, latin: 38, cjk: 16), style: .meta)
      if let notice = references.notice(language: value.language) {
        Text(HUDLayout.compact(notice, latin: 88, cjk: 32), style: .meta)
      }
      if references.sources.indices.contains(value.sourcePage) {
        let source = references.sources[value.sourcePage]
        Text(HUDLayout.compact(source.title, latin: 64, cjk: 28), style: .meta)
        Text(URL(string: source.url)?.host ?? "", style: .meta, color: .secondary)
        if references.sources.count > 1 {
          Text("\(value.sourcePage + 1) / \(references.sources.count)", style: .meta, color: .secondary)
          ButtonGroup {
            if value.sourcePage > 0 {
              Button(label: zh ? "上一条" : "Previous", style: .secondary,
                onClick: { [weak self] in self?.dispatch(run: run) { $0.onSourcePage?(-1) } })
            }
            if value.sourcePage + 1 < references.sources.count {
              Button(label: zh ? "下一条" : "Next reference", style: .secondary,
                onClick: { [weak self] in self?.dispatch(run: run) { $0.onSourcePage?(1) } })
            }
          }
        }
      }
      ButtonGroup {
        Button(label: zh ? "返回导览" : "Back to guide", style: .secondary,
          onClick: { [weak self] in self?.dispatch(run: run) { $0.onSourcesVisibility?(false) } })
      }
    }
  }
}
