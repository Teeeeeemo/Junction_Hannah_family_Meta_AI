# Museum Companion：iOS DAT 相机接入工程

状态：工程与接入代码已准备；尚未使用完整 Xcode 编译、签名安装或真机运行。Swift 语法检查、Info.plist 和 Xcode 工程属性列表检查通过，这些检查不解析或验证 Meta SDK 类型。

## 工程范围

- Meta AI 注册、回调和眼镜相机权限请求。
- 在同一个 DAT `DeviceSession` 中接入相机与 Display；视频使用 `.raw`、中等分辨率、15 FPS。
- 接收并显示真实眼镜帧；收到第 8 帧后自动发起一次作品识别。
- 将真实帧压缩后提交给现有 `/api/analyze`，复用本机 Gemini 后端。
- 接收作品、介绍和细节点，并尝试通过 DAT Display 显示文字与选点按钮。
- 手动再次扫描；停止、超时、后台与过期异步结果的清理。

这不是完整 iOS 版导览：尚未迁移连续细节追踪、镜片现实坐标校准、2×／4×局部窗、完整语音导览、麦克风追问和语音倍速控制。Swift 代码中的 Display 与相机并行使用仍须实际编译及真机验证。

## 构建条件

官方样例基线为 Xcode 26.4+、Swift 6.3+、iOS 17.2+；工程通过 Swift Package Manager 固定引用 Meta DAT **1.0.1** 的 `MWDATCore`、`MWDATCamera`、`MWDATDisplay`。

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

以上已通过；**不能据此宣称 iOS SDK 类型检查、链接、签名、安装或真机功能通过**。环境升级完成后首先执行：

```bash
xcodebuild -project native/ios/MuseumCompanion.xcodeproj -scheme MuseumCompanion -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

此命令尚未执行成功。构建、设备权限、相机与显示并发、后台行为和实际延迟等结果需补充到进度文档。
