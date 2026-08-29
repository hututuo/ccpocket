# Phase 1：Identity / Authority / Receive / Cache / Order / Live 草案

状态：`DRAFT_FOR_ROOT_INTEGRATION / DESIGN_ONLY / IMPLEMENTATION_NOT_AUTHORIZED`

本草案只修订原 `CCPocket-Codex-Kernel-Redesign-20260829` 的单一 Codex Session Kernel。它不建立第二个 history core、Mirror writer、V2 adapter、legacy runtime 或多 Provider 产品核心；`CatalogRead`、`CanonicalProjectionWriter`、`LiveObservation` 仍是同一 Session Kernel 内部 owner。设备/route/配对仍由现有宿主模块提供 authenticated source port，不迁入 Session Kernel。

## 0. 绑定身份、事实等级与边界

| 项目 | 绑定值 |
|---|---|
| 工作树 | `/Users/developer/AI agent/Codex/_keep/projects/ccpocket-worktrees/ccpocket-v4-design-p1-identity-read-20260830` |
| branch | `codex/v4-design-p1-identity-read-20260830` |
| 起点 | `d152b118045264abeb8a1760b94113e323e46283` |
| 当前源码事实基线 | `main@a706200233c55cc82d7a17e433f80f132d0f280d`, tree `ac85f620445151f45eda856f55f4b96ee442f41a`，已被当前设计分支包含 |
| 原设计基线 | `04-original-proposal-evidence/CCPocket-Codex-Kernel-Redesign-20260829/FULL_DESIGN.md`，ZIP SHA-256 `d5c33a5455a1f1375efd4b68e0bb91844a5e6467c7115b3a204b4ea1faeeef76` |
| v4 输入包 | SHA-256 `d0f597cc089850214ec5aece824a3eb0265e20e0ce0e0bbef27add1381f0e257` |
| 生产/迁移/8765/发布 | `NOT_AUTHORIZED / NOT_RUN` |

本文使用四种事实标签：

- `FIXED_DECISION`：已在 `01-INPUT-AND-DECISION-LOCK.md` 或当前长期决定中固定；
- `SOURCE_PRESENT`：精确源码中有入口或现有行为，但本轮没有证明运行时语义；
- `DESIGN_AMENDMENT`：为关闭 P0/P1 而提出的最小必要合同修订；
- `EXPERIMENT_REQUIRED`：当前 Provider build 的 identity、cursor、order、terminal、snapshot 或容量语义没有实验证明。

时间、标题、正文、IP、URL、到达次序、数组位置和数据库插入顺序一律不能从 `EXPERIMENT_REQUIRED` 被提升为 identity 或 order proof。

## 1. 结论先行：保留什么，修改什么，删除什么

| ID | 原基线语义 | 处置 | 最小修订 | 原因/审查绑定 |
|---|---|---|---|---|
| P1-R01 | 一个 Codex Session Kernel，内部 owner 分责 | `KEEP` | 不拆多核心，不增加另一个 timeline DB/runtime | v4 固定方向；P0-12/P1-05 |
| P1-R02 | Provider durable history 是最终历史事实权威 | `KEEP` | cache 只能保存验证后的 materialization；不能反写 Provider | FIXED_DECISION |
| P1-R03 | Provider thread/turn/item + runtime fence | `AMEND` | 加入 computer/Bridge identity/Bridge instance/route/Codex source 分层；业务 key 使用完整 source partition | P0-02/K-002/P-001 |
| P1-R04 | 客户端 `device_id` 参与 interaction claim | `DELETE` | actor 只由 authenticated connection context 注入；payload 中同名字段至多做一致性检查 | P0-03 |
| P1-R05 | `EvidencePage`、segment、edge、last-good | `KEEP_AND_AMEND` | 把 Provider build/capability/read request/response/coverage/order evidence 变成可持久、可核验字段 | P0-14/P1-01/P1-09/P1-10 |
| P1-R06 | app-server page 或 rollout reader 可作为 bounded reader | `KEEP_CONDITIONAL` | 每个策略须按精确 build 认证；无安全 reader 时 capability fail closed | E-CODEX-READ-CONTRACT/UNK-002/UNK-012 |
| P1-R07 | timestamp/body/index fallback item identity | `DELETE` | 无 stable ID 时只建立 read-local structural locator，不能跨 read 合并或连 island | 当前 `sessions-index.ts` / `conversation-content-sync.ts` / `conversation-sync-v2.ts` 弱兜底 |
| P1-R08 | partial cache + gap + order proof | `KEEP_AND_AMEND` | coverage island 为第一等对象；无 proof 的边界永久保持 typed Gap，直到新 evidence 关闭 | FIXED_DECISION/P0-14 |
| P1-R09 | last-good | `KEEP_AND_AMEND` | head 是 per source/thread/read-semantics 的 CAS；empty 必须有 exact-scope completeness proof | FIXED_DECISION/P0-14 |
| P1-R10 | live memory overlay | `KEEP_AND_AMEND` | 四类 producer 进入唯一 LiveObservation owner；绝不混入 canonical candidate/sync event/SQLite | FIXED_DECISION/K-006 |
| P1-R11 | live 与 canonical 合并 | `AMEND` | 只有 stable provider turn/item identity 可原位 promote；正文/时间/近似 UUID 不得 alias | 当前源码仍存在弱 matching |
| P1-R12 | Bridge single writer / Mobile single writer | `KEEP_AND_AMEND` | Bridge head transaction 与 Mobile durable inbox/apply/readback/ACK 明确为唯一写入口 | P0-07/P1-09/P1-10 |
| P1-R13 | 当前 `conversation_sync_v2` / Mirror / route provisional cache | `DELETE_AS_TARGET` | 只保留 characterization fixtures 和已证失败语义，不作为新运行时 fallback | FIXED_DECISION/P0-13 |
| P1-R14 | Claude/unbounded legacy read | `DEFER_UNREACHABLE` / `DELETE` | Claude 只留内部不可达 typed seam；禁止 whole-read 隐式降级 | FIXED_DECISION |

## 2. 唯一语义字典

### 2.1 产品、连接和数据身份

