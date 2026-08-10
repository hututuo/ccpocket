# CC Pocket 当前运行线程实时追平：根因、修复与诊断协议

> 日期：2026-08-10  
> 工作线：`codex/connection-chain-stability-20260810`  
> 性质：实现与验证记录；生产 Bridge、IPA、OTA 均需另行授权和验收。

## 1. 用户现象

同一个 Codex Desktop 线程仍在持续运行，Desktop 已出现大量新思考、工具和中间输出，但手机页面长期停在旧轮次末尾。退出重进、点击刷新或重连后仍可能得到同一份旧窗口。

这不是单纯的 Flutter 列表刷新问题。真实链路探针证明断点首先发生在 Bridge 输出之前。

## 2. 真实线程证据

测试线程只记录稳定 ID、类型、数量、时间戳和哈希，不记录正文、路径或凭据。

- 线程：当前协调线程，日志中只使用目标哈希。
- app-server `thread/turns/list(limit=5, desc, full)`：
  - 最新 turn 为 `inProgress`；
  - 调查期间从 34 项持续增长到 161 项；
  - 包含新的 `agentMessage`、`commandExecution` 和 `fileChange`。
- 旧生产 Bridge 的 focused v2 快照：
  - revision 长期不变；
  - 最新稳定助手/工具仍属于上一已完成 turn；
  - 当前 turn 仅有用户消息壳；
  - `latestTurnGap.turnId` 甚至仍指向上一 turn。
- 修复后源码探针：
  - 归一化窗口能够看到当前 turn 的最新工具过程；
  - 最终快照保留根用户消息、文本/思考主干和最近尾部；
  - 最终复跑实测快照 43 项、约 69 KiB，远低于 512 KiB 上限；
  - 最新条目与 app-server 当前尾部一致；
  - `latestTurnGap.turnId` 正确指向当前 in-progress turn。

一次长线程实测分项耗时：

- Desktop 时间戳富化：首次约 158–246 ms，缓存后约 5 ms；
- app-server 最近 5 turns full 读取：本次长线程约 1.8–3.5 s；
- 结果通过有界分页输出，单帧上限仍为 64 KiB。

## 3. 三个叠加根因

### 3.1 目录 revision 被错误当作内容 revision

`thread/list` 的 recency/catalog revision 适合触发目录变化，但运行中的同一 turn 可以继续增加 items，而目录 revision 不一定同步前移。

旧实现把构建出的内容哈希覆盖为目录 revision，造成：

1. 新内容与旧内容拥有同一个客户端游标；
2. Bridge 快照缓存把旧窗口视为已完成；
3. Mobile ACK 后没有任何协议信号说明内容已经变化。

修复后分离：

- `sourceRevision`：Bridge 内部的 provider/catalog 触发 token；
- `revision`：由条目 ID、顺序、内容哈希、gap 和游标共同生成的内容 digest，作为 Mobile 真正提交的 thread state。

`sourceRevision` 不上 wire；新旧 Mobile 都继续把 `revision` 当作不透明 token，协议保持加法兼容。

### 3.2 打开/刷新会话没有真正重读 provider

旧 `conversation_sync_focus(refresh:true)` 只把线程标为 dirty。发送阶段若手机已知 revision 与目录 revision 相同，会在 `snapshotFor` 之前直接返回，因此“刷新成功完成”也可能零读取、零 timeline。

修复后：

- 每个新的交互订阅对 focused、最近 5 个以及 working/compacting Codex 做一次有界重验证；
- 用户普通点入一个会话也会做一次最新轮校验，不要求先点“刷新”；
- 显式 refresh 必须执行 provider read；
- 有旧快照时只读最新 turn，不重建全部历史；
- 内容 digest 未变化时不重复传输或重写 SQLite；
- 同一 source revision 下可保留新旧两个内容版本，便于生成 patch，后续缓存读取总是取最新版本。

### 3.3 在途读取、ACK 和重试缺少同一条单调链

独立复审继续发现，旧修复即使能读到最新 provider，也可能在并发边界回退：

- 强制 focus 会复用更早开始的普通读取；
- provider 读取期间 live/source 已前移，旧结果仍可能入队；
- 同 source 的最终一致性旧响应可能用较短的同 ID 内容覆盖较新缓存；
- P、Q 两个 patch 尚未 ACK 时，Q 仍可能错误地以 K 为 base；ACK(P) 还会误删 Q 的 pending 状态；
- 有缓存的强制读取失败后，定时 retry 会被 cache fast-path 跳过；
- 快速 A→B focus 会把 A 的 refresh requestId 与 B 的目标组合。

修复后：

- snapshot flight 同时携带 source revision 与 forced 属性；强制读取只复用同代 forced flight，否则等待后重读；
- provider read 返回后再次比较当前 source，过期结果不下发，保留 dirty 意图继续追平；
- 同 source/latest-turn 合并保留更完整的同 ID assistant/tool 结果和既有权威时间戳；目录 revision 前移时仍使用完整窗口执行权威删除；
- pending revision 与最终 frame sequence 一起追踪，后续 patch 以 pending revision 为 base，累计 ACK 只清自己对应的 pending 代次；
- provider failure、空 latest 和“目录称有内容但返回空”均进入 2/5/15/30 秒有界恢复；到期 retry 不再被缓存短路；
- 自动 retry 与用户主动 focus 分离：主动 focus 只把当前 retry 标为立即到期，不清除失败计数；连续故障会真实递进 2/5/15/30 秒；
- focus target 与 refresh requestId 保存为一个不可拆分对象，快速切换不会串线；
- Mobile refresh 使用 focus generation 和可取消 flight；A→B→C 不会让 B 在 C 后复活，A→B→A 会创建新的 A 请求；
- bootstrap 背压重试会记住已经校验过的线程，避免反复读取同一活动线程。

