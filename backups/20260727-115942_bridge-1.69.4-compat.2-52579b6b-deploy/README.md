# Bridge 1.69.4-compat.2 回滚说明

本目录保存将后台 Bridge 从
`1.69.4-compat.1-ae17d712` 更新到
`1.69.4-compat.2-52579b6b` 前后的 LaunchAgent 配置。

- `com.ccpocket.bridge.plist`：更新前的完整配置。
- `com.ccpocket.bridge.after.plist`：候选配置；只把
  `EnvironmentVariables.BRIDGE_CLI_ENTRY` 指向新版本目录。
- 除运行入口外的配置已经通过规范化哈希比较，保持逐字段一致。
- 本次不修改监听地址、端口、公开 URL、允许目录、文件传输目录、会话数据、
  手机数据或任何凭据。

回滚：

```zsh
plist="/Users/huyiyang/Library/LaunchAgents/com.ccpocket.bridge.plist"
launchctl unload "$plist"
ditto "/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/backups/20260727-115942_bridge-1.69.4-compat.2-52579b6b-deploy/com.ccpocket.bridge.plist" "$plist"
plutil -lint "$plist"
launchctl load "$plist"
curl -fsS http://127.0.0.1:8765/version
```

回滚后应看到 `1.69.4-compat.1`，且 TCP 8765 只有一个监听进程。
