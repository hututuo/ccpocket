# Bridge compat.6 LaunchAgent 回滚

本目录保存正式切换前后的 LaunchAgent：

- `com.ccpocket.bridge.plist.before`：compat.5；
- `com.ccpocket.bridge.plist.deployed`：compat.6。

仅有 `EnvironmentVariables.BRIDGE_CLI_ENTRY` 不同。回滚 runtime 为：

`/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.4-compat.5-00ee7c18/packages/bridge/dist/cli.js`

回滚步骤：

1. 将 LaunchAgent 的 `BRIDGE_CLI_ENTRY` 精确改回上述路径；
2. `launchctl bootout gui/501/com.ccpocket.bridge`；
3. 确认 8765 listener 和 job 均已退出；
4. 等待至少两秒，再 bootstrap
   `/Users/huyiyang/Library/LaunchAgents/com.ccpocket.bridge.plist`；
5. 验证 `/version` 为 `1.69.4-compat.5`、`/health` 为 `ok`，并且只有一个
   `127.0.0.1:8765` listener。

不要用旧 plist 覆盖其他环境变量，也不要修改 Mullvad、Tailscale、会话数据、
手机缓存或 OTA channel。

SHA-256：

- before：
  `445eeab8b1b79a898a668facd3b53010d3cd61087d9fc5fb4ecebfca6f448957`
- deployed：
  `e2cbaa3913f6b3f0da54c4de02c738adb6951776021d1a771c1c11137f5c5996`