### 3.4 两级有界压缩都偏向早期内容

第一层 raw turn 投影从头向后消耗 192 KiB；第二层 512 KiB snapshot fallback 最终只保留用户/文本主干。长活动 turn 的最新工具和思考会同时在两层被裁掉。

修复后：

- raw turn 保留官方根 item，并从最新 item 向前使用剩余预算，再恢复 provider 顺序；
- snapshot 超限时保留：
  1. 当前 turn 的根用户消息；
  2. 文本/思考主干及工具 gap 壳；
  3. 当前 turn 最近最多 64 个有界条目；
- 被省略的中段通过 `latestTurnGap` 明示，并继续使用 `items_page` 按需修复；
- 不隐藏或伪造完整性，不突破 64 KiB 帧和 512 KiB快照预算。

## 4. 新的脱敏链路日志

Bridge 与 Mobile 使用相同的 12 位 `target` 哈希，因此可以跨端关联同一线程，但日志不出现 thread ID、标题、正文或项目路径。

Bridge 诊断默认每分钟最多 240 条，可用 `CCPOCKET_SYNC_TRACE=0` 完全关闭；达到上限只记录一次限流提示。稳定后无需保留无界逐帧日志。

Bridge 顺序：

```text
provider turns read
provider timeline enrichment
timeline read
timeline normalized
timeline enqueued
```

关键字段：

- target；
- scope（full/latest_turn）；
- source/content/base revision 前 12 位；
- provider turn 数、最新 turn 哈希和 item 数；
- messages/entries 数；
- latestComplete、gapTurn；
- page、sequence 和 elapsedMs。

Mobile 顺序：

```text
timeline_received
timeline_window_committed
preview_read_start
preview_applied
```

Mobile 同样使用每分钟 240 条的进程级上限，可在构建时通过
`--dart-define=CCPOCKET_SYNC_TRACE=false` 关闭。批次 ID 以跨端一致的哈希记录，
不再截取固定前缀；timeline 不重复记录“收到、逐帧 commit、窗口提交”三份日志。

异常分支会明确记录：

- `event_ignored`：processing、Bridge identity、Codex source、cache target 或 subscription fence；
- `preview_read_superseded`：新 commit 抢先、读取变脏、旧缓存或路由/source 已变化；
- `preview_read_skipped`：权威 source 冲突或 cache target 不一致。

由此可以区分：Bridge 没读到、Bridge 没发送、Mobile 没接收、SQLite 没提交，还是 UI 没应用。

## 5. 兼容与性能边界

- 没有 wire 字段、数据库 schema、Codex/Claude 权威历史格式或 native-Dart 边界变化。
- 旧 Mobile + 新 Bridge：收到普通 opaque 内容 revision；无需升级解析器。
- 新 Mobile + 旧 Bridge：新增日志代码 dormant；原同步行为不变。
- 新 Bridge 首次遇到旧 Mobile 保存的“目录 revision 游标”时，会做一次有界迁移快照；之后按内容 digest 增量。
- provider 同时读取仍受既有并发 2 限制；同内容 refresh 不重传。
- 活动/聚焦线程每个新交互订阅只重验证一次；首次无缓存的 recent 会话仍加载，但 unchanged reconnect 不强读最近 5 个 idle Codex，普通 idle 缓存继续复用。
- Mobile 仍先显示已提交 SQLite 窗口，读取/刷新期间不清空可见消息。

## 6. 验证与剩余门禁

已完成的源码级证据：

- Bridge conversation sync/content sync 定向回归：177 项通过；
- 连续失败/空历史递进退避、5 个 idle unchanged reconnect、在途读取、ACK、重试与迟到响应均有定向覆盖；
- Mobile conversation sync service：37 项通过，包含 A→B、A→B→C、A→B→A focus generation；
- Bridge 单 worker 全量：118/118 files、2425/2425 tests；
- Flutter 全量：3082 项通过、4 项既有跳过；
- Flutter analyze：0 error、0 warning，53 个仓库既有 info；
- TypeScript typecheck 与 Bridge/native helper build：通过；
- 真实当前线程只读探针（最终复跑）：app-server 最近 5 轮读取约 3.5 秒；最新 turn 100 项，归一化 850 条消息；最终快照保留 43 项、约 69 KiB，尾部时间到探针前不足 1 分钟，未回退到旧轮次。
- 独立 Sol Max 最终复审：P0/P1/P2/P3 均为 0，NO BLOCKER。

发布激活前仍需：

1. 隔离候选 v2 wire smoke；
2. 用户另行授权后才可切换生产 Bridge、构建/发送 IPA 或发布 OTA；
3. 真机核对同一 target 的 Bridge `enqueued`、Mobile `received/committed/applied` 连续日志，并确认当前线程不再回退。
