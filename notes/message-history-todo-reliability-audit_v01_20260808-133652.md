# CC Pocket 消息、历史、待办与同步可靠性最终源码审计

状态：`source-verified / release-device-pending`

- Worktree: `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/session-reliability-and-tasks-20260808`
- Branch: `feature/session-reliability-and-tasks-20260808`
- Base: `685e67cb926d68b478a48abd7540df56bbe4f064`
- Audited HEAD: `0f78670d0514e79a5b897935ee251a924d95d9f0`
- Plan: `plans/mobile-message-history-todo-reliability_v01_20260808-094120.md`
- Audit time: 2026-08-08 13:36 CST

## 1. 结论

本轮按 provider → Bridge → wire → SQLite → Cubit → UI 的真实链路修复了消息重复/消失、
跨轮次和跨页身份碰撞、迟到历史页覆盖新缓存、压缩后历史读取、轻量用户消息导航、悬浮
待办、冷会话设置原地刷新、连接进度与停滞提示。最终源码审计未发现未处置的 P0/P1/P2。

Bridge-owned auto approval 已有持久策略、Action Broker 请求订阅、writer lease 与 source
generation 门禁；本轮没有在 Mobile 新建第二套审批循环，也没有放宽后端写入权限。

生产 Bridge、Cloud、OTA、IPA、Desktop/CODEX_HOME、网络和物理 iPhone 尚未在本源码任务中
改变。它们必须由固定发布任务基于本文件记录的精确 HEAD 重新构建和验收，不能沿用旧产物。

## 2. 原始问题与最终处置

| 原始问题 | 根因 | 最终处置 | 证据 |
|---|---|---|---|
| 发送中与发送完成显示成两条；用户消息会短暂消失或落到上一轮 | optimistic、ACK、provider echo 与历史回填使用了不同身份；Codex 页内 ordinal 被误当全局身份 | `clientMessageId`、`providerItemId`、`historyTurnId` 分工；ACK 原位升级；强身份不同禁止弱文本合并 | `00af2aca`、`0e7cf2a3`、`a90131f6`；Cubit/Bridge 回归 |
| thinking、tool、result 随增量或分页错轮、排序不稳 | assistant/tool fallback key 没有 provider turn 范围 | Bridge、Mirror、Cubit、Widget/process key 全部按 provider turn 作用域化 | `03ccee33`、`3232b9a3`、`72f1c081`、`38c9af0b` |
| 两个旧历史页复用相同 UUID 时覆盖 | 每一页重新生成 `legacy-turn:<uuid>`，Claude reader 又过早写入未隔离 ID | 非首 source page 用 opaque source cursor 的短 SHA-256 命名空间；同一页 offset 保持稳定 | `3bc3d296`、`0f78670d`；真实默认 Claude bounded-reader 双页回归 |
| 历史页迟到后把新缓存/实时尾部倒退 | 请求开始时没有冻结 revision/cursor，SQLite 写入缺 compare-and-commit | 捕获 expected revision/cursor；事务内不一致即拒绝迟到页并保留现有窗口 | `cecbf986`；repository race 回归 |
| `/compact` 成功后出现 history error，Retry 不推进 | compact 结果与历史读取耦合；fallback 使用过期/无界接口；终端 error 没有进入分页状态 | compact 结果独立；durable thread 使用 bounded turns/items；相关 error 停止自动分页，显式 Retry 复用 cursor | `b0ba1ddd`、`079b6b08` |
| 用户消息导航依赖下载完整聊天记录 | 只有完整 Mirror 提供导航索引 | 新增 `conversation_user_index_v1`；SQLite v7 保存可重建 user shells、revision/cursor/locator；点击才补目标 turn/items | `3becf973`、`c9317613`、`69f5eaf7`、`471b53b4`、`e994d8a6` |
| 轻量索引重新打开后偶发旧页或混合 revision | state 与 rows 分离读取、旧 schema 缺复合 revision 约束 | v6→v7 原子迁移；state/rows 同一事务；entry FK 与 revision 对齐；迟到 flight 拒绝 | `e994d8a6`、`1c052d32` |
| 悬浮窗缺少可执行待办 | 无当前主会话隔离的本地待办模型 | 非模态 dock 内新增版本化待办、勾选/删除/一键发送；按 Bridge/source/provider/thread 隔离 | `6646da53`、`9718791d` |
| 冷会话设置只有退出重进后显示 | focused hydration 已到达 SQLite，但已挂载 loader/Cubit 未重新绑定当前 source/thread | 打开即 focus；有界补读；当前页原地 rebind；字段逐项 known；旧 source/revision 迟到结果拒绝 | `2666a39e`、`d3a58c70` |
| 连接进度后半段跳跃，整段固定超时过早 | UI 只暴露少数里程碑；watchdog 未绑定 generation/stage/progress | 真实 producer milestones 均匀映射；同 generation+stage+percent/progressKey 停滞 10 秒才提示，进展即重置 | `1c57bcee`；Home progress/watchdog 回归 |

## 3. 权威身份、排序与缓存边界

### 3.1 身份优先级

1. provider item id：跨快照、分页和重连的首选身份；
2. provider turn id：限定 user/assistant/tool fallback、展开状态和工具详情；
3. client message id：手机提交、ACK、队列和 provider echo 的幂等身份；
4. 兼容 UUID：仅在缺少上面强身份时使用；
5. 文本/时间弱匹配：只允许在当前尾部、时间有界且不存在相互冲突的强身份时使用。

时间戳只用于显示、目录 recency 和最后 tie-breaker，不驱动常规历史全量重排。分页提交使用
revision/cursor/generation fence；不同 provider turn 中相同文本、相同 tool id 或 fallback UUID
均不得合并。

