import SwiftUI
import AVKit
import UniformTypeIdentifiers
import MWDATMockDevice

/// MUSE's phone companion: setup and full text stay here, the glasses stay sparse.
struct MuseumPhoneView: View {
  @ObservedObject var model: GlassCameraModel
  @ObservedObject var narration: TourNarrator
  @State private var backendLink = ""
  @State private var setupOpen = true
  @State private var showingVideoPicker = false
  private let gold = Color(red: 0.88, green: 0.77, blue: 0.50)
  private let ink = Color(red: 0.035, green: 0.055, blue: 0.035)
  private var zh: Bool { model.language == "zh" }
  private func text(_ en: String, _ cn: String) -> String { zh ? cn : en }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          HStack {
            Text("◈  MUSE.").font(.system(size: 29, weight: .semibold, design: .rounded)).tracking(4)
            Spacer()
            AudioOutputPicker().frame(width: 36, height: 36)
          }.foregroundStyle(gold)
          Text(text("Look closer.", "看见更多。"))
            .font(.system(size: 38, weight: .regular, design: .serif))
          Text(text("Every detail has a story.", "每一处细节，都有故事。"))
            .font(.subheadline).foregroundStyle(.secondary)

          inputCard

          DisclosureGroup(isExpanded: $setupOpen) {
            VStack(alignment: .leading, spacing: 14) {
              Picker(text("Museum reference", "馆方参考资料"), selection: $model.referenceArtworkID) {
                Text(text("Visual observations only", "仅作视觉观察")).tag("")
                Text(text("The Met · Wheat Field with Cypresses", "大都会博物馆 · 麦田与柏树")).tag("met-436535")
              }.disabled(model.recognizing || model.translating)
              SecureField(text("Complete HTTPS test link", "粘贴完整 HTTPS 测试链接"), text: $backendLink)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(10).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
              Button(text(model.backendReady ? "Backend connected · reconnect" : "Connect backend", model.backendReady ? "后端已连接 · 重新连接" : "连接后端")) {
                Task { await model.connectBackend(link: backendLink) }
              }
              if !model.inputMode.isMock {
                Button(text(model.registered ? "Registered with Meta AI" : "Register with Meta AI", model.registered ? "Meta AI 已注册" : "注册 Meta AI 连接")) {
                  Task { await model.register() }
                }.disabled(model.registered)
              } else {
                Text(text("Simulation uses local mock registration and permissions. Connect the backend only when you want Gemini image analysis.",
                  "模拟模式使用本地模拟设备授权；连接后端后才会调用 Gemini 识别当前画面。"))
                  .font(.caption).foregroundStyle(.secondary)
              }
            }.padding(.top, 12)
          } label: { Text(text("Connection settings", "连接设置")).font(.headline) }
          .padding(16).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))

          Picker("Language", selection: Binding(get: { model.language }, set: { value in Task { await model.changeLanguage(value) } })) {
            Text("English").tag("en"); Text("中文").tag("zh")
          }.pickerStyle(.segmented).disabled(model.translating)

          if let image = model.preview {
            Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 440)
              .overlay {
                GeometryReader { geometry in
                  // Whole artwork: thin dashed outline whenever Vision tracks it.
                  if model.trackingStatus == "tracking", let box = model.trackedArtworkBox, box.count == 4 {
                    Rectangle().stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                      .frame(width: box[2] * geometry.size.width, height: box[3] * geometry.size.height)
                      .position(x: (box[0] + box[2] / 2) * geometry.size.width, y: (box[1] + box[3] / 2) * geometry.size.height)
                      .accessibilityIdentifier("tracked-artwork-box")
                  }
                  // Current detail: bold gold box with its point number.
                  if let box = model.trackedDetailBox, box.count == 4 {
                    Rectangle().stroke(gold, lineWidth: 4)
                      .frame(width: box[2] * geometry.size.width, height: box[3] * geometry.size.height)
                      .overlay(alignment: .topLeading) {
                        if let number = narration.selectedNumber {
                          Text("\(number)").font(.caption.bold()).foregroundStyle(.black)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(gold)
                            .offset(y: -20)
                        }
                      }
                      .position(x: (box[0] + box[2] / 2) * geometry.size.width, y: (box[1] + box[3] / 2) * geometry.size.height)
                      .accessibilityIdentifier("tracked-detail-box")
                  }
                }
              }
              .clipShape(RoundedRectangle(cornerRadius: 16))
            if model.guide?.mode == "gemini" {
              Text(text("Image tracking: ", "画面追踪：") + model.trackingStatus).font(.caption)
            }
          }
          if let search = model.artworkSearch, search.status == "needs_confirmation" {
            Text(search.reason).font(.callout)
            ForEach(search.candidates) { candidate in
              Button(text("Confirm: ", "确认作品：") + candidate.label) { model.analyzeCurrentFrame(confirmedCandidateID: candidate.id) }
                .disabled(model.recognizing)
            }
          }
          if let image = model.zoomImage {
            HStack {
              Spacer()
              Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: 175, maxHeight: 110)
                .overlay(alignment: .topTrailing) { Text("\(model.zoom)×").font(.caption).padding(4).background(.black.opacity(0.7)) }
            }.accessibilityIdentifier("detail-zoom")
          }
          if model.inputMode.isMock, let display = model.debugPreview {
            VStack(alignment: .leading, spacing: 8) {
              Text(text("NATIVE GLASSES DISPLAY · SIMULATED", "原生眼镜界面预览 · 模拟")).font(.caption).foregroundStyle(gold)
              Group {
                if model.phoneQuestionEditing { Color.clear }
                else { MockDisplayPreview(view: display).id(ObjectIdentifier(display)) }
              }.frame(height: 320)
                .accessibilityIdentifier("mock-display")
                .background(.black).clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay {
                  if model.phoneQuestionEditing {
                    Text(text("Preview hidden while typing on your phone. Finish typing to show it again.",
                      "手机输入时暂时隐藏模拟预览，结束输入后恢复。"))
                      .font(.callout).foregroundStyle(.secondary).padding(24)
                      .accessibilityIdentifier("mock-preview-typing")
                  }
                }
              Text(text("Tap the preview's buttons to test the actual DAT click handlers. This preview cannot validate optical alignment.",
                "可点击预览中的按钮，测试实际 DAT 交互；此预览不能验收镜片现实对齐。"))
                .font(.caption).foregroundStyle(.secondary)
            }
          }
          if let guide = model.guide {
            if guide.mode == "demo" {
              Text(text("OFFLINE LAYOUT EXAMPLE · NOT CAMERA RECOGNITION", "离线布局样例 · 非当前画面识别"))
                .font(.caption.bold()).foregroundStyle(.orange)
            }
            Text(guide.artwork.artist.uppercased()).font(.caption).tracking(2).foregroundStyle(gold)
            Text(guide.artwork.title).font(.system(size: 28, weight: .regular, design: .serif))
            narrationCard
            pointsCard(guide)
            HStack {
              Text(text("Detail view", "细节放大"))
              ForEach([1,2,4], id: \.self) { value in
                Button("\(value)×") { model.setZoom(value) }.buttonStyle(.bordered)
                  .disabled(value > 1 && model.trackedDetailBox == nil)
              }
            }
            DisclosureGroup(isExpanded: $model.showingSources) {
              if guide.sources.isEmpty { Text(text("No verified historical sources for this artwork. Descriptions are visual observations.", "该作品暂无可核验的历史资料，当前内容仅作视觉观察。")) }
              ForEach(guide.sources) { source in
                if let url = URL(string: source.url), url.scheme == "https" { Link(source.title, destination: url) }
              }
              Text(text("These are references for the guide, not the object's ownership history.", "这里展示讲解参考资料，不代表藏品流传记录。"))
            } label: { Text(text("Guide sources", "讲解依据")) }
            DisclosureGroup(text("Read the full guide", "展开完整讲解")) {
              VStack(alignment: .leading, spacing: 12) {
                Text(guide.overview)
                ForEach(guide.details) { point in
                  Text("\(point.number). \(point.title)").font(.headline)
                  Text(point.description)
                }
              }.font(.body).padding(.top, 12)
            }.foregroundStyle(.secondary)
          }

          HStack {
            if model.sessionActive || model.connecting {
              Button(text("Scan again", "重新识别")) { model.analyzeCurrentFrame() }
                .disabled(!model.streaming || model.recognizing || !model.backendReady)
              Spacer()
              Button(text("End visit", "结束导览")) { model.stop() }
                .accessibilityIdentifier("end-visit")
            } else {
              Button {
                Task { await model.startCamera() }
              } label: {
                Label(model.connecting ? text("Connecting…", "正在连接…") : model.inputMode.isMock ? text("Start simulated preview", "开始模拟预览") : text("Begin your visit", "开始导览"), systemImage: "camera")
                  .frame(maxWidth: .infinity).padding(.vertical, 8)
              }.buttonStyle(.borderedProminent)
                .accessibilityIdentifier("start-preview")
                .disabled(!model.canStart)
            }
          }
          VStack(alignment: .leading, spacing: 5) {
            Text(model.status).accessibilityIdentifier("camera-status")
            Text(text(model.inputMode.isMock ? "Simulated input frames: " : "Live glasses frames: ", model.inputMode.isMock ? "模拟输入帧数：" : "真实眼镜帧数：") + String(model.frameCount))
          }.font(.caption).foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("camera-state")
            .accessibilityValue(String("frames=\(model.frameCount); streaming=\(model.streaming); sdk=\(model.sdkReady); source=\(model.inputMode.rawValue); sessionActive=\(model.sessionActive); connecting=\(model.connecting); mockEnabled=\(MockDeviceKit.shared.isEnabled); mockPaired=\(MockDeviceKit.shared.pairedDevices.count); recovery=\(model.recoveryPhase); recoveries=\(model.recoveryCount); injectedGap=\(model.injectedInputGap); gapBaseline=\(model.injectedGapRecoveryBaseline); recoveredPCMBase=\(model.recoveredPCMBase); hudSends=\(model.hudSendCount)"))
          if !model.error.isEmpty { Text(model.error).font(.callout).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("camera-error") }
          Text(text("Live camera + spoken guide. Keep this app in the foreground. Detail tracking and spatial boxes are still in development.",
            "实时相机与语音导览。使用时请保持 App 在前台；持续细节追踪与现实对齐框仍待接入。"))
            .font(.caption).foregroundStyle(.secondary)
        }.padding(22)
      }.background(ink).tint(gold).preferredColorScheme(.dark)
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: model.streaming) { _, streaming in if streaming { setupOpen = false } }
        .fileImporter(isPresented: $showingVideoPicker, allowedContentTypes: [.mpeg4Movie, .quickTimeMovie]) { result in
          switch result {
          case .success(let url): Task { @MainActor in await model.importVideo(from: url) }
          case .failure(let error):
            let message = "Video selection: " + error.localizedDescription
            Task { @MainActor in model.error = message }
          }
        }
    }
  }
  private var inputCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      NativeInputSourcePicker(model: model, mode: model.inputMode,
        disabled: model.changingInput || model.connecting, language: model.language).equatable()
      if model.inputMode.isMock {
        Text(text("SIMULATION · NO PHYSICAL GLASSES", "模拟调试 · 无需实体眼镜"))
          .font(.caption.bold()).foregroundStyle(.orange)
        if model.inputMode.needsVideo {
          HStack {
            Button(model.changingInput ? text("Importing…", "正在导入…") : text("Choose MP4 / MOV", "选择 MP4／MOV")) { showingVideoPicker = true }
              .disabled(model.changingInput || model.connecting)
            Spacer()
            Button(text("Replay from start", "从头回放")) { Task { await model.replayVideo() } }
              .disabled(!model.videoReady || model.changingInput || model.connecting)
              .accessibilityIdentifier("replay-video")
          }
          if !model.videoName.isEmpty { Text(model.videoName).font(.caption).lineLimit(2) }
          Text(text("Use a short local video. HEVC MP4/MOV is the SDK's documented test format. The iOS Simulator uses file replay, not an iPhone camera.",
            "使用短视频；SDK 文档推荐 HEVC 编码 MP4／MOV。iOS Simulator 请使用文件回放。"))
            .font(.caption).foregroundStyle(.secondary)
        }
        Button(text("Load offline layout example (not recognition)", "载入离线布局样例（非画面识别）")) { model.loadLayoutExample() }
          .disabled(!model.streaming || model.recognizing || model.changingInput)
          .accessibilityIdentifier("load-layout")
        if !model.streaming {
          Text(text("Start the simulated preview to enable the layout example.", "先开始模拟预览，收到画面后即可载入样例。"))
            .font(.caption).foregroundStyle(.secondary)
        }
      }
    }.padding(16).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
  }
  private var narrationCard: some View {
    NativeNarrationCard(narration: narration, language: model.language, editingContext: model.phoneInputContext,
      onQuestionEditing: { [context = model.phoneInputContext] editing in
        model.setPhoneQuestionEditing(editing, context: context)
      }).equatable()
  }
  private func pointsCard(_ guide: MuseumGuide) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(text("LOOK CLOSER", "细节探索")).font(.caption).tracking(2).foregroundStyle(gold)
      Button(text("The whole story", "先认识这幅作品")) { narration.select(number: nil) }
      ForEach(guide.details.sorted { $0.number < $1.number }) { point in
        Button { narration.select(number: point.number) } label: {
          HStack {
            Text(String(point.number)).monospacedDigit().foregroundStyle(gold)
            Text(point.title).multilineTextAlignment(.leading)
            Spacer()
            if narration.selectedNumber == point.number { Image(systemName: "waveform") }
          }.padding(.vertical, 10)
        }
        .accessibilityIdentifier("point-\(point.number)")
      }
    }.buttonStyle(.plain)
  }
}