| semantic_id | 术语 | 定义 | 唯一 owner / 执行位置 | durability | 明确不是 |
|---|---|---|---|---|---|
| SID-001 | `Computer` | Mobile 产品层的一台电脑展示主体；由用户别名和一个已验证 Bridge signing identity 归组 routes | 现有 `MachineManagerService` / device-route repository | Mobile local product state | 不是 IP、route、Bridge data partition 或硬件 UUID |
| SID-002 | `BridgeIdentityId` | Bridge Ed25519 public key 派生的签名身份，用于证明多 route 指向同一 Bridge signing installation；它是跨 Bridge 的 source partition 前缀 | `BridgeIdentityStore` 与 Mobile key pinning | Bridge 0600 identity file + Mobile trust record | 不是鉴权 secret，不是 `bridgeInstanceId`，不是 route |
| SID-003 | `BridgeInstanceId` | Bridge 可持久状态实例的随机 opaque ID；Bridge 状态重建或明确重置后可以变化 | 独立 `BridgeInstallationStore`；原子创建并存于 Bridge private state，prompt-history 只能读取，不能继续拥有它 | Bridge private state | 不是 process PID、binary version、route 或 signing key |
| SID-004 | `ConnectionRouteId` | 一条可独立编辑、排序、删除的 LAN/Tailscale/DNS/SSH 连接配置；当前 `Machine.id` 继续承担此语义 | Mobile `MachineManagerService` | Mobile local | 不是 computer/data/source identity |
| SID-005 | `AuthenticatedActor` | 当前业务 envelope 的调用主体，由完成认证的 WebSocket connection context 注入；类型为 paired-device、API-key credential 或受限 open connection | Bridge transport auth context；application service 只接收已注入 actor | connection-lifetime；paired device trust 独立持久 | 不是 payload 自报 device ID、URL token 字符串或 route ID |
| SID-006 | `CodexSourceId` | Bridge `SourceRegistry` 首次登记一个 Codex authority 时生成并持久化的 opaque ID；`CODEX_HOME`、账号、配置和 app-server 只作当前绑定/再认证事实 | `SourceRegistry`；`codex-home.ts` 只提供 locator/config 输入 | Bridge private state | 不是目录路径或其 hash、app-server process、route、Bridge identity |
| SID-007 | `SourcePartition` | 跨 Bridge/Mobile canonical 数据分区 `(bridgeIdentityId, bridgeInstanceId, codexSourceId)`；Bridge 本机表可把前两项作为 installation metadata 的隐式常量，但 wire、manifest、Mobile FK 和导出必须显式完整 | Session Kernel Identity owner；Bridge/Mobile DDL 复合归属 | durable | 不是缓存 alias；旧 endpoint partition 不得晋升为 canonical |
| SID-008 | `ConversationId` | `(SourcePartition, providerThreadId)` 的 typed tuple；不再生成第二个与 Provider thread 竞争的 durable session ID | Session Kernel Catalog owner | durable provider fact/cache locator | 不是 runtime session ID、标题、项目路径 |
| SID-009 | `RuntimeAttachmentId` | Bridge 当前 active attachment 的临时别名，用于定位 process/control；可变且只在 authority fence 内有效 | `SessionManager` | memory / diagnostic projection | 不是 conversation identity |
| SID-010 | `ProviderTurnId` | Provider 返回且在目标 build 上经 probe 证明稳定的 turn identity | Codex adapter | durable provider fact | 缺失时不得用 startedAt/completedAt/turn ordinal 补成 stable ID |
| SID-011 | `ProviderItemId` | Provider 返回且在目标 build 上经 probe 证明稳定的 item identity；scope 至少含 SourcePartition/thread/turn | Codex adapter | durable provider fact | 不是 tool name、正文 hash、数组 ordinal 或 UI UUID |
| SID-012 | `EvidenceItemKey` | stable item ID 缺失时，绑定一个 read evidence + segment + structural ordinal 的 read-local locator；只允许在该 segment 内引用 | CatalogRead owner | durable cache locator，`identity_strength=READ_LOCAL` | 不是跨 read dedupe key；不能关闭 island 边界 |

### 2.2 fence、revision 和 delivery 语义

| semantic_id | 术语 | 定义/失效事件 | owner | 允许用途 | 禁止用途 |
|---|---|---|---|---|---|
| SF-001 | `connectionEpoch` | Mobile 每建立/替换一个 socket 单调推进；旧 socket frame 立即失效 | Mobile transport | 拒绝旧 connection work | cache identity、timeline order |
| SF-002 | `sourceEpoch` | 每次 authenticated `SourcePartition` 初次绑定或同 socket replacement 时由 Bridge 生成的新 epoch | Bridge Identity/Authority owner | fence durable subscription、read flight、mutation admission | source identity 本身 |
| SF-003 | `providerInstanceEpoch` | app-server/read process/socket identity变化时推进 | Codex adapter/runtime owner | fence in-flight Provider read 与 live observation | durable turn/item identity |
| SF-004 | `authorityGeneration` | exact runtime attachment/control owner/active turn 变化时推进 | SessionManager / control projection | stop/steer/interaction/live attachment | history revision或 source switch代替品 |
| SF-005 | `producerEpoch` | direct runtime、shared observer、detached observer 每个 live producer 生命周期的 opaque generation | LiveObservation owner | 丢弃 producer 的迟到 live | 跨 producer order；Provider refresh 属于 durable read，不是 live producer |
| SF-006 | `subscriptionId + streamSeq` | 一个 authenticated sourceEpoch 下的 durable publication delivery order | Bridge Sync publisher | replay、gap、ACK | timeline item order |
| SF-007 | `headVersion/headDigest` | CanonicalProjectionWriter 每次成功 head CAS 产生的本地 commit version/hash | Bridge writer；Mobile replica同值 | cache reuse、base CAS、publication apply | Provider revision或 live generation |
| SF-008 | `capabilitySnapshotId` | exact Provider build + method/schema/probe result 的 immutable fingerprint | Codex adapter certification owner | read strategy、evidence compatibility | 静态 generated type 版本 |

任何 API 只接收自己需要的精确 fence。不得重新引入一个万能 `generation` 字段。

## 3. Identity / authority 可执行模型

```text
Computer (product grouping)
  └─ BridgeIdentityId (signed route-grouping proof)
       └─ BridgeInstanceId (data-state installation)
            ├─ Route A / Route B / Route C (transport only)
            └─ CodexSourceId
                 └─ providerThreadId
                      └─ providerTurnId
                           └─ providerItemId | read-local EvidenceItemKey

authenticated WebSocket
  └─ AuthenticatedActor + connectionEpoch + sourceEpoch
       └─ providerInstanceEpoch / authorityGeneration / producerEpoch
```

### 3.1 authority promotion

连接只有依次达到以下状态才可成为 active source：

1. `ROUTE_SELECTED`：只知道 route；允许 transport 打开，不允许读取 canonical partition；
2. `BRIDGE_SIGNATURE_VERIFIED`：可验证 route grouping，仍不能推断 source；
3. `ACTOR_AUTHENTICATED`：connection context 已有 actor；open 模式只能得到受限 anonymous actor；
4. `SOURCE_ASSERTED`：Bridge 给出完整 `bridgeIdentityId/bridgeInstanceId/codexSourceId`、sourceEpoch 和 capability snapshot；
5. `SOURCE_VERIFIED`：Mobile 与用户选择/route hint 校验，无 mismatch；
6. `REPLICA_BOUND`：选择精确 SourcePartition，才可 subscribe/publish/ACK/重放 mutation；
7. `APPLICATION_READY`：catalog/status/priority head 与 runtime readiness 各自达门禁。