### 3.2 SQLite

继续扩展现有 Session Catalog Cache，未创建竞争数据库。schema v7 的 user-index state 与
entries 以 Bridge/source/provider/thread/revision 分区；分页先写 staging generation，事务
成功后再推进 state。该索引是可重建 Mobile 缓存，不写回 Mac/provider 权威历史。

旧 schema 原子迁移；损坏或未来 schema 只重建可恢复的索引表，不删除草稿、提交队列、
凭据、设置、传输断点或 provider 历史。

## 4. 兼容性审计

- 新 Mobile + 新 Bridge：启用 `conversation_user_index_v1`、turn-scoped identity 和
  `historyTurnId` 工具详情定位。
- 新 Mobile + 旧 Bridge：能力缺失时不发送新 user-index 请求；继续使用有界 v2/legacy
  历史与严格尾部兼容匹配，不假装索引完整。
- 旧 Mobile + 新 Bridge：新增字段与能力均为 additive；旧客户端忽略它们，原 v1/v2 路径
  保留。
- Codex：优先官方 turn/item identity；bounded turns/items 不可用时只对已证明可消费游标
  的兼容 reader 回退，不做交互路径全量 rollout 扫描。
- Claude：JSONL 从尾部有界分页；source cursor 被验证并用于 fallback turn namespace。
- ephemeral thread：不请求不支持的 includeTurns/持久历史组合。
- 当前 turn 写入、stop、steer、approval 仍受 exact runtime/source/authority/writer lease
  门禁；本轮只增强只读历史和本地投影，没有用 UI 稳定性绕过写入安全边界。

## 5. 性能扫描

最终 HEAD 的 `benchmark:session-sync`（2026-08-08T05:35:03Z）：

| 场景 | 结果 |
|---|---:|
| 真实目录 324 项 | median 20.81 ms；p95 23.48 ms；max 78.63 ms |
| 合成 1,500 项 priority | p95 37.80 ms |
| 合成 1,500 项 complete | p95 53.16 ms |
| 合成 10,000 项 priority | p95 82.42 ms |
| 合成 10,000 项 complete | p95 95.71 ms |
| 无变化重复同步 | 0 次历史读取 |
| live delta | 1,500 项场景 p95 3.25 ms；10,000 项场景 p95 0.99 ms |
| provider 历史读取并发 | 最大 2 |
| 最大帧 | 57,603 bytes，低于 64 KiB |
| 单轮最大发送 | 1,500 项 806,565 bytes；10,000 项 5,263,715 bytes |

轻量用户索引只传 user shell，不读取工具正文；revision 未变化不重复读取历史。SQLite 逐页
事务写入，不在 Dart 内存聚合全量会话。原性能线的重要语义仍存在：32 ms streaming
coalescing、文件后缀弱缓存、ordinal seek pagination 和首帧后非关键初始化。

## 6. 自动验证

### Bridge

- 定向生产路径：`conversation-sync-v2.test.ts` 130/130；
- v2 + websocket：431/431；
- 单 worker 全量：114 files / 2,354 tests；
- TypeScript `tsc --noEmit`：通过；
- native file-browser helper：darwin 构建通过；
- `git diff --check`：通过。

全量第一次运行暴露测试兼容问题：构造 handler 时过早访问 `websocket.test` 的部分
`sessions-index` mock 中不存在的 Claude reader 导出，造成 300 个同根初始化失败。该问题在
`0f78670d` 改为真正读取 Claude 历史时才解析默认 reader；随后关键套件和全量均通过。

### Mobile

- 定向链路：240/240；
- 最终串行全量：2,971 passed / 4 environment skips / 0 failed；
- `flutter analyze --no-pub --no-fatal-infos`：0 error / 0 warning / 56 info；
- 56 个 info 为 initializing-formal、3 个 deprecated imageBuilder 和 1 个测试 dependency 等
  lint，不构成发布阻断；本轮没有为消除 lint 噪声机械格式化或改写无关业务。
- Flutter 3.44.7 可用；mise 对未登记的 Shorebird 1.6.114 只产生工具发现 warning，不影响
  test/analyze。本源码任务没有据此声称 Shorebird release 可用。

## 7. 最终审计结论

- P0：0
- P1：0
- P2：0（最后一个 Claude 跨 source-page fallback UUID 碰撞已在 `3bc3d296` 修复，并由
  `0f78670d` 保持全量 mock 兼容）
- 非阻断/设备门禁：生产 runtime、真实共享 app-server writer lease、手机前后台、物理 iPhone
  滚动/悬浮窗/设置原地刷新、Bridge-owned auto approval 在手机断开后的真实审批、IPA/OTA
  lineage 尚待发布任务和用户验收。

## 8. 发布交接要求

固定发布任务必须使用当前分支最终 clean HEAD，并证明其代码树包含本次已审计代码 HEAD
`0f78670d0514e79a5b897935ee251a924d95d9f0`；其后的提交只允许是本审计文档与项目索引。
发布前重新核对当前生产 Bridge 路径/PID/listener/health/readyz/writer lease 和回滚 runtime。
Bridge 候选必须做认证、
v1/v2、历史双页、user-index capability、focused settings、消息发送/ACK 和 auto-approval
smoke 后才可切换；只允许修改 `BRIDGE_CLI_ENTRY`，不得顺带改变 Desktop、CODEX_HOME、
网络、Cloud 或 stable。

Mobile 必须从同一 HEAD 重新构建，核对版本单调递增、Shorebird lineage/native diff、arm64、
Bundle ID、ZIP 安全和 SHA-256。OTA、IPA、安装和物理设备验收分别报告；没有匹配 base 时
不能把 IPA 重装说成 OTA。
