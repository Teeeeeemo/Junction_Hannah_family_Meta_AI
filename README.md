# Museum Companion — Meta Ray-Ban Display 博物馆导览

项目状态：Simulator MVP · 2026-11-14（Europe/Helsinki）

先进行通识语音介绍，再自动识别作品细节点并在眼镜屏幕右侧显示编号列表，从 1 号点位开始讲解；用户可随时打断并选择关心的点位。自动讲解与用户选点讲解时，检测框均持续跟随当前细节。

## 当前阶段

已实现本地 Chrome Simulator MVP：React + 官方 Meta UI Toolkit、Gemini 视觉／问答／Live 语音、本地 OpenCV 追踪、右侧点位列表、自动首点讲解、打断改选、整句字幕、0.75×–2×播放倍速及局部放大。64 项自动测试与生产构建通过，真实 Gemini 调速指令已联调。

设备更新：用户已取得 Meta Ray-Ban Display，通过 iPhone 的 Meta AI App 完成配对并开启 Developer Mode。截图显示 Meta AI App 299.0.0.26.159、设备在线、DAT SDK 1.0.0.0；该 SDK 版本不是固件版本。Web apps 添加入口已确认可见。iOS DAT 接入、眼镜端显示／相机／音频与现实对齐仍待实现和真机验证，当前没有可安装的 iOS App。

## 运行

```bash
npm ci --registry=https://registry.npmjs.org
npm run build
npm start
```

在安装 Simulator 插件的 Google Chrome 打开 **http://127.0.0.1:4173/**，再点击扩展图标开启模拟器。首次配置参考 `.env.example`，将密钥填在被 Git 忽略的 `.env.local` 中；已有配置不要覆盖。普通视觉模型使用 `gemini-3.8-flash`，Live 使用经本机接入验证的 `gemini-2.5-flash-native-audio-preview-12-2025`，可按账号能力修改。

点击 **Begin your visit／开始导览** 使用真实 Gemini；**Explore offline demo／体验离线演示** 是明确标记的预设内容。摄像头与麦克风只在用户启用后申请权限。

详细操作、验证结果与限制见 [MVP 运行与验收记录](docs/05-mvp-runbook.md)。

下面的 PRD 与技术计划保留最终产品要求；各项是否已验证，以运行记录为准。最大的未决条件是公开 SDK 的低延迟显示更新，以及相机到佩戴者视野的现实对齐。A 版仍是核心需求，不以相机画面内的框替代真机验收。

## 阅读顺序

1. [产品文档 PRD](docs/01-product-requirements.md)：目标用户、核心流程、功能范围与验收要求。
2. [技术文档](docs/02-technical-design.md)：架构、追踪与校准、局部放大、实时语音、数据与接口。
3. [平台与 API 调研](docs/03-platform-and-api-research.md)：iOS／Android 配置、官方 GitHub 示例、云服务接入建议和证据。
4. [开发、测试与交付计划](docs/04-validation-and-delivery.md)：48 小时安排、可行性验证、测试用例和交付清单。
5. [MVP 运行与验收记录](docs/05-mvp-runbook.md)：本次实现、启动步骤、真实 Gemini 联调与未完成验收。
6. [真机网页接入](docs/06-device-preview.md)：临时 HTTPS 入口、Meta AI App 添加步骤、访问控制与验证范围。

## 已确定与待确定

| 项目 | 状态 |
|---|---|
| 真实作品上的跟随框（A 版） | 用户明确要求；技术可行性待真机验证 |
| 右上角半宽、半高放大窗，2×／4× | 用户明确要求；UI 尺寸暂定 |
| 通识介绍后自动进入细节模式、右侧显示编号列表 | 用户明确要求 |
| 默认从 1 号点位开始；用户可打断并切换任意列表点位 | 用户明确要求 |
| 自动／用户选点讲解时，检测框持续跟随当前点位 | 用户明确要求 |
| 中英双语、联网、二维画作为主 | 用户明确要求 |
| 1 个真实 3D 物体示例 | 高级功能，核心功能通过后再做 |
| 当前手机平台 | 已通过 iPhone 配对，接下来按 iOS 路线接入；Mac 的完整 Xcode 构建环境尚未就绪 |
| 首批 3 幅画作、打印或屏幕展示 | 本文建议，尚未由用户最终选定 |
| Gemini API | 已由用户本地配置；真实视觉、问答与 Live 音频接入验证成功 |
| 眼镜设备权限 | 已取得并配对、Developer Mode 已开启；实际 SDK 权限仍待验证 |

下一步通过 HTTPS 入口完成 Web 真机显示验证，准备 iOS 构建环境并执行 Gate 0；继续保留 Simulator 作为原型与回归入口。原型测试不代表 A 版现实对齐已经通过。早期 PRD 与技术计划中的设备状态属于当时的记录，最新设备和平台状态以此处为准。
