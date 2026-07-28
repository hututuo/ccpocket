# CC Pocket 仓库、分支与工作树单线收束计划 v01

> 状态：`superseded`；执行结果见
> `repository-branch-convergence_v02_20260728-222804.md`
> 创建时间：2026-07-28 19:08:33 +0800  
> 本文只定义源码、文档和 Git 历史的收束方式；不授权部署 Bridge/Cloud、
> 构建或安装 IPA、发布 owner/stable、删除分支或清理脏工作树。

> 2026-07-28 说明：用户随后授权执行源码收束。本文件保留执行前盘点，
> 不再作为当前状态；实际提交覆盖、冲突处置、验证和未授权门槛以 v02 为准。

## 1. 结论先行

当前最适合作为唯一收束起点的是：

- 工作树：
  `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-v03-20260728`
- 分支：`fix/mobile-comprehensive-source-closure-20260728`
- HEAD：`e1080577a7fc9c374a3f3f591476f609425984f3`
- 状态：干净

仓库虽然保留 72 个本地分支，但这不代表还有 72 组代码需要合并：

- 37 个分支的 tip 已经是 `e1080577` 的祖先，代码按 Git 血缘直接包含；
- 35 个分支表面分叉，其中：
  - 13 个已通过 patch-equivalence、明确提交映射或语义整合进入当前候选；
  - 20 个是旧实现、阶段性 checkpoint、autosquash/pre-upstream 备份或已被
    后续最终分支取代；
  - 1 个是独立的 AltServer 远程签名工具，不属于 App/Bridge 主源码；
  - 1 个是脏的旧 `feature/mobile-session-tools` 工作线，需要保留审计但不能
    整枝合入。

因此，真正需要在最终单线上继续处理的不是所有历史分支，而是：

1. 给当前源码补上正式的官方 `upstream/main` Git 血缘；
2. 审查 `fix/mobile-comprehensive-v02-20260726` 在今天分叉前留下的未提交源码；
3. 审查并隔离旧主工作树的 Side Chat 实验，最多提取当前实现仍缺失的有效部分；
4. 全量验证后，再由用户决定是否合入共享/稳定分支以及是否清理旧 worktree/ref。

## 1A. 今天早上产生或参与本轮分叉的 worktree

这是本计划最先处理的对象。今天的工作不是继续从历史分支挑代码，而是先把下表
7 个 worktree 完整收口。

| 今日 worktree | 分支 / HEAD | 当前状态 | 明确处理方式 |
|---|---|---|---|
| `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-v03-20260728` | `fix/mobile-comprehensive-source-closure-20260728`；行为源码 `e1080577`，其后仅文档提交 | 干净 | **保留并作为唯一收束工作树。** 后续官方血缘合并、遗漏代码提取、验证和最终候选都只在由它建立的单一收束线上进行 |
| `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725` | `fix/mobile-comprehensive-v02-20260726@3fb83d12` | **脏：17 个 tracked + 10 个 untracked 入口** | **优先保留并提取。** 07:09～07:17 的 441/47 行源码产生在分叉前但未提交，没有进入子分支；先做 patch/校验快照，再与 `e1080577` 三方审核，提取真正缺口后才可处理该 worktree |
| `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/bridge-device-identity-20260728` | `feature/bridge-stable-device-identity-20260728@1645dfe3` | 干净 | **不再次合并。** 已以 `fac56c47` 适配进入当前收束线；只需核对提交映射和测试证据，确认后列为已吸收，可在用户授权清理阶段移除 worktree |
| `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-shared-codex-session-source-20260728` | `feature/mobile-shared-codex-session-source-20260728@30a33de3` | 干净 | **不再次合并。** `c56fe921 → a9f855a9 → 30a33de3` 已以 `8aabde45 → 170621dd → 0e6d2525` 进入当前线；核对后列为已吸收 |
| `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/review-perf-security-v03-20260728` | detached `3fb83d12` | 干净、无独有 commit | **仅审核场地。** 没有代码需要合并；用户授权清理时属于第一批可移除 worktree |
| `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/review-requirements-v03-20260728` | detached `3fb83d12` | 干净、无独有 commit | **仅审核场地。** 没有代码需要合并；用户授权清理时属于第一批可移除 worktree |
| `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/review-startup-v03-20260728` | detached `3fb83d12` | 干净、无独有 commit | **仅审核场地。** 没有代码需要合并；用户授权清理时属于第一批可移除 worktree |

