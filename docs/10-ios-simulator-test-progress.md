# iOS 模拟器测试进度与交接

## 2026-11-15 04:00：0.2.2 / build 6 演示构建

由用户接手开发；基于 `aca786a`（0.2.1 WIP）。

**行为变更（演示连续性，经用户同意，与 PRD“不讲无法定位的点”有意不同）：**

- 追踪丢失只清除框和局部窗，不再暂停正在进行的讲解（`TourNarrator.setLocated`）。
- 切换到新点位时最多等待 2.5 秒定位（`NarrationLocationPolicy.continuityGraceSeconds`），超时仍开始讲解，定位恢复后框再出现。
- Vision 单帧丢失、初次播种失败或验证失败后，自动走 0.2.1 的有限同作品重新确认流程，不再必须手动“Scan again”；两次自动尝试至少间隔 8 秒（`GlassCameraModel.beginAutomaticRecovery`）。
- `CloudIntegrationUITests` 的断流恢复断言改为新规则：恢复完成且讲解持续出声；导览可能已越过 1 号点。

| 检查 | 结果（Mac mini，Xcode 26.6，iOS Simulator 26.5） |
|---|---|
| Web / 后端 | 87/87，生产构建通过 |
| 原生纯逻辑 | 导览、会话、恢复、点位注册、追踪、Live 协议、离线音频全部通过 |
| Release 归档与 IPA | 通过 |
| 离线 UI（`scripts/test-ios-ui.sh`） | 11 项中 10 通过，云端用例按设计跳过。此前阻塞的 `testNativeHUDAndAutomaticTour` 通过。失败：`testQuestionDoneRestoresDATPreviewAndCallbacks`（手机输入结束后，恢复的模拟 DAT 预览未显示当前暂停状态） |
| 原生云端（`scripts/test-ios-cloud.sh`，真实 Gemini） | 视频 → 搜索锁定 → ROI 分析 → 实际 PCM → 总览自动进入 1 号 → 受控断流 → 自动恢复且讲解持续 → 手动选 2 号并实际出声 → 暂停后提问并实际播出回答，均通过。最后一步失败：与离线失败相同，恢复的模拟预览网页 DOM 未暴露“Play” |

两个失败都只涉及模拟设备模式下手机输入后的预览恢复。真眼镜模式不显示该预览（`setPhoneQuestionEditing` 只在 mock 模式生效）。实体眼镜、现实框和真实麦克风仍待用户上机验收。证据位于 Mac mini 的 `~/Developer/Junction/takeover-logs/`（`ui-022/`、`cloud-022b/`）。

## 2026-11-15 03:03：已暂停，0.2.1 尚未发布

用户最新要求：停止继续修复，记录问题，收完当前回归；可用才生成 IPA 并同时上传 GitHub，随后暂停等待指令。收尾回归失败，已停止修复和后续测试，不生成新 IPA。本轮最新指令要求把未通过验收的进度也提交到 GitHub，因此将两份草稿分别保存为 WIP 分支；这不代表发布可用版本，不再自动推进开发。

**GitHub 同步阻塞：** 已确认连接账号有仓库写权限，但 CLI 联网提权及 GitHub `create_blob` 写入均被自动审批器初始化错误拦截（`thread-store internal error: Operation not permitted`），写入未执行。两份源码分别保存为本地 WIP 提交；远端同步需待客户端审批功能恢复，不将本地提交冒充已上传。

