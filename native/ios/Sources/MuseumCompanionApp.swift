import SwiftUI
import MWDATCore

@main
struct MuseumCompanionApp: App {
  @StateObject private var model: GlassCameraModel
  @State private var backendLink = ""
  @Environment(\.scenePhase) private var scenePhase
  init() {
    var message: String?
    do { try Wearables.configure() } catch { message = error.localizedDescription }
    _model = StateObject(wrappedValue: GlassCameraModel(configurationError: message))
  }
  var body: some Scene {
    WindowGroup {
      NavigationStack {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            Text("MUSE · Glasses camera bring-up").font(.title2)
            Text("Uses the actual glasses camera through Meta DAT. The stream starts only after you authorize it.")
            SecureField("Complete HTTPS test link", text: $backendLink).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Connect backend") { Task { await model.connectBackend(link: backendLink) } }
            Button(model.registered ? "Registered with Meta AI" : "Register with Meta AI") { Task { await model.register() } }.disabled(model.registered)
            Picker("Guide language", selection: $model.language) { Text("English").tag("en"); Text("中文").tag("zh") }.pickerStyle(.segmented)
            Button("Start glasses camera · authorize in Meta AI if prompted") { Task { await model.startCamera() } }.disabled(!model.registered || !model.backendReady || model.streaming || model.connecting)
            Text(model.status)
            Text("Actual received frames: \(model.frameCount)").font(.caption)
            if let image = model.preview { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 280) }
            HStack {
              Button("Scan again") { model.analyzeCurrentFrame() }.disabled(!model.streaming || model.recognizing)
              Button("Stop camera") { model.stop() }
            }
            if !model.error.isEmpty { Text(model.error).foregroundStyle(.red) }
            if let guide = model.guide {
              Text(guide.artwork.title).font(.headline); Text(guide.overview)
              ForEach(guide.details) { detail in VStack(alignment: .leading) { Text("\(detail.number). \(detail.title)").bold(); Text(detail.description) } }
            }
            Text("Camera integration prototype. Continuous detail tracking, optical alignment and the full voice tour are not implemented in this iOS target yet.").font(.caption).foregroundStyle(.secondary)
          }.padding()
        }.navigationTitle("Museum Companion")
      }
      .onOpenURL { url in Task { await model.handleURL(url) } }
      .onChange(of: scenePhase) { _, phase in if phase == .background { model.stop() } }
    }
  }
}
