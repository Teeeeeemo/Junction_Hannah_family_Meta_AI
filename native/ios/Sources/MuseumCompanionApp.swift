import SwiftUI
import MWDATCore

@main
struct MuseumCompanionApp: App {
  @StateObject private var model: GlassCameraModel
  @Environment(\.scenePhase) private var scenePhase
  init() {
    var message: String?
    do { try Wearables.configure() } catch { message = error.localizedDescription }
    _model = StateObject(wrappedValue: GlassCameraModel(configurationError: message))
  }
  var body: some Scene {
    WindowGroup {
      MuseumPhoneView(model: model, narration: model.narration)
      .onOpenURL { url in Task { await model.handleURL(url) } }
      .onChange(of: scenePhase) { _, phase in if phase == .background { model.stop() } }
    }
  }
}