/// This menu depends on source state, not every incoming video frame.
private struct NativeInputSourcePicker: View, Equatable {
  let model: GlassCameraModel
  let mode: DebugInputMode
  let disabled: Bool
  let language: String
  private let identity: ObjectIdentifier
  init(model: GlassCameraModel, mode: DebugInputMode, disabled: Bool, language: String) {
    self.model = model; self.mode = mode; self.disabled = disabled; self.language = language
    identity = ObjectIdentifier(model)
  }
  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.identity == rhs.identity && lhs.mode == rhs.mode && lhs.disabled == rhs.disabled && lhs.language == rhs.language
  }
  private func text(_ en: String, _ cn: String) -> String { language == "zh" ? cn : en }
  private func sourceName(_ source: DebugInputMode) -> String {
    switch source {
    case .glasses: return text("Real glasses", "真实眼镜")
    case .phoneCamera: return text("iPhone back camera", "手机后置相机")
    case .video: return text("Video replay", "视频回放")
    }
  }
  var body: some View {
    Picker(text("Input source", "输入来源"), selection: Binding(get: { mode }, set: { mode in
      Task { await model.setInputMode(mode) }
    })) {
      ForEach(DebugInputMode.allCases, id: \.self) { mode in Text(sourceName(mode)).tag(mode) }
    }.pickerStyle(.menu).disabled(disabled).accessibilityIdentifier("input-source")
  }
}

