import Foundation

struct MuseumSource: Codable, Identifiable, Sendable {
  let id: String
  let title: String
  let url: String
}
struct MuseumArtworkCandidate: Codable, Identifiable, Sendable {
  let id: String
  let identityKey: String
  let label: String
  let box: [Double]
  let confidence: Double
  let evidence: String
  let kind: String
}
struct MuseumArtworkSearch: Codable, Sendable {
  let schemaVersion: Int
  let status: String
  let reason: String
  let candidates: [MuseumArtworkCandidate]
  let selectedCandidateId: String?
  let observationCount: Int
  var selectedCandidate: MuseumArtworkCandidate? { candidates.first { $0.id == selectedCandidateId } }
  /// The old identity is a matching hint, never a current observation or lock.
  func identityHints() -> MuseumArtworkSearch? {
    guard schemaVersion == 2, status == "locked", observationCount >= 2,
      let candidate = selectedCandidate, candidate.kind == "planar",
      !candidate.identityKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return MuseumArtworkSearch(schemaVersion: 2, status: "searching", reason: "Identity hints only; verify in new frames.",
      candidates: [candidate], selectedCandidateId: nil, observationCount: 0)
  }
}
struct MuseumROI: Codable, Sendable {
  let frameId: String
  let frameWidth: Int
  let frameHeight: Int
  let box: [Double]
  // Axis-aligned native-pixel crop, no synthetic perspective correction.
  func frameBox(for local: [Double]) -> [Double]? {
    guard box.count == 4, local.count == 4,
      (box + local).allSatisfy({ $0.isFinite }),
      box[0] >= 0, box[1] >= 0, box[2] > 0, box[3] > 0,
      box[0] + box[2] <= 1.001, box[1] + box[3] <= 1.001,
      local[0] >= 0, local[1] >= 0, local[2] > 0, local[3] > 0,
      local[0] + local[2] <= 1.001, local[1] + local[3] <= 1.001 else { return nil }
    return [box[0] + local[0] * box[2], box[1] + local[1] * box[3], local[2] * box[2], local[3] * box[3]]
  }
}
struct MuseumDetail: Codable, Identifiable, Sendable {
  let id: String
  let number: Int
  let title: String
  let description: String
  let box: [Double]
  let sourceIds: [String]
  init(id: String, number: Int, title: String, description: String, box: [Double], sourceIds: [String] = []) {
    self.id = id; self.number = number; self.title = title; self.description = description; self.box = box; self.sourceIds = sourceIds
  }
  enum CodingKeys: String, CodingKey { case id, number, title, description, box, sourceIds }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id); number = try c.decode(Int.self, forKey: .number)
    title = try c.decode(String.self, forKey: .title); description = try c.decode(String.self, forKey: .description)
    box = try c.decode([Double].self, forKey: .box); sourceIds = try c.decodeIfPresent([String].self, forKey: .sourceIds) ?? []
  }
}
struct MuseumGuide: Codable, Sendable {
  struct Artwork: Codable, Sendable { let id: String; let title: String; let artist: String; let year: String }
  let mode: String
  let artwork: Artwork
  let overview: String
  let details: [MuseumDetail]
  let sources: [MuseumSource]
  let schemaVersion: Int?
  let recognition: MuseumArtworkSearch?
  let coordinateSpace: String?
  let roi: MuseumROI?
  init(mode: String, artwork: Artwork, overview: String, details: [MuseumDetail], sources: [MuseumSource] = [], schemaVersion: Int? = nil, recognition: MuseumArtworkSearch? = nil, coordinateSpace: String? = nil, roi: MuseumROI? = nil) {
    self.mode = mode; self.artwork = artwork; self.overview = overview; self.details = details; self.sources = sources
    self.schemaVersion = schemaVersion; self.recognition = recognition; self.coordinateSpace = coordinateSpace; self.roi = roi
  }
  enum CodingKeys: String, CodingKey { case mode, artwork, overview, details, sources, schemaVersion, recognition, coordinateSpace, roi }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    mode = try c.decode(String.self, forKey: .mode); artwork = try c.decode(Artwork.self, forKey: .artwork)
    overview = try c.decode(String.self, forKey: .overview); details = try c.decode([MuseumDetail].self, forKey: .details)
    sources = try c.decodeIfPresent([MuseumSource].self, forKey: .sources) ?? []
    schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
    recognition = try c.decodeIfPresent(MuseumArtworkSearch.self, forKey: .recognition)
    coordinateSpace = try c.decodeIfPresent(String.self, forKey: .coordinateSpace)
    roi = try c.decodeIfPresent(MuseumROI.self, forKey: .roi)
  }
  func frameBox(for detail: MuseumDetail) -> [Double]? {
    coordinateSpace == "artwork_roi" ? roi?.frameBox(for: detail.box) : detail.box
  }
  /// A late translation contributes text only, never its stale geometry or IDs.
  func mergingTranslation(_ translated: MuseumGuide) -> MuseumGuide? {
    let ids = details.map(\.id), translatedIDs = translated.details.map(\.id)
    guard mode == translated.mode, artwork.id == translated.artwork.id,
      Set(ids).count == ids.count, Set(translatedIDs).count == translatedIDs.count,
      Set(ids) == Set(translatedIDs) else { return nil }
    let byID = Dictionary(uniqueKeysWithValues: translated.details.map { ($0.id, $0) })
    let textDetails = details.map { detail in
      let text = byID[detail.id]!
      return MuseumDetail(id: detail.id, number: detail.number, title: text.title, description: text.description,
        box: detail.box, sourceIds: detail.sourceIds)
    }
    return MuseumGuide(mode: mode,
      artwork: .init(id: artwork.id, title: translated.artwork.title, artist: artwork.artist, year: artwork.year),
      overview: translated.overview, details: textDetails, sources: sources, schemaVersion: schemaVersion,
      recognition: recognition, coordinateSpace: coordinateSpace, roi: roi)
  }
  /// Fixed local diagnostics only: no image content, identity or server text.
  /// This is the single validation path used by relocalized(to:roi:).
  func relocalizationFailure(to lock: MuseumArtworkSearch, roi: MuseumROI) -> String? {
    func validBox(_ box: [Double]) -> Bool {
      box.count == 4 && box.allSatisfy(\.isFinite) && box[0] >= 0 && box[1] >= 0 &&
        box[2] > 0 && box[3] > 0 && box[0] + box[2] <= 1.000000001 && box[1] + box[3] <= 1.000000001
    }
    guard coordinateSpace == "artwork_roi" else { return "coordinate_space" }
    guard lock.schemaVersion == 2, lock.status == "locked", lock.observationCount >= 2,
      let candidate = lock.selectedCandidate, candidate.kind == "planar" else { return "lock_state" }
    guard let identity = recognition?.selectedCandidate?.identityKey,
      !identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      candidate.identityKey == identity else { return "identity_mismatch" }
    guard validBox(candidate.box), validBox(roi.box),
      !roi.frameId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      (1...20_000).contains(roi.frameWidth), (1...20_000).contains(roi.frameHeight) else { return "roi_region" }
    guard details.allSatisfy({ validBox($0.box) }) else { return "detail_box" }
    guard Double(roi.frameWidth) * roi.box[2] >= 96,
      Double(roi.frameHeight) * roi.box[3] >= 96 else { return "pixel_count" }
    // Integral cropping rounds either edge by less than one original pixel.
    // Compare edges so size rounding cannot silently shift the artwork region.
    for axis in 0...1 {
      let pixels = Double(axis == 0 ? roi.frameWidth : roi.frameHeight)
      // At least one original pixel of margin: an edge-touching artwork may
      // be partially cropped, so ask the visitor to reframe rather than guess.
      guard candidate.box[axis] * pixels >= 0.9999999,
        (1 - candidate.box[axis] - candidate.box[axis + 2]) * pixels >= 0.9999999 else { return "cropped_artwork" }
      guard abs(roi.box[axis] - candidate.box[axis]) * pixels <= 1.0000001,
        abs(roi.box[axis] + roi.box[axis + 2] - candidate.box[axis] - candidate.box[axis + 2]) * pixels <= 1.0000001 else { return "crop_rounding" }
    }
    return nil
  }
  /// Reuse annotations for the controlled, near-frontal planar demo baseline.
  /// This is not perspective correction or a fresh detail detection.
  /// The caller must still obtain a fresh tracking result before showing boxes.
  func relocalized(to lock: MuseumArtworkSearch, roi: MuseumROI) -> MuseumGuide? {
    guard relocalizationFailure(to: lock, roi: roi) == nil else { return nil }
    return MuseumGuide(mode: mode, artwork: artwork, overview: overview, details: details, sources: sources,
      schemaVersion: schemaVersion, recognition: lock, coordinateSpace: coordinateSpace, roi: roi)
  }
}

