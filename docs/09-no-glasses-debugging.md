# Museum Companion：无眼镜调试手册

更新：2026-11-14（Europe/Helsinki）。适用源码版本：0.1.2 / build 3。

当前状态：0.1.2 / build 3 已发布并安装；本次又补充模拟器签名／会话启动修复和 XCUITest，实际视频出帧、离线样例、自动首点及手机选点已运行。最新 UI suite 2 通过／3 失败；此次修复尚无新 IPA，详见[实际测试进度](10-ios-simulator-test-progress.md)。以下操作说明不代表所有步骤已验收。

## 1. 能做什么

| 输入来源 | 图像来源 | 显示与识别 |
|---|---|---|
| 真实眼镜 | DAT 眼镜相机 | 保留原有注册、授权、原生 Display 和后端链路 |
| 手机后置相机 | iPhone 实际相机，经 MockDeviceKit 输入 | 在手机预览相机帧和同一 DAT 会话的原生眼镜界面；无需实体眼镜和真实 Meta 注册 |
| 视频回放 | 用户明确导入的本地 MP4／MOV | 视频帧经同一 DAT 管线进入后端；可以从头回放；适合重复测试同一运动与遮挡 |

所有模拟入口都显示“模拟调试／SIMULATION”，计数标为模拟输入帧。它不是实际眼镜相机，也不证明镜片现实对齐。SDK 的 `createPreviewView()` 显示同一套原生 Display 组件与按钮回调，不是另一套 Web 界面的截图。

模拟预览不要求后端连接。连接后端后，会自动分析收到的真实手机相机／视频帧；不连接时可明确选择“离线布局样例”，测试菜单、字幕和系统朗读。样例在手机、眼镜预览标题和朗读开头均说明不是当前画面识别。

## 2. 构建与安装

本地旧 Mac 不需要升级或安装 Xcode。在有 Xcode 的 Mac mini 的仓库中操作；推荐独立 worktree 保留旧工程修改：

```bash
git fetch origin
git worktree add --detach ../museum-ios-no-glasses origin/feat/museum-simulator-mvp
cd ../museum-ios-no-glasses
bash scripts/test-ios-presentation.sh
set -o pipefail
bash run_ios.sh unsigned 2>&1 | tee /tmp/museum-ios-no-glasses-build.log
```

成功后才会生成 `build/ios/MuseumCompanion-unsigned.ipa`。确认版本为 0.1.2 / build 3，再下载回 iPhone 附近的 Mac，沿用现有 Sideloadly 账号与原始 Bundle Identifier 重签名安装。保留 `museumcompanion://` 回调。

工程新增 `MWDATMockDevice`，与其他 DAT 模块一样固定在 1.0.1。无需把 Gemini Key 复制到远端或 iPhone；测试后端仍在原 Mac，连接方式不变。

用户本地旧 Mac 只有 Command Line Tools；完整编译已在 Mac mini 实际执行。语法检查和纯 Swift 测试不能代替 Xcode 编译及运行。出现编译错误时保留完整日志，以第一处 error 为起点修复。

## 3. iPhone：手机相机模式

1. 打开 Museum Companion，在“输入来源”选择“手机后置相机”。切换来源会先结束旧会话与朗读。
2. 确认出现“模拟调试 · 无需实体眼镜”，Meta AI 注册按钮不再显示。
3. 不连接后端也可以点“开始模拟预览”。首次允许 Museum Companion 访问手机相机；拒绝后可在 iPhone 设置中修改权限，或改用视频回放。
4. 对准画作，检查模拟输入帧数增加、手机相机画面更新。
5. 下方“原生眼镜界面预览 · 模拟”应显示原生 Display 内容，可点击其中按钮。实际交互是否可用仍需此版本运行验收。
6. 要测试 Gemini 视觉识别，展开连接设置、粘贴当次完整 HTTPS 测试链接，点击连接后端；收到可用帧后会自动识别一次。或在连接就绪后点击重新识别。
7. 要离线测试界面，主动点击“载入离线布局样例（非画面识别）”；样例包含四个点，可测试三点分页、选点打断、总览推进、字幕和系统语速。它不调用 Gemini，也不会伪装成当前画面识别。
8. 使用期间保持 App 在前台；停止或进入后台会释放相机／模拟设备并停止旧朗读。

## 4. iPhone：视频回放模式

1. 先把一段短视频放到 iPhone 的“文件”App。可从照片中分享并“存储到文件”。
2. 选择“输入来源 → 视频回放”，点“选择 MP4／MOV”。
3. 文件会复制到 App 自己的缓存，再检查可播放的视频轨道；不保留临时文件提供者 URL。限制 500 MB，优先使用短片。
4. 建议使用 SDK 文档列出的 HEVC 编码 MP4／MOV。文件可由系统播放不代表 SDK 一定支持该编码；若没有出帧，保留报错并换用 HEVC 测试文件。
5. 点“开始模拟预览”，检查视频帧与原生 Display 预览。连接后端或使用离线布局样例的方式与上节相同。
6. 点“从头回放”会停止旧会话后从同一缓存视频重新开始。若视频结束后没有新帧，重新回放再识别，不把旧帧当实时输入。
7. 更换文件或输入来源时先结束旧会话；后台导入取消后不会把迟到文件结果写到新来源。

