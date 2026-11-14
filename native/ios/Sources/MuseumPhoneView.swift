import SwiftUI
import AVKit
import UniformTypeIdentifiers

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

          Picker("Language", selection: $model.language) {
            Text("English").tag("en"); Text("中文").tag("zh")
          }.pickerStyle(.segmented)

          if let image = model.preview {
            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 220)
              .clipShape(RoundedRectangle(cornerRadius: 16))
          }
          if model.inputMode.isMock, let display = model.debugPreview {
            VStack(alignment: .leading, spacing: 8) {
              Text(text("NATIVE GLASSES DISPLAY · SIMULATED", "原生眼镜界面预览 · 模拟")).font(.caption).foregroundStyle(gold)
              MockDisplayPreview(view: display).id(ObjectIdentifier(display)).frame(height: 320)
                .background(.black).clipShape(RoundedRectangle(cornerRadius: 14))
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
            } else {
              Button {
                Task { await model.startCamera() }
              } label: {
                Label(model.connecting ? text("Connecting…", "正在连接…") : model.inputMode.isMock ? text("Start simulated preview", "开始模拟预览") : text("Begin your visit", "开始导览"), systemImage: "camera")
                  .frame(maxWidth: .infinity).padding(.vertical, 8)
              }.buttonStyle(.borderedProminent)
                .disabled(!model.canStart)
            }
          }
          VStack(alignment: .leading, spacing: 5) {
            Text(model.status)
            Text(text(model.inputMode.isMock ? "Simulated input frames: " : "Live glasses frames: ", model.inputMode.isMock ? "模拟输入帧数：" : "真实眼镜帧数：") + String(model.frameCount))
          }.font(.caption).foregroundStyle(.secondary)
          if !model.error.isEmpty { Text(model.error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
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
  private func sourceName(_ source: DebugInputMode) -> String {
    switch source {
    case .glasses: return text("Real glasses", "真实眼镜")
    case .phoneCamera: return text("iPhone back camera", "手机后置相机")
    case .video: return text("Video replay", "视频回放")
    }
  }
  private var inputCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      Picker(text("Input source", "输入来源"), selection: Binding(get: { model.inputMode }, set: { mode in
        Task { await model.setInputMode(mode) }
      })) {
        ForEach(DebugInputMode.allCases, id: \.self) { mode in Text(sourceName(mode)).tag(mode) }
      }.pickerStyle(.menu).disabled(model.changingInput || model.connecting)
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
          }
          if !model.videoName.isEmpty { Text(model.videoName).font(.caption).lineLimit(2) }
          Text(text("Use a short local video. HEVC MP4/MOV is the SDK's documented test format. The iOS Simulator uses file replay, not an iPhone camera.",
            "使用短视频；SDK 文档推荐 HEVC 编码 MP4／MOV。iOS Simulator 请使用文件回放。"))
            .font(.caption).foregroundStyle(.secondary)
        }
        Button(text("Load offline layout example (not recognition)", "载入离线布局样例（非画面识别）")) { model.loadLayoutExample() }
          .disabled(!model.streaming || model.recognizing || model.changingInput)
      }
    }.padding(16).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
  }
  private var narrationCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Image(systemName: narration.playing ? "waveform" : "speaker.wave.2")
        Text(narration.finished ? text("Tour complete", "导览完成") : narration.sectionTitle).font(.subheadline.weight(.semibold))
        Spacer(); Text(narration.rateLabel).monospacedDigit()
      }.foregroundStyle(gold)
      if !narration.sentence.isEmpty { Text(narration.sentence).font(.body).fixedSize(horizontal: false, vertical: true) }
      HStack {
        Button { narration.toggle() } label: {
          Label(text(narration.playing ? "Pause" : "Play", narration.playing ? "暂停" : "播放"), systemImage: narration.playing ? "pause.fill" : "play.fill")
        }
        Spacer()
        Button(text("Next detail →", "下一个细节 →")) { narration.next() }
      }.buttonStyle(.bordered)
      Picker(text("Speech rate", "朗读语速"), selection: Binding(get: { narration.rate }, set: { narration.setRate($0) })) {
        ForEach(TourNarrator.rates, id: \.self) { rate in Text(TourNarrator.label(for: rate)).tag(rate) }
      }.pickerStyle(.menu)
      Toggle(text("Show captions on glasses", "在眼镜上显示字幕"), isOn: $narration.subtitles).font(.subheadline)
      HStack {
        Image(systemName: "hifispeaker")
        Text(text("Audio: ", "音频输出：") + narration.audioOutput)
        Spacer(); AudioOutputPicker().frame(width: 30, height: 30)
      }.font(.caption).foregroundStyle(.secondary)
      Text(text("Voice: iOS system speech. Gemini Live voice is not connected in this build.", "语音：iOS 系统朗读；本版本尚未接入 Gemini Live 语音。"))
        .font(.caption).foregroundStyle(.secondary)
    }.padding(18).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
      .overlay(RoundedRectangle(cornerRadius: 18).stroke(gold.opacity(0.24)))
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
      }
    }.buttonStyle(.plain)
  }
}

private struct MockDisplayPreview: UIViewRepresentable {
  let view: UIView
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
