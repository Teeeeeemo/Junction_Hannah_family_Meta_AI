# 给 Mac mini 上 Codex 的接力 Prompt

将下面内容交给 Mac mini 上、能访问本仓库的 Codex。以实际 Git HEAD 为准；不要只停在分析或新增脚手架。

---

请接手 Museum Companion，在这台有 Xcode 的 Mac mini 上继续实现、运行测试并交付剩余 iOS 功能。先读取仓库当前代码及本文引用的进度，检查已有工作，不覆盖用户未提交修改。代码完成后推送 `feat/museum-simulator-mvp`，不自动合并 main。持续推进已授权、可逆的编码／测试工作；只有必需账号、权限或产品取舍才向用户提问。

## 仓库与环境

- GitHub：`https://github.com/Teeeeeemo/Junction_Hannah_family_Meta_AI.git`。
- 工作分支：`feat/museum-simulator-mvp`。先 `git status`、`git fetch origin`，干净时才快进同步；有修改就保留，必要时独立 worktree，不强制 reset。
- 当前 Mac mini 已实测 macOS 26.5.2、Xcode 26.6（17F113）、iOS Simulator 26.5，Meta DAT 固定 1.0.1。不要为了此任务升级 SDK 或系统。
- 用户另一台本地 Mac 是 macOS 13.7.5、没有 Xcode；不要要求其升级或安装 Xcode。
- iPhone 15 Pro / iOS 26.5.2，在用户身边、无法 USB 接 Mac mini。无付费 Apple Developer 账号；此前已用 Sideloadly 免费账号重签名安装。
- 已安装版本为 `0.1.2 / build 3`，对应 `c0154ac73db8b5647bacc9c2f67efd7110b37cfc`。本次后续源码修复尚未打包或安装。
- 手机安装使用的 Bundle Identifier 是 `com.muse.museumcompanion.WJZW275NK2`。保留 `museumcompanion://` 和 `MWDAT.AppLinkURLScheme`。不要假定重签名自动修正 TeamID、Meta 注册或后端配置。
- 一段时间没有实体眼镜。优先用实际 iOS App + MockDeviceKit + 本地录像开发；保留实体设备路径。Web Chrome Simulator 只能验证 Web 部分，不能替代 iOS 编译和 DAT 运行。
- Gemini Key 只应存在后端本机被 Git 忽略的 `.env.local`；不写入 iOS、前端、文档、日志或仓库。原用户 Mac 已配置，不代表 Mac mini 有 Key；先检查是否存在配置而不打印值。缺少真实服务时先做可复现协议测试，明确记录未联调，不伪造成功。

## 先读这些文档

1. `docs/10-ios-simulator-test-progress.md`：最近实际测试、两个已修复根因、仍失败的用例与证据路径。
2. `docs/08-bugs-and-roadmap.md`：BUG-01～03、GAP-01～09、完整验收目标。
3. `docs/01-product-requirements.md`：最终要求，尤其 P02 现实持续跟随框。
4. `docs/02-technical-design.md`、`docs/09-no-glasses-debugging.md`、`native/ios/README.md`。

## 已有实现与测试基线

Web 已有 Gemini REST 视觉／问答、Live 音频、字幕分句、倍速、OpenCV 追踪和放大原型；不等于这些已迁移到 iOS。

iOS 当前采用原生 DAT Camera + Display，同一 DeviceSession，MUSE 深色金色界面；可选真实眼镜、手机后置相机、HEVC 视频回放；有原生显示预览和明确标记的四点离线布局样例。当前语音仍为 AVSpeechSynthesizer 系统 TTS，不是 Gemini Live。

已修复并实际验证：模拟器需本地 ad hoc 签名；session streams 要在 start() 前创建，否则同步模拟启动丢失 started；收到真实解码帧后才允许载入样例。不要回退这些修复。

运行：

```bash
bash scripts/test-ios-presentation.sh
bash scripts/test-ios-ui.sh
```

31 项纯 Swift 检查通过；最近 UI suite 是 **5 个用例、2 通过、3 失败**，不能当全绿。

最近失败：

