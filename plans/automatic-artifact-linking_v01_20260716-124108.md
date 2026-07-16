# CC Pocket 自动文件链接方案 v01

Status: `accepted` — implementation baseline on `feature/automatic-artifact-links`

Date: 2026-07-16

Scope: 方案与实现基线。Bridge、Flutter 客户端和协议已在独立功能分支实现；
运行中的 8765 服务和 Codex 原始会话数据不在本轮修改范围内。

## 结论

自动转换应该由 CC Pocket Bridge 完成，系统提示词不应承担安全校验、
URL 生成或历史链接续期。

第一版只处理两个高置信来源：

1. Codex `imageGeneration.savedPath` 等明确的结构化产物路径；
2. 最终 `agentMessage.text` 的 Markdown AST 中，目标明确为本地文件的链接。

Bridge 保留 Codex 原文不变，额外附加稳定的 `ArtifactRef`。手机点击时只把
opaque `artifactId` 发回 Bridge，由 Bridge 重新校验文件并签发短期相对 URL。
这样既能自动打开当前文件，也能在 Bridge 重启、Tailscale/LAN 地址变化或
历史会话重载后重新生成有效链接。

## 实施结果

2026-07-16 用户确认进入实现后，本方案在独立分支
`feature/automatic-artifact-links` 落地。Bridge 实现提交为 `9ae7158`，移动端
实现提交为 `f856690`。最终边界比草案进一步收紧：

- preview 产物点击时使用 `resolve_artifact`，Bridge 只返回当前连接 origin 下的
  短期相对 URL；
- project-local source 不签发未使用的 HTTP token，而是使用独立
  `read_artifact_source` RPC；请求绑定 session、message、artifact 和安全的项目
  相对路径，Bridge 从当前 runtime session 重新取得 worktree/allowed roots；
- source 由 registry identity 授权后，通过同一个已验证的文件句柄限量读取，
  防止路径替换、symlink escape、历史引用静默改绑和大文件内存占用；
- `imageGeneration.savedPath` 必须先从 Codex 专用临时目录复制到 Bridge 私有
  managed storage，实时、Gallery/ImageStore 和历史 replay 均不得直接读取原始
  provider path；
- live 与 canonical history 走同一个 enrichment，原始 assistant text、rollout
  和 provider transcript 不写入 token 或被重写；
- Gallery metadata 内部保留稳定 provider session id；history repair 复用已有图片
  并补齐旧条目，因此 Bridge runtime id 改变后仍可见且不会重复复制；
- Phase 1、2 和历史/图片一致性的核心部分已实现；白名单 MCP、裸路径和目录
  浏览仍属于 Phase 4，默认不启用。

## 证据基线

### 官方协议

本机 Codex 为 `codex-cli 0.144.2`，对应官方 `rust-v0.144.2`。官方说明
app-server schema 与二进制版本绑定，集成方应以当前二进制生成的 schema 为准：