route 中保存的旧 Bridge/source 只能用于预热精确旧 partition；它不是本次连接的证明。预热内容可以在“离线、上次已验证 source”视图中读取，但不能在新 socket 下获得 active/writable 标记。握手 mismatch 后保留旧 partition 为离线 last-good，同时切换到新 partition，不 merge、不清空、不重放。

### 3.2 actor 注入

Transport 在调用 application service 前构造：

```ts
type AuthenticatedActor =
  | { kind: 'paired_device'; principalId: string; trustRevision: string }
  | { kind: 'api_key'; principalId: string; credentialRevision: string }
  | { kind: 'open_connection'; principalId: string; connectionEpoch: string };

interface ExecutionContext {
  actor: AuthenticatedActor;
  source: {
    bridgeIdentityId: string;
    bridgeInstanceId: string;
    codexSourceId: string;
    sourceEpoch: string;
  };
  routeClass: 'lan' | 'tailscale' | 'dns' | 'ssh_tunnel' | 'loopback' | 'unknown';
}
```

- `principalId` 是 server-side 派生的非 secret 标识；日志只记录 actor kind 和脱敏 digest。
- payload 不允许提供可授权的 `actor/deviceId`。为迁移期解析旧字段时，字段必须与 context 一致，否则 `ACTOR_MISMATCH`；一致也不增加权限。
- paired device 的 durable claim 可在重新认证后恢复；API-key/open actor 的 connection claim 默认在断线后失效。是否允许 API-key actor 获取跨断线 durable interaction claim 交给 operation/interaction 草案，不在 receive path 猜测。
- `open_connection` 只能访问显式允许的低权限 read surface；owner full-disk、diagnostic upload、mutation 和 durable interaction claim 继续 fail closed，除非另有已固定窄能力。

## 4. Provider bounded read 与 evidence 合同

### 4.1 唯一接口

`CodexProviderAdapter` 是唯一理解 `thread/list`、`thread/turns/list`、`thread/items/list`、rollout/SQLite fact reader 的位置。Session Kernel 只接收下列领域值，不接收 raw Codex DTO：

```ts
type ReadKind = 'CATALOG' | 'TURNS' | 'ITEMS';

interface ProviderReadSpec {
  source: SourcePartition;
  kind: ReadKind;
  threadId?: string;
  turnId?: string;
  cursor?: string;
  limit: number;
  direction: 'ASC' | 'DESC';
  detail: 'SUMMARY' | 'FULL';
  expectedCapabilitySnapshotId: string;
  expectedProviderInstanceEpoch: string;
}

interface ProviderReadEvidence {
  evidenceId: string;
  readSpecDigest: string;
  providerBuildId: string;
  capabilitySnapshotId: string;
  providerInstanceEpoch: string;
  strategy: 'APP_SERVER_PAGE' | 'ROLLOUT_WINDOW' | 'BOUNDED_WHOLE_THREAD';
  requestCursor: string | null;
  responseCursor: string | null;
  responseDigest: string;
  responseBytes: number;
  itemCount: number;
  snapshotToken?: string;
  terminal: 'PROVEN_TRUE' | 'PROVEN_FALSE' | 'UNKNOWN';
  authoritativeEmpty: boolean;
  withinPageOrderProof: OrderProof;
  outgoingBoundaryProof?: OrderProof;
  limitations: ProviderReadLimitation[];
}

interface EvidencePage<T> {
  evidence: ProviderReadEvidence;
  coverage: CoverageClaim;
  values: readonly T[];
}
```

`observedAt`、RPC latency 和日志 sequence 可以进入 diagnostic evidence，但不进入 identity、coverage 或 order proof。

### 4.2 capability certification

每个 `capabilitySnapshotId` 至少固定：CLI label、managed app-server label、executable SHA-256、protocol/schema digest、method/parameter/result/error binding、page/cursor/terminal/empty semantics、turn/item identity strength、单页容量和超限行为。

当前源码证明 `CodexProcess` 有 `listThreads`、`listThreadTurns`、`listThreadItems` 的 bounded-shaped 调用入口，但没有证明目标 runtime 接受所有方法、cursor 在并发 mutation 下稳定、`null` cursor 等于完整、turn/item ID 跨 live/read/restart/compact 稳定，或数组顺序可跨页拼接。因此这些全部是 `EXPERIMENT_REQUIRED`，分别由 `E-CODEX-READ-CONTRACT`、`E-CODEX-LIVE-IDENTITY` 与 `E-CORE-ORDER-PROOF` 关闭。

### 4.3 catalog read

- 只列 primary source kinds：`cli/vscode/exec/appServer`；subagent thread 不进入主 catalog。
- 当前源码物理边界作为 Phase 1 初始上限：Provider page `<=500`，单次 scan `<=10,000` rows，name `<=512` chars，summary/firstPrompt/path `<=4,096` chars。
- 达到 10,000、cursor 重复、不前进、snapshot 变化或 timeout 时，返回 `coverage=PARTIAL` + typed catalog Gap；不得把结果标记 complete。
- `nextCursor=null` 只有在该 build probe 已证明 terminal semantics 时才是 `PROVEN_TRUE`；否则 terminal=`UNKNOWN`。
- catalog empty 只有 exact query/snapshot/terminal 全部证明时才是 authoritative empty。否则保留 last-good catalog head，并发布 `CATALOG_EMPTY_UNPROVEN` degraded fact。

### 4.4 turn read

- 请求 `limit` 最大 200；普通 hot materialization 建议仍取最近 5 turns、最近 3 turns full，但这只是当前行为起点，不是 identity/order事实。
- 一个 page 的 turn 内部顺序与 `DESC` 返回数组需由 build probe 认证；当前代码中的 `reverse()` 只属 `SOURCE_PRESENT`。
- 有 `ProviderTurnId` 时，page 内每个 turn 建 island segment；无 turn ID 时只能使用 `(evidenceId,pageOrdinal,turnOrdinal)` read-local locator。不得用 `startedAt/completedAt/content anchor/occurrence` 制造可跨 read 的 turn ID。
- `turnsNextCursor` 是 opaque Provider locator，只能由 Bridge adapter 消费；Mobile 收到的是 source/thread/read-spec-bound paging token。

### 4.5 item read

- 请求 `limit` 最大 200，明确 `threadId + turnId`；无 Provider turn ID 时不能调用 item endpoint，回退为新的 bounded turn page，而不是伪造 turn ID。
- 单个 source item 超过 control/content inline limit 时返回 `ITEM_TOO_LARGE` 或 typed payload Gap/ContentRef；cursor 不前进，不能截断 item 后假装完整。
- strong `ProviderItemId` 可跨 page/read 匹配；缺失时 `EvidenceItemKey` 只在该 evidence segment 内有效。
- 当前 `codexThreadToSessionHistory` 的 `legacy-turn-${ordinal}`、`codex-item-${turn}-${ordinal}`，以及 `messageIdentity()` 的 serialized hash/source index 兜底全部标为 `DELETE_AS_TARGET`。

