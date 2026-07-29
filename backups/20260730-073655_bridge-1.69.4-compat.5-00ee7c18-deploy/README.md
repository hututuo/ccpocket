# Bridge compat.5 部署回滚

本目录保存 2026-07-30 将运行中 Bridge 从
`1.69.4-compat.4-065cddc0` 切换到
`1.69.4-compat.5-00ee7c18` 前后的 LaunchAgent 配置。

## 文件

- `com.ccpocket.bridge.plist.before`：部署前、指向 compat.4 的配置。
- `com.ccpocket.bridge.deployed.plist`：部署后、指向 compat.5 的配置。

两份文件都不包含 API key。源码、会话历史、手机缓存、Mullvad、Tailscale
和 OTA channel 均未由本次部署修改。

## 回滚

回滚目标：

`/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.4-compat.4-065cddc0/packages/bridge/dist/cli.js`

1. 将 `com.ccpocket.bridge.plist.before` 恢复到
   `/Users/huyiyang/Library/LaunchAgents/com.ccpocket.bridge.plist`。
2. 对 `gui/$(id -u)/com.ccpocket.bridge` 执行 `bootout`。
3. 确认卸载后重新 `bootstrap` 该 plist。
4. 验证 `/health`、`/version`、唯一 `127.0.0.1:8765` listener 和实际进程路径。

launchd 在同一瞬间连续 `bootout → bootstrap` 可能短暂返回 I/O error。本次首次
切换即遇到该竞态，并已成功恢复 compat.4；最终切换使用一秒卸载确认后完成。

