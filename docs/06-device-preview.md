# 真机网页接入：临时 HTTPS 测试

日期：2026-11-14（Europe/Helsinki）。这是设备联调入口，不是 iOS App 发布或现实对齐验收。

## 当前设备状态

用户已通过 iPhone 完成 Meta Ray-Ban Display 配对，开启 Meta AI App 内的 Developer Mode，并确认 Web apps 添加入口可见。截图显示设备在线、Meta AI App 299.0.0.26.159、DAT SDK 1.0.0.0。手机型号、iOS 版本与眼镜固件版本尚未记录。

## 手机上添加

1. 打开 Meta AI App，选择已配对的 Display 眼镜。
2. 进入眼镜设置 → App connections → Web apps → Add a web app。
3. 名称填写 `Museum Companion`；URL 填当次测试提供的完整 HTTPS 链接，保留 `?access=…` 参数。
4. 保存后在眼镜应用列表中打开，观察文字、方向导航、选择操作、画作与编号列表；随后测试音频和倍速。

Meta 官方要求网页可通过 HTTPS 访问，并通过上述入口或二维码添加。[官方 Web 部署步骤](https://github.com/meta/meta-wearables-webapp#4-deploy-to-glasses)

## Mac 上运行

先构建并运行现有服务：

```bash
npm run build
npm start
```

在另一终端启动访问入口：

```bash
DEVICE_PREVIEW_STATE=/private/tmp/museum-device-preview/state.json npm run device:preview
```

入口仅监听 `127.0.0.1:4174`，固定代理到 `127.0.0.1:4173`；现有主服务仍限制为 loopback。启动时生成随机访问码，临时状态文件权限为 `0600`，默认 8 小时后失效。

使用官方 `cloudflared` 可执行文件启动测试通道：

```bash
cloudflared tunnel --url http://127.0.0.1:4174 --no-autoupdate --protocol http2 --metrics 127.0.0.1:49312
```

本机 `localhost` 名称解析不可用，因此监听与目标地址均显式使用 `127.0.0.1`。此任务下载的官方二进制位于 `/private/tmp/museum-device-preview/cloudflared`，没有修改系统级安装。

将通道生成的 HTTPS 主机与当次状态文件中的访问码组合成 `https://<临时主机>/?access=<访问码>`，仅交给参与本次测试的人。不要把实际链接、访问码、会话状态或 `.env.local` 提交到 Git。访问入口验证凭据后设置 HttpOnly、Secure、SameSite=Strict cookie；后续页面资源、API 与实时语音 WebSocket 都需已授权会话。访问码不会转发给 Gemini 后端。

## 验证边界与关闭

新增 8 项自动用例已验证 HTTP 访问控制、入口凭据换取 cookie、Origin 检查、固定本机上游、双向 WebSocket 转发、未授权 WebSocket 拒绝与会话过期。连同原有用例共 64 项通过，生产构建通过。公开 HTTPS 连通性与真实眼镜效果分别记录，尚未通过的部分不能从本地测试推断。

经用户明确授权，公开 HTTPS 最小联调已通过：未授权 API 返回 401；完整入口、已授权配置请求和前端 JS 均返回 200；配置确认 Gemini 已就绪。真实 Live 请求通过该 HTTPS 通道握手并返回 14 个音频块，一次请求约 7.5 秒完成。此检查不等于眼镜实际启动、扬声器播放或麦克风权限已验证；真实佩戴结果待用户反馈。当前临时访问码与完整链接只保留在本机临时会话和交付对话中。

最新 Web 默认流程为实时相机优先，参考图片保留为手动演示入口。眼镜上的网页能显示界面，不表示已获得眼镜实时相机或麦克风权限；遇到不支持的采集 API 时会提示配对手机 DAT 接入。后续仍需通过 iOS DAT 完成真实输入与相机到佩戴视野的校准，当前接入进度见[项目进度](07-project-progress.md)。

Mac、应用服务、访问入口和通道都须保持运行。停止通道进程会立即使该地址失效，重开通道通常会产生新地址；访问码最长 8 小时有效。需要结束测试时，关闭 `cloudflared` 和 `device:preview` 进程即可，本地 Simulator 服务可以保留。[Cloudflare Quick Tunnels 说明](https://developers.cloudflare.com/tunnel/get-started/quick-tunnels/)