当前只保存输入来源偏好，不持久保存上次选中的视频位置；App 重启后需要重新选文件。缓存文件可被系统回收。模拟回放不会上传完整视频，只有实际发起识别时选取的帧进入现有后端。

## 5. Mac mini：iOS Simulator

```bash
bash run_ios.sh simulator
```

编译成功后，通过 Xcode／Simulator 打开构建产物：`build/ios/DerivedData/Build/Products/Debug-iphonesimulator/MuseumCompanion.app`。

- 未设置偏好时，iOS Simulator 默认使用视频回放。
- Simulator 没有这台实体 iPhone 的后置相机；选择手机相机时会提示改用录像。
- 当前集成的是 App 内原生 Display 预览，不包含启动 Chrome 预览服务器。原 Web／Chrome Simulator 保留独立使用。
- 本次复现并修复 `Wearables.configure()` 的 `Internal error`：模拟器 App 使用本地 ad hoc 签名，不再关闭签名。还修复了同步启动时错过 session started 的竞态。现有初始化失败保护保留；其他环境若仍报错需单独记录，不能伪造帧。

## 6. 回到真实眼镜

选择“真实眼镜”会停止并解除本 App 创建的模拟设备，关闭 MockDeviceKit，重新绑定真实设备注册状态。随后按原流程连接后端、注册 Meta AI、授权并开始导览。模拟设备的“已注册／权限已授予”状态不会被显示成真实 Meta 授权。

模拟设备使用 `SpecificDeviceSelector` 指定唯一模拟 ID；不会因为真实眼镜恰好也在线就选错设备。

## 7. 本版本运行验收清单

下表保留完整验收要求。最近实际结果和未到达的断言见[测试进度](10-ios-simulator-test-progress.md)，不要因某一流程前半段通过而整项打勾。

| 用例 | 操作 | 通过标准 |
|---|---|---|
| N01 | 不配对眼镜，选手机相机 | 无需 Meta 注册；系统相机授权后收到实际帧 |
| N02 | 拒绝相机权限 | 明确提示，无假帧；改用视频或恢复权限后可重试 |
| N03 | 导入 HEVC 视频 | 本地拷贝成功、帧计数增加，结束后可从头回放 |
| N04 | 导入空文件／无视频轨道／超限视频 | 有明确错误；不开始假流，不替换成样例图片 |
| N05 | 原生 Display 预览 | 看到同一原生 HUD；点预览按钮能切点、暂停或调速 |
| N06 | 不连接后端，主动载入离线样例 | 明确标记 demo；四点分页与总览顺序可测；不调用 Gemini |
| N07 | 连接后端，识别真实手机／视频帧 | 返回与当前输入相关的分析；不得把 demo 作为在线识别结果 |
| N08 | 识别未返回时停止／切源 | 迟到识别、旧帧、旧字幕及语音不污染新会话 |
| N09 | 前后台与重复启动 | 后台停止；返回后可再启动；无残留相机占用或叠加语音 |
| N10 | 切回真实眼镜 | MockDeviceKit 已关闭，要求真实注册，来源与帧计数标记正确 |

## 8. 保留的产品缺口

此模式不修复 Gemini Live 原生语音、细节跟随框、艺术品优先／小目标检测、局部放大、来源检索或双向追问。详见[已知问题与剩余功能](08-bugs-and-roadmap.md)。当前音频依旧是明确标记的 iOS 系统语音。

光学可读性、现实空间对齐、实际眼镜音频／麦克风和端到端延迟仍需实体设备。还眼镜前建议保存同一作品的正面、移动、远近变化视频，以及眼镜实际显示录像与设备版本记录。

参考：[Meta DisplayAccess 官方预览说明](https://github.com/meta/meta-wearables-dat-ios/tree/main/samples/DisplayAccess#readme)、[DAT 1.0.1 MockDevice 公共接口](https://github.com/meta/meta-wearables-dat-ios/blob/1.0.1/MWDATMockDevice.xcframework/ios-arm64/MWDATMockDevice.framework/Modules/MWDATMockDevice.swiftmodule/arm64-apple-ios.swiftinterface)。

## 9. 可重复的 UI 自动测试

在有完整 Xcode 的 Mac mini 执行 `bash scripts/test-ios-ui.sh`。脚本创建自己的 iPhone 15 Pro 模拟器，导入生成的 HEVC 移动图案，经真实 DAT Mock 相机／Display 运行，并保存 xcresult、截图和操作树。结束时清理自己的模拟器。它不调用 Gemini，也不验证现实对齐。当前 suite 保留三个失败供继续定位，不能宣称全绿。
