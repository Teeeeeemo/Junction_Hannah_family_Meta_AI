import Foundation

struct MuseumSource: Codable, Identifiable, Sendable {
  let id: String
  let title: String
  let url: String
}

/// References are existing backend records, never evidence of claim-by-claim verification.
struct MuseumSourceReferences: Sendable {
  enum Scope: Sendable { case none, artwork, detail }
  enum Status: Sendable { case noGuide, noDetail, empty, available, partial, unavailable }
  let scope: Scope
  let status: Status
  let number: Int?
  let subjectTitle: String
  let sources: [MuseumSource]
  let missingSourceIDs: [String]
  static func resolve(guide: MuseumGuide?, number: Int?) -> MuseumSourceReferences {
    guard let guide else {
      return MuseumSourceReferences(scope: .none, status: .noGuide, number: nil, subjectTitle: "", sources: [], missingSourceIDs: [])
    }
    let scope: Scope = number == nil ? .artwork : .detail
    let title: String
    let requested: [String]
    if let number {
      guard let detail = guide.details.first(where: { $0.number == number }) else {
        return MuseumSourceReferences(scope: .detail, status: .noDetail, number: number, subjectTitle: "", sources: [], missingSourceIDs: [])
      }
      title = detail.title; requested = detail.sourceIds
    } else { title = guide.artwork.title; requested = guide.sources.map(\.id) }
    var seen = Set<String>()
    let ids = requested.filter { seen.insert($0).inserted }
    let records = Dictionary(grouping: guide.sources, by: \.id)
    var resolved: [MuseumSource] = [], missing: [String] = []
    for id in ids {
      // The backend owns the source whitelist. Only referenced existing records
      // can be displayed; never construct a citation from model labels or IDs.
      guard let matches = records[id], matches.count == 1, let source = matches.first,
        !source.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        let url = URL(string: source.url), url.scheme == "https", url.host != nil else {
        missing.append(id); continue
      }
      resolved.append(source)
    }
    let status: Status = ids.isEmpty ? .empty : missing.isEmpty ? .available : resolved.isEmpty ? .unavailable : .partial
    return MuseumSourceReferences(scope: scope, status: status, number: number, subjectTitle: title,
      sources: resolved, missingSourceIDs: missing)
  }
  func heading(language: String) -> String {
    let zh = language == "zh"
    if scope == .artwork { return zh ? "作品参考资料" : "Artwork references" }
    if let number { return zh ? "第\(number)点 · 关联参考资料" : "Point \(number) · Associated references" }
    return zh ? "关联参考资料" : "Associated references"
  }
  func notice(language: String) -> String? {
    let zh = language == "zh"
    switch status {
    case .noGuide: return zh ? "开始导览后可查看参考资料。" : "Start a guide to view references."
    case .noDetail: return zh ? "当前细节已不可用。" : "This detail is no longer available."
    case .empty:
      return scope == .artwork ? (zh ? "该作品暂无已登记的参考资料。" : "No reference records are registered for this artwork.")
        : (zh ? "本细节未关联参考资料。" : "No reference records are linked to this detail.")
    case .partial: return zh ? "部分关联资料记录缺失。" : "Some linked reference records are missing."
    case .unavailable: return zh ? "关联资料记录暂不可用。" : "The linked reference records are unavailable."
    case .available: return nil
    }
  }
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
