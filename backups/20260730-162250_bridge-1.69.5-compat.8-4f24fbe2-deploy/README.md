# Bridge compat.8 LaunchAgent 备份

用途：记录从 `1.69.4-compat.7-4c5f875e` 切换到
`1.69.5-compat.8-4f24fbe2` 前后的唯一全局配置变化。

文件：

- `com.ccpocket.bridge.plist.before`：切换前、指向 compat.7 的完整 plist；
- `com.ccpocket.bridge.plist.candidate`：只替换 `BRIDGE_CLI_ENTRY` 的候选；
- `com.ccpocket.bridge.plist.deployed`：最终实际部署 plist；
- `version.json`、`health.json`：正式 compat.8 本机探针；
- `launchctl.txt`：成功切换后的 launchd 状态快照。

回滚时：

1. 对当前
   `/Users/huyiyang/Library/LaunchAgents/com.ccpocket.bridge.plist`
   执行 `launchctl unload`；
2. 用 `com.ccpocket.bridge.plist.before` 恢复原文件；
3. 执行 `launchctl load -w`；
4. 确认 `/version` 为 `1.69.4-compat.7`、`/health` 为 `ok`，且只有一个
   `127.0.0.1:8765` listener。

回滚 runtime 保留在：

`/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.4-compat.7-4c5f875e`

备份不包含会话数据，也不授权修改 VPN、网络转发或手机缓存。
