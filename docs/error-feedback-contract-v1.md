# CC Pocket 错误反馈链路契约

这份文档固定三套机制的职责，避免再把“实时错误提示”“电脑端真实接收端”和“事后取证上传”混成同一条链。

## 1. 运行时错误链

```text
Provider / app-server
  → Bridge ErrorMessage(errorCode, sessionId?)
  → Mobile BridgeService
  → ChatMessageHandler / ChatSessionCubit
  → ErrorBubble 或全局连接诊断
```

用途是立即告诉用户：当前操作为什么失败、属于哪个会话、是否可以重试。

规则：

- 有 `sessionId` 的错误只能进入该会话的消息流。
- 没有 `sessionId` 的错误只能进入全局连接诊断，不能广播到所有会话。
- `errorCode` 必须保留到 UI；未知错误也要显示稳定错误码和原始安全消息。
- 会话归属错误必须带 `errorEventId`；可关联操作时同时带 `operationId`、`errorSource`
  和 `errorPhase`。Bridge 在会话广播边界补齐缺失的 owner/事件 ID，Mobile 按事件 ID
  去重，不再用正文、时间戳或“同文案”猜测是否重复。
- `unsupported_message` 等协议错误仍由对应的待处理请求专门消费，不得重复生成聊天气泡。
- 运行时/控制错误默认是 live-only 事件，不写入 canonical history；只有带有效
  `historyTurnId` 的 provider 原生错误才允许进入历史。这样历史补页不会把同一错误再投影成第二条气泡。
- Bridge 的消息 enrichment/history pipeline 失败时必须发送
  `bridge_session_message_processing_failed`（带当前 session owner），不能只写服务端日志后让手机表现为“消息消失”。

## 2. 诊断取证链

```text
Mobile 真实 Cubit / SQLite / 展示状态
  → 诊断 JSON
  → 现有 file_transfer_v2
  → Bridge 校验、归档和 durable receipt
  → Mobile completion / errorCode
```

用途不是替代实时错误，而是在实时链路无法说明问题时，保留手机当时看到的真实状态。

规则：

- 必须复用现有文件传输、断点、ACK 和回执，不新增第二套上传协议。
- 失败必须区分采集、暂存、传输、校验、身份、归档等阶段，并保留稳定 `errorCode`。
- 手机提示必须同时显示错误码和安全错误消息；日志可以保留更完整的阶段信息。
- 认证字段继续 fail-closed；拒绝本身也必须可诊断，不能只显示笼统的“上传失败”。

## 3. 电脑端真实接收端验证链

```text
fake Provider / app-server RPC
  → 真实 Bridge / WebSocket
  → 真实 BridgeService
  → 真实 SQLite staging/commit
  → 真实 Cubit / timeline layout
  → receiver-timeline.jsonl
```

这条链不是第三套生产消息系统，也不是“假 Bridge”。只允许伪造最上游的
Provider/app-server；Bridge、协议帧、Dart 解码、SQLite、Cubit 和布局投影都使用生产实现。
它的结果用于回答“错误或乱序究竟在哪一层产生”，并同时保留
`provider-message.jsonl`、`bridge-frame.jsonl`、`client-frame.jsonl`、SQLite、Cubit 和布局轨迹。

旧的数量/ACK 测试只能证明最终计数，不能证明中间过程边界、稳定 ID、页面重建和消息显示顺序。
因此真实接收端必须断言每个阶段的稳定 ID、turn/segment 边界、stream 完成状态和最终布局，不能
只断言“测试全绿”或“条数相同”。当前对应的黑盒入口是
`conversation_live_segment_receiver_test.dart`；它是错误定位门禁，不是用户可见的错误气泡。

## 4. 三套机制的边界

实时错误链回答“现在为什么失败”；诊断取证链回答“刚才手机当时到底收到了什么、显示了什么”。
电脑端真实接收端回答“错误或错序从 Provider、Bridge、协议、SQLite、Cubit、布局的哪一层开始”。
诊断报告不能被当作实时聊天消息，真实接收端也不能替代真机验收；实时错误也不能依赖用户手动上传报告才能被发现。
