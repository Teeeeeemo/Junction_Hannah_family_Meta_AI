# iOS 模拟器测试进度与交接

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
