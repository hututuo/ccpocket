# Bridge 1.69.4-compat.6 未驻留状态语义修复

Status: active. Supersedes v17 for the live Bridge runtime; the build 206 IPA
record in v16 remains valid.

## 目的

修复 build 206 进入目录后把全部普通未驻留会话显示为“状态暂不可用”的兼容性
问题，同时保证新 Mobile 能看到 canonical app-server 状态，真正错误不被隐藏。

## 全局修改

- 新增并启用：
  `/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.4-compat.6-19ee1609`
- 更新：
  `/Users/huyiyang/Library/LaunchAgents/com.ccpocket.bridge.plist`
- 唯一配置变化是 `BRIDGE_CLI_ENTRY`。
- Bridge 当前为唯一 PID `99053`、唯一 `127.0.0.1:8765` listener、版本
  `1.69.4-compat.6`。
- compat.5 保留为直接回滚；compat.4 在 compat.6 验证后删除。
- 没有修改 Mullvad、Tailscale、会话权威历史、手机数据库、IPA 或 OTA channel。

## 证据与回滚

- 根因、测试、隔离/正式 smoke、哈希和设备门禁：
  `../runs/20260730-084109_bridge-1.69.4-compat.6-19ee1609-deploy/DEPLOYMENT.md`
- 回滚：
  `../backups/20260730-084109_bridge-1.69.4-compat.6-19ee1609-deploy/README.md`

## 尚待用户确认

- 物理 iPhone 重新连接后，会话卡片不再整页显示“状态暂不可用”；
- 普通 idle/notLoaded 没有 `Ready`，真实错误仍可见。
