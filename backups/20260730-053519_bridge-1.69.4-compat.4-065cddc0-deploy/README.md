# Bridge compat.4 部署回滚点

时间：2026-07-30 05:35:19 +0800

## 备份对象

- 全局配置：
  `/Users/huyiyang/Library/LaunchAgents/com.ccpocket.bridge.plist`
- 切换前 runtime：
  `/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.4-compat.3-8c1d9907`
- 切换后 runtime：
  `/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.4-compat.4-065cddc0`

`com.ccpocket.bridge.plist.before` 是切换前原件，
`com.ccpocket.bridge.deployed.plist` 是成功切换后的原件。

切换前 plist SHA-256：

`694353239d0bad662a9451b300e6a1531da3776d8676fe8797087f4904a1ec97`

切换后 plist SHA-256：

`c7aa0653009ed20378ba3fa9ef71f0ea7f3270347f5aa1e993b2a8d7edb375b4`

除 `EnvironmentVariables.BRIDGE_CLI_ENTRY` 外的规范化 plist 内容哈希在
切换前后均为：

`e84b6cf35f56ec75e9980afbe278ebe1e0790f72fa8681b3ca81ac474a0d6ee5`

## 回滚

1. 用 `com.ccpocket.bridge.plist.before` 恢复
   `~/Library/LaunchAgents/com.ccpocket.bridge.plist`。
2. 对 `gui/<uid>/com.ccpocket.bridge` 执行完整 `bootout`。
3. 用恢复后的 plist 重新 `bootstrap`。
4. 验证实际进程命令指向 compat.3，而不只检查磁盘 plist。
5. 验证只有一个 `127.0.0.1:8765` 监听者。
6. 验证 `/health` 正常，`/version` 为 `1.69.4-compat.3`。

不能只执行 `kickstart`：launchd 会复用已经加载的旧环境，磁盘 plist
即使指向新 runtime，重启出来的进程仍可能运行旧 `BRIDGE_CLI_ENTRY`。

回滚只切换 Bridge runtime，不修改 Mullvad、Tailscale Serve、会话历史、
Mobile SQLite、文件传输、Gallery、通知数据或 Shorebird channel。
