# Bridge 1.69.4-compat.7 与 Mobile build 207 交付

Status: active.

## 目的

修复 durable 会话内部永久显示“正在载入会话运行状态”、Mobile v2 commit
失败形成固定两秒重订阅循环，以及 Bridge global state reset 后旧 thread
revision 阻止热窗口重建的问题。

## 全局修改

- 新增并启用：
  `/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.4-compat.7-4c5f875e`
- 更新：
  `/Users/huyiyang/Library/LaunchAgents/com.ccpocket.bridge.plist`
- 唯一配置变化是 `BRIDGE_CLI_ENTRY`。
- 当前 Bridge 为 compat.7、部署 PID `56059`、唯一
  `127.0.0.1:8765` listener。
- compat.6 保留为直接回滚；compat.5 已删除。
- 没有修改 Mullvad、Tailscale、Cloud、会话权威历史、手机数据库或 OTA
  channel。

## 证据与回滚

- 修复、测试、候选/正式 smoke、哈希和切换记录：
  `../runs/20260730-101950_bridge-1.69.4-compat.7-4c5f875e-deploy/DEPLOYMENT.md`
- 回滚：
  `../backups/20260730-101950_bridge-1.69.4-compat.7-4c5f875e-deploy/README.md`
- build 207 IPA：
  `../runs/20260730-104039_ccpocket-build207-ipa/README.md`

## 尚待用户确认

- 物理 iPhone 重新连接 compat.7；
- build 206 能否通过 Bridge reset 恢复目录/热窗口；
- build 207 会话打开不再显示永久运行状态假加载；
- 手机日志能否给出任何剩余 SQLite/runtime error 的隐私安全错误类型。
