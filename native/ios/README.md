# Museum Companion：iOS DAT 相机接入工程

> 收尾状态：0.2.1 / build 5 仍是未通过验收的 WIP 源码草稿，完整回归未通过，尚无新 IPA。用户要求收完当前回归后暂停，详见 [最新交接](../../docs/10-ios-simulator-test-progress.md)。已发布安装包仍为下述 0.2.0。

> 2026-11-15 最新：0.2.0 / build 4 源码的完整离线模拟器 UI 7/7 通过，基础检查与生产构建通过。原生 Live、作品锁定／裁剪、Vision 基线和局部窗已有实现；原生云端完整闭环仍需单独验收，镜片现实框绘制和光学映射尚未实现。详见 [最新测试记录](../../docs/10-ios-simulator-test-progress.md) 和 [五小时计划](../../docs/13-five-hour-interaction-plan.md)。下文 0.1.x 状态保留为历史说明。

状态（2026-11-14 晚）：0.1.2 / build 3（`c0154ac`）已发布并通过 Sideloadly 安装到指定 iPhone，用户确认新版打开。本次新增模拟器签名／会话启动修复与 XCUITest，实际视频出帧、离线样例和部分交互已运行；最新 UI suite 2 通过／3 失败。修复源码尚未打包或安装。详见[测试进度](../../docs/10-ios-simulator-test-progress.md)及[Mac mini 接力任务](../../docs/11-mac-mini-codex-handoff-prompt.md)。三个产品 BUG 仍未修复。

## 0.1.2：无眼镜调试

- 输入来源可选真实眼镜、手机后置相机、视频回放。手机相机与视频经官方 `MWDATMockDevice` 创建模拟 Display 设备，复用同一 DAT 相机／显示会话与识别管线。
- 手机内显示 SDK 原生 Display 预览，保留实际按钮回调；模拟入口和帧计数明确标记，不冒充实际眼镜。
- 模拟预览不依赖实体眼镜、真实 Meta 注册或后端；云端识别需要连接后端。未连接后端时可主动载入明确标记的四点离线布局样例，声音仍为系统 TTS。
- 手机相机需系统 Camera 权限；Simulator 采用文件回放。文件导入持有安全作用域，复制到 App 缓存并检查可播放轨道；切源／停止使旧帧和迟到分析失效。
- 输入策略、导览与显示逻辑共 31 项检查通过；SDK HEVC 回放、自动首点和部分交互已有实际运行证据；预览点击、菜单命中及其他编码仍待完成验证。

操作与验收：[无眼镜调试手册](../../docs/09-no-glasses-debugging.md)。未完成项：[已知问题与剩余功能](../../docs/08-bugs-and-roadmap.md)。

## 0.1.1：紧凑显示与自动朗读

- 手机采用 MUSE 深色与金色界面，连接设置和完整讲解折叠，当前一句与播放控制独立展示。
- 眼镜使用透明背景与右侧列表，每页最多三个短点位；左侧保留主要视野。字幕默认关闭，开启后仅显示当前一句的限长预览，完整句子仍全部朗读。
- 识别成功后使用 iOS 系统语音先读总览，再自动从 1 号点推进；手机和眼镜的选点都会立即停止旧朗读，播放新点位。
- 手机和眼镜均有暂停／播放、下一处、返回总览和语速控制；0.75、1、1.25、1.5、1.75、2 是系统 TTS 语速档位，不能等同于音频文件精确的时长倍数。改变语速会重读当前一句。
- 语音跟随 iOS 当前媒体输出，可在手机页顶部或朗读卡片的音频图标选择眼镜。实际声音从眼镜扬声器输出、语音可懂度和佩戴布局均须真机验证。
- 切换作品重新识别、停止或进入后台会停止旧语音；旧 utterance 回调和过期显示任务不能覆盖新点位。
- 保留已发布源码附件中的动态框架搜索路径和 SDK 初始化失败保护修复。

在有 Xcode 的 Mac mini、仓库根目录执行：

```bash
bash scripts/test-ios-presentation.sh
bash run_ios.sh unsigned
```

输出为 `build/ios/MuseumCompanion-unsigned.ipa`，下载回本机后用现有 Sideloadly 设置重签名安装。沿用同一 Apple ID 和原始 Bundle Identifier，核对工具实际生成的签名 Bundle ID 是否与旧安装一致。`museumcompanion://` 和 `MWDAT.AppLinkURLScheme` 保持原值；免费签名有效期以新描述文件为准。请勿把源码下载 ZIP 当作 IPA。

`run_ios.sh` 来自已发布预览版的成功构建源码附件；0.1.1 已用此流程构建。0.1.2 已实际构建；当前修复如需安装，须重新生成 IPA。脚本支持 `IOS_BUILD_DIR` 自定义输出目录。

本地已通过 17 项纯 Swift 导览／显示逻辑检查（中英分句、总览自动推进、手动改选、结束与重播、三点分页、Unicode 截断与默认隐藏字幕）、全部 Swift 源码语法检查、工程属性列表检查及构建脚本语法检查。这些检查不包含实际发声、iOS SDK 类型检查或镜片视觉验收。

## 工程范围

