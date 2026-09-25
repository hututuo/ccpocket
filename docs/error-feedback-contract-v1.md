# CC Pocket 错误反馈链路契约

这份文档固定两套机制的职责，避免再把“实时错误提示”和“事后取证上传”混成同一条链。

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
- `unsupported_message` 等协议错误仍由对应的待处理请求专门消费，不得重复生成聊天气泡。

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

## 3. 两套机制的边界

实时错误链回答“现在为什么失败”；诊断取证链回答“刚才手机当时到底收到了什么、显示了什么”。
诊断报告不能被当作实时聊天消息，实时错误也不能依赖用户手动上传报告才能被发现。