- `testVideoReplayAndOfflineTour`：视频出帧、原生预览、离线样例、手机选第 4 点已成功；点击倍速菜单 `1.5×` 报 `Activation point invalid and no suggested hit points based on element frame`，后续字幕等断言未执行。
- `testBackgroundStopReplayAndRealSource`：后台停止和从头重播已成功；切源菜单 `Real glasses` 同样无法计算点击坐标，真实来源／Mock 关闭尚未验收。
- `testNativeHUDAndAutomaticTour`：总览自动进入 1 号、playing 状态和手机暂停已成功；点原生预览第 4 点后仍为 `selected=1; playing=false; rate=1×`。

前两个可能与系统菜单命中、刷新、滚动或自动化等待有关；第三个要区分真实回调问题和点击未命中。读取 screenshot、accessibility tree、xcresult 再判断。不要删测试、跳过断言、仅延长 timeout 或伪造状态来变绿。Debug UI 测试仅关闭过渡动画，保留实际视频／语音；Release 不启用测试入口。

最近证据在本机 `/private/tmp/museum-agent-tests.Of1QHm/source/build/ios/UITests.xcresult`，同目录有 test.log、build.log、attachments、evidence。临时目录可能失效，失效就重跑脚本。

## 最终产品行为

用户对准博物馆作品后，先锁定作品并进行通识语音介绍；结束／跳过后自动识别作品内部可靠细节点，右侧列出稳定编号；无需用户点选便从 1 号开始定位讲解。自动与用户选点的讲解都要有持续跟随框。用户可以随时说话打断、按编号／名称切点、追问、继续、切换语言、调节播放速度或放大。

局部窗支持 1×／2×／4×；放大时在眼镜右上角占半宽半高，右侧列表不遮住窗口。讲解、列表高亮、框和局部窗始终对应同一点。无可靠目标／失跟时不要编造定位，不保持错误框。

## 执行顺序与实现要求

### A. 先稳定无眼镜调试和回归

修复以上三个失败，补全未到达的字幕／倍速／停止／切源验收。添加真正验证会话释放、重复启动、失效任务隔离的测试。保持原生预览按钮确实走 DAT click handlers；手机按钮通过不代表预览通过。必要时独立比较 SDK `sendClick(identifier:)` 和预览坐标点击，但不能用前者冒充后者验收。

### B. BUG-03：先找艺术品，再分析细节

当前第 8 帧全图压到最长边 900 后直接分析，容易解释水瓶和线缆，丢失小画作。增加“搜索候选→稳定／确认→锁定→原分辨率 ROI 裁剪／必要时透视校正→作品内部细节分析”的流程。

- 契约应有作品候选／作品区域、置信或拒绝状态、稳定作品身份、细节点稳定 ID、坐标所属空间与变换。修改接口同时迁移 Web 和 Swift 解码，保留兼容性或明确版本。
- 测试小画作与杂物、多作品、无作品、模糊／遮挡。不要只选最大或居中物体，不要把日常物体类别永久排除（当代艺术可能使用它们）；有展签／展台上下文时使用，没有可靠依据时澄清或拒绝自动讲解。
- 多尺度和裁剪必须保留真实像素信息；信息不足时提示靠近，不声称数字放大恢复了不存在的细节。

### C. BUG-01 + GAP-01/02/08：原生 Gemini Live 与语音交互

复用现有后端 `server/live.ts`、`server/device-preview.ts` 的鉴权 WSS 通道，参考 `src/audio.ts`、`src/captions.ts`、`src/playback-speed.ts`。原生 MuseumBackend 目前只做 HTTP，需要妥善复用会话 cookie、Origin 与连接状态。

- 实际处理 ready、resumed、audio、transcript、interrupted、turn_complete、command、error、closed，以及 playbackId / epoch；不是把 Gemini 文本交给系统 TTS 后标为 Gemini voice。
- 输出 PCM 24 kHz，麦克风输入 PCM 16 kHz，按实际协议验证格式；用 AVAudioEngine／PlayerNode 等实现可立即清空的播放队列和真实音频倍速，避免只修改 TTS rate。
- 默认沿用 Web 当前 Live voice 设置并显示来源；女声本身不是故障，用户关心的是 Gemini 音频与自然交互。系统 TTS 只作为明确选择的离线方式，不静默降级。
- 0.75／1／1.25／1.5／1.75／2× 实际音频播放率、页面当前值和语音命令一致；分句字幕与实际播放进度同步。
- 起声停止旧音频，暂停自动推进；选点、问答和恢复共享明确状态机。用户选点优先于旧任务；追问后等待继续，从当前点恢复，不重播总览或跳回 1 号。
- 验证麦克风权限、无设备／回声、输出路由和断线。Simulator 的语音测试不证明实际眼镜麦克风和蓝牙音频通过。

