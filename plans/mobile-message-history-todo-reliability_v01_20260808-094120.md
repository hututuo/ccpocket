# CC Pocket 消息身份、历史导航与悬浮待办可靠性方案

状态：`accepted / source-verified / release-device-pending`

分支：`feature/session-reliability-and-tasks-20260808`

基线：`685e67cb926d68b478a48abd7540df56bbe4f064`

## 目标与边界

本轮优先修复真实消息链路，不以界面去重或时间戳重排掩盖数据问题：

- 手机发送的用户消息从创建到 Bridge、app-server、SQLite、Cubit 和 UI 始终是同一条逻辑消息；ACK 只原位推进状态，不创建第二条消息。
- 已被 Desktop/app-server 接收的消息不得从手机消失，也不得在稍后回填时落到上一轮开头。
- 历史和实时尾部以 provider 的 turn/item 身份及顺序为权威；时间戳只用于显示和最后兜底，不参与常规全量重排。
- `/compact` 成功后，历史读取能力降级或分页游标失效不得污染当前可见尾部；必须进行有界、单会话恢复。
- 移除“完整下载并常驻”作为用户消息导航前提。近期活跃会话持久保存轻量用户轮次索引，点击后只补目标附近的历史页和工具详情。
- 现有非模态悬浮窗增加当前主会话专属待办列表，复用现有发送路径。
- 自动批准继续由 Bridge 托管；本轮验证现有实现及运行时，不另造手机端审批循环。
- 冷/非活跃会话首次打开后立即提升为 focused conversation：顶部模型、思考强度、Plan 和权限允许短暂显示“未同步”，但权威设置到达后必须在当前页面原地刷新，不能要求退出再进入。
- 连接进度按真实阶段均匀映射到 0–100；只有同一阶段和同一百分比连续停滞约 10 秒才提示超时，阶段推进必须重新计时。
- 保持旧 Mobile/新 Bridge、新 Mobile/旧 Bridge、Codex/Claude 的加法兼容；未知字段可忽略，旧协议继续有界回退。

## 已确认根因

### P1：Codex 用户消息身份碰撞

`conversation_sync_v2` 当前逐个 raw turn 调用历史转换。转换器每次从本地 `userTurnOrdinal = 0` 开始，因此同一页和不同分页中的多个用户 turn 都可能得到 `codex:user-turn:1`。同时 user wire message 丢弃了官方 `rawItemId`。结果是：

- Bridge snapshot entry id 碰撞；
- SQLite prepend/patch 把不同用户消息视为同一项；
- Cubit stable key、历史替换和 Widget turn key 误合并；
- 乐观消息可能先消失，之后被错误回填到上一轮；
- 后续 thinking/tool/result 会跟随错误的用户边界。

Mobile 还会按“当前可见用户消息数 + 1”自行伪造 `codex:user-turn:N`。分页窗口与 Bridge 全历史的计数域不同，因此这个值不能作为 provider 身份。

### P1：用户导航索引依赖完整 Mirror

`loadAllUserMessagesForNavigation()` 的唯一索引提供者是 Conversation Mirror；只有完整镜像存在时才能读到全部用户消息。v2 热窗口和向上分页虽已持久化，但没有独立的全用户轮次 shell 索引、完整度或稳定 locator。因此当前“完整下载并常驻”并非单纯按钮，而是架构耦合。

### 已实现但需验证：Bridge 自动批准

当前源码已经存在 Bridge-owned `auto-approval`、持久设置、Action Broker 订阅、writer lease/authority fencing 和 allowlist。Mobile 只是配置入口。实现阶段只补回归和运行时证据；除非审计发现真实缺口，不重写此模块。

### P1：冷会话 focused settings 只在重新进入后可见

冷会话目录快照可以先于权威 settings hydration 到达，这是允许的；不允许的是当前页面丢失后续提交。必须逐段验证：Bridge focused hydration/dirty fanout、Mobile SQLite 原子提交、`SessionListCubit.catalogSnapshotChanges`、已挂载 `DurableSessionPreviewUpdater`、`ChatSessionCubit` 字段投影和 `SessionModeBar` rebuild。来源指纹或 generation 不匹配时只能拒绝迟到写入，不得吞掉当前来源随后到达的完整快照，也不得用旧缓存覆盖新设置。

## 实施设计

### 1. 身份与顺序模型

用户消息同时保留不同职责的身份：

- `clientMessageId`：手机提交幂等键，从 optimistic 到 ACK/恢复始终保留；
- `providerItemId`：app-server/官方历史的稳定 item 身份，Bridge 必须传透；
- `historyTurnId`：provider turn 身份，用于轮次边界和目标分页；
- `rewindTarget`：仅用于回退/分支操作，不再兼任 UI 去重键；
- `entryIndex/itemOrdinal`：只在对应 revision/page 内表达顺序。

匹配优先级：`providerItemId` → `clientMessageId` → 已确认兼容 UUID → 有界的当前尾部弱匹配。两个都存在且不同的 provider 身份永不因文本相同而合并。

Mobile optimistic 用户消息不再伪造 provider UUID，只用 `clientMessageId` 并固定在 live-tail 占位。权威 echo/history 到达后，在原对象位置升级 provider 身份、时间和送达状态；ACK 不删除消息。分页回填只填入 cursor 对应的旧区间，不允许跨越 live-tail fence。

### 2. Bridge v2 转换与兼容

- Codex turn 转换必须保留 raw user item id 和 turn id。
- v2 snapshot/patch/page 的 entry identity 优先使用 provider item id，禁止页内局部计数作为全局身份。
- 老 Mobile 仍可读取既有字段；若需投影兼容 UUID，必须跨页稳定且 Bridge 能把它解析为正确 rewind/fork 目标。
- 新字段均为 additive，旧 Bridge 缺失时新 Mobile 使用 `clientMessageId`、既有 UUID 和严格限定的尾部弱匹配，不放宽跨会话/source fence。