- Meta AI 注册、回调和眼镜相机权限请求。
- 在同一个 DAT `DeviceSession` 中接入相机与 Display；视频使用 `.raw`、中等分辨率、15 FPS。
- 接收并显示真实眼镜帧；收到第 8 帧后自动发起一次作品识别。
- 将真实帧压缩后提交给现有 `/api/analyze`，复用本机 Gemini 后端。
- 接收作品、介绍和细节点，通过 DAT Display 显示紧凑点位列表与可选当前句字幕，并使用系统 TTS 自动导览。
- 手动再次扫描；停止、超时、后台与过期异步结果的清理。

尚未迁移连续细节追踪、镜片现实坐标校准、2×／4×局部窗、Gemini Live 麦克风追问和语音指令调速。Web 的 HTML/CSS 没有直接嵌入原生 DAT Display；此处为同一产品结构的原生实现，不能宣称视觉逐像素一致或功能完全对齐。

## 构建条件

官方样例基线为 Xcode 26.4+、Swift 6.3+、iOS 17.2+；工程通过 Swift Package Manager 固定引用 Meta DAT **1.0.1** 的 `MWDATCore`、`MWDATCamera`、`MWDATDisplay`、`MWDATMockDevice`。

当前用户 iPhone 系统为 26.5.2，建议选支持 iOS 26.5 的 **Xcode 26.6 + macOS Tahoe 26.2 或更高的 26.x 正式版**。Swift 和 iOS SDK 随 Xcode 提供，不需要单独安装 Swift。当前 Mac 仍为 macOS 13.7.5，只有 Command Line Tools，尚不具备本工程的原生构建环境。

依据：[Meta CameraAccess](https://github.com/meta/meta-wearables-dat-ios/tree/main/samples/CameraAccess)、[Apple Xcode 兼容表](https://developer.apple.com/xcode/system-requirements)。API 设计另参照官方 [camera-streaming](https://github.com/meta/meta-wearables-dat-ios/blob/main/plugins/mwdat-ios/skills/camera-streaming/SKILL.md) 与 [display-access](https://github.com/meta/meta-wearables-dat-ios/blob/main/plugins/mwdat-ios/skills/display-access/SKILL.md)。调研源代码提交：`bbae597cd1c748cd29b9375a1624a8d75b1c9e14`。使用 SDK 时适用 [Meta 开发者条款](https://wearables.developer.meta.com/terms)。

## 在兼容 Mac 上接入

1. 打开 `MuseumCompanion.xcodeproj`，等待 Swift Package Manager 解析依赖。
2. 在 Signing & Capabilities 选择自己的开发 Team；根据需要更换 Bundle Identifier。
3. 连接 iPhone，完成“信任此电脑”和安装阶段要求的 iPhone 系统 Developer Mode；眼镜的 Meta AI Developer Mode 已开启。
4. 选择 `MuseumCompanion` scheme 和真实 iPhone，Build 后 Run。
5. 在手机应用中粘贴本次完整 HTTPS 测试链接，点击 **Connect backend**。链接和会话 cookie 只保存在运行中的应用内存，不包含 Gemini Key。
6. 点击 **Register with Meta AI** 完成注册，再点击明确标明权限跳转的 **Start glasses camera**。
7. 对准作品，检查 **Actual received frames** 持续增加、手机实时预览、真实识别返回结果及眼镜文字显示。
8. 换作品时点击 **Scan again**；结束时点 **Stop camera**。应用进入后台时会释放视频会话。

Meta 相机权限与设备注册必须在此原生应用中完成；Meta AI App 内开启 Developer Mode 不会自动给眼镜 Web App 增加相机权限。本工程使用原生 DAT Display 输出，不假定独立 Web App 与 DAT 显示会话能同时占用镜片。

## 连接与密钥

开发者模式下 `Info.plist` 中 Meta App ID 与 Client Token 使用 `0`，与官方开发说明一致；生产分发需按 Meta 规则配置正式值。Apple 开发 Team 留空，构建者在 Xcode 中设置。

暂时使用已授权的临时 HTTPS 入口；Mac 上的应用服务、访问入口和 Cloudflare 通道须保持运行。实际访问 URL、访问码、API Key、Xcode 用户设置和构建产物不得提交 Git。稳定后端与正式分发不是本阶段已完成项。

## 当前验证

```bash
plutil -lint native/ios/Info.plist native/ios/MuseumCompanion.xcodeproj/project.pbxproj
swiftc -frontend -parse native/ios/Sources/*.swift
```

0.1.2 已构建并安装，当前修复也已通过实际 Debug／UI test target 编译。可在 Mac mini 执行以下构建检查：

```bash
xcodebuild -project native/ios/MuseumCompanion.xcodeproj -scheme MuseumCompanion -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

请以新版构建日志、安装版本号和实际佩戴结果补充验收，尤其验证：默认视野无长段文字；听到总览后自动进入 1 号点；点选 3 号立即切换语音；暂停／继续；开关字幕；三点分页；眼镜音频路由；停止／重扫时无旧语音。

可重复 UI 回归：`bash scripts/test-ios-ui.sh`。测试脚本保留当前失败，结果说明见 docs/10；当前只把实际运行到且通过的断言计入进度。
