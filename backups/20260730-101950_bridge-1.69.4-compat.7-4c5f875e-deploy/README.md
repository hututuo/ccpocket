# Bridge compat.7 LaunchAgent 回滚

本目录保存正式切换前后的 LaunchAgent：

- `com.ccpocket.bridge.plist.before`：compat.6；
- `com.ccpocket.bridge.plist.deployed`：compat.7。

两份配置只有
`EnvironmentVariables.BRIDGE_CLI_ENTRY` 不同。当前回滚 runtime 为：

`/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.4-compat.6-19ee1609/packages/bridge/dist/cli.js`

回滚步骤：

1. 只把现有 LaunchAgent 的 `BRIDGE_CLI_ENTRY` 改回上述绝对路径；
2. `launchctl bootout gui/501/com.ccpocket.bridge`；
3. 确认 job 和 `127.0.0.1:8765` listener 都已退出；
4. 等待至少两秒，再 bootstrap
   `/Users/huyiyang/Library/LaunchAgents/com.ccpocket.bridge.plist`；
5. 验证 `/version` 为 `1.69.4-compat.6`、`/health` 为 `ok`，且只有一个
   8765 listener。

不要用旧 plist 覆盖其他环境变量，也不要修改 Mullvad、Tailscale、会话数据、
手机缓存或 OTA channel。

SHA-256：

- before：
  `e2cbaa3913f6b3f0da54c4de02c738adb6951776021d1a771c1c11137f5c5996`
- deployed：
  `8c2ace48da022c6fc362ec7964db6507ec729af3788b23c78230df839bdc7c3b`
