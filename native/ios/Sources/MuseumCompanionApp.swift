import SwiftUI
import MWDATCore

@main
struct MuseumCompanionApp: App {
  @StateObject private var model: GlassCameraModel
  @Environment(\.scenePhase) private var scenePhase
  init() {
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("--museum-ui-test") {
      // Keep camera frames and speech live; remove only transition animations
      // so XCTest can interact with menus while the preview is refreshing.
      UIView.setAnimationsEnabled(false)
    }
    #endif
    var message: String?
    do { try Wearables.configure() } catch { message = error.localizedDescription }
    _model = StateObject(wrappedValue: GlassCameraModel(configurationError: message))
  }
  var body: some Scene {
    WindowGroup {
      MuseumPhoneView(model: model, narration: model.narration)
      #if DEBUG
      .task {
        // UI tests seed an actual video in this app's Documents directory.
        // Import through the production validator; never substitute camera frames.
        if ProcessInfo.processInfo.arguments.contains("--museum-ui-test") {
          model.language = "en"
          await model.setInputMode(.video)
          if let name = ProcessInfo.processInfo.environment["MUSE_UI_TEST_VIDEO"],
            name == URL(fileURLWithPath: name).lastPathComponent {
            let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            await model.importVideo(from: folder.appendingPathComponent(name))
            if ProcessInfo.processInfo.arguments.contains("--museum-cloud-test"),
              let data = try? Data(contentsOf: folder.appendingPathComponent("museum-cloud-entrance.json")),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let link = config["link"] {
              model.referenceArtworkID = config["artworkId"] ?? ""
              await model.connectBackend(link: link)
            }
          }
        }
      }
      #endif
      .onOpenURL { url in Task { await model.handleURL(url) } }
      .onChange(of: scenePhase) { _, phase in if phase == .background { model.stop() } }
    }
  }
}
