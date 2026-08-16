# CC Pocket 会话时间线单一权威收束 v01

状态：源码修复与隔离协议验证完成，尚未部署 Bridge、发布 OTA 或构建 IPA。

基线：`c43c0b2672151b01b580e52ebc9331fa35c287f8`（build 231 / Bridge compat.34 源码）

## 事故现象与真实数据

物理手机在一个超长、仍活跃的 Codex 会话中同时出现：

- 最新消息窗口停留在较早轮次；
- 一条用户输入显示三份；
- 对应助手回复也显示三份；
- 刷新时旧缓存、实时消息和历史分页互相替换。

只读核对证明，Codex rollout 与 app-server `turns/list` 对应轮次都只有一条
用户消息和一条助手消息。重复不是权威历史损坏，而是在下游投影链生成：

1. Bridge runtime session fanout 保存一份稳定消息；
2. Bridge shared app-server observer 又保存同一 provider item 的另一份临时表示；
3. 两份数据此前被放入同一个无来源区分的 map，无法跨来源别名归并；
4. Mobile detached Cubit 同时接收 SQLite v2 snapshot、runtime stable frame 和
   optimistic/outbox overlay；
5. history replacement 为避免丢实时内容又保留未匹配的旧 ID，最终把同一事实
   扩成三份。

普通短会话通常不会同时命中 runtime、shared observer、focused provider read 和
optimistic overlay，因此问题会显得只发生在某个超长活跃会话。

## 固定权威边界

```text
Codex provider history / app-server turns
                 ↓
Bridge producer-aware normalization
                 ↓
conversation_sync_v2 snapshot / patch
                 ↓
Mobile staging + SQLite atomic commit
                 ↓
detached ChatSessionCubit stable timeline
                 ↓
UI
```

对于支持 `conversation_sync_v2` 的 durable detached 会话：

- 稳定 transcript 的唯一 Mobile 写入者是 `v2 → SQLite → Cubit`；
- runtime stream 提供 control、approval、receipt、status、stream/thinking delta，
  以及 Codex turns 不保存的 result/error/guardian/tool-summary 临时 UI 覆盖层；
- optimistic/outbox 是覆盖层，不是第二份历史；canonical `clientMessageId` 到达后必须
  收束成同一个用户气泡；
- authoritative empty snapshot 可以清除旧 stable rows，但不能删除仍未发送的 outbox；
- legacy Bridge 缺少 v2 capability 时继续使用既有 runtime transcript fallback。

## Bridge 归并规则

每个观察项保留内部 `projectionSource`：

- `runtime`
- `sharedObserver`
- `externalObserver`
- `providerRefresh`

规则：

- 不以显示文本、项目名或单纯时间戳去重；
- 不合并已确认属于不同 turn 或不同 anonymous scope 的项目；
- 跨 producer 可以使用 provider identity、turn、client message identity 和稳定内容
  进行规范化；
- 同 producer 只允许在强证据下合并：相同 provider item ID，或用户消息同时具有
  相同 `clientMessageId` 与 `userMessageUuid`，或助手/工具结果有相同稳定 ID；
- canonical provider history 覆盖所有临时投影后，删除该 thread 的临时 buffer；
- canonical 尚未覆盖时，不把 provisional/live-only snapshot 记成下一轮的 canonical
  base，因为 snapshot 不持久化 producer/scope provenance；
- 迟到 observer/runtime 数据不能重新覆盖已确认的 canonical snapshot。

focused provider read 的脱敏诊断只记录：target hash、canonical/observed/merged 数量、
producer 分类和 coverage 布尔值；不得记录正文、路径、thread ID、token 或凭据。

## Mobile 替换规则

- v2 capability 存在时，detached runtime 的 user/assistant/tool-result 不直接进入
  stable timeline；result/error/guardian/tool-summary 作为当前 attachment 的有界覆盖层
  保留，并在 SQLite 刷新时继续可见；
- history replacement 不再保留非本地的 sent user row，或 user/assistant/tool-result
  stable transcript 的临时副本；
- 保留 `sending/queued/failed`，以及由当前 Cubit 明确发起、虽已 ACK 为 sent 但尚未被
  canonical `clientMessageId` 接管的用户覆盖层；
- canonical history 根据稳定身份吸收对应 optimistic row；
- snapshot 更新不得重建页面、折叠状态或滚动容器；只替换 repository 投影。

## 运行时临时覆盖层

Codex turns/history 无法重建 `result`、`error`、`guardian approval` 和
`tool-use summary` 等短生命周期状态。它们通过加法能力
`conversation_runtime_overlay_v1` 单独传递，不进入 canonical timeline，也不写入
SQLite：

- 只有声明该能力、处于 interactive delivery 且正在聚焦目标 thread 的客户端才接收；
- formal runtime 与 shared app-server observer 都只能经该能力通道进入 Codex detached
  页面；Claude 会话不发送这条 Codex-only 事件；
- Mobile 不直接监听原始 Bridge local-feature 广播，而只监听 sync service 在当前
  subscription、连续 sequence、commit 与 ACK 门禁后转发的有序事件；`sync_begin` 建立
  active subscription 前到达的覆盖层按流连续性错误重订阅，不能提前进入 Cubit；
- 每条覆盖层带稳定 `overlayId`。相同 provider 事实的 ID 不依赖 observer 重连代次，
  Bridge 与 Mobile 都做有界幂等去重；
- Bridge 沿用同步队列的 64 KiB 单帧和未 ACK 背压边界；
- 每条事件包含 `originGeneration`，formal runtime 另带 `runtimeSessionId`，有权威信息时
  带 `authorityGeneration` 与 `turnId`。Mobile 同时校验 Bridge/source/provider/thread、
  当前 attachment、authority 与 active turn；顶层 turn 缺失时使用消息内部
  `historyTurnId` 继续 fail-closed；
