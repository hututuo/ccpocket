# Bridge 1.69.5-compat.8 实时会话同步部署记录

Status: deployed; physical-iPhone confirmation pending.

## 源码与候选

- 最终集成分支：`integration/mobile-session-sync-v2-20260730`
- runtime 源码：`4f24fbe2250fcd97ffe600534aa1db6db425f353`
- 部署记录提交：`93aade0ca4516d8e246fc64345160a2203e65a49`
- 功能提交：`33ab6f1edb7aae5f688cd5ce4f2fdbbb0403a487`
- 官方合并：`4f24fbe2250fcd97ffe600534aa1db6db425f353`
- Bridge 版本：`1.69.5-compat.8`
- runtime：
  `/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.5-compat.8-4f24fbe2`

隔离候选使用 `127.0.0.1:18766`。保留现有、属于其他诊断任务的 18765 服务，
没有停止或修改它。候选结果：

- `/health` 与 `/version` 通过；
- legacy：322 catalog、322 status、3 Working、115 timeline pages，
  8.68 s 完成；
- capable：322 catalog、322 status、3 Working、115 timeline pages，
  3.39 s 完成；
- 两种握手都完成 scoped reset、ACK、priority checkpoint 与 sync complete。

## 正式切换

- LaunchAgent：
  `/Users/huyiyang/Library/LaunchAgents/com.ccpocket.bridge.plist`
- 仅修改 `BRIDGE_CLI_ENTRY`；host、port、公开 URL、允许目录和其他配置不变。
- 当前 PID：`55743`
- 唯一 listener：`127.0.0.1:8765`
- `/health`：`status=ok`
- `/version`：`1.69.5-compat.8`

正式 8765 smoke：

- legacy：322 catalog、322 status、3 Working、114 timeline pages，
  9.75 s 完成，最大帧 65,244 bytes；
- capable：322 catalog、322 status、3 Working、114 timeline pages，
  3.42 s 完成，最大帧 65,246 bytes；
- 两种握手均完成 ACK、priority checkpoint 与 sync complete。

第一次正式切换使用 `bootout/bootstrap` 时遇到 launchd error 5，服务短暂停止；
旧 plist 已恢复，并按项目既有的 `launchctl load` 路径恢复 compat.7。后续部署
脚本中的候选版本断言、macOS `lsof` 路径和健康等待也各触发过自动回滚；每次均
恢复 compat.7 后才继续。最终以已验证的 `unload/load` 配对成功切换
compat.8。没有改写会话、SQLite、Bridge 身份或手机缓存。

## 校验与回滚

Runtime SHA-256：

- `dist/cli.js`：
  `e12c180058a8a6979df899daa8c09cd70c24046bd03d61509991d35893c07a17`
- `dist/websocket.js`：
  `b42f465f95afb5370b85e6afc52959f36de1d23fc2de4d08126fad48207cd80c`
- `dist/local-features/conversation-sync-v2.js`：
  `30d9ee661375a46eb16faa45add859a6a70161ce0a9b8440c26d53acffcd01e1`

直接回滚 runtime：

`/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.4-compat.7-4c5f875e`

LaunchAgent 备份和回滚步骤见：

`backups/20260730-162250_bridge-1.69.5-compat.8-4f24fbe2-deploy/README.md`

验证后删除 compat.6 runtime（262,756 KiB）并删除隔离候选生成的
`~/.ccpocket/prompt-history-v2-18766.json`。最终只保留 compat.8 当前版和
compat.7 回滚版。没有修改 Mullvad、Tailscale、Cloud Function、Shorebird
channel、IPA 或物理设备。

部署验证时 `/health` 为 `clients=0`。因此只确认真实 Bridge 与数据源链路，
不把手机重连、列表稳定、会话视觉状态或物理设备行为写成已验收。
