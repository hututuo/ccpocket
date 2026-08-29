# Content 与 Product Operation 合同

状态：`ROOT_DECISION / DESIGN_ONLY / MACHINE_BINDING_PENDING`

本文关闭 P-001–P-013 对 ContentRef、访问票据、附件、产品 mutation 与大对象承载方式的候选项。最终字段号、Schema 和 DDL 由 `contracts/` 生成；本文中的名称和不变量必须原样进入机器源。

## 1. 三个不能混用的对象

### 1.1 `ContentOffer`

表示尚未 finalized/verified 的上传、capture、artifact resolve 或 lazy materialization 工作。它可以包含 declared size/media/digest，但这些都不是已验证事实。Offer 有 owner、SourcePartition、expiry、capacity reservation 和状态；失败、取消或过期后不能被 timeline、Gallery、composer 或 artifact registry 当作内容引用。

状态：`OFFERED -> TRANSFERRING -> VERIFYING -> FINALIZING -> FINALIZED | FAILED | CANCELLED | EXPIRED`。

### 1.2 `ContentRef`

只在 byte object 已 finalized、可重新打开且完整性验证通过后创建。最小语义：

| 字段 | 规则 |
|---|---|
| `contentRefId` | SourcePartition 内稳定 opaque ref；不是路径、URL 或 ticket |
| `sourcePartition` | 完整三元组，不允许二元缩写 |
| `ownerFeatureId` | lineage/retention policy 的登记 owner；不是任意 mint/ticket 权限 |
| `lineage` | artifact/gallery/messageImage/capture/transfer/gitMaterialization/eventExport 等 sealed union |
| `mediaType` | 规范化 MIME；unknown 使用 typed octet-stream，不猜扩展名 |
| `sizeBytes` | verified UInt64；所有消费者先做容量检查 |
| `digest` | 必需 `{algorithm:"sha256", valueHex}`；小写 64 hex |
| `objectGeneration` | 文件替换、重新物化或 GC 后重新建立时改变 |
| `createdAt` | 诊断/retention；不参与身份、顺序或 fingerprint |
| `securityClass` | public-to-owner/sensitive/secret-derived 等封闭枚举 |

物理 blob store 可以按 SHA-256 去重，但 `ContentRef` 的授权、lineage 和 retention 永远按 SourcePartition/ref 隔离；digest 相同不能跨 source 推导访问权。

### 1.3 Content 的五种责任

| 责任 | 唯一 owner | 说明 |
|---|---|---|
| semantic/schema | `ContentContractRegistry` | 定义 Offer/Ref/Ticket/Attachment、lineage、error、limit；机器源唯一 |
| ref mint 与 lineage commit | `ContentReferenceService` | 只有 finalize verification 通过后 mint ContentRef；feature backend 不能自造 ref |
| bytes | `ContentBlobBackendRegistry` | 每个 lineage/namespace 恰好一个已注册 backend；现有 Artifact/Image/Gallery/Transfer/Capture store 作为 backend 适配 |
| retention | feature `ContentNamespacePolicy` + `ContentGcCoordinator` | feature 声明 pin/TTL/size/clear，GC 统一执行；不能跨 namespace 删除 |
| ticket | `ContentAccessTicketIssuer` | 从 authenticated context 对 Offer 或 Ref 发短期 sealed-target ticket；backend 不自行发 URL/token |

这些都是 ProductPlatform shared service 的窄职责，不是 Session Kernel 新核心。物理实现可以把 reference、backend registry、ticket issuer 组合进同一进程服务，但 registry/manifest 必须保留五列，禁止多个 writer 或一个“万能 ContentStore”绕过 lineage/retention policy。

### 1.4 `ContentAccessTicket`

短期、可撤销、method/range 受限的 HTTP capability。它绑定：ticketId、authenticated actor、完整 SourcePartition、sourceEpoch、connection-or-lease generation、sealed target、issued/expiry、revocation epoch、nonce：

