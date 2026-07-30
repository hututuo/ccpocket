# Bridge compat.9 LaunchAgent 备份

用途：记录从 `1.69.5-compat.8-4f24fbe2` 切换到
`1.69.5-compat.9-146c6f73` 前后的唯一全局配置变化。

完整原始备份保存在用户级应用支持目录，不进入 Git：

`/Users/huyiyang/Library/Application Support/ccPocket Bridge/backups/20260730-185349_bridge-1.69.5-compat.9-146c6f73-deploy`

文件：

- `com.ccpocket.bridge.plist.before`：切换前、指向 compat.8 的完整 plist；
- `com.ccpocket.bridge.plist.candidate`：只替换 `BRIDGE_CLI_ENTRY` 的候选；
- `com.ccpocket.bridge.plist.deployed`：成功部署后实际使用的 plist；
- `version.json`、`health.json`：正式服务的本机探针；
- `launchctl.txt`：成功切换后的 launchd 状态快照。

候选和正式 smoke 的原始脱敏证据保存在：

`/Users/huyiyang/Library/Application Support/ccPocket Bridge/deployment-evidence/20260730-185349_bridge-1.69.5-compat.9-146c6f73-deploy`

回滚时：

1. 对当前 `/Users/huyiyang/Library/LaunchAgents/com.ccpocket.bridge.plist`
   执行 `launchctl unload`；
2. 用 `com.ccpocket.bridge.plist.before` 恢复原文件；
3. 执行 `launchctl load -w`；
4. 确认 `/version` 为 `1.69.5-compat.8`、`/health` 为 `ok`，且只有一个
   `127.0.0.1:8765` listener。

回滚 runtime 保留在：

`/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.5-compat.8-4f24fbe2`

备份不包含会话数据，也不授权修改 VPN、网络转发、凭据或手机缓存。
