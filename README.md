# Museum Companion — Meta Ray-Ban Display 博物馆导览

项目状态（2026-11-15 08:35，演示版）：iOS 0.2.6 / build 10 是当前演示构建（[源码与 IPA](https://github.com/Teeeeeemo/Junction_Hannah_family_Meta_AI/releases/tag/v0.2.6-ios-preview.1)）。包含 0.2.5 的 No.1／BUG-02 跟随框修复（手机相机画面框 + 眼镜“CAMERA VIEW”小图显示通路；镜片现实对齐未实现，P02 不关闭），以及最终交付方案的参观模式／开发者设置、首页状态灯和一键“开始导览”。模拟器离线 UI 10/11、云端 T01／T02 框验收通过；真机待用户确认。详见 [测试进度](docs/10-ios-simulator-test-progress.md) 与 [最终交付方案](docs/16-final-delivery-and-ui-plan.md)。

最新已完成、待验证、阻塞与待办见 **[项目进度与待办](docs/07-project-progress.md)**。本次实际运行结果见 **[iOS 模拟器测试进度](docs/10-ios-simulator-test-progress.md)**；交给 Mac mini Codex 的任务见 **[接力 Prompt](docs/11-mac-mini-codex-handoff-prompt.md)**。

用户报告的问题与最终功能差距见 **[已知问题与剩余功能](docs/08-bugs-and-roadmap.md)**；无实体眼镜时的手机相机、视频回放与原生 Display 预览见 **[无眼镜调试手册](docs/09-no-glasses-debugging.md)**。

产品目标：先进行通识语音介绍，允许概览生成／朗读期间识别细节点；列表加载校验完成即在眼镜屏幕右侧显示编号列表，不等待概览结束；无用户改选时，概览结束／跳过后自动从 1 号讲解；用户可随时打断并选择关心的点位。自动讲解与用户选点讲解时，检测框均持续跟随当前细节。失跟时隐藏无效框和局部窗但继续讲解；新点定位等待最多约 2.5 秒后也开始讲解，恢复可靠定位后再显示。新增目标：概览和每个细节分别显示环形朗读倒计时，细节列表标题最多三个单词；这三项 UI 变更尚未实现。以下按原型实现与最终验收分别记录。

## Web 原型与早期真机交付（历史记录）

已实现本地 Chrome Simulator MVP：React + 官方 Meta UI Toolkit、Gemini 视觉／问答／Live 语音、本地 OpenCV 追踪、右侧点位列表、自动首点讲解、打断改选、整句字幕、0.75×–2×播放倍速及局部放大。71 项自动测试与生产构建通过，真实 Gemini 调速指令已联调。

默认 Web 入口为实时相机输入：收到真实解码帧后才识别，内置图片保留为手动演示入口。眼镜 Web App 没有相机采集权限；[iOS DAT 工程](native/ios/README.md) 已通过远端构建和指定 iPhone 安装，用户反馈相机画面识别和眼镜文字显示。原生版与 Web 功能尚未完全对齐，系统 TTS 不能当作 Gemini Live 语音，现实跟随框和作品优先锁定仍未实现。

设备更新：用户已完成 Meta Ray-Ban Display 配对和 Developer Mode，目标手机为 iPhone 15 Pro / iOS 26.5.2。0.1.2 / build 3 已签名安装并打开。当前新增模拟器签名、会话启动修复及可复现 XCUITest；实际视频出帧、离线样例、自动首点与手机选点已有运行证据，完整 UI 回归为 2 通过／3 失败。此次源码修复尚未打包或安装。相机和模型输出、系统朗读、实际眼镜音频路由与现实对齐分别记录，不合并宣称完成。

## 运行

```bash
npm ci --registry=https://registry.npmjs.org
npm run build
npm start
```

在安装 Simulator 插件的 Google Chrome 打开 **http://127.0.0.1:4173/**，再点击扩展图标开启模拟器。首次配置参考 `.env.example`，将密钥填在被 Git 忽略的 `.env.local` 中；已有配置不要覆盖。普通视觉模型使用 `gemini-3.8-flash`，Live 使用经本机接入验证的 `gemini-2.5-flash-native-audio-preview-12-2025`，可按账号能力修改。

默认点击 **Scan the artwork／识别眼前作品** 请求当前浏览器相机，收到实际视频帧后使用真实 Gemini；眼镜 Web 无相机权限时明确提示配对手机 DAT 接入，不回退到预设画作。手动选择演示画作后，可真实分析图片或明确选择 **Explore offline demo／体验离线演示**。摄像头与麦克风只在用户启用后申请权限。

详细操作、验证结果与限制见 [MVP 运行与验收记录](docs/05-mvp-runbook.md)。

下面的 PRD 与技术计划保留最终产品要求；各项是否已验证，以运行记录为准。最大的未决条件是公开 SDK 的低延迟显示更新，以及相机到佩戴者视野的现实对齐。A 版仍是核心需求，不以相机画面内的框替代真机验收。

## 最新开发与交付排期

当前第一优先级为 **P02／BUG-02 跟随检测框修复**，手机视频、模拟 DAT 和真实镜片分别验收，见 [PRD](docs/01-product-requirements.md)及[专项验收](docs/04-validation-and-delivery.md)。随后推进[首次识别与朗读延迟优化](docs/15-startup-and-narration-latency-plan.md)；[最终交付与界面收口](docs/16-final-delivery-and-ui-plan.md)安排在核心功能修复和验收后的最终阶段实施。两份方案均为待开发任务，不代表当前 IPA 已交付。

[早期 iPhone 实测问题记录](docs/14-iphone-field-issues-2026-11-15.md)保留 0.2.0 历史证据，当前实现与验证以[测试进度](docs/10-ios-simulator-test-progress.md)为准。

## 阅读顺序

1. [产品文档 PRD](docs/01-product-requirements.md)：目标用户、核心流程、功能范围与验收要求。
2. [技术文档](docs/02-technical-design.md)：架构、追踪与校准、局部放大、实时语音、数据与接口。
3. [平台与 API 调研](docs/03-platform-and-api-research.md)：iOS／Android 配置、官方 GitHub 示例、云服务接入建议和证据。
4. [开发、测试与交付计划](docs/04-validation-and-delivery.md)：48 小时安排、可行性验证、测试用例和交付清单。
5. [MVP 运行与验收记录](docs/05-mvp-runbook.md)：本次实现、启动步骤、真实 Gemini 联调与未完成验收。
6. [真机网页接入](docs/06-device-preview.md)：临时 HTTPS 入口、Meta AI App 添加步骤、访问控制与验证范围。
7. [项目进度与待办](docs/07-project-progress.md)：最新总进度、验证层级、iOS 环境阻塞及接下来执行顺序。

## 已确定与待确定

| 项目 | 状态 |
|---|---|
| 真实作品上的跟随框（A 版） | 用户明确要求；技术可行性待真机验证 |
| 右上角半宽、半高放大窗，2×／4× | 用户明确要求；UI 尺寸暂定 |
| 右侧细节列表加载即显示；概览结束后自动首点，用户改选优先 | PRD v0.4；待修改 0.2.3 旧隐藏规则 |
| 每段独立环形朗读倒计时、列表标题最多三词 | PRD v0.4 新增，待实现 |
| 默认从 1 号点位开始；用户可打断并切换任意列表点位 | 用户明确要求 |
| 自动／用户选点讲解时，检测框持续跟随当前点位 | 用户明确要求 |
| 中英双语、联网、二维画作为主 | 用户明确要求 |
| 1 个真实 3D 物体示例 | 高级功能，核心功能通过后再做 |
| 当前手机平台 | iPhone 15 Pro / iOS 26.5.2，已有 0.1.2 安装；Mac mini 承担完整 Xcode 构建，本机不升级 |
| 首批 3 幅画作、打印或屏幕展示 | 本文建议，尚未由用户最终选定 |
| Gemini API | 已由用户本地配置；真实视觉、问答与 Live 音频接入验证成功 |
| 眼镜设备权限 | 已配对并完成 Meta 注册，有基础相机与文字输出反馈；麦克风、音频路由、持续对齐等仍待单独验收 |

下一步在现有 Mac mini 按接力 Prompt 定位三个 UI 失败，再修复原生 Gemini Live、艺术品锁定、现实跟随框与放大等核心缺口。当前 Mac 保持原系统和工具配置；模拟测试不代表 A 版现实对齐已经通过。早期 PRD 与技术计划中的设备状态属于当时的记录，最新事实以进度文档及问题清单为准。