### D. BUG-02 + GAP-03/06/07：框、追踪、放大与统一状态

`MuseumDetail.box` 已解码但未渲染；`GlassesDisplay` 只有文字和按钮；原生没有跨帧 tracker。参考 Web `src/vision.ts`，使用公开、可维护的 iOS 图像跟踪方案，避免把每帧云端识别当低延迟追踪。

- 二维平面作品做作品级定位与细节映射，移动／缩放／遮挡后保持 stable IDs；重识别和语言切换不重排编号。
- 失跟清框，恢复后重新验证；自动进入 1 号和用户选点都受“当前点可定位”约束。
- 当前帧局部窗 2×／4×来自同一基础范围，右上半宽半高；支持关闭和切点同步。
- **图像内框与镜片现实框是两项验收。** 先查实际 DAT Display 公开渲染与更新能力，再实现／验证。无实体眼镜时可以完成录像内跟踪、显示输出代码和校准接口，但不能宣称现实对齐／角误差／真实延迟通过。若公开平台能力不足，留下证据和明确阻塞，不能擅自取消用户 A 版要求。
- 3D 物体不能用同一平面单应性冒充；核心 P0 完成后再做一个真实 3D 范例。

### E. 来源、双语、异常恢复与交付

- GAP-04：Swift 保留并展示 sources/sourceIds；可靠馆方资料支撑背景事实。资料引用与藏品流传 provenance 分开；未知作品不编造艺术家、年代、象征或 URL。准备三件演示作品及可追溯素材，数量是建议，先一件跑通。
- GAP-05：切换中英保留作品／点位 ID、选择、放大与导览状态；双语追问和指令都测。
- GAP-09：断网、失跟、源切换、后台、重连和迟到回调统一处理，保留可靠状态；当前进入后台会停止取流，任何新的后台支持都需实际验证。
- 最后再安排稳定 HTTPS 托管与长期分发，不临时增加账号／付费／导航等范围。

## 代码入口与协作

核心原生文件：`GlassCameraModel.swift`、`DebugDeviceController.swift`、`MuseumBackend.swift`、`TourNarrator.swift`、`TourPresentation.swift`、`MuseumPhoneView.swift`、`GlassesDisplay.swift`。

后端／契约：`server/gemini.ts`、`server/validation.ts`、`server/live.ts`、`server/content.ts`、`src/contracts.ts`。Web 原型仅作复用参考，不能以 Web 已实现代替原生交付。

用户允许通过 agent 分工加速：若有多个 agent，可按“作品锁定／后端契约”“Live 音频与交互”“原生 tracker／Display”拆分。先确定共享 Swift／TS 契约与单一集成负责人，避免多人同时重写 GlassCameraModel。测试和集成不能只留给用户。

## 每轮交付要求

1. 实际代码、适当的单元／协议／UI 测试，保留截图、日志与失败原因。断言应验证真实行为，不能仅复述实现。
2. 原生检查：31 项检查可扩展、Xcode build、真实 Simulator UI suite；改后端时跑相关 npm tests 和 build，保证 Web 不回归。
3. 按 BUG/GAP 编号更新 docs/08 和 docs/10，逐项区分“已写／已编译／模拟运行／真实服务联调／手机运行／实际眼镜”。没有硬件的项目明确待验。
4. 新版准备安装前更新版本／build，实际执行 `bash run_ios.sh unsigned`；仅成功后才说 IPA 已生成。记录源码 commit、文件大小、SHA-256、SDK 版本及构建日志。未签名包不能直接安装；用户本地 Sideloadly 重签名是后续人工凭据步骤。
5. 推送当前开发分支，给出代码 commit、测试结果、IPA 实际位置及剩余限制。不要把源码 ZIP 当 IPA，不泄露密钥，不自动合并 main。

从 A 的三个失败开始，随后按 B～E 逐步集成，持续实现到可验证的完整原生 MVP；硬件缺失的验收留明确交接，不因无法佩戴就停止其他可完成工作。