- overlay 可先于同一 runtime/status snapshot 到达：仅在后续 attachment、authority 与
  turn 完全匹配时保留；不同 runtime、被拒绝的 authority、source suspension 或 active
  turn 改变时立即清除；同一 turn 的 SQLite 刷新不清除它；
- Mobile 最多保留 32 个 runtime overlay，按消息 wire shape 编码后的合计预算为
  64 KiB；超限从最旧项开始淘汰；
- 缺少新能力的兼容直达路径仍可用，但 `result/error/guardian/tool-summary` 现在保留
  Bridge 提供的 `historyTurnId`，迟到的上一轮终态不得挂到当前轮；
- user/assistant/tool-result 永远不能经该通道进入 detached stable timeline。

## 兼容与失败边界

- 新 Mobile + 新 Bridge：使用单一 v2/SQLite stable timeline。
- 新 Mobile + 旧 Bridge：capability gate 保留 runtime transcript，不出现空白会话。
- 旧 Bridge 缺少 authoritative-empty/completeness fence，空 refresh 不清除最后可读窗口。
- 旧 Mobile + 新 Bridge：未声明 `conversation_runtime_overlay_v1` 时 Bridge 不发送新事件，
  继续使用既有 v2/legacy wire。
- Bridge 内部新增 provenance，不改 SQLite schema、wire schema 或 canonical rollout。
- provider history 暂不可用时保留有界观察 buffer；不得把临时空读当作权威删除。
- 本修复不修改 Codex rollout、app-server 数据、Desktop、Cloud、通知、文件传输或网络。

## 回归与真实探针门禁

自动测试必须覆盖：

1. runtime-first 与 observer-first 两种到达顺序；
2. 同一 producer 的强身份重复合并；
3. 不同 provider turn 的相同文本不合并；
4. anonymous legacy turn 的复用 ID 不合并；
5. canonical history 覆盖后临时 buffer 被删除；
6. v2 Mobile 忽略 runtime stable content；
7. legacy Mobile 路径仍接收 runtime stable content；
8. 污染缓存、runtime 与 optimistic 三份输入收束为一份；
9. authoritative empty snapshot 只保留未发送 outbox。
10. ACK 先到、canonical cache 后到时，本地用户气泡始终只有一份且不会消失；
11. result/error/guardian/tool-summary 经 SQLite stable snapshot 刷新后仍可见；
12. 同一 runtime producer 复用 provider UUID、但 client ID 不同的 turnless 用户消息
    保持两条；
13. provisional observer snapshot 不晋升为丢失 provenance 的 canonical base；
14. legacy Bridge 空 refresh 保留最后可读窗口；
15. runtime overlay 只发给能力匹配且聚焦的客户端，重复事件只展示一次；
16. runtime/source/active turn 改变时旧 overlay 清除，同一 turn 的 SQLite 刷新不清除；
17. deferred/queued 消息重复回调仍只创建一个气泡并只向 Bridge 发送一次。
18. overlay 必须经过当前 active subscription 与连续 sequence；旧 subscription、
    `sync_begin` 前事件和旧 generation 都不能进入 Cubit；
19. formal runtime overlay 带 runtime/authority/turn fence，shared observer overlay 可先于
    status 到达并在相同 turn 保留；
20. runtime replacement、source suspension、rejected authority replay 与下一 active turn
    都会清除旧 overlay；
21. 旧 direct fallback 保留内部 `historyTurnId`，迟到 turn-a 的终态不能进入 turn-b；
22. Claude focused session 不接收 Codex-only runtime overlay；
23. overlay 数量不超过 32，编码预算不超过 64 KiB；
24. nested `historyTurnId` 在顶层 turn 缺失时仍参与轮次校验。

隔离候选必须使用临时 Bridge state，关闭 push、mDNS 与自动 artifact，不复用生产
Bridge identity、队列或文件传输状态；只读连接现有 Codex source。真实 thread 的每个
snapshot batch 必须分别检查，不能把同一 subscription 的多个 revision 拼接后误报重复。

源码测试和 wire probe 不能替代物理 iPhone 验收。部署后仍需验证：当前超长会话打开、
刷新、发送、ACK、退出重进和实时增长期间，用户/助手消息始终各一份且保持最新。

## 2026-08-11 最终隔离探针

候选从当前工作树构建，只在 `127.0.0.1:18769` 使用临时 Bridge state 启动；push、
mDNS、自动 artifact 与写入动作关闭，生产 `8765`、LaunchAgent 和真实会话数据未改。

对目标 thread `019fe552-2d01-7730-aaf6-87ae94a777f7` 的一次订阅在会话继续增长时
收到三个独立 snapshot batch。必须逐 batch 判断，不能把三个 revision 拼接后误报重复：

| batch | entries / unique entry IDs | users / unique | assistants / unique | latest source time |
|---|---:|---:|---:|---|
| 1 | 76 / 76 | 1 / 1 | 44 / 44 | `2026-08-10T19:39:25.391Z` |
| 2 | 76 / 76 | 1 / 1 | 44 / 44 | `2026-08-10T19:39:41.921Z` |
| 3 | 76 / 76 | 1 / 1 | 44 / 44 | `2026-08-10T19:39:46.942Z` |

这证明同一窗口每次 revision 都没有内部重复，而且最新时间随正在运行的会话继续推进，
没有退回旧缓存。用户报告中被显示三份的 `1` 对应 provider turn
`019fec98-079d-7573-a687-c0a801007719`；`turns_page_response` 只返回一个该 turn，内部
严格只有两条消息：一条 user `1` 和一条对应 assistant 回复。候选退出后 18769 无监听。
