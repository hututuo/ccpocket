# Bridge 1.69.4-compat.2 综合修复候选部署

Status: active.

## 目的

把 Mac 后台 Bridge 从 `1.69.4-compat.1-ae17d712` 更新到已完成独立复审、
七项审查问题修复和全量分层验证的
`1.69.4-compat.2-52579b6b`。

## 全局修改

- 新增版本化 runtime：
  `/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.4-compat.2-52579b6b`
- 只修改现有
  `/Users/huyiyang/Library/LaunchAgents/com.ccpocket.bridge.plist`
  的 `EnvironmentVariables.BRIDGE_CLI_ENTRY`。
- 保留更新前 runtime 作为直接回滚点。
- 不修改凭据、监听地址、端口、公开 URL、允许目录、文件传输目录、会话数据、
  手机数据、Cloud Function 或 Shorebird。

## 验证与回滚

详细验证见
`../runs/20260727-115942_bridge-1.69.4-compat.2-52579b6b-deploy/DEPLOYMENT.md`。
回滚见
`../backups/20260727-115942_bridge-1.69.4-compat.2-52579b6b-deploy/README.md`。

## Live 结果

- PID `88496` 切换为 `95873`。
- 当前只有一个 TCP 8765 监听者。
- 本机 health 正常，版本为 `1.69.4-compat.2`。
- 进程命令、LaunchAgent 入口和新 runtime 路径一致。
- 验证时没有手机客户端在线；Mac 自身 Tailscale IPv4 探针超时，所以手机
  重连和 Tailnet 可达性仍是独立验收项。
