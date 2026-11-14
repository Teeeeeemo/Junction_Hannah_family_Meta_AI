# 平台、官方示例与 API 调研

版本：v0.2 · 核查日期：2026-11-14（Europe/Helsinki）  
目的：帮助用户在文档完成后选择主平台，并为后续开发提供可追溯的依据。

## 1. 选型建议

**设备接入建议先选 Android 原生 App，使用 Meta DAT；当前无硬件阶段先运行浏览器原型，云端已按用户现有账号选择 Gemini。**

本机实际实现与真实联调记录见 [MVP 运行记录](05-mvp-runbook.md)。下面保留前期平台和服务对比资料，价格与方案比较不等于本轮实际使用了对应服务。

这是基于本机工具和 48 小时限制的工程建议，不是说 Android 已证明能实现现实跟随框。A 版在两端都需要先做真机验证。

用户已说明 iPhone 和 Android 都可用，并要求先完成文档再选择。后续补充确认目前没有实体眼镜，官方 Chrome 显示模拟器已启动；因此当前先做模拟器原型，原生平台建议供之后接入 DAT 时使用。尚未替用户最终选平台、安装 SDK、连接眼镜、配置账号或开始应用开发。

## 2. 能否只在眼镜上运行

Meta 官方列出的两条相关路线是：