/// Camera frames must not recreate UIKit menus while a visitor changes speed.
private struct NativeVoiceSourcePicker: View, Equatable {
  let narration: TourNarrator
  let mode: TourVoiceMode
  let language: String
  private let identity: ObjectIdentifier
  init(narration: TourNarrator, mode: TourVoiceMode, language: String) {
    self.narration = narration; self.mode = mode; self.language = language
    identity = ObjectIdentifier(narration)
  }
  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.identity == rhs.identity && lhs.mode == rhs.mode && lhs.language == rhs.language
  }
  var body: some View {
    Picker(language == "zh" ? "语音来源" : "Voice source", selection: Binding(get: { mode }, set: { narration.selectVoice($0) })) {
      Text("Gemini Live · Aoede").tag(TourVoiceMode.gemini)
      Text(language == "zh" ? "离线系统朗读" : "Offline iOS speech").tag(TourVoiceMode.offline)
    }.pickerStyle(.menu).accessibilityIdentifier("voice-source")
  }
}

private struct NativeNarrationCard: View, Equatable {
  @ObservedObject var narration: TourNarrator
  @ScaledMetric(relativeTo: .body) private var captionHeight: CGFloat = 112
  let language: String
  let editingContext: Int
  let onQuestionEditing: (Bool) -> Void
  private let identity: ObjectIdentifier
  private let gold = Color(red: 0.88, green: 0.77, blue: 0.50)
  private func text(_ en: String, _ cn: String) -> String { language == "zh" ? cn : en }
  init(narration: TourNarrator, language: String, editingContext: Int, onQuestionEditing: @escaping (Bool) -> Void) {
    _narration = ObservedObject(wrappedValue: narration); self.language = language
    self.editingContext = editingContext; self.onQuestionEditing = onQuestionEditing
    identity = ObjectIdentifier(narration)
  }
  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.identity == rhs.identity && lhs.language == rhs.language && lhs.editingContext == rhs.editingContext
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Image(systemName: narration.playing ? "waveform" : "speaker.wave.2")
        Text(narration.finished
          ? (narration.progressSnapshot.automatic ? text("Tour complete", "导览完成") : text("Section complete", "本段讲解完成"))
          : narration.sectionTitle).font(.subheadline.weight(.semibold))
        Spacer(); Text(narration.rateLabel).monospacedDigit().accessibilityIdentifier("speech-rate-value")
      }.foregroundStyle(gold)
      // Sentence boundaries and tracking changes must not move the playback controls.
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          if narration.locationBlocked && narration.selectedNumber != nil {
            Text(text("Waiting for reliable detail tracking. Keep the artwork in view; if tracking does not recover, tap Scan again.",
              "正在定位当前细节，暂不播放讲解。请对准作品；若无法恢复，请重新扫描。"))
              .font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("waiting-for-detail-location")
          }
          Text(narration.sentence).font(.body).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("current-caption")
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(height: captionHeight)
      HStack {
        Button { narration.toggle() } label: {
          Label(text(narration.playing ? "Pause" : "Play", narration.playing ? "暂停" : "播放"), systemImage: narration.playing ? "pause.fill" : "play.fill")
        }.accessibilityIdentifier("toggle-playback")
        Spacer()
        Button(text("Next detail →", "下一个细节 →")) { narration.next() }
      }.buttonStyle(.bordered)
      Picker(text("Speech rate", "朗读语速"), selection: Binding(get: { narration.rate }, set: { narration.setRate($0) })) {
        ForEach(TourNarrator.rates, id: \.self) { rate in Text(TourNarrator.label(for: rate)).tag(rate) }
      }.pickerStyle(.menu).accessibilityIdentifier("speech-rate")
      Toggle(text("Show captions on glasses", "在眼镜上显示字幕"), isOn: $narration.subtitles).font(.subheadline).accessibilityIdentifier("captions")
      HStack {
        Image(systemName: "hifispeaker")
        Text(text("Audio: ", "音频输出：") + narration.audioOutput)
        Spacer(); AudioOutputPicker().frame(width: 30, height: 30)
      }.font(.caption).foregroundStyle(.secondary)
      NativeVoiceSourcePicker(narration: narration, mode: narration.voiceMode, language: language).equatable()
      Text(narration.voiceStatus).font(.caption).foregroundStyle(.secondary)
      if narration.voiceMode == .gemini {
        Button(text("Reconnect Gemini voice", "重新连接 Gemini 语音")) { narration.reconnectVoice() }
        Button(narration.listening ? text("Stop microphone", "关闭麦克风") : text("Talk to Gemini", "与 Gemini 对话")) { narration.toggleMicrophone() }
        NativeQuestionComposer(narration: narration, language: language, editingContext: editingContext,
          onEditing: onQuestionEditing).equatable()
        if narration.awaitingContinue { Text(text("Say or tap Continue to resume this point.", "说“继续”或点播放，从当前点继续。")) }
      }
    }.padding(18).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
      .overlay(RoundedRectangle(cornerRadius: 18).stroke(gold.opacity(0.24)))
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("narration")
      .accessibilityValue(String("selected=\(narration.selectedNumber.map(String.init) ?? "intro"); playing=\(narration.playing); rate=\(narration.rateLabel); voice=\(narration.voiceMode.rawValue); liveBytes=\(narration.liveReceivedBytes); livePlayed=\(narration.livePlayedFrames); awaitingContinue=\(narration.awaitingContinue); locationBlocked=\(narration.locationBlocked)"))
  }
}

