# Bridge 1.69.4-compat.6 状态语义修复与部署记录

Status: deployed; physical-iPhone visual confirmation pending.

## 现象与根因

手机已经能进入会话目录，但所有会话卡片都显示“状态暂不可用”。真实线上
`conversation_sync_v2` 只读探针返回 320 个目录项和 320 个状态：

- 302 个状态为 `unknown / notLoaded / unknown / appServer`；
- 18 个状态为 `unknown / notLoaded / unknown / legacyRollout`。

这不是 app-server 故障，也不是目录或 WebSocket 失败。官方 `notLoaded` 只表示
该线程当前没有驻留在这一 app-server 进程中，不代表持久会话不可读。build 206
旧 UI 将所有 `activity=unknown` 都渲染成“状态暂不可用”，因此把正常未驻留会话
误报成错误。

## 修复

提交 `3d43d68f` 同时修复新旧客户端：

- 新 Mobile 宣告 `app_server_status_v1`，对
  `unknown + notLoaded + confidence=unknown` 不显示错误；
- `systemError`、`ownedElsewhere` 和已加载但真实未知的状态仍显示不可用；
- 新 Bridge 对支持该能力的客户端发送真实
  `unknown / notLoaded / unknown`；
- 对 build 206 等旧客户端，仅把普通未驻留状态兼容投影成
  `idle / notLoaded / unknown`。这不会产生 `Ready` 标签，attachment 与
  confidence 仍然诚实；
- 状态 token schema 升到 v2，旧手机保存的错误状态快照会收到 scoped reset，
  不会继续复用旧缓存；
- app-server 返回真实未知状态时标记 `runtimeAttachment=loaded`，避免与
  “尚未加载、尚未观察”混为一谈。

提交 `19ee1609` 将 Bridge 版本提升为 `1.69.4-compat.6`。

## 自动验证

- Bridge 定向测试：13/13 通过；
- Bridge 全量测试：96 files、1,859 tests 通过；
- Mobile 协议、卡片、消息、内容同步、SQLite 目录、Session cubit 与投影相关
  测试：292 项通过；
- Mobile targeted analyze：`No issues found`；
- Bridge TypeScript build、native helper build、生产依赖安装和
  `npm ls --omit=dev --all` 通过；
- `git diff --check` 通过。

隔离端口 `127.0.0.1:18765` smoke：

- legacy 客户端：320 个
  `idle / notLoaded / unknown`，status scoped reset 和 sync complete 成功；
- capable 客户端：320 个
  `unknown / notLoaded / unknown`，status scoped reset 和 sync complete 成功；
- 目录和状态均为 320 项；最大物理帧分别为 65,244 和 65,246 bytes，低于
  65,536 bytes 上限。

正式端口 `127.0.0.1:8765` legacy smoke：

- 320 个 `idle / notLoaded / unknown`；
- status scoped reset 和 sync complete 成功；
- 最大物理帧 65,260 bytes。

## Runtime 与正式切换

- 当前 runtime：
  `/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.4-compat.6-19ee1609`
- 回滚 runtime：
  `/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.4-compat.5-00ee7c18`
- LaunchAgent：
  `/Users/huyiyang/Library/LaunchAgents/com.ccpocket.bridge.plist`
- 当前 PID：`99053`
- 当前 listener：唯一 `127.0.0.1:8765`
- `/health`：`ok`
- `/version`：`1.69.4-compat.6`

第一次 `launchctl bootout` 后立即 bootstrap 遇到 macOS launchd
`Input/output error`。配置自动恢复为 compat.5，等待两秒后旧服务恢复成功；
随后重新卸载、确认 job/listener 消失、等待两秒，再 bootstrap compat.6 成功。
期间没有修改会话数据、手机数据库、Mullvad、Tailscale 或 OTA channel。

Runtime 哈希：

- `dist/cli.js`：
  `e12c180058a8a6979df899daa8c09cd70c24046bd03d61509991d35893c07a17`
- `dist/websocket.js`：
  `b42f465f95afb5370b85e6afc52959f36de1d23fc2de4d08126fad48207cd80c`
- `dist/local-features/conversation-sync-v2.js`：
  `2df519b20417201b8ba0bcdc39efbfc48c0a42f7724cb17368ce28d5f17dd418`

## 交付边界

兼容投影在 Bridge 完成，因此用户当前安装的 build 206 不需要重装 IPA，也不
需要新的 Shorebird OTA；重新连接 compat.6 后即可收到修正后的状态快照。
Mobile 源码修复会进入未来基线，使新版客户端直接理解 canonical 状态。

自动验证不能替代物理 iPhone 视觉确认。部署检查时手机尚未自动重连
（`clients=0`）；用户需要打开 App 或重新进入连接页，确认：

1. 会话目录不再整页显示“状态暂不可用”；
2. 普通 idle/notLoaded 会话不显示 `Ready`；
3. 真正的系统错误或占用状态仍有明确提示。