今天 worktree 的实际收束顺序固定为：

```text
保留 v03/current closure 作为唯一目标
  → 先快照并审核脏 v02 worktree 的分叉前遗漏
  → 核对 identity 与 shared-source 两条子分支已经完整吸收
  → 确认三个 review worktree 没有独有提交
  → 进入官方 upstream 血缘合并
  → 最后才处理更早的历史分支和旧主工作树
```

也就是说，历史分支调查只是为了防止漏代码；执行优先级以今天这 7 个 worktree
为先，不能反过来先整理历史分支而把今天的脏工作树留到最后。

## 2. 实时盘点快照

### 2.1 分支

| 项目 | 数量 |
|---|---:|
| 本地分支总数 | 72 |
| 已是 `e1080577` 祖先 | 37 |
| 在 `e1080577` 之后继续前进 | 0 |
| 表面分叉 | 35 |

### 2.2 工作树

Git 当前登记 19 个 worktree：

- 17 个仍是有效 Git worktree；
- 其中 15 个干净；
- 其中 2 个脏：
  - 主工作树 `feature/mobile-session-tools`；
  - `fix/mobile-comprehensive-v02-20260726`；
- 另有 2 个无效/prunable 元数据：
  - `/private/tmp/ccpocket-mobile-file-manager-session-polish`
  - `/private/tmp/ccpocket-upstream-1.108-ota-integration`

三个 `review-*-v03-20260728` detached worktree 均停在 `3fb83d12`、干净且没有
自己的提交；它们只是审核场地，不是待合源码。

## 3. 当前完整主线

主线可简化为：

```text
早期 artifact / session / mirror / file transfer / permission / OTA
  → 1.108.1 unified
  → background notification candidate
  → 官方 1.109.2 comprehensive
  → fix/mobile-comprehensive-v02 @ 3fb83d12
      ├─ 今天主开发线 → c56e1c35
      ├─ Bridge 稳定身份子分支
      └─ Codex 共享来源子分支
  → source closure
      → 语义整合两个子分支
      → 继续生命周期、安全、兼容和性能修复
      → e1080577
```

`e1080577` 已包含 2026-07-28 本轮 29 个行为提交及其验证/交接文档。今天两个
子分支不应再次 cherry-pick：

- `feature/bridge-stable-device-identity-20260728@1645dfe3`
  已以 `fac56c47` 适配当前主线；
- `feature/mobile-shared-codex-session-source-20260728@30a33de3`
  已以 `8aabde45 → 170621dd → 0e6d2525` 收束。

## 4. 37 个已直接包含的分支

以下分支 tip 均为当前候选祖先，不需要再合：

### 4.1 基础与模块化功能

- `main`
- `compat/artifact-download`
- `backup/pre-upstream-sync-20260717`
- `feature/automatic-artifact-links`
- `feature/mobile-session-tools-modular`
- `feature/mobile-auto-approval-standalone`
- `feature/codex-next-turn-permissions`
- `feature/mobile-goal-management`
- `backup/pre-upstream-1.67.4-20260719`
- `feature/mobile-codex-parity-modular-final`

### 4.2 连续性、文件管理、UI 与宿主

- `fix/desktop-mobile-live-continuity`
- `feature/mobile-file-manager-session-polish`
- `integration/mobile-file-manager-continuity-hardening`
- `ui/claude-style-effort-motion`
- `feature/mobile-resident-conversations`
- `integration/mobile-resident-session-continuity`
- `ui/message-level-fork-action`
- `fix/desktop-continuity-orphan-turn`
- `integration/mobile-1.68-session-experience`
- `ui/effort-fire-fixed-grid`
- `fix/session-reliability-v2`
- `feature/mobile-permission-host`
- `feature/mobile-ota-host`
- `feature/mobile-ota-baseline-v2`
- `integration/upstream-1.108-ota-baseline`

### 4.3 会话折叠、历史与后续统一线

