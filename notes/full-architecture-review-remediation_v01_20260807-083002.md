# CC Pocket 全架构 Review 修订与源码验收报告

- 状态：`source-verified / release-pending / device-pending`
- 外部 Review：`/Users/huyiyang/WorkBuddy/2026-08-07-00-59-16/review/CC_Pocket_Full_Architecture_Review_20260807.md`
- 权威计划：`plans/full-architecture-review-remediation_v01_20260807-071715.md`
- 工作树：`/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/architecture-review-remediation-20260807`
- 分支：`fix/architecture-review-remediation-20260807`
- 起始基线：`b61597e9b0e4e49a84c2e2e87dbe85375c4c7614`
- 源码验收 HEAD：`1966a4a7fd3c8bd877459422f03668bf5ab3240c`

## 1. 审查修订结论

外部报告的调用链地图有价值，但不能把所有历史入口都当成同时竞争的当前缺陷。本轮逐项复核后：

- 确认并修复：共享 writer / Action Broker 错误缺少恢复说明；Codex 失败消息没有真实重试入口；空且不完整的 hot window 没有恢复入口；provider 历史失败会重复触发昂贵读取；runtime handle 换绑时缺少 turn 级视觉隔离。
- 驳回为当前缺陷：v1/v2/Mirror 必然同时竞争；queue 状态必然双广播；现有背压必然丢 sequence；runtime LRU 驱逐等于 durable catalog 丢失；runtime replacement 应无条件清空 streaming。
- 延后：巨型文件拆分、pending router 统一、Side Chat 历史清理、menubar 和 Firebase/App Check。它们需要独立调用者矩阵或产品授权，不能混入会话稳定性修复。

本轮最终门禁为 `0 P0 / 0 P1`。未发现需要阻断源码验收的新增 P2；结构债务继续登记，不伪装为已消失。

## 2. 上游与独立产品线

CC Pocket 自本轮起独立演进，不再要求整枝兼容官方 upstream。

- 选择性吸收官方 `8c075b33` 的长会话列表、键盘滚动、路径后缀缓存和性能 probe；冲突处保留本地折叠、工具详情、稳定 identity 与页面状态语义。
- 不吸收相邻 `4bb3d2e3` 的纯版本/changelog 变更。
- 这是语义吸收，不制造虚假的官方 merge ancestry。
- 仍保留 CC Pocket 自身的新旧 Mobile/Bridge 加法兼容、provider 历史权威、旧缓存可读和按提交回滚。

## 3. 实施提交

| Commit | 内容 | 关键边界 |
|---|---|---|
| `b726e5a8` | 选择性接入官方长会话性能优化 | 不接版本提交；保留本地会话语义 |
| `68b4adec` | 共享运行时错误提示与消息重试 | 无 authority lease 时 false、消息不变、不发包 |
| `02650c9c` | Codex/Claude 空且不完整窗口恢复条 | 复用既有 latest-turn repair；无新协议/schema |
| `62c7bfa8` | provider 历史失败退避 | per thread+revision 共享退避；自动/显式恢复；不以空旧 snapshot 覆盖手机缓存 |
| `81cd67d7` | runtime 流式状态按 turn 隔离 | 同 turn 续接；新 turn 清旧后回放；idle/terminal 丢弃；旧 generation 无效 |
| `1966a4a7` | 等待权威缓存确认最新轮恢复 | repair 返回 loaded 不等于缓存已完整，横幅只由 SQLite 新快照撤销 |

计划与执行分工提交：`bf2c6277`、`266c3017`。Luna Max 只完成边界封闭的 Mobile L1/L2 和例行验证；Bridge 退避、turn fence、冲突语义与最终复核由根协调任务完成。

## 4. 链路行为

### 4.1 失败与重试

- `codex_shared_runtime_writer_unavailable` 与 `codex_action_broker_required` 现在有中英日韩标题和恢复动作；Bridge 的 fail-closed 没有放宽。
- Codex 失败气泡接入真实 retry。只有当前 runtime/source/authority lease 精确成立才把 failed 改为 sending，并生成新的 `clientMessageId` 走 ordered dispatch。
- lease 未就绪时 UI 明确说明未重发；不会显示虚假排队或发送成功。

### 4.2 不完整最新轮

- Codex 与 Claude 只在当前 source identity 已确认、缓存 entries 为空且 `latestTurnComplete=false` 时显示非模态恢复条。
- 正常权威空会话和已有可见消息均不显示。
- 重试调用现有 `loadOlderTurns` / latest-turn repair；35 秒兜底结束 spinner。即使请求返回 loaded，也必须等待 SQLite 权威快照完整后才撤掉横幅。

