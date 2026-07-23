# CC Pocket 1.108.1 统一集成审计

- 状态：`accepted`（source-only）
- 日期：2026-07-24
- 最终分支：`integration/mobile-1.108.1-unified-20260724`
- 代码与回归 checkpoint：`6b90f9c84bef91296e7c6dca2f52629427d8fe39`
- 独立 worktree：
  `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-unified-integration-20260724`
- 起始本地基线：`169155edb1922a51e3ab54e6d68462d4dc3e20cc`
- 官方基线：`upstream/main@9ff2e76ce3e94af2b00c28b1192c6d08c5de781d`
- Mobile 版本：`1.108.1+200`

## 结果

本次把官方 1.108.1、Codex 图片引用、手机性能优化、分级通知和
iOS 有限后台同步合入同一条受保护的 source-only 分支。所有原任务分支和
worktree 保留，未 push、未发布 Shorebird、未部署 Cloud Function 或
Bridge、未安装 IPA、未晋级 owner/stable，也未改写其他分支历史。

主仓库仍停在带用户未完成改动的
`feature/mobile-session-tools@94c0fd10`，未被 reset、checkout、merge 或
清理。`feature/mobile-ota-baseline-v2@242c98d5` worktree 中原有的未提交
`decisions.md` 也保持原样；其中关于 build 199 的有效边界已在统一分支以
更准确的 build 200 决策重新记录。

## 回放顺序与提交映射

| 模块 | 原提交 | 统一分支提交 |
|---|---|---|
| 官方 1.108.1 / Flutter 3.44.7 | `upstream/main@9ff2e76c` | merge `69c4e046` |
| Codex 图片历史与实时引用 | `2108a3a9` | `ae32f8e8` |
| 图片工具结果按需显示 | `bdac4e5e` | `7571cf95` |
| 图片引用兼容文档 | `b2e6d45e` | `b7544c4d` |
| 流式增量合并 | `2a7b972b` | `f0d28c17` |
| 消息路径与预览解析优化 | `378770be` | `8bfb36fa` |
| 镜像清理与尾分页优化 | `7aa70d9e` | `567509b1` |
| 首帧与应用级重建优化 | `1527f633` | `f53f0105` |
| Prompt History single-flight | `80246f80` | `a96526e1` |
| 性能审计报告 | `e250d250` | `dad6a00b` |
| 性能官方偏移记录 | `917afcf9` | `44a8b16d` |
| 通知后端、筛选与限流 | `2bb9bc30` | `f36d6e2d` |
| Mobile 通知设置 | `ac6f499e` | `160e4815` |
| 通知兼容文档 | `3b48055f` | `b375c951` |
| iOS 后台宿主 | `35dbd225` | `658e41ac` |
| 后台增量对账 | `5dd9f5f2` | `94b4ac86` |
| 后台兼容文档 | `d5c1ee29` | `668ed6ee` |
| 统一回归收束 | 本次集成 | `6b90f9c8` |

通知与性能在 `apps/mobile/lib/main.dart` 的交错冲突采用语义合并：
保留性能分支的窄 selector 和独立 FCM listener，同时让通知服务从当前
Settings 状态初始化，并只在 FCM/通知偏好变化时重新配置。后台生命周期
coordinator 随后作为独立根监听器接入，没有恢复宽泛的全局重建。

## 历史分支处置

- 早期连续性、折叠、完整历史、文件管理、OTA host 等本地提交已是
  `169155ed` 的祖先或已由该基线中的模块化实现取代，不重复挑选。
- `feature/mobile-codex-image-references`、
  `audit/mobile-app-performance-20260724`、
  `feature/mobile-notification-settings` 和
  `feature/mobile-background-sync` 已按上表回放，原分支保留。
- `fix/remote-altserver-signing@feaef76` 属独立的远程签名/安装适配器，
  没有签名与安装验收，不进入 App/Bridge 统一源码。
- 没有删除分支、worktree 或 commit，也没有 push/rebase。

## 兼容边界

### 官方与数据

- 统一分支包含官方 1.108.1 与 Flutter 3.44.7；本地功能保持模块化触点。
- 没有数据库 schema、镜像文件名、历史 JSONL、消息存储格式或文件传输
  格式迁移。性能提交只改变等价分页、清理与缓存路径。