### 4.6 read state / error / unknown

Read attempt 状态仅为：

```text
CREATED → READING → VERIFYING → VERIFIED → COMMITTED
                     ├→ REJECTED
                     ├→ QUARANTINED
                     └→ FAILED
```

最低 typed errors：`CAPABILITY_UNKNOWN`、`METHOD_UNSUPPORTED`、`SOURCE_MISMATCH`、`STALE_SOURCE_EPOCH`、`STALE_PROVIDER_EPOCH`、`TIMEOUT`、`MALFORMED_PAGE`、`PAGE_TOO_LARGE`、`ITEM_TOO_LARGE`、`CURSOR_REPEATED`、`CURSOR_NON_ADVANCING`、`SNAPSHOT_CHANGED`、`IDENTITY_CONFLICT`、`ORDER_UNPROVEN`、`COVERAGE_UNPROVEN`、`EMPTY_UNPROVEN`、`HASH_CONFLICT`、`CAPACITY_EXCEEDED`。

所有失败都保留旧 last-good；失败 attempt 只保留有界 metadata/digest，不把 raw Provider payload 写入业务 timeline 表。

## 5. Cache identity、复用、失效与 islands

### 5.1 cache key

```text
CachePartition = (bridgeIdentityId, bridgeInstanceId, codexSourceId)
ConversationCache = CachePartition + providerThreadId
MaterializationScope = ConversationCache + canonicalReadSpecDigest
Island = MaterializationScope + materializationId + segmentId
```

`canonicalReadSpecDigest` 只包含影响 coverage/shape 的稳定语义，不包含打开时间、route、connection epoch、UI 页面或 retry count。

### 5.2 复用顺序

```text
Mobile compatible last-good coverage
  → Bridge compatible last-good coverage
    → Provider bounded read with recorded reason
```

Mobile hit必须使 Bridge content request 为 0；Bridge hit必须使 Provider content request 为 0。唯一允许 Provider contact 的 reason：`CACHE_MISS`、`EXPLICIT_REFRESH`、`INTEGRITY_FAILURE`、`RECORDED_EVICTION`、`CAPABILITY_INCOMPATIBLE`、`PROVIDER_INVALIDATION_PROVEN`、`GAP_REPAIR`。reconnect、reopen、widget rebuild、elapsed time、route change但source相同都不是 read reason。

二次打开若需要 metadata/order-proof read，必须记录 `SECOND_READ_REASON`、requests/bytes/latency，并由 `E-CORE-CACHE-REUSE` 验证预算；在证据前不得声称“零 Provider read”。

### 5.3 coverage island

一个 island 是在一个或多个 proof-connected evidence segments 中形成的线性有序范围。它包含：

- exact SourcePartition/thread/read semantics；
- segment internal order proof；
- first/last strong boundary identity（若存在）；
- coverage claim：`COMPLETE_SCOPE`、`PREFIX`、`SUFFIX`、`BETWEEN_ANCHORS`、`EXACT_TURN`、`EXACT_ITEM_PAGE`、`UNKNOWN_PARTIAL`；
- gaps before/after/between；
- immutable item payload hash、identity strength 和 provenance；
- capability/build compatibility fingerprint。

disconnected islands 不能按 timestamp、body、arrival、sourceIndex 或 SQLite rowid 拼成一条连续 timeline。Repository 返回 `TimelineSlice[] + Gap[]`；UI 在 island 边界显示 gap barrier/load action。一个 200-entry viewport可以横跨多个 island，但 gap 仍必须占据显式位置。

### 5.4 允许的 order/continuity proof

| proof | 可用条件 | 能证明什么 |
|---|---|---|
| `PROVIDER_PAGE_ORDER` | exact build probe 证明一个 response 内顺序 | 只证明该 segment 内部顺序 |
| `PROVIDER_SNAPSHOT_CHAIN` | 两页同一不可变 snapshot token，cursor chain 被认证 | 证明相邻 page edge |
| `CURSOR_CHAIN` | build probe 证明 cursor 在相应 mutation model 下代表紧邻后页 | 证明指定方向相邻；未认证时禁用 |
| `STRONG_BOUNDARY_OVERLAP` | 同 Source/thread/turn/item strong ID 且 immutable payload hash 一致 | 关闭两个 segment 的 overlap edge |
| `CERTIFIED_ROLLOUT_ADJACENCY` | read-only parser 绑定 file identity、upper bound、offset adjacency、rollback/partial-write规则 | 证明同 snapshot file range 相邻 |

任何 proof 冲突、cycle、重复 strong ID 不同 hash、edge 跨 source/thread，均 quarantine candidate。`sourceIndex` 只在一个 response/segment 内作为 ordinal，不跨 response。

### 5.5 Gap

`Gap` 是事实，不是错误字符串：

```ts
interface Gap {
  gapId: string;
  kind: 'BEFORE' | 'AFTER' | 'BETWEEN' | 'PAYLOAD' | 'COVERAGE_UNKNOWN';
  leftBoundary?: StrongBoundary;
  rightBoundary?: StrongBoundary;
  reason: 'NOT_LOADED' | 'ORDER_UNPROVEN' | 'CAPACITY' | 'READ_FAILED' |
          'SOURCE_CHANGED' | 'PAYLOAD_OMITTED' | 'PROVIDER_UNSUPPORTED';
  repair: 'CATALOG_PAGE' | 'TURN_PAGE' | 'ITEM_PAGE' | 'FULL_BOUNDED_REREAD' | 'NONE';
  repairToken?: string;
}
```

Gap token 绑定 SourcePartition/thread/read spec/headVersion/capability snapshot/expiry；旧 source 或旧 head 的 token 必须 `STALE_REPAIR_TOKEN`。

### 5.6 last-good promotion

Candidate 只有同时满足以下条件才可成为 head：

1. sourceEpoch/providerInstanceEpoch 仍与 read start 相同；
2. evidence build/capability/read spec 完整；
3. 每个 segment 有 internal order proof；
4. 所有新增 edge 有允许的 proof；
5. strong identity overlap 的 payload hash 一致；
6. coverage 准确表达，不把 partial 标 complete；
7. empty 是 exact scope 的 authoritative empty；
8. candidate manifest、page hash、总 hash和容量检查通过；
9. `expectedHeadVersion` CAS 成功；
10. canonical commit 与 durable publication metadata 在同一个 Bridge transaction 完成。

失败/timeout/malformed/partial-empty/quarantine 不能缩短或清空 head。authoritative empty 可以产生一个空 island/head，但必须保留 evidence，并只替换 exact scope；thread missing/delete/archive 是不同 typed fact，不能伪装 empty。

