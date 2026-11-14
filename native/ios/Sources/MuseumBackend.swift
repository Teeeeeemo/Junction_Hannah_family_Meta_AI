import Foundation

struct MuseumDetail: Decodable, Identifiable, Sendable {
  let id: String
  let number: Int
  let title: String
  let description: String
  let box: [Double]
}
struct MuseumGuide: Decodable, Sendable {
  struct Artwork: Decodable, Sendable { let id: String; let title: String; let artist: String; let year: String }
  let mode: String
  let artwork: Artwork
  let overview: String
  let details: [MuseumDetail]
}

/// Uses the existing authenticated backend. Never stores a Gemini key on iPhone.
actor MuseumBackend {
  private let session = URLSession(configuration: .ephemeral)
  private var origin: URL?
  private var cookie: String?

  func connect(entryLink: String) async throws {
    guard var components = URLComponents(string: entryLink.trimmingCharacters(in: .whitespacesAndNewlines)),
      components.scheme == "https", components.host != nil,
      components.user == nil, components.password == nil else {
      throw failure("Paste the complete HTTPS device-test link.")
    }
    guard let entry = components.url else { throw failure("Invalid test link.") }
    let (_, response) = try await session.data(from: entry)
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

  func analyze(jpeg: Data, language: String) async throws -> MuseumGuide {
    guard let origin, let cookie else { throw failure("Connect the test backend first.") }
    var request = URLRequest(url: origin.appendingPathComponent("api/analyze"))
    request.httpMethod = "POST"; request.timeoutInterval = 55
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(cookie, forHTTPHeaderField: "Cookie")
    request.setValue(origin.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forHTTPHeaderField: "Origin")
    let payload: [String: Any] = [
      "image": "data:image/jpeg;base64," + jpeg.base64EncodedString(),
      "language": language, "demo": false,
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: payload)
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      throw failure(body?["error"] as? String ?? "The artwork analysis failed.")
    }
    let guide = try JSONDecoder().decode(MuseumGuide.self, from: data)
    guard guide.mode == "gemini", !guide.details.isEmpty else { throw failure("No reliable artwork details were returned.") }
    return guide
  }

  private func failure(_ message: String) -> NSError {
    NSError(domain: "MuseumCompanion", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
