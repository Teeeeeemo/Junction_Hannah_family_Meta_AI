# iOS 模拟器测试进度与交接

**2026-11-15 最新用户实测：在已安装的 iOS 0.2.3 / build 7 中，用户再次反馈“从头到尾都没看到二维跟踪框”。BUG-02 仍为 P0 未解决，不能把 0.2.3 的追踪加固记为修复通过。手机预览有条件绘框代码，但实际未见框；眼镜 Display 的现实跟随框及光学标定尚未实现。用户这次反馈未进一步区分观察位置与输入来源，需分别复现；不能把整个问题归因于短暂失跟或阈值。**

**当前产品规则（2026-11-15 最新确认，PRD v0.4）：** 细节列表加载并校验完成即在眼镜 Display 右侧显示，概览朗读期间也可展示和选点，不再等待概览结束。没有用户改选时，仍在概览结束／跳过且列表就绪后自动讲 1 号。概览及每个细节分别使用独立的环形朗读倒计时，切段重置；细节列表标题最多三个单词。失跟只隐藏无效框和局部窗，正在进行的讲解继续；新点最多等待约 2.5 秒定位，超时仍讲解，可靠定位恢复后再显示框和局部窗。用户暂停、打断、结束仍须生效；无可靠作品／细节点时不得凭空讲解。列表时序、倒计时和标题限制是待实现的新要求，不代表已安装的 0.2.3 已支持。

本次仅同步用户反馈与需求，不重跑测试、不声称已修复或生成新 IPA。以下保留按时间记录的历史测试证据。

## 2026-11-15 07:50：0.2.5 / build 9（No.1／BUG-02 跟随检测框：阶段 1 手机框、阶段 2 眼镜显示通路）

基于 `bc040ed`（0.2.4 + 最新文档）。**未在真机复现，手机与镜片结果仍待用户上机确认。**

**本轮定位到的无框原因（代码与模拟器证据）：**

1. **等比显示留白（0.2.4 回归）：** 0.2.4 把预览改为全宽后，框按整个容器尺寸定位；竖向眼镜画面在宽容器中左右留白，框会横向偏移、拉伸。已改为先计算等比显示后的图像区域（`PreviewGeometry.fittedRect/place`），再放置框。
2. **画作超出画面边缘即判失跟：** 追踪结果只要越过画面边界（近距离观看时常见）就整帧判 `lost`。现在只要作品可见面积 ≥25% 就继续追踪，输出裁剪到可见部分。
3. **细节框贴边被丢弃：** 模型坐标的微小越界导致细节不在参考区域内而无框；现裁剪到作品区域，不再丢弃。
4. **图像方向：** DAT 帧若带非 `.up` 方向，Vision／裁剪使用原始像素而 SwiftUI 按方向显示，坐标会错位；现在收帧时统一转正。
5. **无框原因不可区分：** `TrackingSnapshot.reason` 区分 Vision 错误、低置信（含数值）、作品出画、跳变、尺度突变、细节不在作品内／出画、追踪器释放、结果过期；手机显示“细节框：…”诊断（0.2.6 起在开发者设置中）。

**阶段 2（显示通路，非现实对齐）：** 同一有效追踪几何在 1× 时以带标注 “CAMERA VIEW” 的相机小图发送到眼镜 Display（金色细节框 + 编号 + 作品虚线框，限速 2 fps），2×／4× 时仍为细节局部图。这证明几何 → Display 渲染链路，**不是**与真实作品对齐的镜片框；光学映射仍未实现。