- [官方 app-server schema 说明](https://github.com/openai/codex/blob/a6645b6b8a656360fa16fb7e1c6721d0697d3d6a/codex-rs/app-server/README.md#L55-L62)
- [0.144.2 `ThreadItem` tagged union](https://github.com/openai/codex/blob/a6645b6b8a656360fa16fb7e1c6721d0697d3d6a/codex-rs/app-server-protocol/src/protocol/v2/item.rs#L222-L396)

关键事实：

- 普通 `agentMessage` 只有文本、阶段和 memory citation，没有通用
  `fileOutput` 或 `artifact` 字段；PDF、DOCX、XLSX、ZIP 等路径通常只是
  Markdown/文本的一部分。
- 官方结构化路径的语义很窄：`imageGeneration.savedPath` 是生成图片的保存
  位置；`imageView.path` 只表示 Agent 看过某张图；`fileChange.changes[].path`
  是编辑目标；`commandExecution.cwd` 是命令上下文。这些不能等价处理。
- MCP result 的 `structuredContent` 是开放 JSON，不存在跨工具统一的本地文件
  字段。
- 官方规定 `item/completed` 是 item 的最终权威状态，路径识别不应发生在
  streaming delta 上。

相关源码：

- [`agentMessage` 字段](https://github.com/openai/codex/blob/a6645b6b8a656360fa16fb7e1c6721d0697d3d6a/codex-rs/app-server-protocol/src/protocol/v2/item.rs#L240-L249)
- [`imageGeneration.savedPath`](https://github.com/openai/codex/blob/a6645b6b8a656360fa16fb7e1c6721d0697d3d6a/codex-rs/protocol/src/items.rs#L303-L330)
- [MCP result 类型](https://github.com/openai/codex/blob/a6645b6b8a656360fa16fb7e1c6721d0697d3d6a/codex-rs/app-server-protocol/src/protocol/v2/mcp.rs#L128-L142)
- [`item/completed` 生命周期](https://github.com/openai/codex/blob/a6645b6b8a656360fa16fb7e1c6721d0697d3d6a/codex-rs/app-server/README.md#L1351-L1389)
- [官方文件工作流说明](https://learn.chatgpt.com/docs/artifacts-viewer)：Codex CLI
  创建文件后通常报告输出路径，本身没有桌面文件预览层。

### 本机 120 个近期根会话抽样

抽样范围为 2026-06-12 至 2026-07-16 的最近 120 个非 subagent rollout：
111 个 `vscode` 会话和 9 个 `exec` 会话。只做分类计数，没有复制会话正文。

| 最终回复中的形态 | 出现次数 | 涉及会话 |
|---|---:|---:|
| Markdown 本地普通链接 | 2,017 | 64/120 |
| Markdown 本地图片语法 | 60 | 7/120 |
| Markdown HTTP(S) 链接 | 718 | 52/120 |
| 行内代码中的本地路径 | 1,316 个 span | 43/120 |
| 含本地路径的 fenced code block | 150 条消息 | 20/120 |
| 去掉链接、行内代码和代码块后仍有裸路径 | 37 条消息 | 12/120 |
| 真正的 `/artifacts/` HTTP 链接 | 4 | 1/120 |

2,077 个 Markdown 本地目标中：

- 1,574 个当前仍是普通文件；
- 92 个是目录；
- 411 个已不存在；
- 766 个带 `:line` 或 `:line:column`，大量链接是源码定位而非交付物；
- 689 个使用 `<绝对路径>` 包裹；
- 1,151 个包含百分号编码；
- 类型约为源码/配置 50.5%、文档/表格 30.9%、安装包/压缩包/App 5.8%、
  图片/媒体 4.3%。

另外，127,883 条工具结果中有 39,762 条含路径，涉及 99/120 个会话；它们
主要来自命令、补丁、测试和等待日志，不能统一转换。`view_image` 调用 451 次，
但语义是 Agent 查看输入。图片生成相关调用只有 5 次；历史 JSONL 仅保留短状态
字符串，无法靠历史文件恢复生成图片，必须在实时结构化事件中截获并持久化引用。

### 当前 CC Pocket 的直接故障点

1. Codex 的 `[文件](/Users/.../file.pdf)` 原样成为 assistant `TextContent`；
   Flutter 把 href 直接交给系统外部 launcher，手机无法访问 Mac 本地路径。
2. File Peek 只识别项目文件列表中的 backtick/裸相对路径；绝对 Markdown
   link 不走 File Peek，空格、中文和项目外产物也覆盖不完整。
3. 当前 `/artifacts/<token>` 默认仅存活一小时，最长 24 小时；token 只在
   Bridge 内存中，Bridge 重启后历史链接必然失效。
4. tool result 使用普通 `Text`/`SelectableText`，其中的 Markdown URL 不会被
   渲染成可点击链接。
5. 实时 `imageGeneration.savedPath` 先被压平成 `savedPath: ...` 字符串，再靠
   ASCII 图片路径正则回捞；空格和中文路径会丢。历史恢复却保留结构化
   `imagePaths`，因此实时与重连后的表现可能不一致。

## 输出分类与处理规则

| 来源 | 置信度 | 第一版行为 | 原因 |
|---|---|---|---|
| `imageGeneration.savedPath` | 高 | 自动注册 artifact | 官方明确的生成结果路径 |
| 最终 assistant Markdown `link`/`image` 的本地目标 | 高 | 验证后自动转换 | 模型明确表达了“这是链接” |
| 已知 MCP 的明确产物字段 | 高/中 | 仅白名单 schema | MCP 通用 result 是开放 JSON |
| 最终回复行内代码/裸绝对路径 | 中 | 第一版不改原文；后续可附加候选 | 可能是交付物，也可能是源码说明 |
| `fileChange.changes[].path` | 低 | 不发布；可用于源码跳转 | 编辑目标不等于交付物 |
| `imageView.path` | 低 | 不发布 | 查看输入/中间图不等于交付 |
| command stdout/stderr、diff、stack trace | 极低 | 永不自动扫描发布 | 本机样本中路径噪声数量巨大 |
| fenced code block、示例、glob、变量路径 | 极低 | 跳过 | 容易误发布或生成死链接 |
| 目录、不存在路径、HTTP(S) 链接 | 不适用 | 拒绝或原样保留 | artifact 只服务真实普通文件 |

源码定位和交付物必须分流：

- 项目内源码/文本且带行号：走 File Peek，并保留 line/column；
- PDF、DOCX、XLSX、PPTX、ZIP、安装包、图片、音视频等：走 Artifact Preview；
- 项目外但位于允许目录内的普通文件：走 Artifact Preview；
- 目录：后续单独设计目录浏览或显式打包，不冒充单文件 artifact。

## 目标架构

```text
Codex app-server item/completed
  -> Codex adapter 保留结构化候选
  -> Markdown AST 提取明确本地链接
  -> ArtifactResolver 做真实文件与 allowed-root 校验
  -> 原始 assistant/tool text 保持不变
  -> ServerMessage.artifacts 附加 opaque ArtifactRef
  -> 手机点击 artifactId
  -> Bridge 重新校验并签发短期 /artifacts/<token>
  -> 手机按当前 WebSocket origin 派生 HTTP 地址并打开
```

建议的客户端协议：

```ts
interface ArtifactRef {
  id: string;                 // opaque, stable; never a local path
  filename: string;
  mimeType: string;
  sizeBytes: number;
  kind: "source" | "preview";
  source:
    | "assistant_markdown"
    | "image_generation"
    | "structured_tool";
  textContentIndex?: number;
  originalHref?: string;      // 仅用于本地渲染匹配，不作为 resolve 参数
  line?: number;
  column?: number;
}

interface ResolveArtifactRequest {
  type: "resolve_artifact";
  requestId: string;
  sessionId: string;
  messageId: string;
  artifactId: string;
}

interface ArtifactResolvedMessage {
  type: "artifact_resolved";
  requestId: string;
  artifactId: string;
  relativeUrl: string;        // /artifacts/<short-lived-token>
  expiresAt: string;
}

interface ReadArtifactSourceRequest {
  type: "read_artifact_source";
  requestId: string;
  sessionId: string;
  messageId: string;
  artifactId: string;
  filePath: string;           // ArtifactRef.projectRelativePath only
  maxLines?: number;
}
```

约束：

- 手机不提交任意绝对路径；preview 只提交 `artifactId`，source 只能回传 Bridge
  已附带的安全项目相对路径，并由四元身份和当前 session roots 再次约束；
- 新字段放在 assistant/tool_result 顶层 `artifacts`，不要新增未知
  `AssistantContent` 类型，以便旧客户端忽略未知字段；
- 只有声明支持 `artifact_resolved` server message 的客户端才能发送
  `resolve_artifact`；
- 原始 provider transcript 和 Codex rollout 不写入临时 HTTP URL；
- 当前显式 `ccpocket-bridge share` 保留，作为人工兜底和回滚路径。

## 路径解析算法

第一版必须使用 Markdown AST，不能用全局路径正则：

1. 仅处理最终 `item/completed` 对应的 assistant message；
2. 枚举 Markdown `link` 和 `image` 节点，跳过 fenced code；
3. HTTP(S)、`data:`、`app:` 等非本地 scheme 原样保留；
4. 支持 POSIX、Windows drive/UNC、`file://`、`<...>`、空格、中文和
   百分号编码；
5. 对 `:line[:column]` 先尝试完整文件名，完整目标不存在时才剥离行列后缀；
6. 相对目标只相对该 thread/turn 的真实 `cwd` 解析；远程执行环境路径不能
   默认映射到 Bridge 主机；
7. 依次执行 `open`、`fstat`、`realpath`、canonical allowed-root、regular-file、
   大小和 MIME 校验；
8. 以 canonical path + device/inode + size + mtime 去重；
9. changed/gone/越界/目录只返回不可用状态，不创建链接；
10. 不在普通日志中记录源路径、capability token 或完整 URL。

## 历史会话与链接寿命

短期 URL 不能充当历史消息的身份。需要新增 Bridge-only 的持久
`ArtifactRegistry`，只保存描述符，不保存公开 token：

```text
artifactId -> sessionId + messageId + canonicalPath + file identity
           + filename + MIME + createdAt + lastAccessAt
```

建议行为：

- 实时消息：识别后登记 descriptor，发送 `ArtifactRef`；
- 历史 replay：重新跑同一高置信解析器，并按 session/message/path identity
  去重，旧会话中仍存在的本地文件可重新变成可点击项；
- 点击：重新校验 allowed root 和文件 identity，再调用现有 ArtifactStore
  签发短期 token；
- Bridge 重启：registry 仍在，token 重新签发；
- LAN/Tailscale 地址变化：客户端使用相对 URL 和当前连接 origin，不保存旧
  绝对地址；
- 文件改变或被替换：返回 `file_changed`，不得静默把历史链接指向新内容；
- 会话删除/归档策略：descriptor 跟随会话清理或进入可回收状态；
- `generatedImage`/image generation：实时收到结果时立即登记或复制到受控存储，
  不依赖信息不足的历史 JSONL。

## 系统提示词的角色

不把系统提示词作为主方案。它做不到：

- 验证路径是否真实、是否越过 allowed roots；
- 生成安全 capability token；
- 感知当前 LAN/Tailscale 地址；
- 在 Bridge 重启后给历史链接续期；
- 让 tool result 的纯文本自动变成可点击控件。

完成协议能力后，可以增加一个 CC Pocket 会话级、可关闭的轻量提示：要求
Codex 对“用户要拿走的最终文件”使用明确 Markdown 本地路径链接，不让模型
自行构造网络 URL，也不要求模型主动运行 `share`。它只提高识别召回率，不参与
安全决策。

## 分阶段实施

### Phase 1：高置信 Bridge enrichment

- 新增独立的 Markdown candidate extractor、ArtifactResolver 和持久 registry；
- 在 `processItemCompleted()` 把 `imageGeneration.savedPath` 保留为内部结构化
  candidate，不再先压成字符串；
- 在 SessionManager 历史入库前 enrich 完整 assistant/tool_result；
- 仅启用 `imageGeneration.savedPath` 和明确 Markdown 本地 link/image；
- 不处理裸路径、命令输出、diff、`imageView` 或目录；
- 通过 `BRIDGE_AUTO_ARTIFACTS=0` 可整体关闭，现有显式 share 不受影响。

### Phase 2：Flutter 渲染与按需 resolve

- assistant/tool_result 模型增加可选顶层 `artifacts`；
- Markdown link tap 先查 `ArtifactRef`，匹配时发送 `artifactId`，否则沿用外部
  URL handler；
- source ref 通过独立、不可离线排队或重放的 `read_artifact_source` 进入 File
  Peek；preview ref 显示附件 chip 并按需换取相对 URL；
- tool result 不再依赖 Markdown 是否渲染；图片生成的 savedPath 也能显示附件；
- `ChatMessageHandler` 重建 assistant 消息时必须保留 artifacts 和 message id。

### Phase 3：历史修复和图片一致性

- `thread/read`、历史转换和 JSONL fallback 共用同一 enrichment；
- 历史消息点击时重新签发 token；
- 实时与历史 image generation 使用相同结构化路径；
- 将可恢复的旧本地 Markdown 链接转为 refs，不修改 Codex 原始 rollout；
- 加入 registry 清理、容量上限和会话删除联动。

### Phase 4：谨慎提高召回率

- 只为明确白名单 MCP 工具读取 `structuredContent.output_file/filePath`；
- 对最终回复的行内代码/裸路径使用“存在的普通文件 + allowed root + 交付语境”
  组合规则，并默认只显示候选 chip，不篡改原文；
- 以匿名统计观察误识别率，再决定是否默认开启；
- 目录浏览/打包另立方案。

## 预计代码边界

Bridge：

- `packages/bridge/src/codex-process.ts`
- `packages/bridge/src/session.ts`
- `packages/bridge/src/sessions-index.ts`
- `packages/bridge/src/parser.ts`
- `packages/bridge/src/websocket.ts`
- 新增独立 `artifact-candidate`、`artifact-resolver`、`artifact-registry` 模块

Flutter：

- `apps/mobile/lib/models/messages.dart`
- `apps/mobile/lib/services/bridge_service.dart`
- `apps/mobile/lib/services/chat_message_handler.dart`
- `apps/mobile/lib/widgets/bubbles/assistant_bubble.dart`
- `apps/mobile/lib/widgets/bubbles/tool_result_bubble.dart`
- `apps/mobile/lib/theme/markdown_style.dart`

现有 `artifact-store.ts`、HTTP 预览和下载路由继续复用，不重新实现文件服务。

## 验证门槛

必须覆盖：

- 普通 Markdown link、image link、`<...>`、百分号编码；
- 空格、中文、emoji、Windows drive/UNC；
- `:line`、`:line:column` 与文件名本身含冒号的优先级；
- 相对路径、绝对路径、项目外允许路径；
- 目录、不存在、超大、不可读、symlink escape、changed/gone；
- HTTP(S)/data URL 原样保留；
- fenced code、shell stdout、diff、stack trace 不转换；
- source ref 走 File Peek，preview ref 走 Artifact Preview；
- `imageGeneration.savedPath` 含空格/中文时实时与历史一致；
- MCP base64 图片与 Gallery 现有行为不回归；
- Bridge 重启后历史 ref 可重新签发；
- LAN/Tailscale 地址变化后使用当前 origin；
- 新客户端 capability、旧客户端忽略字段、旧 Bridge 的降级行为；
- 原始 assistant text、Codex rollout 和 provider transcript 字节不变。

提交实现前的建议验证顺序：

1. candidate/resolver/registry 单元测试；
2. Codex adapter 与 SessionManager 集成测试；
3. WebSocket protocol 和历史 replay 测试；
4. Flutter model、Markdown tap、tool result widget 测试；
5. Bridge 全量测试、TypeScript、production build；
6. Flutter analyze/test/build；
7. 新构建单实例运行，分别用 LAN 和 Tailscale 真机点击；
8. 重启 Bridge 后重新打开同一历史会话，确认链接可重新签发。

### 2026-07-16 实施验证

已完成的本地门禁：

- Bridge 全量测试通过：43 个 test files、950 个 tests；
- `npx tsc --noEmit -p packages/bridge/tsconfig.json` 通过；
- `npm run build --workspace=packages/bridge` 通过，构建版本为
  `1.66.1-compat.2`；
- `npm pack --workspace=packages/bridge --dry-run` 通过，自动 artifact 模块
  已进入发布清单；
- `git diff --check` 和四份 Flutter ARB JSON 解析通过；
- 8766 clean-env 隔离实例启动成功，`/health`、`/version`、WebSocket
  capability/list_sessions 均通过；该实例 HOME、allowed roots、registry 和 prompt
  history 均与 8765 隔离，会话数为 0；
- 使用包含中文和空格的 `报告 final.txt` 做显式 share 冒烟，preview、content、
  download 均返回 200，content/download 与源文件逐字节一致，下载响应为
  attachment；冒烟后 8766 已释放；
- 冒烟前后 8765 始终为 PID 58728、`1.66.0-compat.1`，7 个 sessions、1 个
  client；未重载、未安装新构建、未修改会话数据。

依赖审计仍报告上游基线已有的 8 项 production advisories（4 high、4
moderate，来自 Hono/Anthropic/MCP、undici、ws 等链路）；本轮新增的 `marked`
没有引入新的 advisory。依赖大版本维护不混入本功能提交。

尚未完成、不能冒充已经验收的门禁：

- 本机没有 Flutter/Dart SDK，因此本轮不能实际运行 `flutter analyze`、widget
  tests 或移动端构建；已有 Dart 测试与 UI 代码仅完成静态复核；
- 最新客户端没有部署到手机，LAN/Tailscale 真机点击和 Bridge 重启后的同一历史
  会话点击仍待后续独立验收；
- `:line:column` 会完整保留并显示，但 File Peek 当前只自动滚动到行，尚未定位
  到列；
- Claude plan 的跨消息 Write-tool fallback、白名单 MCP、裸路径和目录浏览仍属于
  Phase 4，不纳入本次 Codex 高置信自动转换。

## 验收定义

- 明确 Markdown 指向、当前真实存在且在允许目录内的普通文件，可在手机一击
  打开；
- 源码定位不被误当下载产物；
- 工具日志、代码示例、目录和失效路径不会被批量公开；
- 历史消息保存稳定 `artifactId`，而不是保存一小时 URL；
- Bridge 重启和连接地址变化不会永久破坏仍有效的历史文件引用；
- 图片生成实时与历史表现一致；
- 关闭 feature flag 后完整退回当前显式 share 行为；
- 不重写 Codex 原始会话数据。

## 当前决策边界

本方案扩展而不替代 `docs/design/artifact-preview-links.md` 的 accepted 显式
share 设计；`ccpocket-bridge share` 继续作为人工兜底。实现只保留在
`feature/automatic-artifact-links`，不自动合并稳定分支、不推远端，也不在有
活跃会话时擅自重启 8765 Bridge。`BRIDGE_AUTO_ARTIFACTS=0` 可完整关闭自动 refs，
不会关闭显式 share。
