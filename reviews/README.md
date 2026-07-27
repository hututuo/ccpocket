# CC Pocket 代码审查产出 — 索引

本目录是 2026-07-26 三轮 9 路全项目代码审查的完整产出。

## 目录内容

| 文件 | 说明 |
|---|---|
| `REQUIREMENT_LEDGER_20260727.md` | **当前产品完成度权威台账**：把用户原始要求、v02 方案、当前源码/提交和验证逐项对齐；后续修改必须持续更新 |
| `ccpocket-full-code-review-and-plan_v2_20260726.md` | **主文档**：规划与实施顺序。155 条精选条目 + 11 个实施批次 + 测试门禁 + 2 项待决策 |
| `INDEPENDENT_REVIEW_REMEDIATION_20260727.md` | **后续独立复审闭环**：对 38 个修复提交的质量评价、7 个新增发现、红绿测试证据与 6 个补救提交 |
| `raw-agent-reports/` | **原始报告 27 份（856 KB）**：各路子代理的完整输出，未经压缩 |

## ⚠️ 重要：两者的关系

主文档**不是**原始报告的全集，而是**精选与整合**。

- 主文档枚举 **155 条**，含全部 P0（21）、安全（25）、以及 P1/P2/P3 中影响面较大者
- 原始报告含 **1363 处 `file:line` 引用**，主文档只覆盖其中 **252 处**
- 差额主要是 **P2/P3 长尾**，以及主文档条目的补充证据行

**原因**：本次会话中途触发了上下文压缩，第 2 轮 8 路 agent 的详细报告被压缩为摘要，
只有高严重度条目完整保留。原始报告是从子代理 transcript 中恢复的，**未经任何压缩**。

**因此**：
- 排优先级、定实施顺序 → 看主文档
- 动手改某个模块前 → **必须**去 `raw-agent-reports/` 里翻对应那份，主文档在该模块上大概率不全
- 主文档与原始报告冲突时，**以原始报告为准**（它更接近一手取证）

## 原始报告清单

### Bridge 服务端

| 文件 | 大小 | 覆盖 |
|---|---|---|
| `bridge-core-5files-deep.md` | 78 K | **最大的一份**。Bridge 核心五文件深度审查：进程生命周期、消息解析与协议、并发、错误传播 |
| `bridge-codex-process-6965lines.md` | 19 K | `codex-process.ts` 全 6965 行逐行；交叉核对 `codex-transport.ts`、`codex-agent-turn-tracker.ts`、`session.ts` 监听器、全仓库 `unhandledRejection` 检索 |
| `bridge-sdk-process-1427lines.md` | 12 K | `sdk-process.ts` 全 1427 行；核对 `sdk-process.test.ts` 与调用方 |
| `bridge-parser-ts.md` | 17 K | `parser.ts` 专项 |

### 移动端 — 协议解析（本次发现 P0 最密集的区域）

| 文件 | 大小 | 覆盖 |
|---|---|---|
| `mobile-deserialization-and-strict-key-whitelist.md` | 66 K | **第二大**。反序列化健壮性全景 + 严格 key 白名单族（协议 additive 原则的直接违反）。含爆炸半径基线，是所有严重度判定的依据 |
| `mobile-models-dir.md` | 39 K | `lib/models/` 全目录（30 文件 14001 行） |
| `deserialization-sessioninfo.md` | 31 K | `messages.dart` 的 `SessionInfo` / `pendingPermission` 裸转换 |
| `deserialization-historyentry.md` | 36 K | `HistoryEntry.fromJson` 裸转 Map |
| `deserialization-cast-string-recheck.md` | 33 K | `List.cast<String>()` 惰性检查逃逸 try/catch 的复核 |
| `protocol-slots-10files.md` | 20 K | 10 个 protocol slot 逐行；交叉核对 `ServerMessage.fromJson` |
| `models-4files.md` | 18 K | 另 4 个模型文件；含解码异常实际后果的分析 |
| `diff-parser.md` | 28 K | `diff_parser.dart` 专项 |

### 移动端 — 功能域

| 文件 | 大小 | 覆盖 |
|---|---|---|
| `permission-approval-autoapproval-e2e.md` | 32 K | 权限/审批/自动批准端到端；含权限状态来源账本（全部写入点/读取点与实际优先级） |
| `sidechat-subagents-session-git.md` | 45 K | Side Chat 生命周期取证、子 Agent、session_* 系列、Git |
| `artifact-preview-route-chain.md` | 40 K | 预览路由决策链完整决策树 |
| `file-transfer-state-machine.md` | 26 K | 传输状态机（客户端侧） |
| `file-upload-subsystem.md` | 16 K | 上传子系统 |
| `file-browser-transfer-models.md` | 19 K | file_browser（1472 行）+ file_transfer（687 行）模型 |
| `explore-feature.md` | 20 K | Explore feature |
| `mobile-providers-dir.md` | 33 K | `lib/providers/` |
| `tool-result-bubble-widgets.md` | 18 K | `tool_result_bubble.dart` 等 widget |
| `lifecycle-concurrency-consistency.md` | 36 K | 生命周期 / 并发竞态 / 数据一致性 横切审查 |
| `functional-correctness-sweep.md` | 22 K | 功能正确性横扫（不含安全面） |

### 原生 / 云端 / 工程

| 文件 | 大小 | 覆盖 |
|---|---|---|
| `menubar-macos-swift.md` | 25 K | `apps/menubar` —— **此前从未被审查过的独立 macOS 菜单栏 App**，含架构概述 |
| `notification-e2e-bridge-cf-apns.md` | 18 K | 通知端到端：Bridge → Cloud Functions → APNs/FCM → Mobile → 本地通知 → 长按 action → 回传；含隐私与功耗边界是否被代码强制 |
| `l10n-coverage-quantified.md` | 26 K | l10n 覆盖率量化审查（含统计表） |
| `mobile-comprehensive-and-l10n.md` | 53 K | 移动端综合 + 本地化覆盖率扫描（含量化统计） |

## 审查基线

```
worktree:        _keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725
branch:          fix/mobile-comprehensive-v02-20260726
HEAD:            20382de6
功能 checkpoint:  341b2a26
upstream/main:   aa215a3b
```

审查期间**未修改任何源码**，本目录是唯一新增内容。

> 上述“未修改源码”仅描述 2026-07-26 三轮初始审查。2026-07-27 又对
> `20382de6..48fe6d15` 的 38 个修复提交进行了独立复审，并根据复审结果
> 追加了 6 个窄修复提交。详情与当前边界见
> `INDEPENDENT_REVIEW_REMEDIATION_20260727.md`。

## 当前继续实施基线

上述代码块保留的是 2026-07-26 初始审查快照，不代表当前源码。继续实施已推进到
`fix/mobile-comprehensive-v02-20260726@8da4e688`；2026-07-28 重新 fetch 后的
`upstream/main` 为 `82962136`，其中导航修复已由 `c2cc8379` 结合本地嵌入式
工作区语义整合，版本记录由 `97fb5aab` 同步为 `1.109.3+205`。逐项状态和验证
证据以 `REQUIREMENT_LEDGER_20260727.md` 为准。

## 前序文档

- `../plans/mobile-comprehensive-remediation_v02_20260726-004125.md` — 当前交接文档
- `../plans/mobile-comprehensive-remediation_v01_20260725-012458.md` — 上一版
- `../docs/PROJECT_HANDOFF.md` — CLAUDE.md 要求必读
- `../CLAUDE.md` — 注意其架构图已过时（`claude-process.ts` 不存在，实际是 `sdk-process.ts`）
