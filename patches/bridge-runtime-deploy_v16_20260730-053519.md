# Bridge 1.69.4-compat.4 与 Mobile build 206 交付

Status: active.

## 目的

部署经过全量测试、性能扫描和安全审计的分层会话同步 Bridge，并交付
`1.110.1+206` AltStore 无签名输入 IPA。

## 全局修改

- 新增版本化 runtime：
  `/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.4-compat.4-065cddc0`
- 更新：
  `/Users/huyiyang/Library/LaunchAgents/com.ccpocket.bridge.plist`
- 唯一配置变化是 `BRIDGE_CLI_ENTRY`。
- 重新加载后 Bridge 为唯一 PID `58249`、唯一
  `127.0.0.1:8765` 监听者、版本 `1.69.4-compat.4`。
- 保留 compat.3 runtime 作为直接回滚。
- 没有修改 Mullvad、Tailscale、会话权威历史、手机数据库或 OTA channel。

## 交付物

- IPA：
  `/Users/huyiyang/Documents/Downloads/CC-Pocket-1.110.1-build206-session-sync-v2-065cddc0-AltStore.ipa`
- SHA-256：
  `87f1c73e87cadca50b3fb8a6f3d0c0e5270e73f76be7e0434ba70dc9217c5e03`
- 完整验证、Cloud 边界和清理：
  `../runs/20260730-053519_bridge-1.69.4-compat.4-065cddc0-deploy/DEPLOYMENT.md`
- 回滚：
  `../backups/20260730-053519_bridge-1.69.4-compat.4-065cddc0-deploy/README.md`

## 未完成的外部门禁

- IPA 尚未由 AltStore 重签或安装到物理 iPhone。
- 物理设备通知、后台、Face ID、路线切换和视觉验收仍待用户执行。
- Firebase CLI 未登录，Cloud Functions 未部署。
- IPA 使用 dummy Firebase 配置，不能据此宣称 APNs/FCM 可用。
- 未发布 Shorebird release/patch，未改变 owner/stable，未 push 远端。
