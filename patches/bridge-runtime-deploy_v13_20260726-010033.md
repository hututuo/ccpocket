# Bridge 1.69.4-compat.1 全面集成候选部署

Status: active.

## 目的

把 Mac 后台 Bridge 从 `1.69.0-compat.6-4e611c6b` 更新到已经完成统一集成和
全量 Bridge 验证的 `1.69.4-compat.1-ae17d712`，使 build 202 Mobile 可以看到
新会话目录、临时侧聊、通知、文件预览与安全能力协商。

## 全局修改

- 新增版本化 runtime：
  `/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.4-compat.1-ae17d712`
- 只修改现有
  `/Users/huyiyang/Library/LaunchAgents/com.ccpocket.bridge.plist`
  的 `EnvironmentVariables.BRIDGE_CLI_ENTRY`。
- 保留旧 runtime 作为直接回滚点。
- 不修改 API key、监听地址、端口、公开 URL、允许目录、文件传输目录、会话数据、
  手机数据、Cloud Function 或 Shorebird。

## 验证与回滚

详细验证见
`../runs/20260726-010033_bridge-1.69.4-compat.1-ae17d712-deploy/DEPLOYMENT.md`。
回滚见
`../backups/20260726-010033_bridge-1.69.4-compat.1-ae17d712-deploy/README.md`。

Live 激活后为 PID `88496`、单一 TCP 8765 监听，本机和 Tailscale 版本探针均为
`1.69.4-compat.1`。检查时没有手机客户端在线，因此手机重连留给用户打开 App
后确认。