- `feature/mobile-current-progress-collapse`
- `fix/mobile-history-index-lifecycle`
- `ui/auto-approval-card-unification`
- `fix/mobile-partial-turn-fold`
- `fix/mobile-lazy-tool-plan-disclosure`
- `integration/mobile-1.108.1-unified-20260724`
- `backup/pre-upstream-1.109.2-comprehensive-20260725`
- `integration/mobile-1.108.1-background-notify-candidate-20260724`
- `integration/mobile-1.109.2-comprehensive-20260725`
- `fix/mobile-comprehensive-v02-20260726`
- `fix/mobile-comprehensive-v03-20260728`
- `fix/mobile-comprehensive-source-closure-20260728`

## 5. 35 个表面分叉分支的处置

### 5.1 已经语义整合：不再合并

以下 13 个分支虽然不是当前候选的祖先，但功能已进入当前线：

- `audit/mobile-app-performance-20260724`
- `docs/project-handoff-manual`
- `feature/bridge-stable-device-identity-20260728`
- `feature/mobile-background-location-notify`
- `feature/mobile-background-sync`
- `feature/mobile-codex-image-references`
- `feature/mobile-effort-animation`
- `feature/mobile-notification-settings`
- `feature/mobile-shared-codex-session-source-20260728`
- `fix/archive-capacity-mobile-timeout`
- `fix/mirror-reconcile-epoch`
- `fix/mobile-session-continuity-hardening`
- `fix/start-lifecycle-lock`

证据分三类：

1. 性能、背景同步、背景定位通知、图片引用、动画和几个窄修复的原提交均可由
   `git cherry` 找到 patch-equivalent 当前提交；
2. 通知分支在
   `plans/mobile-unified-integration_v01_20260724-040347.md` 中有逐提交映射；
3. 会话连续性和今天两个子分支在 `decisions.md` 与
   `reviews/SOURCE_CLOSURE_REPORT_20260728.md` 中有明确语义映射。

这些分支只能作为审计/回滚来源，不能再次整枝合入。

### 5.2 已被后续实现取代：不进入收束线

以下 20 个分支是中间态、旧模块实现或备份：

- `backup/mobile-session-tools-modular-pre-decisions-autosquash-20260718-055759`
- `backup/mobile-session-tools-modular-pre-final-autosquash-20260718-054042`
- `backup/mobile-session-tools-modular-pre-lint-autosquash-20260718-054717`
- `backup/mobile-session-tools-modular-pre-squash-20260718`
- `backup/pre-upstream-sync-20260716`
- `feature/bridge-codex-core-actions`
- `feature/bridge-file-transfer-v1`
- `feature/core-bridge-modular-prep`
- `feature/core-mobile-modular-prep`
- `feature/mirror-bridge-modular-prep`
- `feature/mobile-auto-approval`
- `feature/mobile-codex-core-parity`
- `feature/mobile-codex-lifecycle-archive`
- `feature/mobile-codex-parity-modular`
- `feature/mobile-conversation-mirror`
- `feature/mobile-file-transfer-v1`
- `fix/bridge-plan-capability-probe`
- `fix/core-action-pending-lock`
- `fix/mobile-plan-capability-consumer`
- `fix/session-correctness`

它们的有效行为后来集中在已经成为当前候选祖先的以下分支中：

- `feature/mobile-session-tools-modular`
- `feature/mobile-auto-approval-standalone`
- `feature/mobile-codex-parity-modular-final`
- `integration/mobile-resident-session-continuity`

不能因为旧分支还有 “unique commit” 就直接挑选；许多 unique commit 是被
squash、重写、语义迁移后的旧 checkpoint。

### 5.3 独立工具：留在源码收束之外

- `fix/remote-altserver-signing@feaef763`

这是 AltServer/真机远程签名适配器，不属于 Mobile/Bridge 产品源码。后续可单独
迁入自己的工具仓库或保留归档，但不得混入 CC Pocket App 源码收束提交。

### 5.4 脏旧工作线：隔离审计

- `feature/mobile-session-tools@94c0fd10`

主工作树当前有：

- 14 个已跟踪文件修改，约 970 行新增、5 行删除；
- 13 个未跟踪入口，主要是旧 Side Chat 源码、测试、方案、run、patch 和备份。

这批内容主要形成于 2026-07-18。当前候选已经包含它的模块化、后续演进版本：

