# 中间消息分段与接收端权威链路

日期：2026-08-12

## 问题与根因

用户观察到两个相互关联的现象：

1. 一段中间输出已经结束，流式光标仍继续闪烁；下一段输出随后拼到同一段文字中。
2. 手机发出的最新消息在退出再进入会话后可能暂时消失，等持久历史追上后又出现。

这不是渲染组件单独识别不了分隔符。真实链路中存在两个权威层次：

```text
app-server item delta/completed
        -> Bridge runtime frame
        -> Mobile transient projection

app-server turns/items
        -> conversation_sync_v2
        -> SQLite atomic commit
        -> Mobile durable projection
```

旧实现为了避免实时帧和 SQLite 同时写正文，在 detached v2 会话中丢弃了完整
`AssistantServerMessage`，但仍接收 `stream_delta`。结果是 item completion 没有到达
`ChatMessageHandler` 和 `StreamingStateCubit`，流式状态无法在真实 item 边界结束，下一
个 item 的 delta 继续追加到旧缓冲区。

最新用户消息的短暂消失来自另一个交接窗口：Bridge 已返回 `input_ack`，但 app-server
历史和 SQLite 尚未包含该 user item。退出页面会销毁本地 optimistic row；重新创建的
detached Cubit 过去只读取 SQLite，没有恢复 Bridge 运行时缓存中的 ACK-only envelope。

JSONL 回退路径还存在一个独立身份缺口。Codex 会把同一条可见 assistant 更新先写成
没有稳定 item ID 的 `event_msg`，随后再写成带稳定 ID 的 `response_item`。旧解析器没有
把后者的 ID 提升到前一条临时记录，既可能错误合并相同文本，也会丢失跨层去重所需的
稳定身份。

## 修复后的权威规则

- SQLite 仍是 detached durable transcript 的唯一持久写入者。
- 实时 `AssistantServerMessage` 仅作为有界 presentation overlay：
  - 立即结束当前 stream/cursor；
  - 使用 provider assistant item ID 保留独立分段；
  - SQLite 出现同一稳定 ID 后由 canonical row 接管，不产生第二条消息。
- Bridge 已接收、SQLite 尚未接收的 user input 使用 `clientMessageId` 作为临时身份；页面
  重建时从当前 runtime cache 恢复，canonical user item 到达后再由 provider item ID、
  turn ID 和 UUID 接管。
- JSONL 中相邻的 event/response 双写只有在文本和 turn 相同且一方没有稳定 ID 时才视为
  同一消息，并把 response item ID 提升到该记录。两个不同稳定 ID 即使文本相同也必须
  保留为两个 item。
- 时间戳只用于显示和最后的 tie-breaker，不承担 item 边界或去重身份。

## 为什么旧模拟接收端没有发现

原 `conversation_real_bridge_chain_test.dart` 主要验证：

- 每一步 SQLite entry 数量；
- user/assistant/tool 的最终数量；
- turn ID 集合；
- ACK 是否在 SQLite commit 后发出。

它没有注入真实的 `item/started -> delta -> item/completed` 生命周期，也没有断言：

- 每个 assistant item 完成后 stream 必须关闭；
- 相邻中间输出必须有不同稳定 ID 和 segment key；
- 中间输出、当前输出与最终回复的实际布局位置；
- 页面销毁和重建前后的用户/assistant 正文是否逐行一致；
- `input_ack` 已到、SQLite 未到的窗口是否仍保留用户消息。

因此“数量最终正确”仍可与“运行中全部拼成一段、重进暂时丢消息”同时成立。

## 新的真实闭环接收端

`conversation_live_segment_receiver_test.dart` 只伪造 Provider/app-server，以下均运行生产
实现：

```text
fake app-server notifications and turns
        -> real CodexProcess notification normalization
        -> real SessionManager
        -> real BridgeWebSocketServer
        -> real conversation_sync_v2 frames
        -> real BridgeService
        -> real SQLite staging/commit
        -> real SessionListCubit and ChatSessionCubit
        -> real chat process layout projection
```

测试生成 `receiver-timeline.jsonl`，逐阶段记录 row index、类型、turn ID、assistant ID、
正文、segment key、布局位置和 stream 状态。固定不变量为：

1. 每个 item 的 delta 期间 stream 为 active，`item/completed` 后立即归零。
2. 两条 commentary 使用两个稳定 assistant ID，不允许拼接或互相覆盖。
3. turn 运行中，前一段位于 intermediate，最新一段位于 current。
4. turn 完成后，两段 commentary 均位于 intermediate，final answer 位于 final。
5. SQLite 接管前后不重复；页面重建后所有 user/assistant row 与 segment 保持一致。
6. `input_ack` 已到而 SQLite 未到时，重建页面仍显示同一个 `clientMessageId`，且只有一条。

`scripts/test-conversation-chain.sh` 已把这一闭环加入核心链路门禁。旧数量测试仍保留，作为
分页、ACK 和大窗口回归的互补检查，而不再单独代表业务链路正确。

## 边界

- ACK-only user overlay 当前覆盖同一 App 进程内的页面退出/重进；完整 App 被系统杀死后
  仍依赖现有持久 outbox 与下一次 conversation sync 恢复。本修复没有新增第二套数据库。
- transient `ResultMessage` 属运行态指示，不是 provider 正文；重进一致性比较只针对用户
  和 assistant durable rows。测试仍记录完整 receiver rows，便于发现运行态额外变化。
- 本次不改变协议字段、SQLite schema、生产 Bridge 配置或原生 iOS 边界。
