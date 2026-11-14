import Foundation

/// Keeps assigned numbers for an established appearance identity. It does not
/// claim to match a new model-generated identity key to the same physical work.
struct MuseumDetailRegistry: Sendable {
  private var artworkIdentity: String?
  private var numbers: [String: Int] = [:]
  private var nextNumber = 1

  mutating func reset() {
    artworkIdentity = nil; numbers = [:]; nextNumber = 1
  }

  mutating func reconcile(_ guide: MuseumGuide) -> MuseumGuide {
    guard let identity = guide.recognition?.selectedCandidate?.identityKey, !identity.isEmpty else {
      reset(); return guide
    }
    if identity != artworkIdentity { reset(); artworkIdentity = identity }
    var details: [MuseumDetail] = []
    var included = Set<String>()
    for detail in guide.details {
      guard included.insert(detail.id).inserted else { continue }
      if numbers[detail.id] == nil {
        // Live commands accept 1...8. Reserved numbers are never recycled while
        // this artwork identity is active, so an absent point cannot change ID.
        guard nextNumber <= 8 else { continue }
        numbers[detail.id] = nextNumber; nextNumber += 1
      }
      details.append(MuseumDetail(id: detail.id, number: numbers[detail.id]!, title: detail.title,
        description: detail.description, box: detail.box, sourceIds: detail.sourceIds))
    }
    // Only currently detected details are published. Stored IDs carry no stale
    // coordinates or visibility claims; a returning ID uses its new detection.
    return MuseumGuide(mode: guide.mode, artwork: guide.artwork, overview: guide.overview,
      details: details.sorted { $0.number < $1.number }, sources: guide.sources,
      schemaVersion: guide.schemaVersion, recognition: guide.recognition,
      coordinateSpace: guide.coordinateSpace, roi: guide.roi)
  }
}