### 5.7 invalidation 与 eviction

| 事件 | canonical bytes | proof/head | live | 行为 |
|---|---|---|---|---|
| route 切换且身份/source相同 | 复用 | 复用 | 清旧 connection overlay | 新 handshake 后绑定同 partition |
| Bridge/source mismatch | 保留旧 partition | 不跨 partition复用 | 清 | 新建/选择新 partition，旧 partition离线可读 |
| provider process restart，同 source/build | 保留 | 保留；in-flight read废弃 | 清 | 推进 providerInstanceEpoch，按 gap/read reason修复 |
| Provider build/capability变化 | 保留可检查 bytes | proof compatibility 变 unknown；不得与新 evidence接边，直到 upgrade certification | 清 | last-good 可只读显示 degraded；新 read 独立 island |
| explicit provider invalidation | 保留审计或按删除策略清理 | exact scope head tombstone/CAS | 清相关 | 需要 Provider fact |
| hash/DB corruption | quarantine受影响 island | 回退到前一可验证 head | 不相关 | `CACHE_CORRUPT`，不得清全 partition |
| explicit cache purge/recorded eviction | 删除列明的 rebuildable namespace | 记录 eviction reason | 清相关 | 不删除 draft、outbox、settings、credentials、transfer checkpoints |

U-006（容量/保留/静态保护）仍为 `USER_DECISION_REQUIRED`。Phase 1 只冻结“每次 eviction 有持久 reason、清理 namespace 显式、last-good 不因 TTL/时间猜测失效”；不得先替用户选择永久 TTL/LRU/SQLCipher。

## 6. Live overlay、唯一入口和 canonical promotion

### 6.1 三类 live producer 只有一个 owner

现源码中的 direct runtime、shared observer 与 detached/external observer 进入同一个 `LiveObservationCore`。Provider refresh 不属于 live：它只能进入 `CatalogRead` 的 evidence→candidate→verify→canonical 路径；在 canonical commit 前既不可见也不能发 live overlay。

`LiveSourceArbiter` 对每个 SourcePartition/thread 选择一个 active direct producer：formal shared attachment 存在时不再创建第二 observer；只有 detached 且无 direct stream 时才建立 bounded read-only observer。切换窗口可能短暂重叠，但跨 producer alias 只允许 strong provider turn/item ID；否则保留独立 unanchored activity，不能正文去重。

### 6.2 live key 与状态

```text
LiveKey = SourcePartition + threadId + providerTurnId + providerItemId
          + producerKind + producerEpoch
```

无 provider turn/item ID 时使用 observation-local key，只在该 producerEpoch 内有效，不可 promote。live 状态：

```text
OBSERVED → ANCHORED → DISPLAYED → PROMOTED
     └→ UNANCHORED_ACTIVITY → EXPIRED
ANCHORED/DISPLAYED → CONFLICT → REPAIR_REQUESTED
任意非终态 → DROPPED_STALE_FENCE | DROPPED_CAPACITY | LOST_ON_RESTART
```

### 6.3 memory-only 硬约束

- Bridge live body 仅在 `LiveObservationCore` memory；Mobile 仅在 focused/current overlay memory；
- 不写 `segment_item`、`sync_event`、Mobile inbox、replica、隐藏 temporary history 或 diagnostic payload table；
- durable stream gap 由 canonical snapshot/reread修复，live gap 不 replay 成历史；
- Bridge/Mobile crash 后 overlay 丢失是预期行为；last-good 保持可读；
- current source bounds 作为初始防护：每 thread `<=256` live records / `<=512 KiB`，最多 `64` threads / `8 MiB` total；每 subscription pending overlay `<=1 MiB`、dedupe IDs `<=128`。超限发送 `LIVE_OVERFLOW` metadata并触发 bounded repair，不截断成 canonical；这些数值需 `E-CODEX-LIVE-IDENTITY` 与 `E-CORE-REPLICA-ACK` 实测后冻结。

### 6.4 promote 规则

只有后续 VERIFIED durable read 满足以下条件才原位 promote：

- exact SourcePartition/thread；
- strong ProviderTurnId + ProviderItemId 相同；
- build certification允许该 ID 跨 live/read 稳定；
- canonical payload hash 与 live final payload compatible；
- current focused source/producer fence仍可解释 overlay；
- canonical head transaction已提交且Mobile replica commit已完成。

canonical item 是事实权威。payload 冲突时 canonical 替换显示，live进入 `CONFLICT` 诊断；不能覆盖 cache。无 strong ID 的 unanchored live 在 durable coverage证明相应 active turn 已完整后整体退休，但不能靠文本把其中某条认成 canonical item。

当前 `conversation-sync-v2.ts` 中按 `clientMessageId + text + timestamp`、assistant content hash、近 1 秒 timestamp 或 synthetic UUID alias 的路径全部为 `DELETE_AS_TARGET`。sender-local outgoing 与 canonical user item 的合并规则由 operation草案基于 operation/provider correlation 冻结，不由 receive 文本匹配兜底。

## 7. Canonical sole writer、Mobile replica publication 与 ACK

### 7.1 Bridge 唯一 writer transaction

`CanonicalProjectionWriter.commit(candidate, expectedHeadVersion)` 是唯一可修改 materialization/head/publication 的入口。Adapter、observer、WebSocket handler、feature UI 均无写权限。

一个 commit transaction 必须：

1. 重新校验 SourcePartition/sourceEpoch/providerInstanceEpoch；
2. 插入 VERIFIED attempt/segments/items/edges/coverage/gaps；
3. 运行跨 source/thread/segment/head 复合约束；
4. CAS `materialization_head(expectedHeadVersion)`；
5. 计算/保存 head manifest hash；
6. 追加只引用该 head/materialization 的 durable publication record；
7. commit；
8. commit 后才通知 Sync publisher。

候选表不可被 Repository 查询；`STAGED/REJECTED/QUARANTINED` 数据无 visible head。

### 7.2 wire pressure（交给 Phase 1 wire owner 统一命名）

本草案不新增平行协议，只要求最终 durable/live envelope 至少表达：

- `authority.bind`：`bridgeInstanceId/codexSourceId/sourceEpoch/capabilitySnapshotId`；actor 不回显 secret；
- durable server envelope：强制 `subscriptionId/streamId/streamSeq/messageId/sourceEpoch`；
- catalog/read publication：`materializationId/headVersion/baseHeadVersion/readSpecDigest/coverage/islands/gaps/manifestHash/pageIndex/pageCount`；
- page item：strong provider identity或明确 `READ_LOCAL` locator、content hash、segment ordinal、ContentRef；
- commit frame：head manifest/hash + publication state；
- `replica.ack`：`persistedSeq/appliedHeadVersion/appliedManifestHash`；
- live envelope：`durability=MEMORY_ONLY`、source/provider/authority/producer fences、observation id/seq；不得进入 durable stream ACK；
- typed problem：本章 error codes + exact target/source；unscoped error不得投到每个会话。

