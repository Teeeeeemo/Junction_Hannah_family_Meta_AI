import Foundation

@main struct MuseumDetailRegistryTests {
  static func main() {
    var registry = MuseumDetailRegistry()
    func guide(_ ids: [String], identity: String = "blue-landscape") -> MuseumGuide {
      let candidate = MuseumArtworkCandidate(id: "work-" + identity, identityKey: identity, label: "Exhibit", box: [0.1,0.2,0.5,0.5], confidence: 0.95, evidence: "Museum label", kind: "planar")
      return MuseumGuide(mode: "gemini", artwork: .init(id: "unidentified", title: "Visible exhibit", artist: "Unknown", year: "Unknown"), overview: "Observation", details: ids.enumerated().map { index, id in
        MuseumDetail(id: id, number: index+1, title: id, description: "Visible " + id, box: [0.1,0.2,0.3,0.4], sourceIds: ["test-source"])
      }, sources: [.init(id: "test-source", title: "Trusted source", url: "https://museum.example/source")], schemaVersion: 2,
        recognition: .init(schemaVersion: 2, status: "locked", reason: "Exhibit", candidates: [candidate], selectedCandidateId: candidate.id, observationCount: 2),
        coordinateSpace: "artwork_roi", roi: .init(frameId: "f1", frameWidth: 1000, frameHeight: 800, box: candidate.box))
    }
    let initial = registry.reconcile(guide(["tree", "cloud", "wheat"]))
    precondition(initial.details.map(\.number) == [1,2,3])
    let reordered = registry.reconcile(guide(["wheat", "tree", "cloud"]))
    precondition(Dictionary(uniqueKeysWithValues: reordered.details.map { ($0.id,$0.number) }) == ["tree":1,"cloud":2,"wheat":3], "Reordering must retain existing ID numbers")
    let missing = registry.reconcile(guide(["wheat", "tree"]))
    precondition(missing.details.map(\.id) == ["tree","wheat"] && missing.details.map(\.number) == [1,3], "Missing points reserve their number without publishing a stale box")
    let appended = registry.reconcile(guide(["new-hill", "tree", "wheat"]))
    precondition(appended.details.map(\.number) == [1,3,4] && appended.details.last?.id == "new-hill", "New points append after reserved numbers")
    let restored = registry.reconcile(guide(["cloud"]))
    precondition(restored.details.count == 1 && restored.details[0].number == 2, "Reappearing ID recovers its original number")
    precondition(restored.roi?.frameId == initial.roi?.frameId && restored.recognition?.selectedCandidateId == initial.recognition?.selectedCandidateId && restored.coordinateSpace == initial.coordinateSpace && restored.sources[0].id == "test-source" && restored.details[0].sourceIds == ["test-source"], "Reconcile must preserve guide metadata and current-frame geometry")
    let other = registry.reconcile(guide(["tree"], identity: "different-work"))
    precondition(other.details.first?.number == 1, "Different physical artwork identity starts a new list")
    _ = registry.reconcile(guide(["tree", "cloud"], identity: "different-work")); registry.reset()
    let reset = registry.reconcile(guide(["cloud"], identity: "different-work"))
    precondition(reset.details.first?.number == 1, "Session reset releases old numbering")
    registry.reset()
    _ = registry.reconcile(guide((1...8).map { "point-\($0)" }))
    let capped = registry.reconcile(guide(["point-9", "point-3"]))
    precondition(capped.details.count == 1 && capped.details[0].id == "point-3" && capped.details[0].number == 3, "Reserved numbers are bounded to valid Live command numbers without recycling absent identities")
    var relocationChecks = 0
    func check(_ result: Bool, _ message: String) {
      precondition(result, message); relocationChecks += 1
    }
    let movedBox = [0.2, 0.1, 0.6, 0.7]
    func lock(identity: String = "blue-landscape", kind: String = "planar", status: String = "locked", observations: Int = 2,
      box: [Double] = [0.2, 0.1, 0.6, 0.7], selected: Bool = true) -> MuseumArtworkSearch {
      let candidate = MuseumArtworkCandidate(id: "new-observation", identityKey: identity, label: "Fresh exhibit", box: box,
        confidence: 0.95, evidence: "Fresh museum label", kind: kind)
      return MuseumArtworkSearch(schemaVersion: 2, status: status, reason: "Fresh observations", candidates: [candidate],
        selectedCandidateId: selected ? candidate.id : nil, observationCount: observations)
    }
    func roi(box: [Double] = [0.2, 0.1, 0.6, 0.7], frame: String = "fresh-frame", width: Int = 1000, height: Int = 800) -> MuseumROI {
      MuseumROI(frameId: frame, frameWidth: width, frameHeight: height, box: box)
    }
    let newLock = lock(), newROI = roi()
    let relocated = appended.relocalized(to: newLock, roi: newROI)
    check(relocated != nil, "A freshly locked matching planar work can replace its ROI")
    if let relocated {
      let expected = MuseumGuide(mode: appended.mode, artwork: appended.artwork, overview: appended.overview,
        details: appended.details, sources: appended.sources, schemaVersion: appended.schemaVersion,
        recognition: newLock, coordinateSpace: appended.coordinateSpace, roi: newROI)
      let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
      check(try! encoder.encode(relocated) == encoder.encode(expected), "Relocation changes only recognition and ROI; all text, IDs, numbering and citations survive")
      check(relocated.details.map(\.number) == [1,3,4], "Relocation preserves reserved, nonconsecutive point numbers")
      check(relocated.roi?.frameId == "fresh-frame" && relocated.recognition?.selectedCandidateId == "new-observation",
        "New geometry records the new observation and frame, not the old lock")
      check(relocated.frameBox(for: relocated.details[0]) == newROI.frameBox(for: appended.details[0].box),
        "Retained artwork-relative detail coordinates map through the fresh ROI")
    }
    check(initial.relocalized(to: lock(identity: "other-work"), roi: newROI) == nil, "A different identity cannot inherit the old narration")
    check(guide(["tree"], identity: "").relocalized(to: lock(identity: ""), roi: newROI) == nil, "Empty identities cannot establish a match")
    check(initial.relocalized(to: lock(kind: "object"), roi: newROI) == nil, "Object geometry cannot use planar relocation")
    check(initial.relocalized(to: lock(status: "searching"), roi: newROI) == nil, "An unconfirmed search cannot relocate a guide")
    check(initial.relocalized(to: lock(status: "needs_confirmation"), roi: newROI) == nil, "Ambiguous works require confirmation")
    check(initial.relocalized(to: lock(observations: 1), roi: newROI) == nil, "One observation does not establish a fresh lock")
    check(initial.relocalized(to: lock(selected: false), roi: newROI) == nil, "A lock without a selected candidate is invalid")
    let frameGuide = MuseumGuide(mode: initial.mode, artwork: initial.artwork, overview: initial.overview, details: initial.details,
      sources: initial.sources, recognition: initial.recognition, coordinateSpace: "frame", roi: initial.roi)
    check(frameGuide.relocalized(to: newLock, roi: newROI) == nil, "Frame-relative details cannot be reinterpreted as artwork-relative")
    check(initial.relocalized(to: newLock, roi: roi(frame: " \n")) == nil, "A fresh ROI must identify its input frame")
    check(initial.relocalized(to: newLock, roi: roi(width: 0)) == nil, "Frame dimensions must be positive")
    check(initial.relocalized(to: newLock, roi: roi(height: 20_001)) == nil, "Frame dimensions retain the backend size bound")
    check(initial.relocalized(to: newLock, roi: roi(width: 100, height: 100)) == nil, "Digital enlargement cannot substitute for 96 original pixels per axis")
    check(initial.relocalized(to: newLock, roi: roi(box: [0.225, 0.1, 0.6, 0.7])) == nil, "ROI must correspond to the newly selected artwork region")
    for invalid in [[0.2, 0.1, 0.6], [Double.nan, 0.1, 0.6, 0.7], [-0.1, 0.1, 0.6, 0.7], [0.2, 0.1, 0.9, 0.7], [0.2, 0.1, 0, 0.7]] {
      check(initial.relocalized(to: lock(box: invalid), roi: roi(box: invalid)) == nil, "Malformed, nonfinite or out-of-frame regions are rejected")
    }
    check(initial.relocalized(to: lock(box: [0.2003, 0.1004, 0.5993, 0.6993]), roi: roi(box: movedBox)) != nil,
      "Integral original-pixel cropping may round each candidate edge by at most one pixel")
    for edgeBox in [[0, 0.1, 0.6, 0.7], [0.0005, 0.1, 0.6, 0.7], [0.4, 0.1, 0.6, 0.7], [0.2, 0, 0.6, 0.7], [0.2, 0.3, 0.6, 0.7]] {
      check(initial.relocalized(to: lock(box: edgeBox), roi: roi(box: edgeBox)) == nil,
        "Frame-edge candidates may be cropped and require the visitor to reframe")
    }
    let onePixelMargin = [0.001, 0.00125, 0.6, 0.7]
    check(initial.relocalized(to: lock(box: onePixelMargin), roi: roi(box: onePixelMargin)) != nil,
      "A full one-original-pixel candidate margin satisfies the conservative edge check")
    let malformed = MuseumGuide(mode: initial.mode, artwork: initial.artwork, overview: initial.overview,
      details: [.init(id: "invalid", number: 1, title: "Invalid", description: "Invalid", box: [0, 0, 2, 1])],
      recognition: initial.recognition, coordinateSpace: "artwork_roi", roi: initial.roi)
    check(malformed.relocalized(to: newLock, roi: newROI) == nil, "Relocation rejects invalid retained detail coordinates without filtering IDs")
    let relocationCount = relocationChecks
    // HTTP translation started before recovery and returns the old ROI later.
    // Its text is useful, but all of its transport/geometry metadata is stale.
    func translation(details: [MuseumDetail]? = nil, mode: String = "gemini", artworkID: String = "unidentified") -> MuseumGuide {
      MuseumGuide(mode: mode, artwork: .init(id: artworkID, title: "新标题", artist: "Changed artist", year: "2099"),
        overview: "翻译后的介绍。", details: details ?? appended.details.reversed().map {
          MuseumDetail(id: $0.id, number: 8, title: "译文 " + $0.id, description: "翻译后的细节 " + $0.id,
            box: [0.8, 0.8, 0.1, 0.1], sourceIds: ["untrusted-translation-source"])
        }, sources: [.init(id: "untrusted-translation-source", title: "Changed source", url: "https://translation.example")],
        schemaVersion: 99, recognition: appended.recognition, coordinateSpace: "frame", roi: appended.roi)
    }
    let freshGuide = appended.relocalized(to: newLock, roi: newROI)!
    let lateTranslation = translation()
    let merged = freshGuide.mergingTranslation(lateTranslation)
    check(merged != nil, "Late translation can merge into the same guide after a fresh ROI was committed")
    if let merged {
      let translatedByID = Dictionary(uniqueKeysWithValues: lateTranslation.details.map { ($0.id, $0) })
      let expected = MuseumGuide(mode: freshGuide.mode,
        artwork: .init(id: freshGuide.artwork.id, title: lateTranslation.artwork.title,
          artist: freshGuide.artwork.artist, year: freshGuide.artwork.year), overview: lateTranslation.overview,
        details: freshGuide.details.map { detail in
          MuseumDetail(id: detail.id, number: detail.number, title: translatedByID[detail.id]!.title,
            description: translatedByID[detail.id]!.description, box: detail.box, sourceIds: detail.sourceIds)
        }, sources: freshGuide.sources, schemaVersion: freshGuide.schemaVersion, recognition: freshGuide.recognition,
        coordinateSpace: freshGuide.coordinateSpace, roi: freshGuide.roi)
      let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
      check(try! encoder.encode(merged) == encoder.encode(expected),
        "Only translated titles, overview and descriptions change; current identity, citations and geometry survive")
      check(merged.roi?.frameId == "fresh-frame" && merged.recognition?.selectedCandidateId == "new-observation",
        "Translation cannot restore its old ROI or old recognition lock")
      check(merged.details.map(\.id) == freshGuide.details.map(\.id) && merged.details.map(\.number) == [1,3,4],
        "Translated response order and numbers cannot reorder the current list")
    }
    check(freshGuide.mergingTranslation(translation(mode: "demo")) == nil, "A translation cannot change guide mode")
    check(freshGuide.mergingTranslation(translation(artworkID: "other-work")) == nil, "A different artwork cannot supply translated content")
    check(freshGuide.mergingTranslation(translation(details: Array(lateTranslation.details.dropLast()))) == nil,
      "Missing translated detail IDs are rejected without partially updating text")
    check(freshGuide.mergingTranslation(translation(details: lateTranslation.details + [lateTranslation.details[0]])) == nil,
      "Extra translated entries are rejected")
    let duplicateIDs = [lateTranslation.details[0], lateTranslation.details[0], lateTranslation.details[2]]
    check(freshGuide.mergingTranslation(translation(details: duplicateIDs)) == nil, "Duplicate translated IDs cannot masquerade as complete content")
    let changedID = MuseumDetail(id: "new-id", number: 1, title: "New", description: "New", box: [0,0,1,1])
    check(freshGuide.mergingTranslation(translation(details: [changedID] + lateTranslation.details.dropFirst())) == nil,
      "A new translated ID cannot replace an established detail")
    let duplicateCurrent = MuseumGuide(mode: freshGuide.mode, artwork: freshGuide.artwork, overview: freshGuide.overview,
      details: [freshGuide.details[0], freshGuide.details[0], freshGuide.details[2]])
    check(duplicateCurrent.mergingTranslation(translation(details: duplicateIDs)) == nil, "Current IDs must also be unique before merging")
    let demo = MuseumGuide(mode: "demo", artwork: appended.artwork, overview: appended.overview, details: appended.details)
    check(demo.mergingTranslation(translation(mode: "demo"))?.details.map(\.id) == demo.details.map(\.id),
      "Offline demo translations use the same ID-safe text merge")
    let translationCount = relocationChecks - relocationCount
    let diagnosticCases: [(MuseumGuide, MuseumArtworkSearch, MuseumROI, String?)] = [
      (initial, newLock, newROI, nil),
      (initial, lock(identity: "other-work"), newROI, "identity_mismatch"),
      (frameGuide, newLock, newROI, "coordinate_space"),
      (initial, lock(status: "searching"), newROI, "lock_state"),
      (initial, lock(observations: 1), newROI, "lock_state"),
      (initial, lock(selected: false), newROI, "lock_state"),
      (initial, lock(kind: "object"), newROI, "lock_state"),
      (initial, newLock, roi(box: [0.2, 0.1, 0.9, 0.7]), "roi_region"),
      (initial, lock(box: [Double.nan, 0.1, 0.6, 0.7]), newROI, "roi_region"),
      (initial, newLock, roi(frame: ""), "roi_region"),
      (initial, newLock, roi(width: 0), "roi_region"),
      (malformed, newLock, newROI, "detail_box"),
      (initial, newLock, roi(width: 100, height: 100), "pixel_count"),
      (initial, newLock, roi(box: [0.225, 0.1, 0.6, 0.7]), "crop_rounding"),
      (initial, lock(box: [0, 0.1, 0.6, 0.7]), roi(box: [0, 0.1, 0.6, 0.7]), "cropped_artwork"),
    ]
    let diagnosticStart = relocationChecks
    for (current, candidateLock, candidateROI, expectedCode) in diagnosticCases {
      check(current.relocalizationFailure(to: candidateLock, roi: candidateROI) == expectedCode,
        "Relocation diagnostics distinguish the exact failed gate using a fixed reason code")
      check((current.relocalized(to: candidateLock, roi: candidateROI) != nil) == (expectedCode == nil),
        "Diagnostics and relocation share identical acceptance gates")
    }
    let diagnosticCount = relocationChecks - diagnosticStart
    let unrelated = MuseumArtworkCandidate(id: "unrelated", identityKey: "other-work", label: "Another work", box: movedBox,
      confidence: 0.95, evidence: "Another frame", kind: "planar")
    let reference = MuseumArtworkSearch(schemaVersion: 2, status: "locked", reason: "Original identity lock",
      candidates: newLock.candidates + [unrelated], selectedCandidateId: newLock.selectedCandidateId, observationCount: 3)
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    let referenceBefore = try! encoder.encode(reference)
    let hints = reference.identityHints()
    check(hints != nil, "An established planar artwork can provide identity hints for recovery")
    check(hints?.candidates.map(\.id) == [newLock.selectedCandidate!.id], "Hints contain only the previously selected work")
    check(hints?.candidates.first?.identityKey == newLock.selectedCandidate?.identityKey && hints?.candidates.first?.box == movedBox,
      "Identity hints preserve the selected candidate without rewriting its appearance key")
    check(hints?.status == "searching" && hints?.observationCount == 0 && hints?.selectedCandidateId == nil,
      "Hints contribute zero current observations and no confirmed selection")
    check(hints?.reason == "Identity hints only; verify in new frames.", "Hint reasoning is fixed and does not inherit model instructions")
    check(try! encoder.encode(reference) == referenceBefore, "Preparing hints cannot mutate the established lock")
    let invalidReferences = [
      MuseumArtworkSearch(schemaVersion: 1, status: reference.status, reason: reference.reason, candidates: reference.candidates,
        selectedCandidateId: reference.selectedCandidateId, observationCount: reference.observationCount),
      lock(status: "searching"), lock(observations: 1), lock(selected: false), lock(kind: "object"),
      lock(identity: ""), lock(identity: " \n"),
    ]
    for invalid in invalidReferences {
      check(invalid.identityHints() == nil, "An invalid, unselected or unconfirmed identity cannot supply recovery hints")
    }
    print("Passed 9 native stable-detail registry checks, \(relocationCount) guide relocation checks, \(translationCount) translation merge checks, \(diagnosticCount) relocation diagnostic checks and \(relocationChecks - diagnosticStart - diagnosticCount) identity hint checks. Identity changes still require visual re-identification.")
  }
}
