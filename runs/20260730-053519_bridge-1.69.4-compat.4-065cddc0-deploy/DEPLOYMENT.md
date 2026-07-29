# CC Pocket 会话同步 v2 最终部署记录

时间：2026-07-30

源码：`integration/mobile-session-sync-v2-20260730@065cddc01342ad1da41920553600ac48fec2a93f`

## Bridge runtime

- 新 runtime：
  `/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.4-compat.4-065cddc0`
- 回滚 runtime：
  `/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.4-compat.3-8c1d9907`
- `dist/cli.js` SHA-256：
  `e12c180058a8a6979df899daa8c09cd70c24046bd03d61509991d35893c07a17`
- `dist/websocket.js` SHA-256：
  `b42f465f95afb5370b85e6afc52959f36de1d23fc2de4d08126fad48207cd80c`
- 生产依赖树：完整。
- production npm audit：0 vulnerabilities。

18765 隔离数据 smoke：

- `/health` 和 `/version` 通过；
- v1 `list_sessions` 通过；
- v2 subscribe/ACK/sync-complete 通过；
- 两客户端并发和断线重连通过；
- Bridge/source identity 在客户端和重连之间稳定；
- 隔离目录和 listener 已删除。

实际 8765 切换：

- 只修改 LaunchAgent 的 `BRIDGE_CLI_ENTRY`；
- `BRIDGE_HOST=127.0.0.1`、端口、公开 URL、允许目录和其他设置保持；
- 通过完整 `bootout → bootstrap` 重新载入 launchd 环境；
- 实际 PID：`58249`（部署时观测值，后续需以 live 状态为准）；
- 唯一 listener：`127.0.0.1:8765`；
- `/health`：ok；
- `/version`：`1.69.4-compat.4`；
- 实际进程命令指向 compat.4；
- 真实数据源上的 v1、v2、两个本地客户端和重连只读 smoke 通过；
- smoke 后手机/本地客户端数归零。

部署时没有在线物理手机，因此没有把真实手机重连写成已验收。

## Cloud Functions

Functions 的 typecheck、24 tests 和 build 均通过，production npm audit
为 0 vulnerabilities。Firebase CLI 只读检查返回“未登录”，仓库也没有
`.firebaserc` 默认项目；因此没有足够权限证明当前账号可部署
`ccpocket-ca33b`，本轮没有执行 Cloud deploy。

Bridge 本地同步和 IPA 交付不依赖这次 Cloud deploy。APNs/FCM 远程通知仍是
独立外部门禁。

## IPA

- 文件：
  `/Users/huyiyang/Documents/Downloads/CC-Pocket-1.110.1-build206-session-sync-v2-065cddc0-AltStore.ipa`
- 大小：`26,009,487` bytes。
- SHA-256：
  `87f1c73e87cadca50b3fb8a6f3d0c0e5270e73f76be7e0434ba70dc9217c5e03`
- Bundle ID：`com.k9i.ccpocket`
- Version/build：`1.110.1 (206)`
- Minimum iOS：15.0
- Mach-O：38 个，全部 arm64，无 simulator 架构。
- 无 `embedded.mobileprovision`、无 `_CodeSignature`。
- ZIP integrity、路径安全和 fresh-extract byte comparison 通过。
- 后台模式：fetch、location、remote-notification。
- Background refresh、Always Location 和 Face ID 描述/宿主已编入。
- 使用仓库 dummy Firebase plist。

这是 AltStore/AltServer 的无签名输入包，不是已签名安装包；没有创建
Shorebird cloud release，也没有修改 `owner` 或 `stable`。

## 清理和保留

删除：

- build 204 IPA；
- compat.2 Bridge runtime；
- 上一台 XCTest clone；
- Mobile `build/`、`.dart_tool`、Pods、Flutter ephemeral；
- IPA staging/fresh extraction；
- 18765 smoke data；
- 临时 app-server schema；
- 本轮临时 Firebase CLI npx cache。

保留：

- build 206 IPA；
- build 205 Shorebird release IPA 作为回滚；
- compat.4 runtime；
- compat.3 runtime 作为回滚；
- 最新一台项目 XCTest clone；
- 当前集成 worktree 的 Node 依赖。

目录表观清理量约 9.5 GiB；APFS 实际可用空间从构建前约 45 GiB
提高到约 50 GiB。