- `OFFER_TARGET` 只允许对 exact offerId/generation 做 PATCH/HEAD-upload-offset/finalize，并限制 offset、maxBytes 和 declared media；
- `REF_TARGET` 只允许对 exact contentRefId/objectGeneration 做 HEAD/GET，并限制 range/maxBytes；
- 两类 target 互斥，不能让尚未 finalized 的 offer 借用 ref 读取权限，也不能用 finalized ref ticket 继续上传。

ticket/token/URL 不写 timeline、canonical replica、通知或诊断正文。

SHA-256 不在 ticket 重复存储：客户端先从授权 control response 得到 `ContentRef`，再用 HTTP ETag/Digest 与下载字节验证。ticket 只证明“谁在什么时间能对哪个 object generation 做什么”，不成为内容事实。

## 2. `ComposerAttachmentRef`

composer attachment 是 immutable operation input，不是文件路径或上传任务：

- `attachmentId`：Mobile local intent 内稳定；
- `contentRef`：必须 finalized 且 SourcePartition 与 target thread 相同；
- `displayName`：安全 UTF-8 basename，最多 255 bytes；
- `disposition`：`INLINE_IMAGE` 或 `CODEX_FILE_REFERENCE`；
- `transferReceiptId`：证明 landing/finalize，但 receipt 不能替代 ContentRef；
- `providerBindingHint`：只允许 adapter 注册的 typed hint，不能传任意 provider DTO。

`START_TURN` fingerprint 包含 attachmentId、ContentRef identity/digest、displayName、disposition 和 expected target head；不包含 ContentAccessTicket、临时路径、connection epoch 或 Unicode-normalized 副本。用户在显式 Send 前删除 attachment，不会发送或创建 operation。

## 3. Product operation registry

ProductPlatform mutation 使用与 Session Kernel mutation 相同的 `OperationHeader`、RFC 8785 fingerprint、authenticated actor、admission/queue/dispatch/terminal/reconcile 和 error envelope。差别只在 typed family/variant 与 executor；不建立第二 ledger、generic command 或万能 product gateway。

每个 descriptor 必须声明：`operationKind`、owner feature、typed body Schema、target Schema、required assurance、offline policy、queue lane、delivery/replay/reconcile、capacity、error union、executor、accepted/canonical-or-domain observation、negative vectors。

### 3.1 必须注册的 sealed variants

| Family | Variants | Executor / observation |
|---|---|---|
| `connectivity` | `REMOTE_SESSION_STOP`, `TRUST_PRINCIPAL_REVOKE` | Connectivity/Identity service；readback runtime/trust revision |
| `transfer` | `TRANSFER_LAND_FINALIZE`, `TRANSFER_CANCEL` | TransferService；finalized ContentRef 或 cancelled transfer |
| `file` | `FILE_CREATE`, `FILE_WRITE`, `FILE_MOVE`, `FILE_TRASH`, `FILE_DELETE_PERMANENT` | FileService；exact identity/revision re-stat |
| `gallery` | `GALLERY_IMPORT`, `GALLERY_DELETE_OWNED` | GalleryService；paged index readback |
| `git` | `GIT_STAGE`, `GIT_UNSTAGE`, `GIT_BRANCH_CREATE`, `GIT_CHECKOUT`, `GIT_COMMIT`, `GIT_FETCH`, `GIT_PULL`, `GIT_PUSH`, `GIT_REVERT`, `WORKTREE_CREATE`, `WORKTREE_REMOVE` | GitService；HEAD/index/worktree/remote generation readback |
| `capture` | `SCREENSHOT_CAPTURE`, `VIDEO_RECORDING_START`, `VIDEO_RECORDING_STOP`, `CAPTURE_DELETE`, `EVENT_RECORDING_START`, `EVENT_RECORDING_STOP`, `EVENT_RECORDING_DELETE`, `CAPTURE_EXPORT` | CaptureService；capture state/ContentRef/index readback |

暂停/恢复 transfer、选择本地 route、编辑 Mobile preference 等纯本地且可逆的动作可以是 feature-local state transition；一旦请求 Bridge 执行有副作用的动作，就必须使用 registry 中的 typed operation。

## 4. assurance 与确认