/// Uses the existing authenticated backend. Never stores a Gemini key on iPhone.
actor MuseumBackend {
  private let session = URLSession(configuration: .ephemeral)
  private var origin: URL?
  private var cookie: String?
  private var connectionGeneration = 0

  func connect(entryLink: String) async throws {
    connectionGeneration += 1; let generation = connectionGeneration
    origin = nil; cookie = nil
    guard var components = URLComponents(string: entryLink.trimmingCharacters(in: .whitespacesAndNewlines)),
      components.scheme == "https", components.host != nil,
      components.user == nil, components.password == nil else {
      throw failure("Paste the complete HTTPS device-test link.")
    }
    guard let entry = components.url else { throw failure("Invalid test link.") }
    let (_, response) = try await session.data(from: entry)
    guard generation == connectionGeneration else { throw CancellationError() }
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      throw failure("The device-test link was rejected or expired.")
    }
    let headers = http.allHeaderFields.reduce(into: [String: String]()) { values, pair in
      values[String(describing: pair.key)] = String(describing: pair.value)
    }
    let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: entry)
    guard cookies.contains(where: { $0.name == "museum_device_preview" }) else {
      throw failure("The test entrance did not issue a session cookie.")
    }
    components.path = "/"; components.query = nil; components.fragment = nil
    origin = components.url
    cookie = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
  }

  private func request(path: String) throws -> URLRequest {
    guard let origin, let cookie else { throw failure("Connect the test backend first.") }
    var request = URLRequest(url: origin.appendingPathComponent(path))
    request.timeoutInterval = 55
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(cookie, forHTTPHeaderField: "Cookie")
    request.setValue(origin.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forHTTPHeaderField: "Origin")
    return request
  }

  func liveSocket() throws -> URLSessionWebSocketTask {
    var value = try request(path: "api/live")
    guard var components = URLComponents(url: value.url!, resolvingAgainstBaseURL: false) else { throw failure("Invalid backend URL.") }
    components.scheme = "wss"; value.url = components.url; value.timeoutInterval = 18
    return session.webSocketTask(with: value)
  }

  private func post<T: Decodable>(_ path: String, payload: [String: Any]) async throws -> T {
    let generation = connectionGeneration
    var value = try request(path: path); value.httpMethod = "POST"
    value.httpBody = try JSONSerialization.data(withJSONObject: payload)
    let (data, response) = try await session.data(for: value)
    guard generation == connectionGeneration else { throw CancellationError() }
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      throw failure(body?["error"] as? String ?? "The backend request failed.")
    }
    return try JSONDecoder().decode(T.self, from: data)
  }

  private func object<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
  }

  func searchArtwork(jpeg: Data, language: String, previous: MuseumArtworkSearch? = nil, confirmedCandidateId: String? = nil) async throws -> MuseumArtworkSearch {
    var payload: [String: Any] = ["image": "data:image/jpeg;base64," + jpeg.base64EncodedString(), "language": language]
    if let previous { payload["previous"] = try object(previous) }
    if let confirmedCandidateId { payload["confirmedCandidateId"] = confirmedCandidateId }
    return try await post("api/artwork-candidates", payload: payload)
  }

  func analyze(jpeg: Data, language: String, lock: MuseumArtworkSearch? = nil, roi: MuseumROI? = nil, artworkId: String? = nil) async throws -> MuseumGuide {
    var payload: [String: Any] = ["image": "data:image/jpeg;base64," + jpeg.base64EncodedString(), "language": language, "demo": false]
    if let lock { payload["lock"] = try object(lock) }
    if let roi { payload["roi"] = try object(roi) }
    if let artworkId { payload["artworkId"] = artworkId }
    let guide: MuseumGuide = try await post("api/analyze", payload: payload)
    guard guide.mode == "gemini", !guide.details.isEmpty else { throw failure("No reliable artwork details were returned.") }
    return guide
  }

  func translate(_ guide: MuseumGuide, language: String) async throws -> MuseumGuide {
    try await post("api/translate", payload: ["analysis": try object(guide), "language": language, "demo": guide.mode == "demo"])
  }

  private func failure(_ message: String) -> NSError {
    NSError(domain: "MuseumCompanion", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