### 4.3 provider 失败退避

- 同一 `provider + thread + revision` 的失败在多手机之间共享 `2s → 5s → 15s → 30s` 有界退避；到期自动重试。
- 用户 focus 可绕过一次冷却；catalog revision 或实时内容 revision 前进立即清除旧失败状态。
- 没有新实时内容时只发送 scoped `timeline_failed`，不会把 Bridge 的空或旧 snapshot 写进 Mobile。
- 权威历史失败但已有真实实时内容时仍可显示增量。若手机带着 Bridge 当前内存中没有的缓存 revision，只发送 `deletes=[]` 的 additive patch，保留手机已有正文。

### 4.4 runtime 换绑流式一致性

- 换绑立刻撤销写 authority，但暂存已有视觉流；新 runtime 的 text/thinking delta 在 turn 身份确认前有界隔离。
- 新权威状态证明 activeTurnId 相同后续接；证明为不同 turn 后清旧流再播放新 delta；idle/completed/failed 时清旧并丢弃晚到 delta。
- 被拒绝的旧 authority generation 不参与确认；旧 runtime subscription generation 的迟到消息继续被拒绝。

## 5. 验证

### Bridge

- build：TypeScript 与 darwin native file-browser helper 通过。
- 定向：6 files / 455 tests passed。
- `conversation-sync-v2.test.ts`：122/122 passed。
- 全量单 worker：114 files / 2323 tests passed，exit 0。
- git-ops 错误路径 fixture 会输出预期的 `fatal/pathspec/whitespace` 文本，但 Vitest 无失败。

### Mobile

- 本轮指定集合：281 tests passed。
- `chat_session_cubit_test.dart`：192 tests passed。
- `durable_session_preview_test.dart`：21 tests passed。
- 全量：2925 passed、4 skipped、0 failed。
- analyze：0 error、0 warning、52 info；原始命令因 info exit 1，`--no-fatal-infos` exit 0。52 条主要是既有 `prefer_initializing_formals`，另有 3 条 deprecated `imageBuilder`。
- `git diff --check`：通过。

### 性能

Bridge benchmark：

- 当前 Mac 实际 state DB：323 entries、20 iterations，median 20.27 ms，p95 21.12 ms，max 30.60 ms。
- 合成 1500 会话：priority p95 37.65 ms，complete p95 52.16 ms。
- 合成 10000 会话：priority p95 82.38 ms，complete p95 95.68 ms。
- 重连历史读取：0；单次 live revision 历史读取：1；provider 并发上限：2。
- 1000 个 live delta dispatch p95：1500 会话 3.19 ms，10000 会话 0.96 ms。
- 最大物理帧：57,603 bytes，小于 64 KiB 目标。

Mobile 长会话列表、键盘滚动、路径缓存与 fork 判定新增/更新测试均包含在指定集合和全量回归中。没有以截断会话或隐藏状态换取基准结果。

## 6. 兼容、安全与发布边界

- 无新 wire 字段、SQLite schema、provider 历史格式、Swift/native channel、Cloud Function 或版本号变化。
- 新 Mobile + 旧 Bridge 仍按旧错误和 v1 fallback 工作；旧 Mobile + 新 Bridge 只会看到既有 error/timeline 事件。
- private Codex、shared daemon Codex 和 Claude 的现有 provider 路径保留；共享 writer、source、generation 和 turn 门禁均未放宽。
- 本轮没有切生产 Bridge、发布 OTA/stable、构建/发送 IPA、修改 Desktop/daemon、网络、密钥或物理设备。
- 真机仍需验证恢复横幅、失败消息手动重试、runtime 换绑同 turn 连续性和不同 turn 不串流；生产 Bridge 退避需单独候选 wire smoke 后才可发布。

## 7. 产物与容量

- 验收后工作树 clean。
- 复用 `node_modules` 114 MiB、Bridge workspace dependencies 210 MiB、Bridge `dist` 6.8 MiB、Mobile `build` 163 MiB、`.dart_tool` 27 MiB。
- 未生成 IPA/APK/AAB/ZIP/DMG/PKG；无临时 git-ops 残留或失败重复产物。
- Data volume 约剩余 14 GiB。本轮依赖和构建仍属于当前活跃 worktree；分支收束或发布完成后应按两版规则清理。