Provider raw cursor、local file path、raw app-server DTO、route URL、正文 hash identity 和 payload self-reported actor 不跨 wire。Mobile paging token 由 Bridge 绑定 source/thread/read spec/head/capability/expiry。

### 7.3 Mobile 唯一 apply writer

`ReplicaApplyWriter`（当前 `ConversationContentSyncService → SessionCatalogCacheRepository` 路径的收敛目标）顺序固定：

```text
frame validation
  → sourceEpoch/subscription/streamSeq fence
  → inbox dedupe(messageId, streamSeq, payloadHash)
  → pages/manifest staging
  → commit frame verifies manifest + baseHeadVersion
  → one SQLite transaction applies islands/items/edges/gaps/head/checkpoint
  → same transaction commit
  → bounded readback(headVersion, manifestHash, row counts)
  → Repository publishes new immutable snapshot
  → ACK persistedSeq + appliedHeadVersion + appliedManifestHash
```

- 普通 page ACK 只表示 page/inbox durably staged；visible head不变；
- final commit ACK 只有在 domain apply + readback成功后发送；
- ACK丢失时 Bridge replay同 message；Mobile dedupe后返回相同 receipt；
- frame sequence gap只重建该 subscription，不清已提交 partition/head；
- base mismatch只清该 thread的 staging并请求 replacement，last-good继续可见；
- Repository/Cubit不能写SQLite或提前 publish；UI projection不参与 ACK；
- draft/outbox/credentials/settings/transfer checkpoints位于独立 local-state namespace，不对 rebuildable replica做 `ON DELETE CASCADE`。

## 8. crash、reconnect 与 source-switch 规则

| 场景 | 必须行为 | 禁止行为 |
|---|---|---|
| Bridge crash before canonical commit | candidate不可见；恢复时 attempt=`FAILED/ABANDONED`；返回旧 head | 根据内存 candidate发布 |
| Bridge crash after head commit before send | `sync_event/publication` 同 transaction 已在；重放 publication | 重读 Provider来猜是否提交 |
| Mobile crash during page staging | 保留/清理同 subscription staging；visible head仍旧 | partial page可见 |
| Mobile crash after apply before ACK | readback已保存；重放 frame时返回同 ACK | 重复插入/重建 head |
| Bridge/Mobile crash during live | 丢弃 overlay；显示 last-good；按 GAP_REPAIR bounded reread | 从 diagnostic/runtime buffer恢复成历史 |
| same source, provider process replaced | providerInstanceEpoch推进；丢 in-flight read/live；cache/head保留 | 清空会话或让旧 event继续写 |
| same Bridge/source via another route | 新 connectionEpoch；权威 handshake 后复用同 partition | route复制cache/queue |
| same socket source replacement | Bridge发新 sourceEpoch；旧subscription终止；Mobile保留旧partition并切新partition | 旧ACK/frame满足新source；跨source merge |
| Bridge identity/instance mismatch | 显示新电脑/新data partition；旧last-good离线保留 | 静默改route绑定或重放旧mutation |
| capability/build change | 旧bytes可读，proof compatibility降级；新read独立island，待upgrade probe | 旧cursor/edge自动沿用 |
| authoritative empty | 只替换exact proven scope，保留evidence | empty/error/timeout清整个thread |
| cache corruption | quarantine最小island/head，回退前一valid head | 清全source或draft |

## 9. DDL 压力与必需约束

### 9.1 Bridge（修订原表，不另建第二数据库）

| 原表/语义 | 必需修订 |
|---|---|
| `provider_build` | 保存 CLI/app-server labels、binary hash、schema digest；不可只存 version string |
| `provider_instance` | 复合归属 SourcePartition + providerInstanceEpoch + capabilitySnapshotId；process identity变化不可覆盖旧 row |
| `capability_snapshot` | immutable，唯一 `(provider_build_id, adapter_schema_digest, probe_digest)`；保存 method/cursor/identity/order capability flags |
| `session` | 跨端自然键为 `(bridge_identity_id,bridge_instance_id,codex_source_id,provider_thread_id)`；Bridge-local DDL 可由 installation metadata 隐式约束前两项，但禁止 provider thread global UNIQUE |
| `materialization_attempt` | 增 `scope_kind/scope_id/read_spec_digest/source_epoch/provider_instance_epoch/capability_snapshot_id/status/error_code/response_manifest_hash/head_eligible` |
| `materialization_segment` | 复合 FK 回 attempt/source/scope；存 request/response cursor、snapshot token、terminal、coverage、order proof、raw digest/bytes；page ordinal unique |
| `segment_item` | 复合 FK 含 source/thread/segment；`identity_strength` enum；strong ID unique scope为 source/thread/turn/item；READ_LOCAL key只在segment unique |
| `continuity_edge` | 两端复合 FK 必须同 source/thread/read scope；proof enum + proof digest；禁止 cross-session edge/cycle由writer guard测试 |
| `materialization_head` | PK `(source,scope,read_spec_digest)`；CAS head_version；复合 FK 只能引用 `head_eligible=1` candidate；manifest hash必填 |
| `sync_event` | 只引用已commit head/materialization；kind enum拒绝 live；durable source/subscription/seq必填；无任意 raw payload JSON |
| `client_checkpoint` | 复合 source + client principal + stream；ACK不得跨 sourceEpoch |

DDL/guard 故意失败样本必须证明：cross-source session merge、cross-thread edge/head、READ_LOCAL key跨segment复用、同scope双active head、非eligible attempt进head、live event写sync、hash格式错误、sourceEpoch旧CAS均失败。

### 9.2 Mobile replica

| 现有语义 | 必需修订 |
|---|---|
| route alias/provisional partition | canonical replica只能由 verified `(bridgeIdentityId,bridgeInstanceId,codexSourceId)` 建立；endpoint/logical alias仅作为外部 hint，不可成为 partition PK |
| `conversation_hot_windows` 单窗口 | 改为 head + islands/segments/items/edges/gaps；允许partial islands，不用一个 `entry_index` 假装全局连续 |
| timeline staging | manifest/page均绑定 sourceEpoch/subscription/materialization/head base；旧generation staging可清，active head不清 |
| inbox/checkpoint | stream/subscription/source/seq/hash均非空；duplicate相同hash幂等，不同hash quarantine |
| draft/local intents | 不 FK cascade 到 replica session/source；保留 stable source/thread locator、reattach metadata和独立删除策略 |
| publication | Repository只读 `applied_head` view；staging/live无查询入口 |

## 10. 容量、超限和 unknown