- 图片引用沿用既有 `ImageRef`/工具历史结构；Bridge 不把大段 base64
  直接推到 Mobile wire。

### 旧/新 Mobile 与 Bridge

- 新 Mobile + 旧 Bridge：通知字段和 capability 都是加法；旧 Bridge
  可忽略未知字段。后台只尝试 delta，不支持时等待前台补偿，绝不在后台
  降级成全量历史。
- 旧 Mobile + 新 Bridge/Cloud：legacy token 保留既有重要通知，但不会
  自动收到 `session_progress`；旧客户端不会收到未协商的镜像/后台事件。
- 新 Mobile + 新 Bridge/Cloud：按 `enabledEventTypes` 精确筛选；进度
  必须显式订阅，并有会话级 45 秒限流和工具阶段去重。

### 旧/新 IPA 与 Dart

- 旧 IPA + 新 Dart：缺少 background host capability 时 fail closed；
  前台 catch-up 仍工作。
- 新 IPA + 旧 Dart：没有 ready handshake，不会持续调度后台循环。
- Swift/Xcode/Info.plist/background capability 是 native 变化，因此
  build 200 必须作为新基础 IPA 签名、安装和真机验收，不能伪装成纯 OTA。

## 验证证据

- Bridge：Node 22.23.1，build 通过；82 files / 1540 tests 通过。
- Cloud Function：Node 22.23.1，typecheck、17 tests、build 全部通过。
- Mobile 定向组合：353 tests 通过。
- 旧的 artifact source 与 subagent summary 测试已按现行三层过程折叠
  校准；新增/修正的相关 24 tests 与 9 tests 分别通过。
- Mobile 全量：Flutter 3.44.7、`--concurrency=2`，机器可读结果
  `success=true`，0 failed、0 error。文件传输的 30 秒资源型用例曾在组合
  运行中超时，单独复跑通过。
- `flutter analyze --no-pub --no-fatal-infos`：0 error / 0 warning，
  49 个既有 info。
- iOS Simulator Debug：Flutter 3.44.7，Xcode build 35.9 秒，
  `build/ios/iphonesimulator/Runner.app` 生成成功。
- RunnerTests：iPhone 17 Pro Max / iOS 26.1，arm64 单架构；
  22/22 passed，0 failed，0 skipped。
- `git diff --check 169155ed..6b90f9c8` 通过；无冲突标记、凭据或调试输出
  混入。

## 已知非本轮回归

- 官方 npm registry 的 production audit 在起始基线和统一分支完全相同：
  root/Bridge 9 项（4 high），Cloud Functions 20 项（2 critical、
  5 high）。本轮通知提交没有改 npm manifest/lock。这不是集成回归，
  但 Cloud/Bridge 不能在依赖升级完成兼容复审前声称“安全审计通过”。
- 根 `npm ci` 的仓库 hook 假设 `.git` 是目录，在 Git worktree 中会失败；
  本次用 `npm ci --ignore-scripts` 完成依赖准备。应另做 setup hook 的
  worktree 兼容修复，不混入本次功能集成。
- 模拟器不能证明后台时间、BGAppRefresh 调度、真实 APNs/FCM、AltStore
  provisioning、真机首帧/RSS/能耗或用户视觉验收。

## 构建产物收束

磁盘不足曾使 Xcode 无法写 Flutter.framework 和 xcresult。确认目标后，
仅删除可重建的 CC Pocket DerivedData：后台同步、性能、通知和两份失败的
统一版缓存。源码、分支、worktree、Pods 和用户文件未删除。最终保留最新
Runner.app 与通过 22/22 的统一版 DerivedData；可用空间恢复后完成验证。

## 后续发布门槛

1. 单独审查并升级 Cloud/Bridge 的既有高危/严重 npm 依赖。
2. 若决定上线通知，严格按 Cloud Function → Bridge → Mobile 的顺序。
3. 从 `1.108.1+200` 构建并签名新的基础 IPA，确认 APS entitlement、
   真实 Firebase 配置和 AltStore profile。
4. 在物理 owner iPhone 验收有限后台续跑、前后台补偿、锁屏推送、
   长会话性能、文件/图片引用和现有会话数据。
5. 只有以上通过后才考虑 owner patch；stable 仍需用户明确确认。

本次不执行上述发布步骤。