**已发布仍为 0.2.0 / build 4，源码 `e51654d`。** [GitHub 源码与 IPA](https://github.com/Teeeeeemo/Junction_Hannah_family_Meta_AI/releases/tag/v0.2.0-ios-preview.1) 已上传。0.2.1 / build 5 是 WIP 源码草稿，尚无新 IPA，不应按完整云端可用版安装验收。

| 项目 | 证据和实际边界 |
|---|---|
| 原生云端主链前半段 | `mvp-cloud-final-prd-20261115`：真实视频→搜索/分析→实际 PCM→总览自然进入 1 号（73.03 秒）→受控 1.4 秒断流后重新确认同作品、fresh 当前点定位和新 PCM→真实手选 2 号并播放 PCM均通过；随后提问框键盘失败，两次问答未执行 |
| 有限恢复实现 | 保留旧身份仅作提示，观察次数清零，两个不同新帧重新确认；严格身份/planar/ROI门、fresh当前点门、失败锁存、人工暂停/等待继续保护仍在。不是透视重识别或现实对齐验收 |
| 单项回归 | 字幕清空造成按钮位移 56.33 pt，固定滚动阅读区后同用例位移 0；翻译合并不覆盖新几何的纯回归已过 |
| 输入焦点原因 | 无云同场景确认 `UITextField → WKContentView` 抢焦点，composer未重建。旧容器隔离原型中，两轮输入可跨 7/6 次实际 HUD 发送保持键盘，但不能将该结果算作后续不同实现的绿灯 |
| 最近一次完整离线 UI | `mvp-ui-final-prd-20261115`：11 项中 8 通过、3 失败，487.534 秒。旧自定义容器下 HUD More、恢复后的 Play、字幕 DOM 缺失；该容器已撤回 |
| 当前预览实现 | 恢复原 SDK UIView 直接嵌入；手机输入时同步脱窗并切同高占位，结束后重新呈现同 SDK UIView。`mvp-ui-sdk-direct-20261115` 已确认 HUD DOM/More/点位重新出现；当前变体仍需完整回归 |
| 当前剩余阻塞 | 多次普通 Native HUD 回归在离线总览自动进入 1 号的 45 秒门失败。`mvp-ui-sdk-direct-tts-20261115` 记录真实 didStart，但无 finish/cancel/pause/continue；尚未确定原因，不能归因或放宽超时 |
| 最终收尾回归 | `mvp-ui-sdk-direct-tts-progress-20261115`：0 通过、1 失败、0 跳过，64.297 秒；原 Native HUD 用例仍在 45 秒自动首点门失败，状态为 `selected=intro; playing=true; voice=offline`。未到 More/点位点击。构建成功不等于回归通过；不再开展修复循环 |

最终安全日志 `tts-focus-diagnostics.log` 只有 enqueue（89 字符、Speaker）及 current=true 的真实 start；未观测到后续 willSpeakRange、finish、cancel、pause、continue，也没有音频中断/路由变化/media reset/lost事件。根因仍未知，不以猜测补结论。脚本退出码 65，本轮执行会话已结束，脚本所建模拟器目录已清理；没有继续启动回归或云请求。

本地保全包：`../build-artifacts/handoff-20261115-0303/`，包含主目录和独立下一版草稿的补丁、基线提交、源码 SHA-256 清单及回归摘要；不含 `.env`、凭据或构建产物，不代表通过验收。

主目录分支 `feat/museum-simulator-mvp` 基于 `e51654d` 保留 0.2.1 的 WIP 修改，主要涉及 `GlassCameraModel`、`MuseumBackend`、`SessionEpoch`、`TourNarrator`、`NativeLiveVoice`、`MuseumPhoneView`、`GlassesDisplay`、相关回归及云测试记录工具；不重置现有 WIP。DEBUG 断流/发送压力/诊断不会注入 Release。

下一版来源与语言上下文草稿另存于 `/Users/norman/Developer/Junction/worktrees/museum-current-point-sources`，独立分支 `feat/museum-current-point-sources`，基于 `e51654d`，保留 9 个代码/测试文件的草稿及分支状态说明。只有纯逻辑/部分类型检查通过，未集成到主目录、未做完整 iOS UI/云回归、未打包；按最新指令同步 WIP 源码后仍保持暂停。

后续清单与估时见 [交互收口计划](13-five-hour-interaction-plan.md)，仅供下次指令决定。现实镜片框及标定仍未实现；实际眼镜麦克风/耳边输出、透视追踪及当前点来源完整验收仍未完成。下文为已发布检查点及更早历史。

---

## 2026-11-15：0.2.0 / build 4 模拟器检查点

完整离线 UI 回归在 00:39（Europe/Helsinki）结束：**7 项通过、0 失败**，执行 309.034 秒。当前源码包含原生 Live、作品候选／原始区域分析、Vision 基线追踪及局部窗，但这些代码存在不等于完整云端或实体眼镜通过验收。

本轮已修：手选点讲完后的 Next；短暂输入停顿不再立即永久关闭追踪（超过 1 秒要求重新扫描）；输入来源菜单与逐帧刷新隔离。新增定位等待提示，手选段结束不再误标整段导览完成。暂停后追问的语音暂停状态也已修正，实际云端答案播放留在下一检查点验收。

| 检查 | 实际结果与边界 |
|---|---|
| Web／Node | 84 项通过，生产构建通过；本地 API 测试需监听 localhost，不是实际 Gemini 验收 |
| 原生纯逻辑 | 43 项导览／显示／输入策略、310 项会话生命周期、9 项稳定点位注册检查通过 |
| 追踪 | 6 项时效策略及 9 项实际 Vision 合成图像检查通过；不代替真实输入中断恢复或光学对齐 |
| 原生 Live 协议 | 代际、PCM、命令和字幕边界检查通过 |
| 音频 | AVAudioEngine 离线合成 PCM 六档倍速和停队列检查通过；不含真实麦克风／蓝牙输出 |
| 离线 XCUITest | 7/7：来源切换与会话释放、打断后暂停隔离、实际 DAT HUD 选点与自动首点、相机／无视频保护、空视频拒绝、三轮停止重启、六档倍速／字幕／停止重播 |
| 原生云端／真机 | 本检查点不声明通过；上轮云测试在选点后实际音频播放断言失败，新的选点／暂停后追问回归另行执行 |

证据位于仓库外 `../build-artifacts/mvp-ui-release-20261115/`：`build.log`、`test.log`、`UITests.xcresult`、导出附件及源码 SHA-256 清单。首次来源菜单隔离验证为 `mvp-ui-source-isolated-20261115`，原同一用例 0 失败通过。证据、入口令牌、证书与构建产物不提交 Git。

原生镜片现实框绘制及光学映射**尚未实现**，不是仅待真机核对。真正失跟后自动再识别、透视跟踪、跨重识别稳定编号和镜片当前点来源仍在剩余清单。用户要求本轮先用 iOS 模拟器，最后自行真机验收。

最新五小时计划与每版回归后立即推送规则见 [交互收口计划](13-five-hour-interaction-plan.md)。本节以下保留此前历史记录。

---

记录时间：2026-11-14 23:00（Europe/Helsinki）。分支：`feat/museum-simulator-mvp`。

本次由 Codex 通过用户建立的临时 SSH 共享连接，在 Mac mini 实际构建、启动和操作 iOS App。不是仅阅读代码或运行逻辑单元测试。

## 当前结论

- 已发布的 `0.1.2 / build 3` 对应 `c0154ac73db8b5647bacc9c2f67efd7110b37cfc`。用户已通过 Sideloadly 安装，并确认手机新版打开。
- 本次在该提交上补充 XCUITest、视频素材生成工具及两处运行修复。修复后的 App 已在模拟器出帧、显示原生 DAT HUD、载入离线样例、自动进入 1 号点并响应手机选点与暂停。
- 最新完整 UI 回归：**5 个用例，2 个通过、3 个失败**。失败用例中的前半段有成功断言，不把整个用例算作通过。
- 本次没有生成或安装新 IPA；手机仍是此前的 0.1.2 构建。当前源码的模拟器验证不能替代手机或真实眼镜验收。
- Gemini Live、艺术品优先锁定和持续跟随框仍未修复，见[问题清单](08-bugs-and-roadmap.md)。

## 1. 实际测试环境

| 项目 | 实际值 |
|---|---|
| Mac mini | macOS 26.5.2，Xcode 26.6（17F113） |
| SDK / runtime | Meta DAT 1.0.1；iOS Simulator 26.5 |
| 设备类型 | 新建的隔离 iPhone 15 Pro 模拟器 |
| App 配置 | Debug，`com.muse.museumcompanion`，本地 ad hoc 签名，无 Apple 账号 |
| 输入 | 工具生成的 120 秒 HEVC MP4；移动色块，不是艺术品识别素材 |
| 后端 | 未连接；本轮没有调用 Gemini，未上传视频或密钥 |
| 语音 | 现有 iOS 系统 TTS；验证了状态和完成回调，未进行听感／蓝牙输出验收 |

没有升级当前用户 Mac，也没有在当前 Mac 安装 Xcode。用户原有的另一个模拟器未被修改；测试只使用本次新建实例。

## 2. 已修复的运行问题

### FIX-01：关闭模拟器签名导致 DAT 初始化失败

原 `run_ios.sh simulator` 使用 `CODE_SIGNING_ALLOWED=NO`。实际启动后出现 `Internal error`，`sdkReady=false`，即便视频验证成功也不能开始预览。

对照实验使用 `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO` 后，SDK 初始化成功，相关用例继续运行。已将模拟器脚本改为该本地签名方式；不需要付费账号，也不改变真机 IPA 的重签名流程。未改动 `MWDAT.TeamID` 或回调 scheme。

### FIX-02：模拟会话同步启动时错过状态事件

原代码在新 `Task` 内才调用 `connected.stateStream()`／`errorStream()`，随后立即 `start()`。模拟设备可能在 Task 开始订阅前已发出 `.started`，因此一直没有接入 Camera，最终报没有帧。

修复为在 `start()` 之前同步创建两个 stream，再交给 Task 消费。修复后实际收到帧；中途截图记录累计 **1,007 帧**。这是测试视频帧，不是眼镜相机或作品识别结果。

同时只在收到可转换成 UIImage 的帧后启用依赖画面的操作；单独收到 `.streaming` 状态不再算作已有画面。灰色离线样例按钮增加“先开始模拟预览”的提示。

## 3. 最新 XCUITest 结果

结束时间：23:00:13；5 个用例总执行约 118.7 秒；xcodebuild 退出码 65。

| 用例 | 已执行且通过的步骤 | 用例结论／停止位置 |
|---|---|---|
| `testNoVideoAndSimulatorCameraGuard` | 无视频时启动／样例按钮禁用；切手机相机后明确提示 Simulator 无 iPhone 相机；帧数保持 0 | **通过** |
| `testRejectsEmptyVideo` | 空 MP4 被拒绝；显示 empty 错误；没有假帧，启动保持禁用 | **通过** |
| `testVideoReplayAndOfflineTour` | 实际视频帧、原生预览存在、样例启用、明确 offline 标记、手机选择第 4 点后状态为 4 | **失败**：倍速菜单 `1.5×` 无法计算点击坐标；后续倍速断言、字幕开关和结束后回放未执行 |
| `testNativeHUDAndAutomaticTour` | 总览经实际语音完成回调自动进入 1 号；playing=true；手机暂停后 playing=false；原生 More 菜单可找到第 4 点 | **失败**：点击原生第 4 点后仍为 `selected=1; playing=false; rate=1×` |
| `testBackgroundStopReplayAndRealSource` | 视频有帧；进入后台再回来，帧数清零且停止；从头回放后重新出帧 | **失败**：切源菜单 `Real glasses` 无法计算点击坐标；切到真实来源及 Mock 关闭的断言未执行 |

### 必须继续定位的三个失败

1. `1.5×` 和 `Real glasses`：准确错误为 `Activation point invalid and no suggested hit points based on element frame`。先检查持续刷新时的菜单布局、元素等待、滚动与系统命中测试，不能直接认定倍速／切源业务逻辑错误，也不能跳过断言把用例改绿。
2. 原生 HUD 第 4 点：`Expected narration selected=4; actual selected=1; playing=false; rate=1×`。检查预览缩放／点击落点、SDK click identifier、回调注册与主线程派发，区分点中但没回调和自动化没有实际点中。手机第 4 点已经通过，不代表原生 HUD 回调也通过。
3. UIKit 菜单在持续预览时曾等待动画空闲 60 秒。测试专用 Debug 启动参数会关闭过渡动画；视频和语音仍运行。默认产品启动和 Release 不启用该开关。关闭动画后仍有上述命中测试失败，不能宣称已解决。

## 4. 证据与复现

新增：

- `native/ios/UITests/DebugInputUITests.swift`：真实 App UI 测试，保留截图和 accessibility tree。
- `scripts/test-ios-ui.sh`：默认创建自己的模拟器，构建、安装、生成视频、运行测试、导出结果并清理该模拟器。
- `scripts/make-ios-test-video.swift`：生成明确的移动色块 HEVC 测试视频。
- Debug 专用 `--museum-ui-test` / `MUSE_UI_TEST_VIDEO`：从 App 自己的 Documents 导入测试文件，走生产视频验证和 DAT 管线；不伪造识别或帧计数。Release 不包含该入口。

在有完整 Xcode 和 iOS runtime 的 Mac mini，仓库根目录执行：

```bash
bash scripts/test-ios-presentation.sh
bash scripts/test-ios-ui.sh
```

31 项纯 Swift 检查已通过，Debug App 和 UI test target 已实际编译。完整 UI suite 目前应返回失败，直到上述问题修复。

本次远端证据根目录：`/private/tmp/museum-agent-tests.Of1QHm`。

- 当前完整结果：`source/build/ios/UITests.xcresult`（约 101 MB）。
- 当前构建／测试日志：`source/build/ios/build.log`、`source/build/ios/test.log`。
- 导出附件：`source/build/ios/attachments/`；精简截图和操作树：`source/build/ios/evidence/`。
- 初始化失败的对照：`ui-tests-1.xcresult`；仅加签名、仍没接相机的对照：`ui-tests-signed.xcresult`。
- 当前 Mac 的副本：仓库下 `build/ios/agent-tests/latest/`，以及 `build/ios/agent-tests/during-ui.png`。

这些是测试临时目录／Git 忽略的产物，不随代码 push；临时目录可能被系统清理。中间轮次的[帧数与倍速菜单截图](assets/ios-simulator-rate-menu-2026-11-14.png)仅作运行证据，不代表测试全通过。不在仓库记录密码、访问码、cookie 或 API Key。

## 5. 尚未进行的验收

手机后置相机的实际授权与取流；Files 选择器实际导入；其他编码／大文件兼容；真实 Gemini 识别与 Live 音频；字幕开关和全档倍速最终结果；原生 HUD 点击闭环；真实来源切换；真实眼镜扬声器／麦克风；跟随框、放大、现实校准、光学可读性和端到端延迟；十分钟连续导览。

下一位 Codex 的任务与验收要求见[Mac mini 接力 Prompt](11-mac-mini-codex-handoff-prompt.md)。