| 范围 | Phase 1 初始硬边界 | 超限结果 | 事实状态 |
|---|---:|---|---|
| Provider catalog page | 500 rows | 减页或 `PAGE_TOO_LARGE` | current source bound；Provider acceptance `EXPERIMENT_REQUIRED` |
| Catalog scan | 10,000 rows | partial coverage + catalog Gap | current source bound |
| Turn/item request | 200 rows | reject/decrease limit；不能截断并前进 cursor | current source/client parser bound；Provider semantics `EXPERIMENT_REQUIRED` |
| Control frame | 64 KiB；content budget 56 KiB | 分页/ContentRef/typed error | current source bound |
| Timeline publication page | 24 entries | next page | current source bound |
| One hot materialization | 512 KiB inline | payload Gap/ContentRef；不得静默裁正文 | current source bound，需 `E-CORE-REPLICA-ACK` |
| Inline message text | 40 KiB | ContentRef或PAYLOAD Gap | current source bound |
| Mobile local conversation product ceiling | 100,000 normalized entries / 64 MiB；render约200 envelopes | eviction/paging/explicit error，不降低产品上限 | accepted product boundary |
| Mobile staging | 2,000 rows / 128 pages / 8 MiB | abort candidate，last-good不变 | current source bound |
| Durable sync backpressure | 2 MiB outstanding+queued threshold | pause producer，超时typed gap | current source bound |
| Live per thread/global | 256 / 512 KiB；64 threads / 8 MiB | drop oldest overlay + `LIVE_OVERFLOW` + repair | current source bound，需 `E-CODEX-LIVE-IDENTITY` |

缓存永久保留/自适应 LRU/TTL/静态加密由 U-006 决定；Provider支持版本范围由 U-007 决定。边界未决不允许无界默认。

## 11. 必须故意失败的 fault vectors

| ID | 注入 | 预期 |
|---|---|---|
| FV-ID-01 | 两 route 指向同 signed Bridge/source | UI可归组 routes；data只有一个partition；route记录仍两条 |
| FV-ID-02 | 同 endpoint 更换 Bridge signing key/instance | handshake mismatch；旧partition不写不清；新partition隔离 |
| FV-ID-03 | 同 thread ID 出现在两个 CodexSourceId | 两份独立 session/cache/head；任何 global unique/merge失败 |
| FV-ID-04 | payload 自报另一 paired device ID | `ACTOR_MISMATCH`；server context actor不变 |
| FV-ID-05 | 旧 sourceEpoch frame/ACK/repair token | `STALE_SOURCE_EPOCH`；当前head/checkpoint不动 |
| FV-RD-01 | catalog cursor重复/不前进/在并发mutation后回卷 | partial+Gap；不标complete；last-good保留 |
| FV-RD-02 | turn/item无Provider ID，内容和时间与另一turn相同 | 建两个read-local locators；不得dedupe/拼接 |
| FV-RD-03 | 同 strong item ID 不同 payload hash | candidate quarantine；旧head字节不变 |
| FV-RD-04 | empty、timeout、malformed、partial、oversized依次刷新good head | 全部不替换head；只有proven exact empty可commit |
| FV-OR-01 | 两个合法island按相反到达顺序 | UI顺序只随proof graph；无edge则显示Gap |
| FV-OR-02 | timestamp单调但cursor/order未认证 | 不产生edge |
| FV-OR-03 | cross-thread/cross-source continuity edge/head | SQLite/Writer拒绝 |
| FV-LV-01 | runtime/sharedObserver重复同strong ID | active-source rule + strong ID alias为一个overlay；无strong ID则两个activity |
| FV-LV-02 | live正文相同、时间相近、ID不同 | 不alias、不promote |
| FV-LV-03 | producer/provider/source generation切换后迟到live | drop stale；canonical last-good不变 |
| FV-LV-04 | live期间Bridge/Mobile crash，DB快照审计 | 所有durable timeline/inbox/sync表无live body；恢复靠bounded read |
| FV-WR-01 | Bridge在candidate insert/head CAS/publication各点kill | 只出现旧head或完整新head；无半可见candidate |
| FV-WR-02 | Mobile在每页staging/apply/readback/ACK各点kill | 只出现旧head或完整新head；replay返回同receipt |
| FV-WR-03 | sequence gap/base mismatch | 仅重订阅或thread replacement；不清partition/last-good/draft |
| FV-CACHE-01 | 二次打开已覆盖range | Mobile hit=0 Bridge content requests；Bridge hit=0 Provider reads |
| FV-CACHE-02 | build/capability升级后用旧cursor连接新page | 拒绝edge，保留旧island degraded，直到probe认证 |

## 12. 当前源码定位与目标处置

| 源码 | 当前事实 | 目标处置 |
|---|---|---|
| `packages/bridge/src/bridge-identity.ts` `BridgeIdentityStore` | Ed25519 signing identity、signed `bridgeInstanceId` response 已存在 | `KEEP` security seam；补统一 instance owner/actor/source binding |
| `packages/bridge/src/prompt-history-store.ts` `bridgeInstanceId` | stable random instance 当前偶然存于 prompt-history store | `REWRITE_OWNER`：迁到独立 `BridgeInstallationStore`；prompt history只消费 |
| `packages/bridge/src/codex-home.ts` `codexSourceIdentity` | CODEX_HOME derived / explicit shared source ID 已存在 | `MINE_BINDING_FACTS`：路径可作 locator，最终 ID 由 `SourceRegistry` 生成并持久化，禁止用路径或路径 hash 作身份 |
| `packages/bridge/src/websocket.ts` `connectionAuth` / `sendSessionList` | paired device可得到server-side deviceId；API-key/open无统一 typed actor；session_list发布identity | `AMEND` transport context；业务handler不读payload actor |
| `apps/mobile/lib/models/machine.dart` | `Machine.id` 是route，保存Bridge identity/instance/source hint | `KEEP` route语义；Computer grouping留产品层 |
| `apps/mobile/lib/models/bridge_data_source_identity.dart` | authenticated pair和legacy route fallback并存 | `DELETE` legacy canonical fallback；route只作hint/offline locator |
| `packages/bridge/src/codex-process.ts` `listThreads/listThreadTurns/listThreadItems` | bounded-shaped RPC入口存在 | `KEEP` adapter I/O；加build/capability/evidence，无证据不启用 |
| `packages/bridge/src/local-features/conversation-sync-v2.ts` `readCodexCatalog/snapshotFor` | 500-page/10k catalog、bounded turns/items、last-good/backoff和live buffers存在 | `MINE_BEHAVIOR_AND_TESTS`；不保留v2 runtime owner |
| 同文件 `normalizeCodexTurns/anonymousCodexTurnAnchor` | 用started/completed time、content anchor、occurrence补turn ID | `DELETE_AS_TARGET`；改read-local locator |
| 同文件 `resolveObservedTurnScopes/equivalent*Alias/observedMessageIdentity` | 仍有text/time/hash/UUID weak merge | `DELETE_AS_TARGET`；只strong Provider ID promote |
| `packages/bridge/src/sessions-index.ts` `codexThreadToSessionHistory` | 无item ID时用turn/item ordinal构造跨层ID | `AMEND`：ordinal只作segment local locator |
| `packages/bridge/src/local-features/conversation-content-sync.ts` `messageIdentity` | 仍以serialized hash/source index/synthetic ID形成entry ID | `AMEND` identity strength + evidence scope；hash只做integrity |
| `packages/bridge/src/local-features/slots/conversation-sync-v2-protocol.ts` | identity/source/sequence/runtime overlay字段和容量解析已有事实 | `REPLACE_WITH_FINAL_PHASE1_WIRE`；保留有用边界，不保留v2/Claude/weak target |
| `apps/mobile/lib/features/session_list/cache/session_catalog_cache_database.dart` | source partition、hot window、staging、FK已存在；仍是单window模型 | `MINE_SCHEMA_TESTS`；改islands/edges/head/inbox约束 |
| `apps/mobile/lib/features/session_list/cache/session_catalog_cache_repository.dart` | atomic staging/commit、last-good、thread-scoped reset、alias merge存在 | `KEEP_BEHAVIOR_AMEND_OWNER`；删除provisional route merge，收敛ReplicaApplyWriter |
| `apps/mobile/lib/features/conversation_content_sync/conversation_content_sync_service.dart` | source/subscription/sequence fence、commit后ACK、runtime overlay不入SQLite已有 | `KEEP_CHARACTERIZATION`；移除v2/legacy并补manifest readback ACK |
| `apps/mobile/lib/features/chat_session/state/chat_session_cubit.dart` | focused overlay有authority/origin generation fence | `KEEP_UI_EFFECT`；Cubit只消费Repository+LiveOverlay，不拥有matching/durable write |

