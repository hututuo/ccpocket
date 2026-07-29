# Bridge 1.69.4-compat.5 会话目录摘要边界修复

Status: active. Supersedes v16 for the live Bridge runtime; the build 206 IPA
record in v16 remains valid.

## 目的

修复真实手机进入会话首页时卡在 85% 并连续报错的问题，同时保持现有 build
206、旧 Mobile、新 Mobile 和 Bridge v2 加法兼容。

## 全局修改

- 新增版本化 runtime：
  `/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.4-compat.5-00ee7c18`
- 更新：
  `/Users/huyiyang/Library/LaunchAgents/com.ccpocket.bridge.plist`
- 唯一配置变化是 `BRIDGE_CLI_ENTRY`。
- 重新加载后 Bridge 为唯一 PID `29341`、唯一
  `127.0.0.1:8765` listener、版本 `1.69.4-compat.5`。
- 保留 compat.4 runtime 作为直接回滚。
- 验证后删除已被取代的 compat.3 runtime；全局 runtime 只保留当前版和一个
  回滚版。
- 没有修改 Mullvad、Tailscale、会话权威历史、手机数据库或 OTA channel。

## 证据与回滚

- 根因、测试、真实目录 smoke 和 OTA 边界：
  `../runs/20260730-073655_bridge-1.69.4-compat.5-00ee7c18-deploy/DEPLOYMENT.md`
- 回滚：
  `../backups/20260730-073655_bridge-1.69.4-compat.5-00ee7c18-deploy/README.md`

## 尚待用户确认

- 物理 iPhone 重新进入首页是否不再停在 85%；
- 真机上的目录、状态和最近会话视觉结果。