/// Keyboard state belongs to a stable subtree, independent of PCM counters.
private struct NativeQuestionComposer: View, Equatable {
  let narration: TourNarrator
  let language: String
  let editingContext: Int
  let onEditing: (Bool) -> Void
  private let identity: ObjectIdentifier
  @State private var question = ""
  @FocusState private var focused: Bool
  @State private var keyboardWasVisible = false
  init(narration: TourNarrator, language: String, editingContext: Int, onEditing: @escaping (Bool) -> Void) {
    self.narration = narration; self.language = language; identity = ObjectIdentifier(narration)
    self.editingContext = editingContext; self.onEditing = onEditing
  }
  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.identity == rhs.identity && lhs.language == rhs.language && lhs.editingContext == rhs.editingContext
  }
  private func submit() {
    let text = question; question = ""; focused = false; onEditing(false); narration.ask(text)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      TextField(language == "zh" ? "询问当前细节" : "Ask about this detail", text: $question)
        .textFieldStyle(.roundedBorder).focused($focused).onSubmit { submit() }
        .simultaneousGesture(TapGesture().onEnded {
          // Detach synchronously before the visitor's one focus request.
          onEditing(true)
          focused = true
          #if DEBUG
          print("MUSE_QUESTION_TAP")
          museumFocusDiagnostic("question-tap")
          #endif
        })
        .onChange(of: focused) { _, value in
          if !value { onEditing(false) }
          #if DEBUG
          print("MUSE_QUESTION_FOCUS \(value)")
          museumFocusDiagnostic("question-focus-\(value)")
          #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
          keyboardWasVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
          if keyboardWasVisible { keyboardWasVisible = false; focused = false; onEditing(false) }
        }
        .onDisappear {
          onEditing(false)
          #if DEBUG
          museumFocusDiagnostic("composer-disappear")
          #endif
        }
        #if DEBUG
        .onAppear { museumFocusDiagnostic("composer-appear") }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
          museumFocusDiagnostic("keyboard-show")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
          museumFocusDiagnostic("keyboard-hide")
        }
        #endif
      Button(language == "zh" ? "提问" : "Ask") { submit() }
        .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .toolbar {
      ToolbarItemGroup(placement: .keyboard) {
        Spacer()
        Button(language == "zh" ? "完成" : "Done") { focused = false; onEditing(false) }
          .accessibilityIdentifier("question-done")
      }
    }
  }
}

