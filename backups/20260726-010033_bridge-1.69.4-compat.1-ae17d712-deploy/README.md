# Bridge 1.69.4-compat.1 回滚说明

本目录保存 2026-07-26 将后台 Bridge 从
`1.69.0-compat.6-4e611c6b` 更新到
`1.69.4-compat.1-ae17d712` 前后的 LaunchAgent 配置。

- `com.ccpocket.bridge.plist`：更新前配置。
- `com.ccpocket.bridge.after.plist`：只把
  `EnvironmentVariables.BRIDGE_CLI_ENTRY` 改为新版本目录；其他配置保持一致。
- 更新没有新增 API key，也没有更改监听地址、端口、允许目录、公开 URL、文件
  传输目录、会话数据或手机数据。

回滚：

```zsh
plist="$HOME/Library/LaunchAgents/com.ccpocket.bridge.plist"
launchctl unload "$plist"
ditto "/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/backups/20260726-010033_bridge-1.69.4-compat.1-ae17d712-deploy/com.ccpocket.bridge.plist" "$plist"
plutil -lint "$plist"
launchctl load "$plist"
curl -fsS http://127.0.0.1:8765/version
```

回滚后应看到 `1.69.0-compat.6`，TCP 8765 只存在一个监听进程。