| 检查 | 结果（Mac mini，Xcode 26.6，iOS Simulator 26.5） |
|---|---|
| Web / 后端 | 90/90 |
| 原生纯逻辑 | 50 项导览检查（新增 3 项等比留白映射），会话／恢复／点位注册通过 |
| Vision 追踪 | 7 项时效 + 14 项实际 Vision 检查（新增：无框必带原因、贴边细节裁剪保留） |
| Release 归档 | 通过 |
| 离线 UI | 10/11，失败仍为模拟预览恢复（与 0.2.4 相同） |
| 原生云端（真实 Gemini）+ 框验收 | 视频→锁定→分析→实际 PCM→自动 1 号→**T01 手机预览出现细节框**→4.4 秒断流后重识别→手选 2 号实际出声→**T02 框切换为 2 号（`point=2`）**→暂停后提问并播出回答，均通过；最后一步与历来相同的模拟预览恢复检查失败 |

**BUG-02 专项（模拟器，可重放二维画作视频）：** T01 自动讲解期间手机预览出现细节框（XCUITest 断言 `tracked-detail-box` 存在并截图）；录屏帧确认讲到 2 号时金色框带“2”编号框住天空区域、白色虚线框住整幅画，位置与画面一致。模拟器 Vision 在 CPU 上较慢，结果超过 0.3 秒时框会按时效门暂隐，因此框在模拟器中会闪烁；真机 ANE 速度待实测。

本轮还修复两个由新增界面引起、会让真机按钮错位的问题：诊断文字固定占两行、追踪状态固定一行，避免文本长度变化推动下方讲解卡片和输入框；眼镜相机小图降为 1 fps、240 px，减轻与相机流共享无线链路的负担。模拟器 Mac mini 在高负载（load ≈ 20+）时 Vision 结果常超过 0.3 秒而被时效门丢弃，导致框缺失；低负载重跑通过。证据：Mac mini `~/Developer/Junction/takeover-logs/ui-n1/`、`cloud-n1d/`（T01／T02 截图与录屏）。

**仍未验证／未完成：** 真机手机相机上的框（请看手机相机画面，开发者诊断行会给出无框原因）；真实眼镜上的相机小图显示与带宽影响；镜片与现实作品的光学对齐（未实现，P02 不关闭）。

## 2026-11-15 06:40：0.2.4 / build 8（手机框可见性、列表即显、三词标题）

**“真的有框吗”的排查结论（模拟器证据，未在真机复现）：** `cloud-023` 录屏中手机预览确有金色细节框，但预览仅缩略图大小、框线 2 pt，且“画面追踪”大部分时间显示 `lost — waiting to verify the artwork again`：每次输入断帧超过 1 秒即丢弃追踪并走云端两次搜索重识别（5–10 秒无框）。概览阶段没有选中细节，本来就不画框。眼镜 Display 从未实现框。

本版修改：

- `TrackingFreshnessPolicy.rescanAfter` 1 → 4 秒：1–4 秒断帧只隐藏框，本地 Vision 续跟；超过 4 秒才云端重识别。云端回归的受控断流相应改为 4.4 秒，仍覆盖重识别路径。
- 手机预览放大（最大高 440 pt、全宽）；细节框 4 pt 并带点位编号；只要 Vision 追踪成功就用白色虚线画出整幅作品轮廓（概览期间也可见）。新增 `trackedArtworkBox`。
- PRD v0.4 REQ-01：撤销 0.2.3 的概览期间隐藏列表，列表加载即显示。
- PRD v0.4 REQ-03：分析新增 `shortTitle`（≤3 词）；后端 `shortenDetailTitles` 用 `Intl.Segmenter` 校验（中文分词），超限时去虚词保留三词兜底，且不制造重复标题；翻译结果同样校验。后端已在 Mac mini 重启生效。
- REQ-02 环形倒计时：未包含，单独开发。

| 检查 | 结果（Mac mini，Xcode 26.6，iOS Simulator 26.5） |
|---|---|
| Web / 后端 | 90/90（新增 3 项三词标题测试），`tsc --noEmit` 通过 |
| Vision 追踪 | 7 项时效 + 12 项实际 Vision 检查通过（新增“2 秒断帧本地续跟”） |
| 其他原生纯逻辑、Live 协议、Release 归档 | 通过 |
| 离线 UI | 10/11（失败仍为模拟预览恢复） |
| 原生云端（真实 Gemini） | 主流程至暂停后提问通过（含 4.4 秒断流后重识别恢复），最后一步同一模拟预览检查失败 |