- **Web Apps**：HTML／CSS／JavaScript 直接运行在 Display 眼镜上，不需要自研原生手机 App。
- **Device Access Toolkit**：将 iOS／Android 手机 App 的能力扩展到眼镜，使用相机、音频、显示和交互等设备能力。[官方 FAQ](https://developers.meta.com/wearables/faq/)

Web App 的独立运行并不代表能拿到所有硬件接口。官方公开仓库中的[相机支持请求](https://github.com/meta/meta-wearables-webapp/issues/13)仍未关闭；[较新的讨论](https://github.com/meta/meta-wearables-webapp/issues/33)也描述了 Web 相机访问限制，但这些用户讨论不是正式发布承诺。当前证据不足以把纯 Web 方案作为实时相机项目的可靠基础。

本项目推荐 DAT。手机可以负责计算与云端通信，交互目标是尽量留在眼镜上。锁屏、后台、音频路由和长时间连接仍要测试，不能仅凭架构承诺“手机完全不需要操作”。

## 3. iOS 与 Android 配置对比

下表以**本次读取的官方 DisplayAccess 示例**为基准，而非泛指所有历史版本 SDK。

| 配置 | Android | iOS |
|---|---|---|
| 开发电脑 | 能运行对应 Android Studio 的系统 | 能运行对应完整 Xcode 的 Mac |
| IDE | Android Studio Narwhal 2025.1.1 或更高 | 示例标注 Xcode 26.4+ |
| 语言／工具链 | Kotlin；JDK 17+ | Swift 6.3+ |
| 编译 SDK | Android SDK 36 | 对应 Xcode iOS SDK |
| 示例最低手机系统 | minSdk 31，即 Android 12 | iOS 17.2+ |
| 构建版本 | 示例 AGP 8.11.1、Gradle wrapper 8.14.1、Kotlin 2.2.21 | Swift Package／示例工程所声明的版本 |
| Meta SDK | 本次 Android 示例使用 DAT 1.0.1 | 按对应示例锁定依赖版本 |
| 真机安装 | USB 调试、ADB、debug 签名 | 自有 bundle identifier、开发签名与设备开发设置 |
| 共同条件 | Meta AI App、正确配对、眼镜 Developer Mode、相机与所需音频权限、兼容固件 | 同左 |

依据：[Android 示例 README](https://github.com/meta/meta-wearables-dat-android/tree/main/samples/DisplayAccess)、[Android 构建配置](https://github.com/meta/meta-wearables-dat-android/blob/main/samples/DisplayAccess/app/build.gradle.kts)、[版本目录](https://github.com/meta/meta-wearables-dat-android/blob/main/samples/DisplayAccess/gradle/libs.versions.toml)、[Gradle wrapper](https://github.com/meta/meta-wearables-dat-android/blob/main/samples/DisplayAccess/gradle/wrapper/gradle-wrapper.properties)、[iOS 示例 README](https://github.com/meta/meta-wearables-dat-ios/tree/main/samples/DisplayAccess)。

Android 通用入门材料中存在 Android 10+ 的表述，但当前 DisplayAccess 示例明确采用 minSdk 31。为减少迁移成本，第一版按示例要求准备 Android 12+ 手机，不把“SDK 的一般下限”当作“当前示例的下限”。

当前示例版本会变化。正式开发时锁定对应提交和依赖，不把 main 分支视为永远不变的版本。本次 Android 仓库树读取到的提交为 `f4371bc9f90249d51eb07d7f8a61e8d829294f16`；这是调研记录，不表示本地已下载或编译该提交。

## 4. 当前电脑检查结果

| 项目 | 本次读取结果 | 含义 |
|---|---|---|
| 系统 | Apple Silicon，macOS 13.7.5 | 需与 IDE 支持系统匹配 |
| Android Studio | Otter 3 Feature Drop 2025.2.3 | 已有较新的 Android IDE |
| Java | 系统 JDK 17.0.19；Android Studio 自带 JDK 21 | 有可用 Java 工具链 |
| Android SDK | 已有 android-36 与 build-tools 36.0.0 | 基础构建 SDK 已在本机 |
| Gradle | 缓存发现 9.1／9.5，未确认有示例的 8.14.1 | 应使用工程自带 wrapper，允许后续下载正确版本 |
| Meta DAT | 未在检查的标准 Gradle 缓存路径发现 | 后续仍需获取依赖，不能称已就绪 |
| Xcode | `xcodebuild -version` 指向 Command Line Tools 并报错 | 没有已可用的完整 Xcode 构建环境 |
| Swift | 5.8.1 | 不满足本次 iOS 示例标注的 Swift 6.3+ |
| ADB | 工具存在，但受限环境无法创建监听端口 | 尚未证明手机已连接；这不是设备或 App 失败 |
| 项目目录 | 本轮开始时为空，无 Git 仓库 | 本次只生成文档 |

Apple 当前系统要求表中，Xcode 26.4.1 要求 macOS Tahoe 26.2 起；当前 macOS 13.7.5 不满足。若选择 iOS，需要另一台符合要求的 Mac 或先解决完整工具链条件，不建议把升级主力电脑当作黑客松的默认前置步骤。[Apple 官方系统要求](https://developer.apple.com/xcode/system-requirements)

因此 Android 的准备工作较少。以上检查未运行示例构建，也未修改系统、启动模拟器或连接真机。

## 5. 已找到的官方 GitHub 示例

| 示例 | 链接 | 本项目借鉴内容 |
|---|---|---|
| Android DisplayAccess | [官方目录](https://github.com/meta/meta-wearables-dat-android/tree/main/samples/DisplayAccess) | 注册、选择 Display 设备、显示生命周期与内容发送 |
| Android CameraAccess | [官方目录](https://github.com/meta/meta-wearables-dat-android/tree/main/samples/CameraAccess) | 相机帧、权限、流状态、清理资源 |
| Android BirdSpotter | [官方目录](https://github.com/meta/meta-wearables-dat-android/tree/main/samples/BirdSpotter) | 多设备能力组合的参考，采用前检查所需权限 |
| iOS DisplayAccess | [官方目录](https://github.com/meta/meta-wearables-dat-ios/tree/main/samples/DisplayAccess) | Swift 端显示接入与开发预览 |
| iOS CameraAccess | [官方目录](https://github.com/meta/meta-wearables-dat-ios/tree/main/samples/CameraAccess) | Swift 端相机接入 |
| Web App 工具与模拟器说明 | [官方仓库](https://github.com/meta/meta-wearables-webapp) | 显示 UI 与浏览器预览；不作为相机权限已验证的依据 |

推荐先分别运行相机与显示最小示例，再合并到同一会话，随后验证音频。官方仓库代码遵守其原有许可证与声明；调研找到示例不等于已把整个示例拷贝到本项目。

后续采用 Android 时可按以下顺序准备；下面是操作说明，本轮未执行：

```bash
git clone https://github.com/meta/meta-wearables-dat-android.git
cd meta-wearables-dat-android/samples/DisplayAccess
./gradlew assembleDebug
./gradlew installDebug
```

执行前先确认所选提交、JDK、SDK 路径和手机。Developer Mode 下官方入门流程允许开发用注册配置；相机、音频等能力的权限仍需分别确认，不能把开发注册跳过 attestation 与“所有权限自动具备”混淆。[官方接入说明](https://github.com/meta/meta-wearables-dat-android/blob/main/plugins/mwdat-android/skills/getting-started/SKILL.md)

## 6. 已知能力与证据边界

| 能力 | 调研结论 | 尚需验证 |
|---|---|---|
| 相机采集 | 官方有相机示例与视频帧接口 | 实际画质、带宽、权限与稳定性 |
| 显示内容 | 官方有图文和视频示例 | 连续画框更新与精确定位能力 |
| 真实细节锚定 | 未找到足以证明本需求的公开接口／示例 | 显示通路、坐标标定、延迟和视野 |
| 眼球注视选择 | 本方案不依赖此能力 | 使用头部对准 + 确认 |
| 相机音频流 | Android 官方列为实验能力 | 开发者配置、实际 PCM、并行运行 |
| 设备端 Speech | Android 官方列为实验能力 | 语言、权限与可用性；不默认替代主语音通路 |
| 额外 Inputs | Android 官方列为实验能力 | 应用启用配置和实际事件 |
| 声音输出 | 需要通过手机／设备支持的音频路径验证 | 回声、延迟、锁屏和连接变化 |
| 模拟器 | 可验证布局、事件与部分状态 | 不能证明实际视野对齐、麦克风和光学效果 |

证据：[显示能力说明](https://github.com/meta/meta-wearables-dat-android/blob/main/plugins/mwdat-android/skills/display-access/SKILL.md)、[音频流说明](https://github.com/meta/meta-wearables-dat-android/blob/main/plugins/mwdat-android/skills/audio-streaming/SKILL.md)、[Speech 说明](https://github.com/meta/meta-wearables-dat-android/blob/main/plugins/mwdat-android/skills/speech/SKILL.md)、[Inputs 说明](https://github.com/meta/meta-wearables-dat-android/blob/main/plugins/mwdat-android/skills/inputs/SKILL.md)。

公开 FAQ、仓库 README 与具体版本说明存在部分状态措辞差异：例如 FAQ 描述 DAT 1.0 稳定发布，部分仓库 README 仍写 developer preview。对本项目应以锁定版本、具体能力和实际权限为准，不能从整体版本名称推导实验能力已经开放生产发布。

## 7. 视觉、语音与模型方案

### 7.1 方案比较

| 路线 | 组合 | 优点 | 代价与判断 |
|---|---|---|---|
| 当前采用 | 本地 OpenCV + Gemini API／Live | 复用用户现有账号，视觉发现、双语文本与 Live 语音由一家提供 | 已完成最小真实联调；完整浏览器打断与实际追踪体验仍待操作验收 |
| 前期备选 | 本地 OpenCV + OpenAI Realtime | 可覆盖双语对话、音频和按需图像 | 本轮未接入，不要求用户再配置 OpenAI 账号 |
| 分段管线 | STT → 文本／视觉模型 → TTS | 文本审核和来源关联更直观 | 多段延迟、队列和中断协调更多，不作第一选择 |

OpenAI 当前模型页列出 `gpt-realtime-2.1`：语音与文本输入输出、图像输入和函数调用；不提供直接视频输入，也不应依赖严格 Structured Outputs。建议用可校验的工具参数，而非让模型输出未经检查的坐标。[模型能力](https://developers.openai.com/api/docs/models/gpt-realtime-2.1)

Gemini Live 的官方说明包含实时音视频交互、多语与打断。它是可选替代，文档并不证明它在本项目的现场网络、中文和设备音频下优于主方案。[Gemini Live 官方概览](https://aistudio.google.com/docs/live-api)

**可先复用同一多模态服务提出细节点候选，无需立即增加第二家视觉提供商。** v0.2 要求根据当前画面自动发现／确认点位，再在右侧生成列表，不能只使用预设静态菜单。本地视觉方法负责定位与持续追踪，语义模型负责候选名称与解释；候选位置和出处要校验，识别质量与耗时尚未实测。对任意作品的无限细节发现和完整分割仍不在第一版承诺范围内。

### 7.2 最短的云端接入步骤

1. 使用用户已有的 Gemini API 项目，确认图像与 Live 模型的可用性和额度。[Gemini Live 概览](https://aistudio.google.com/docs/live-api)
2. 在本地后端 `.env.local` 设置 `GEMINI_API_KEY`，不把主密钥放入手机、网页、Git 仓库或聊天消息。
3. 先用电脑或手机测试中文／英文语音往返和打断，排除云账号与模型配置问题；注明这还不是眼镜测试。
4. 后端通过 Gemini Live SDK 连接实时模型，按会话配置音频格式，连接 App 的 PCM 输入和播放队列。
5. 加入作品／细节内容工具，再连接眼镜相机与音频；最后测完整链路延迟与回声。

后端已采用 Node.js 与轻量 HTTP／WebSocket 服务，依赖保存在 package-lock.json。用户已在本机配置 Gemini Key，最小联调成功；本轮没有创建付费账户或部署公网服务。前期环境检查和候选价格资料保留为调研快照。

### 7.3 费用与控制

截至核查时，模型页列出的未缓存音频价格（美元／百万 tokens）：

| 模型 | 音频输入 | 音频输出 |
|---|---:|---:|
| gpt-realtime-2.1 | $32 | $64 |
| gpt-realtime-2.1-mini | $10 | $20 |

依据：[2.1 价格](https://developers.openai.com/api/docs/models/gpt-realtime-2.1)、[2.1 mini 价格](https://developers.openai.com/api/docs/models/gpt-realtime-2.1-mini)。文本、图像、缓存和其他工具另按对应项目计费；价格会变动，接入前复核。不把 token 单价直接换成未经测量的“每小时费用”。

建议先用主模型验证核心体验，若成本不合适，比较 mini 的事实遵循、中文人名、噪声和打断效果再换。记录每次会话的 usage 和时长，限制最大会话时间；正式预算待用户决定。缓存经过核对的固定概览可减少重复生成，但不能用缓存冒充实时回答。

## 8. 演示内容候选

建议优先使用 The Met 提供的作品资料。以下三幅已核查到馆方页面，**尚未下载图像、完成标注或制作双语讲稿**：

| 作品 | 馆方记录 | 可优先研究的视觉细节 |
|---|---|---|
| Vincent van Gogh, Wheat Field with Cypresses, 1889 | [436535](https://www.metmuseum.org/art/collection/search/436535) | 柏树、天空线条、麦田 |
| Rembrandt, Aristotle with a Bust of Homer, 1653 | [437394](https://www.metmuseum.org/art/collection/search/437394) | 半身像、手部、链饰 |
| Emanuel Leutze, Washington Crossing the Delaware, 1851 | [11417](https://www.metmuseum.org/art/collection/search/11417) | 中心人物、旗帜、船与冰面 |

右栏是供标注选择的视觉候选，不等于已验证的历史解释。正式内容包需逐项确认图像使用条件、资料支撑和适合讲述的观点。

The Met 有公开 Collection API；其文档已说明旧搜索端点的迁移安排，因此新增搜索应核对当前 `/v1.1/search`，不要照搬旧教程中的退役搜索接口。直接获取已知作品记录应遵循当前对象接口说明。[馆方 API 文档](https://metmuseum.github.io/)

## 9. 本轮调研验证等级

- 已读取官方网页、GitHub 文件与当前公开模型文档。
- 已检查本机系统、IDE、Java、Android SDK、Xcode／Swift 和部分缓存。
- 未下载 SDK／工程依赖，未编译示例或应用。
- 未取得可用设备连接；ADB 在当前受限环境中未能创建监听端口。
- 未运行任何付费 API 请求、语音测试或真实作品光学对齐实验。
- 部分 Wearables Developer Center 页面需要登录；公开 GitHub 资料是本轮主要 API 证据，未访问到的页面不当作已核查。