| Tier | 动作 | 默认 UX | step-up |
|---|---|---|---|
| A0 | bounded read、status、preview、diff page | 无二次确认 | 不需要 |
| A1 | stage/unstage、fetch、screenshot、transfer cancel | 显式 tap + stale precondition | 不需要 |
| A2 | create/write/move/trash、branch/checkout/commit/pull/push、video/event start/stop、Gallery delete | 明确 summary sheet | 由 feature policy；默认文件 mutation 使用既有 exact password/biometric proof，Git 不借用该 proof |
| A3 | permanent delete、revert all、forced worktree remove、trust revoke、删除唯一 recording | 红色 destructive sheet + exact effect disclosure | file permanent delete 使用 exact step-up；其他动作默认 authenticated actor + red confirmation，未来提高 assurance 必须新 policy revision |

所有 tier 都需要 OperationKernel precondition 和 typed fingerprint。确认 UI 不是 authority；Bridge 必须重新验证 target/generation/actor。Git hunk SHA-1 只是 stale domain evidence，不是 operation fingerprint 或 content digest。

字符串 canonicalization 只做 Schema 明示的 validation：按 UTF-8 bytes 检查长度，拒绝 NUL/控制符、路径分隔符、`.`/`..` 等危险结构；不做 NFC/NFD/NFKC、locale case-fold 或平台文件系统 normalization。title 原样通过或整项拒绝。若 landing collision policy 生成可见 suffix，request 必须同时携带原始 `requestedName` 与预览确认过的 `effectiveName`，fingerprint 同时覆盖二者；Bridge 仍在 commit 时 no-clobber 复核。

## 5. 大对象承载

- Git status、目录、diff 和 recording index 默认使用 generation-scoped bounded paging；page token 绑定 SourcePartition、object/generation、query digest 和 expiry。
- 用户请求下载、分享、复用，或单个稳定结果无法在 64 KiB control envelope 内分页表达时，executor 将该 immutable generation 物化为 ContentOffer，finalize 后返回 ContentRef。
- event JSONL、screen video、image、artifact/file bytes 和 export archive 始终走 ContentRef/content plane。
- control response 只含 descriptor、page metadata、ContentRef 或 offer state；绝不塞大 base64/raw JSONL/diff。
- 两页属于不同 generation 时 fail stale，不能拼接。

## 6. 旧数据与“v2”命名

旧 route-keyed 或 `(bridgeInstanceId,codexSourceId)` 二元 cache/session projection 不导入、不在 runtime 读取，也不建立迁移 adapter。现有 route/credential/product preference 若其 store 可独立验证，可继续由 Connectivity 模块保留；它们不能恢复成 canonical data identity。

Conversation Sync V2 不存在任何 runtime fallback。现有独立文件传输协议若在产品能力实施时继续复用，必须显式命名 `FT/2`；新增 digest/finalize generation 命名 `FT/3`。`FT/2`/`FT/3` 只属于 P-006 content transport，不能写作模糊的“v2/v3”，也不能写 timeline、operation terminal 或 Session Kernel checkpoint。

## 7. 故意失败向量

1. ContentOffer 未 finalize 就生成 ContentRef；
2. ticket 跨 actor/source/method/range/objectGeneration；
3. ticket URL/token 持久化进 timeline/replica；
4. digest 相同内容跨 SourcePartition 获得访问；
5. ComposerAttachmentRef 引用路径、expired ticket 或未 verified receipt；
6. Product module 绕过 OperationKernel 直接执行 Bridge mutation；
7. generic product command 或 unknown sealed variant；
8. Unicode-normalized payload 与原输入共用 fingerprint；
9. Git A1/A2/A3 action 缺 exact generation/confirmation；
10. diff page 跨 generation 拼接；
11. 64 KiB 以上 control frame 回退成 base64；
12. FT/2 被当成 Conversation Sync V2 fallback；
13. 二元/route-keyed cache 自动导入为完整 SourcePartition；
14. permanent file delete 使用邻近路径的 step-up proof；
15. capture finalize 失败却发布 ContentRef。

以上 core-facing binding 已由根设计冻结，但只有全部进入机器 registry/schema 并具有 negative vectors 后，D04 才能从 `DRAFTED` 升级为 `STATIC_VERIFIED`；缺少任一机器约束都不得用文档结论冒充冻结门禁通过。
