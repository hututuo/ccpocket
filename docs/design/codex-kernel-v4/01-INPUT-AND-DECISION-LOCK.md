# 输入与决定锁

## 精确身份

| 输入 | 身份 |
|---|---|
| 本地完整设计 branch | `codex/codex-kernel-v4-local-design-20260830` |
| source HEAD | `a706200233c55cc82d7a17e433f80f132d0f280d` |
| source tree | `ac85f620445151f45eda856f55f4b96ee442f41a` |
| v4 输入 ZIP SHA-256 | `d0f597cc089850214ec5aece824a3eb0265e20e0ce0e0bbef27add1381f0e257` |
| 原设计 ZIP SHA-256 | `d5c33a5455a1f1375efd4b68e0bb91844a5e6467c7115b3a204b4ea1faeeef76` |
| 历史审计补遗 ZIP SHA-256 | `d45f622d5f0824e91b8254d31cb2a62629d1f29e9d23ced6b4f2f0ac45bbc02c` |

## 已固定产品决定

1. Codex-first；Claude 只留不可达 typed unfinished seam。
2. 不保留 V2、Mirror writer、legacy runtime、dual read/write 或 production fallback。
3. 旧数据默认不导入；只有隔离、低成本、零运行时兼容负担时才另行决定一次性 importer。
4. 默认保留一个 Codex Session Kernel；内部 owner 可拆清，但不强制多产品核心。
5. Provider durable history 是历史事实权威；canonical history 只有一个 writer。
6. cache 必须复用；partial loading 允许不完整，但显示顺序必须有 proof，失败保留 last-good。
7. live 是 generation/source-fenced memory overlay，Provider durable fact 确认后才晋升。
8. operation 先 admission/idempotency 后 dispatch；`OUTCOME_UNKNOWN` 不盲重发。
9. computer、Bridge identity/instance、route、Codex source、thread/turn/item 分层；route/IP/title/text/time 不是数据身份。
10. actor 来自 authenticated connection context。
11. Goal 是 Provider-backed thread state。
12. Plan item=timeline；collaboration=settings；ExitPlan=Interaction。
13. Persisted 与 Ephemeral Side Chat 都保留；ordinary Fork 独立。
14. subagent=relation + ordinary child conversation/live。
15. 当前 52 项用户可见能力默认保留；现有补丁结构不是必须保留的实现结构。

## 当前仍需用户裁决

U-001–U-007 仍是会改变体验、安全、容量或发布策略的真实产品取舍；详见 `matrices/USER-DECISION-REQUIRED.csv`。设计给出安全推荐但不冒充用户决定。

U-008 已按用户最新要求关闭为默认 `NO_IMPORT`；U-009 已关闭为 Claude private/unregistered `NOT_IMPLEMENTED` seam，不新增 cloud core。任何新取舍必须进入 `USER_DECISION_REQUIRED`，不得由设计 Agent 默认为永久合同。
