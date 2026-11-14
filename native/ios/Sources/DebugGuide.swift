import Foundation

extension MuseumGuide {
  /// Explicit user-triggered layout fixture; never presented as a recognition
  /// of the current feed. This is useful with the backend disconnected.
  static func layoutExample(language: String) -> MuseumGuide {
    let zh = language == "zh"
    return MuseumGuide(mode: "demo",
      artwork: Artwork(id: "layout-example", title: zh ? "离线布局样例" : "Offline layout example", artist: "MUSE · DEBUG", year: ""),
      overview: zh ? "这是离线布局与朗读样例，不是对当前画面的识别。介绍完成后会自动进入第一个测试点。" : "This is an offline layout and speech example, not recognition of the current camera view. The first test point follows this introduction.",
      details: (1...4).map { number in
        MuseumDetail(id: "layout-\(number)", number: number,
          title: zh ? "测试点位 \(number)" : "Test point \(number)",
          description: zh ? "正在测试第 \(number) 个点位。你可以选择其他编号打断，或测试暂停、语速和字幕开关。这段内容没有来自当前画面。" : "Testing point \(number). Select another number to interrupt, or test pause, speech rate, and the caption switch. This content is not from the current frame.",
          box: [0.1, 0.1, 0.2, 0.2])
      })
  }
}
