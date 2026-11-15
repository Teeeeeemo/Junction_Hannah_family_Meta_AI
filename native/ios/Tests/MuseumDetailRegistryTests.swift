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
    var sourceChecks = 0
    func check(_ value: Bool, _ message: String) { precondition(value, message); sourceChecks += 1 }
    let sourceA = MuseumSource(id: "catalog-a", title: "Registered museum record A", url: "https://museum.example/a")
    let sourceB = MuseumSource(id: "catalog-b", title: "Registered museum record B", url: "https://museum.example/b")
    func referencedGuide(_ ids: [String], sources: [MuseumSource] = []) -> MuseumGuide {
      MuseumGuide(mode: "gemini", artwork: initial.artwork, overview: initial.overview,
        details: [.init(id: "referenced-point", number: 2, title: "Current detail", description: "Visible marks.",
          box: [0.1,0.2,0.3,0.4], sourceIds: ids)], sources: sources)
    }
    let sourceGuide = referencedGuide(["catalog-b", "catalog-a", "catalog-b"], sources: [sourceA, sourceB])
    let references = MuseumSourceReferences.resolve(guide: sourceGuide, number: 2)
    check(references.scope == .detail && references.status == .available, "A selected detail resolves its own associated references")
    check(references.sources.map(\.id) == ["catalog-b", "catalog-a"], "References follow linked-ID order, deduplicate IDs, and never use the global list order")
    check(references.number == 2 && references.subjectTitle == "Current detail", "The panel title and content identify the same current detail")
    check(references.missingSourceIDs.isEmpty, "Every resolved ID has an existing reference record")
    let overview = MuseumSourceReferences.resolve(guide: sourceGuide, number: nil)
    check(overview.scope == .artwork && overview.sources.map(\.id) == ["catalog-a", "catalog-b"], "Overview shows explicitly scoped artwork references")
    check(overview.heading(language: "en") == "Artwork references" && references.heading(language: "zh").contains("2"), "Overview and detail headings cannot imply the same scope")
    let empty = MuseumSourceReferences.resolve(guide: referencedGuide([], sources: [sourceA]), number: 2)
    check(empty.status == .empty && empty.sources.isEmpty, "An unreferenced detail must never fall back to artwork references")
    check(empty.notice(language: "en") != nil, "An unreferenced detail has a clear in-place explanation")
    let partial = MuseumSourceReferences.resolve(guide: referencedGuide(["catalog-a", "missing", "missing"], sources: [sourceA]), number: 2)
    check(partial.status == .partial && partial.sources.map(\.id) == ["catalog-a"] && partial.missingSourceIDs == ["missing"], "Partly missing references remain explicit without inventing a URL")
    let unavailable = MuseumSourceReferences.resolve(guide: referencedGuide(["missing"], sources: [sourceA]), number: 2)
    check(unavailable.status == .unavailable && unavailable.sources.isEmpty, "Unknown linked IDs cannot expose unrelated artwork references")
    let invalidURL = MuseumSource(id: "catalog-a", title: sourceA.title, url: "http://museum.example/a")
    let invalid = MuseumSourceReferences.resolve(guide: referencedGuide([sourceA.id], sources: [invalidURL]), number: 2)
    check(invalid.status == .unavailable && invalid.sources.isEmpty, "Only existing HTTPS records are eligible; no URL is generated")
    let ambiguous = MuseumSourceReferences.resolve(guide: referencedGuide([sourceA.id], sources: [sourceA, sourceA]), number: 2)
    check(ambiguous.status == .unavailable, "Duplicate reference records are ambiguous rather than silently chosen")
    let noDetail = MuseumSourceReferences.resolve(guide: sourceGuide, number: 99)
    check(noDetail.status == .noDetail && noDetail.sources.isEmpty, "An unknown selected point cannot inherit another point's references")
    let noGuide = MuseumSourceReferences.resolve(guide: nil, number: 2)
    check(noGuide.status == .noGuide && noGuide.sources.isEmpty, "A stopped visit exposes no prior reference records")
    let switched = MuseumSourceReferences.resolve(guide: referencedGuide([sourceA.id], sources: [sourceA]), number: 2)
    check(switched.subjectTitle == references.subjectTitle && switched.sources.map(\.id) == [sourceA.id], "Each publication derives references from the current guide, not a retained panel cache")
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    let before = try! encoder.encode(sourceGuide)
    _ = MuseumSourceReferences.resolve(guide: sourceGuide, number: 2)
    check(try! encoder.encode(sourceGuide) == before, "Opening references cannot change guide text, geometry, IDs or numbering")
    print("Passed 9 native stable-detail registry checks and \(sourceChecks) current-reference checks.")
  }
}
