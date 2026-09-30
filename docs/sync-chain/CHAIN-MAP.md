# 当前接收链路地图

地图固定到起始 SHA；后续修改由账本说明。它描述源码调用关系，不能单凭存在调用就声称运行通畅。

| 段 | owning path | 输入/输出与权威 | 需要证明的完成条件 |
|---|---|---|---|
| Provider | Codex app-server/history；Claude 原始记录 | 原始 Thread/Turn/Item、状态与内容 | 原始事实可读取；完成事件不是完整历史的替代 |
| Bridge Provider 转换 | codex-process.ts / local-features/codex-thread-history.ts | 原始 DTO → normalized 稳定身份、顺序、内容 | 不用正文/时间/位置造身份；工具与所属轮次正确 |
| Bridge 同步 | local-features/conversation-sync-v2.ts | 订阅/快照/patch/分页/Gap；带 source、subscription、sequence | 合法帧有界，partial 诚实，恢复与回补有终态 |
| Mobile 接收 | services/bridge_service.dart；models/local_features/slots/conversation_sync_v2_protocol_slot.dart | WebSocket JSON → 类型事件；错误分类和诊断 | 合法输入不误拒绝，非法输入明确拒绝，解析失败不静默消失 |
| Mobile 入站顺序 | features/conversation_content_sync/conversation_content_sync_service.dart | 校验 identity/generation/subscription，再串行提交 | 旧源/旧代响应不生效；序列洞转恢复；事务后 ACK |
| SQLite | features/session_list/cache/session_catalog_cache_repository.dart | staging → hot window；受 revision/identity/预算约束 | 原子提交；partial 保留 last-good；完整性不误报 |
| 缓存通知 | SyncService._publishCacheUpdate / syncUpdates | 本地 commit epoch 与数据变化事件 | 有效内容/coverage 变化可被观察；不改 Provider revision |
| 页面重读 | codex_session_screen.dart._loadDurablePreview | 订阅 updates → durable window → 页面/Cubit | 新内容到达页面；旧异步读不能回退已更新画面 |
| 展示投影 | chat_session_cubit.dart / chat_process_layout.dart | committed 内容与独立 live overlay | 稳定顺序、无重复、工具归属正确、partial 不清空可读内容 |

## 不同状态不能互相替代

| 状态 | 证明的事实 | 不能据此声称 |
|---|---|---|
| frame received / decoded | 传输/解析完成 | 已提交、已展示、全量完整 |
| committed sequence | 该事件已处理/事务结束 | 该会话最新轮次已完整 |
| canonical revision | 历史基线/lineage | 所有后续 partial 内容都相同 |
| cache commit epoch | 本地观察者应重新读取 | Provider 历史发生了同名版本变化 |
| loaded | 一次请求得到并接受内容 | 缺口已填完或无需后续修复 |
| latestTurnComplete / windowComplete | 对应覆盖范围的声明 | 数据是否改变、是否应该通知 |
| runtime overlay | 已验证的临时展示事实 | 可取代 durable canonical history |

## 第一批已确认的接缝

- turns_page 修复在 Repository 保留 latest_turn_complete=0；Service 用该值决定是否通知。
- 自动 turns_page 修复以 canonical revision 记住成功，而合法 partial 内容可能继续使用该 revision。
- Service 已有 Gateway、Repository、通知出口；先修 owning path，无需新造刷新系统。
- 自动修复状态、计时器、去重记录集中，但 focus/source/transport/reset/dispose 接点分散，
  抽取时必须把这些接点一并列入回归。

## 仍需单独验证

真实 Provider 的新消息到达、长会话/工具密集、fork/同名隔离、旧 Bridge 降级、
后台恢复、发送/steer/approval、实际设备与生产运行均不能仅由本批短闭环测试覆盖。