### 3. 压缩与历史恢复

- 区分 `/compact` 操作结果与随后历史读取结果；压缩成功不得被历史页读取失败改写成“压缩失败”。
- ephemeral thread 禁止请求不支持的 turns/includeTurns 组合；durable thread 优先 v2 turns summary，items 不支持时使用已存在的 turns fallback。
- 旧 revision/cursor 在 compaction 后只触发该 thread 的 scoped reset；保留最后一次已提交的可见窗口和实时尾部，直到新 snapshot 原子提交。
- Retry 必须发出真实请求、记录 request/subscription/generation/cursor，并在成功 commit 后消失。

### 4. 轻量用户轮次索引

在现有 session catalog/cache SQLite 分区中增加独立、可重建的 user-turn index，不创建竞争数据库。每项至少保存：

- bridge/source/provider/thread 身份；
- provider turn id、provider user item id；
- client id（若存在）；
- 用户文本的有界显示副本、图片数量；
- provider 产生时间及是否权威；
- 可定位的 page cursor/revision/邻域 locator；
- 索引完整度与下一游标。

Bridge 对近期活跃会话使用官方 `thread/turns/list(itemsView=summary)` 或对应 Claude 有界索引，投影为用户 shell；不读取工具正文。Mobile 逐页事务写入，成功后推进 cursor。revision 未变时复用本地索引。

打开用户消息导航时先读本地索引；点击某项后按 turn id/cursor 请求目标邻域并写入现有 hot cache。工具详情继续按需分页。取消 Codex 路径的完整 Mirror 下载 CTA；Mirror 仅作为已有完整副本的兼容数据源，不再独占 loader。

### 5. 悬浮待办

- 归属键为当前 durable 主会话，临时会话/子 Agent 不共享错位数据；
- 非模态悬浮窗内直接展开，高密度展示；
- 支持新增、勾选/取消、删除；
- 一键发送复用现有 composer/`ChatSessionCubit.sendMessage`，成功提交后再标记完成；
- 使用版本化本地持久化，旧数据损坏时安全回退为空；
- 不改 Swift、Cloud、Bridge schema。

### 6. 冷会话设置原地刷新

- 打开 durable 会话时立即登记 source-scoped focused conversation，不通过 resume/取得写入权来读取设置；
- Bridge 将 focused settings 作为同一 thread 的增量 catalog upsert 发出，并在 timeout 时对仍处于 focused 的同一 source/generation 做有界重试；
- Mobile 只有在 SQLite commit 成功后推进投影，并为已挂载页面发出 source/thread 精确的变更通知；
- 当前页面保留同一个 `ChatSessionCubit`、草稿、滚动和展开状态，只更新设置事实及对应 loader；
- 模型、effort、speed、Plan 和权限逐字段判断 known，某个字段暂缺不得清空已经确认的其他字段；
- source/thread/revision/generation 发生变化时拒绝旧结果，且不得放宽设置 mutation 的 authority 门禁。

### 7. 连接进度与停滞提示

- 百分比只来自可观测阶段，不用固定延时伪造；各阶段映射覆盖完整 0–100 区间并保持单调；
- watchdog 的键至少包含连接 generation、阶段和当前百分比；任一项前进即重置停滞计时；
- 同一步骤连续约 10 秒无进展才显示“超过预期”，错误、认证失败和密钥错误走明确错误分支，不伪装成超时。

## 验证门禁

### Bridge

- 多 turn、跨两页用户 item 身份全部唯一且稳定；
- snapshot → patch → turns page 不发生 entry id 碰撞；
- raw provider item 与 legacy rewind target 映射正确；
- compact 后旧 cursor 只做 thread-scoped recovery；
- auto approval 在手机断开后仍由 Bridge 处理，且 writer lease/source generation 不匹配时 fail closed；
- TypeScript build、native helper、定向和单 worker 全量测试。

### Mobile

- optimistic → Bridge ACK → provider accepted → canonical history 始终一个 bubble；
- ACK/echo/history 的全部先后顺序、重连、compact、页面重建都不消失；
- 连续相同文本不会错误互换；
- 按需旧页插入不移动 live tail，thinking/tool/result 保持所属 turn；
- 用户索引跨重启持久，目标页失败可重试，成功后无需再次下载；
- 悬浮待办会话隔离、一键发送和持久化；
- 冷会话同页完成 `unknown -> known` 设置刷新，退出/重进不是验收步骤；迟到的其他 source/thread 设置不得污染当前页；
- 连接进度阶段分布均匀、单调，只有同阶段/同百分比停滞约 10 秒才提示；
- Flutter 定向、全量测试和 analyze。

### 性能与审计

- 100 个 revision 未变化的近期会话不读正文；
- 用户索引只传 user shell，帧和未 ACK 预算沿用 v2 上限；
- SQLite 用复合索引和增量 upsert，不在内存聚合全量历史；
- UI 只重建变化 turn/可见窗口；
- 完成功能后做 provider → Bridge → wire → SQLite → Cubit → UI 全链路审计和性能扫描，P0/P1 清零后才可交付发布会话。

## 发布边界

源码、测试和集成由当前任务完成。发布只交给用户指定的固定会话 `019f8e9d-2490-79c0-817c-87e3eb93ea2f`，并提供精确 worktree、branch、完整 HEAD、测试、Bridge 回滚点和 Mobile lineage。不得联系历史协调会话；不得默认发布 stable、Cloud 或修改 Desktop/CODEX_HOME/网络。