- 两个 Side Chat 文件与候选完全相同；
- 其余同名控制器、面板、测试和 Bridge 实现均在候选中存在更新版本；
- 旧独立 protocol 文件已经迁入现行 typed slot/feature seam；
- 产品语义也已多次变化，不能恢复旧工作树里的整套持久 Side Chat。

处置方式：

1. 原样保存工作树；
2. 生成只读差异账本；
3. 只检查是否存在当前需求台账仍缺少的测试或边界；
4. 如有价值，在最终收束线上按现行架构重新实现；
5. 不 cherry-pick 整枝、不复制整目录、不提交旧工作树本身。

## 6. 今天分叉前遗漏的未提交源码

`fix/mobile-comprehensive-v02-20260726` 工作树当前 HEAD 为 `3fb83d12`，但在
该提交之后、今天各分支创建之前留下了未提交修改：

- 17 个已跟踪文件；
- 约 441 行新增、47 行删除；
- 源码修改时间集中在 07:09～07:17；
- 今天子分支从 09:55 起创建，因此这些工作树改动没有随 commit 进入子分支。

这批代码主要尝试把 `codexSourceId` 继续贯穿：

- session link 请求与响应；
- Deep Link；
- 通知 payload、当前可见会话和未读；
- route identity；
- Bridge 对来源不匹配的拒绝。

当前 `e1080577` 已经有更新的 `BridgeDataSourceIdentity`、稳定 Bridge 身份、
Codex 来源隔离、通知来源和路由隔离，所以这 441/47 行不能整体应用。但其中
`resolve_session_link` wire 明确携带 source identity、响应回显和错误码的设计，
可能仍是有效加固点。

执行时必须：

1. 先把原始 diff 和未跟踪文件做只读、可校验快照；
2. 以 `3fb83d12`、脏工作树、`e1080577` 做三方语义对照；
3. 将每个 hunk 标记为“已被现行身份模型覆盖 / 仍有价值 / 已过时 / 缺测试”；
4. 只在当前身份模型上补真正缺少的行为；
5. 增加 Deep Link、session link、通知路由、未读和旧 Bridge 降级测试；
6. 不提交生成的 `app_router.gr.dart`，除非由同一源码变更重新生成并验证。

该工作树还含网络事件 notes、patches、runs 和备份。这些是 build 204、
Tailscale/Mullvad/Serve 调查证据，应作为运行事件资料迁移/归档，不与上述源码
commit 混合。

## 7. 官方上游血缘

现场 fetch 后：

- `upstream/main`：
  `829621364b730b866e0c39b27d0aab868084f2aa`
- 官方版本：`1.109.3+202`
- 相比本地上次正式 merge 基点 `aa215a3b` 有两个提交：
  - `3289ce93`：阻止重复 session route；
  - `82962136`：版本更新。

当前候选已经以 `c2cc8379` 和 `97fb5aab` 语义实现同一官方变化，并使用本地
`1.109.3+205`，但官方两个 SHA 尚未成为当前候选祖先。

只读 `merge-tree` 预演显示，正式接入官方血缘会在 7 处产生冲突：

- `claude_session_screen.dart`
- `codex_session_screen.dart`
- `session_link_screen.dart`
- `main.dart`
- `session_stack_navigation.dart`
- `pubspec.yaml`
- `session_stack_navigation_test.dart`

因此不能简单再次 cherry-pick，也不能永远保留“功能已抄入但官方 SHA 不在
历史中”的状态。最终单线应从 `e1080577` 建立一次显式 upstream merge：

- 保留官方重复路由防护；
- 保留本地 `BridgeDataSourceIdentity`、多来源隔离、缓存/通知/路由语义；
- 版本号按本地 build lineage 处理；
- 形成真正包含 `upstream/main@82962136` 的 merge commit；
- 对 7 个冲突文件逐个运行官方测试与本地回归。

## 8. 唯一执行路线

### 阶段 0：冻结与备份

1. 从 `e1080577` 建立唯一的新收束分支和独立 worktree；
2. 记录完整 HEAD、上游 SHA、所有 worktree/ref 状态；
3. 对两个脏工作树生成精确 patch、未跟踪文件清单和校验值；
4. 不 stash、不 reset、不 checkout、不清理旧工作树；
5. 保留 `e1080577` 作为直接回滚点。