#if DEBUG
/// Only responder classes and fixed event names; never question text or credentials.
@MainActor
func museumFocusDiagnostic(_ event: String) {
  let arguments = ProcessInfo.processInfo.arguments
  guard arguments.contains("--museum-ui-test"),
    arguments.contains("--museum-hud-focus-test") || arguments.contains("--museum-cloud-test") else { return }
  func firstResponder(in view: UIView) -> UIView? {
    if view.isFirstResponder { return view }
    return view.subviews.lazy.compactMap { firstResponder(in: $0) }.first
  }
  let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
  let responder = windows.lazy.compactMap { firstResponder(in: $0) }.first
  let name = responder.map { String(describing: type(of: $0)) } ?? "none"
  print("MUSE_FOCUS t=\(ProcessInfo.processInfo.systemUptime) event=\(event) responder=\(name)")
}
#endif

private struct MockDisplayPreview: UIViewRepresentable {
  let view: UIView
  // Keep the SDK's original embedding path; a custom parent can interfere with
  // its hosted renderer. SwiftUI removes this branch while phone typing.
  func makeUIView(context: Context) -> UIView { view }
  func updateUIView(_ uiView: UIView, context: Context) { }
}

private struct AudioOutputPicker: UIViewRepresentable {
  func makeUIView(context: Context) -> AVRoutePickerView {
    let view = AVRoutePickerView()
    view.prioritizesVideoDevices = false; view.tintColor = .systemYellow
    return view
  }
  func updateUIView(_ uiView: AVRoutePickerView, context: Context) { }
}
