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
    print("Passed 9 native stable-detail registry checks. Identity key changes still require visual re-identification; absent points are not rendered.")
  }
}