建议唯一执行分支：

`integration/ccpocket-single-line-20260728`

### 阶段 1：正式接入官方 1.109.3 血缘

1. 在新收束线上显式 merge `upstream/main@82962136`；
2. 逐个语义解决上述 7 个冲突；
3. 确认官方 route 去重测试与本地来源隔离测试同时保留；
4. 形成一个清晰 upstream merge commit；
5. 完成本阶段定向测试后再进入历史收割。

### 阶段 2：收割今天分叉前的脏源码

1. 对 441/47 行 patch 做三方逐 hunk 审核；
2. 优先审查 `resolve_session_link`、Deep Link、通知、未读与 route identity；
3. 已被现行 `BridgeDataSourceIdentity` 覆盖的内容不重复实现；
4. 真缺口按协议层、Mobile 路由层、测试分开提交；
5. 保持旧 Mobile/新 Bridge、新 Mobile/旧 Bridge的 additive/fail-closed 行为。

### 阶段 3：收割旧主工作树

1. 对旧 Side Chat 代码和当前实现做功能矩阵，不按文本 diff 决定；
2. 以当前产品合同和 `plans/mobile-comprehensive-remediation_v02...` 为准；
3. 旧持久 Side Chat/重复前端套件不恢复；
4. 仅提取当前线确实缺失的测试、边界或可复用小模块；
5. 若没有有效缺口，记录“无代码需合入”，保留审计证据即可。

### 阶段 4：历史分支闭环

1. 为 72 个分支生成最终处置表：
   `included / semantically-integrated / superseded / external-tool /
   dirty-harvested / keep-as-rollback`；
2. 对 13 个语义整合分支保留 commit 映射；
3. 对 20 个旧分支记录其替代分支；
4. 不再从历史分支临场 cherry-pick。

### 阶段 5：全量验证

最低门禁：

- `git diff --check`
- Bridge TypeScript build 与全量测试
- 通知/Cloud 代码若变化则 Functions typecheck、build、全量测试
- Mobile 全量 Flutter tests
- Mobile analyze：0 error / 0 warning
- iOS Simulator Debug build
- RunnerTests
- 来源身份、Deep Link、session link、通知/未读、重连、目录 readiness、
  Mirror、文件传输与历史分页专项测试
- 旧 Bridge + 新 Mobile、新 Bridge + 旧 Mobile的 fallback 验证
- 再次 fetch 后确认没有新的 upstream commit

源码门禁通过不等于 Bridge 已部署、IPA 已构建、真机已安装或 owner/stable
已发布。

### 阶段 6：形成唯一候选

完成后只把以下对象视为活跃源码：

1. 单一收束分支；
2. 一个明确的前收束回滚 ref/tag；
3. `upstream/main` 官方跟踪；
4. AltServer 工具若仍需保留，迁到独立工具仓库或明确归档。

用户确认前：

- 不合入 stable；
- 不 push；
- 不删除分支；
- 不移除 worktree；
- 不触碰运行中 Bridge、Cloud、手机数据或发布通道。

## 9. 清理顺序（仅在用户另行授权后）

1. 先移除三个无提交 detached review worktree；
2. 再处理两个 invalid/prunable worktree 元数据；
3. 再移除已证明语义整合且干净的专项 worktree；
4. 两个脏工作树必须在 patch/校验快照、价值审查和收割 commit 全部完成后处理；
5. 分支删除晚于 worktree 清理，并先保留一个可定位的回滚 tag；
6. 最终遵守“一个活跃源码 worktree + 最多一个验证/回滚 worktree”的收束目标。

## 10. 完成判定

只有同时满足以下条件，才能说“历史分支已经汇成一条线”：

- 官方最新 SHA 已进入真实 Git 祖先链；
- 两个脏工作树的代码和资料均已逐项处置；
- 所有表面分叉分支都有可审计处置结论；
- 当前产品要求没有因选择旧实现而回退；
- Bridge/Mobile/native/Cloud兼容矩阵通过；
- 全量自动验证通过；
- 用户确认最终源码候选；
- 分支/worktree清理另获明确授权。