## 13. 必做实验与可接受输出

| ID | 实验 | 必须输出 | 失败时设计动作 |
|---|---|---|---|
| E-CODEX-READ-CONTRACT | 精确Codex build的catalog/turn/item RPC、cursor、terminal、empty、order | build/binary/schema digest、raw request/response digest、de-identified fixtures、limits/latency | 禁用未证read strategy；不退回unbounded whole-read |
| E-CODEX-LIVE-IDENTITY | runtime/shared/detached observer在duplicate/reorder/reconnect/source switch下覆盖 | 每producer generation、strong ID覆盖率、gap/duplicate矩阵、memory peak | live只显示separate activity；缺失全靠durable reread |
| E-CORE-CACHE-REUSE | 同range首次/二次打开 | Mobile/Bridge/Provider request counts、bytes、latency、SECOND_READ_REASON | 无法零读则冻结明确proof-read预算，不假称cache hit |
| E-CORE-ORDER-PROOF | split/reorder/duplicate/inclusive cursor/cycle fixtures + real样本 | 每条visible adjacency的proof path | 无proof island保持Gap |
| E-CORE-REPLICA-ACK | WSS→staging→SQLite→readback→ACK→Repository/UI | 每kill点、commit/readback receipt、replay、RSS/frame budgets | commit/readback前禁止publish/ACK |

所有实验仅在隔离 state dir、测试端口 `8766`、throwaway threads 上另行授权执行。本草案未运行这些实验，状态全部 `NOT_RUN`。

## 14. 成本控制与最小实现面

| 修改面 | 必要性 | 预计成本 | 不采用的更大方案 |
|---|---|---:|---|
| 扩充原 Identity value objects 与 source binding | 所有cache/read/wire/ACK的前置 | M | Device Core / hardware identity |
| 将原 materialization segment/head 加入evidence/coverage/复合FK | 关闭P0-02/P0-07/P0-14 | L | 第二history DB、全局DAG service |
| 删除weak identity/alias和v2 target owner | 防串会话/错序/双writer | L | 保留兼容fallback或双读 |
| LiveObservation owner收敛 + strong-ID promotion | 防live写durable/正文去重 | M-L | 每producer独立timeline |
| Mobile replica改island/head + strict source partition | 正确partial/cache reuse | L | 继续单hot window并以Gap字段打补丁 |
| publication manifest/readback ACK | crash/replay/verified-before-visible | M | UI先乐观publish后修复 |

没有证据需要新产品核心、第二 SQLite 文件、通用 event bus 或万能 repository。本草案只要求在原 Session Kernel owner内增加必要字段、约束和 typed ports。

## 15. 仍需根 Agent 统一裁决/集成的项目

1. 最终 wire agent 对消息名和 durable envelope 的统一命名；本草案只冻结必备语义，避免与 operation/interaction/wire 草案产生第二协议。
2. Bridge installation identity 固定由独立 `BridgeInstallationStore` 持有；实施时可复用现有私有状态目录与原子文件工具，但不得继续借宿 `PromptHistoryStore` 或把它等同 `BridgeIdentityStore`。
3. U-006 cache retention/capacity/at-rest protection 的用户待决表达；本草案不默认 TTL/LRU/SQLCipher。
4. U-007 certified Codex build/range policy；在用户裁决前，adapter按一个精确build fail closed 是最安全施工假设，但不能写成永久产品决定。
5. Provider refresh 已从 live producer 列表移除，固定进入 `CatalogRead`/`CanonicalProjectionWriter` 路径；最终 registry 只需统一其 read reason 名称。
6. sender-local outgoing→canonical user item correlation 由 operation草案提供；receive草案明确拒绝text/time兜底，但不重复定义operation ledger。
7. 最终 DDL agent 决定在原20/19表内复用/重命名还是增加最少的page-evidence/stage表；必须满足本章复合约束和故意失败vectors，表数本身不是目标。

## 16. Phase 1 接收门禁

根 Agent 只有在累计设计同时满足以下条件时才能把本草案标为 integrated：

- 一个且仅一个 canonical writer / Mobile apply writer；
- route、Bridge identity、Bridge instance、Codex source、thread/turn/item 和各 fence 无混用；
- actor 完全来自 authenticated connection context；
- Provider read evidence、bounded catalog/turn/item、cache islands、coverage/gap/order proof、last-good 可由 machine contract表达；
- live body在所有 durable表/wire replay中为零，只有strong Provider identity可promote；
- source switch/crash/ACK replay均不清last-good、不中断draft、不跨partition；
- weak time/text/index identity路径被明确删除；
- 每个 `EXPERIMENT_REQUIRED` 有隔离probe和失败降级；
- P0-02/P0-03/P0-07/P0-14 与 P1-01/P1-02/P1-09/P1-10 在最终矩阵中有唯一owner、DDL/wire和故意失败test；
- 设计、实现、runtime、部署、IPA/OTA、真机、stable继续独立，当前仍全部未授权/未运行。
