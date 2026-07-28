# Bridge 1.69.4-compat.3 回滚说明

本目录保存本次全局 Bridge 更新前后的两份 LaunchAgent 配置：

- `com.ccpocket.bridge.plist`：更新前原件，指向
  `1.69.4-compat.2-52579b6b`，并保留当时的 `0.0.0.0` 监听地址。
- `com.ccpocket.bridge.deployed.plist`：当前部署配置，指向
  `1.69.4-compat.3-8c1d9907`，并把监听地址收窄为 `127.0.0.1`。

两份文件权限均为 `0600`。本次没有修改公开 URL、端口、允许目录、文件传输目录
或会话数据。

## 为什么不能原样恢复旧 plist

Tailscale TCP Serve 当前占用 Tailnet 地址的 8765，并转发到
`127.0.0.1:8765`。原样恢复旧配置的 `0.0.0.0:8765` 会再次与 Tailscale
冲突。回滚 Bridge 版本时，应保留当前 loopback 监听，只把 runtime 入口改回
compat.2。

## 回滚步骤

```zsh
plist="/Users/huyiyang/Library/LaunchAgents/com.ccpocket.bridge.plist"
current="/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-v03-20260728/backups/20260728-232718_bridge-1.69.4-compat.3-8c1d9907-deploy/com.ccpocket.bridge.deployed.plist"
old_entry="/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.4-compat.2-52579b6b/packages/bridge/dist/cli.js"

launchctl unload "$plist"
ditto "$current" "$plist"
/usr/libexec/PlistBuddy \
  -c "Set :EnvironmentVariables:BRIDGE_CLI_ENTRY $old_entry" \
  "$plist"
plutil -lint "$plist"
launchctl load "$plist"
curl -fsS http://127.0.0.1:8765/version
```

回滚后应看到 `1.69.4-compat.2`，且本机 loopback 8765 只有一个 Bridge
监听进程。原始更新前 plist 仅用于审计；除非先改变 Tailscale Serve 配置，否则
不要直接加载它。