**未验证：** 真机手机预览上框是否可见。请在“画面追踪”显示 `tracking` 时看手机预览（不是眼镜）。证据：Mac mini `~/Developer/Junction/takeover-logs/ui-024/`、`cloud-024/`。

## 2026-11-15：0.2.3 用户复测与 PRD v0.4（晚于下列发布记录）

- 用户报告：“从头到尾都没看到二维跟踪框”。BUG-02 仍为 P0 未解决；0.2.3 只有追踪加固代码和模拟器证据，没有手机修复通过结论。输入来源与观察位置待复现区分。
- 本次只读核对：手机 `MuseumPhoneView` 存在条件矩形叠层，`GlassCameraModel` 需当前点及可用追踪区域；`GlassesDisplay` 不具备现实跟随框渲染和光学映射。不能据此宣称用户已能看到框。
- 新需求：列表就绪立即展示；每段独立环形朗读倒计时；细节列表标题最多三词。均待实现和验收，PRD v0.4 取代 v0.3 的概览隐藏列表规则。
- 下列 0.2.3 “概览期间隐藏列表”是旧版本实际行为及其历史测试，不再是后续产品目标；保留历史通过／失败记录，不改写为新规则已通过。

## 2026-11-15 05:10：0.2.3 / build 7（手机追踪框加固 + 概览期间隐藏列表）

基于 `4abe843`。针对用户实测“手机没有二维追踪框”，根因未在真机复现；按代码审查定位的最可能环节加固：

- `ArtworkTracker`：单帧低置信不再丢弃追踪器。返回 `reacquiring`（不带区域，框与局部窗隐藏，不触发重新确认），连续 12 帧（约 0.8 秒）失败才判 `lost` 并丢弃；目标回到视野自动接上。置信门槛 0.65→0.5（`minimumConfidence`），位移与尺度门保留。
- `GlassCameraModel`：重新确认后的首个结果若为 `reacquiring`，等待下一帧，不判恢复失败（仍受恢复任务自身期限约束）。
- `GlassesDisplay`：按 PRD v0.3，概览结束／跳过（首次选中点位）之前眼镜 Display 不展示细节列表，只保留播放／下一处（跳过概览）／倍速／总览控制。

| 检查 | 结果（Mac mini，Xcode 26.6，iOS Simulator 26.5） |
|---|---|
| Web / 后端 | 87/87 |
| Vision 追踪 | 6 项时效 + 12 项实际 Vision 检查通过，新增“短暂遮挡后无需重扫接上”“持续遮挡才判失跟并清除区域” |
| 其他原生纯逻辑、Live 协议、离线音频、Release 归档 | 通过 |
| 离线 UI | 10/11，与 0.2.2 相同；含概览隐藏列表后的 `testNativeHUDAndAutomaticTour` 通过；失败仍为 `testQuestionDoneRestoresDATPreviewAndCallbacks`（模拟预览恢复） |
| 原生云端（真实 Gemini） | 与 0.2.2 相同：主流程至暂停后提问全部通过，最后一步同一模拟预览检查失败 |

**未验证：** 真机手机预览上的追踪框是否出现，须用户上机确认；若仍无框，请记录手机上“Image tracking/画面追踪”一行的状态及画作是否贴近画面边缘。证据：Mac mini `~/Developer/Junction/takeover-logs/ui-023/`、`cloud-023/`。

## 2026-11-15 04:00：0.2.2 / build 6 演示构建

由用户接手开发；基于 `aca786a`（0.2.1 WIP）。

**行为变更（讲解连续性；现已纳入 PRD v0.3，取代旧定位成功后才开讲规则）：**

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
