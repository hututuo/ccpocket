# CC Pocket 综合修复交接与实施方案 v02

> **这是本轮唯一交接文档。接手 Agent 应从本页开始，并继续读完整文件。**
>
> 状态：**source implementation closure / device and deployment pending**
>
> 创建时间：2026-07-26 00:41:25 +0800
>
> 交接快照：2026-07-26 15:47:01 +0800
>
> 当前行为源码 checkpoint：
> `fa3aa6db715bcfe47f4d93a3b090e18e508ef164`
>
> 当前继续分支：
> `fix/mobile-comprehensive-source-closure-20260728`
>
> 当前继续工作树：
> `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-v03-20260728`
>
> `fa3aa6db` 之后只有台账与交接文档提交。恢复时仍以实际
> `git rev-parse HEAD` 为准，并确认该行为 checkpoint 是其祖先。
>
> 上一版方案：
> `plans/mobile-comprehensive-remediation_v01_20260725-012458.md`

本文最初是 build 202 之后根据真实使用反馈建立的调查方案，现已进入部分实施。
下方原始调查、需求矩阵、证据和验收标准全部保留；本节新增的交接快照是当前事实，
若后文仍写着“尚未开始实施”或“待实施”，以本节和实际 Git 为准。已经落地的部分
也仍需在整轮收束时重新做跨层回归、性能审查、模拟器构建和真机验收，不能仅凭
commit 存在就宣称产品完成。

### 当前源码收束检查点（2026-07-28）

- 源码批次以 `3fb83d12` 为起点，共形成 29 个行为提交；`fa3aa6db`
  是最后一个行为提交。完整顺序见
  `reviews/SOURCE_CLOSURE_REPORT_20260728.md`。
- 最终行为源码上独立复跑：Bridge 95 个测试文件、1836 项通过；Mobile
  2572 项通过、4 项外部 SSH smoke 因环境未配置而跳过；Mobile analyze 为
  0 error / 0 warning / 52 info。
- iOS Simulator Debug 以相同源码成功编译并产出 `Runner.app`。这只证明
  源码与模拟器构建门禁，不等于已生成签名 IPA、已安装物理 iPhone、已部署
  Bridge/Cloud 或已发布 owner/stable。
- 2026-07-28 最后一次 fetch 的 `upstream/main` 为
  `829621364b730b866e0c39b27d0aab868084f2aa`（`1.109.3+202`）；本地语义整合
  `c2cc8379` 与版本记录 `97fb5aab` 都是当前分支祖先，本地源码保持
  `1.109.3+205`。
- 用户当前合同是两个外部 Codex/Cockpit 实例顺序使用同一来源；顺序共享已纳入
  稳定 Bridge/来源身份隔离。真正并发多写者的跨进程租约仍是未来范围，不能把它
  误报成当前已实现或当前源码阻塞项。
- 真机重复消息如果再次出现，必须先取得
  `raw/provider → Bridge → Mirror/SQLite → reducer → render` 的同一事件线，
  不能继续凭表象修改去重逻辑。

## A. 当前项目、工作树与 Git 身份

| 项目 | 当前值 |
|---|---|
| 共享 Git 仓库 | `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-compat` |
| 本轮独立工作树 | `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725` |
| 当前分支 | `fix/mobile-comprehensive-v02-20260726` |
| 起始集成基线 | `9e8078ba97fd85d5bdb38a1876d08eba6855b7d7` |
| 基线分支名 | `integration/mobile-1.109.2-comprehensive-20260725` |
| 功能源码 checkpoint | `341b2a2690f830ed1070af6e153eb3350ece7c1b` |
| 分支 HEAD | 提交本交接文档后将前移一个 docs commit；以恢复时 Git 实际值为准 |
| 官方远端 | `upstream=https://github.com/K9i-0/ccpocket.git`，push 被禁用 |
| 交接时 `upstream/main` | `aa215a3b98a8035cba0e6bdd8005803f76041d66`，`1.109.2+201` |
| 官方包含关系 | 交接时 `upstream/main` 已是起始基线祖先；继续开发前仍必须重新 fetch/核对 |
| 工作树状态 | 交接文档提交前源码工作树干净；不得假定未来恢复时仍然干净 |
| 磁盘状态 | 交接时数据卷约剩余 31 GiB、使用率 93%；构建前后必须按根级规则收束缓存 |

不要在共享仓库当前主工作树
`/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-compat`
直接继续本轮修改；它当时位于 `feature/mobile-session-tools`，属于另一条工作线。
继续本轮应使用上表独立工作树和分支。

### A.1 接手前必须先读

1. 工作区根规则：
   `/Users/huyiyang/AI agent/Codex/AGENTS.md`
2. 易错索引：
   `/Users/huyiyang/AI agent/Codex/AGENT_ERROR_INDEX.md`
3. 仓库规则：
   `CLAUDE.md`
4. 长期边界：
   `docs/PROJECT_HANDOFF.md`、`decisions.md`
5. 本文全部内容，尤其 v02-014、v02-015 和本节。
6. 修改新代码区前先用 Codegraph 查完整调用链；只在索引未覆盖具体细节时再做
   小范围源码读取。

### A.2 仍保留的参考工作树

以下工作树/分支包含历史专项或候选，不能因为“看起来旧”就直接删除，也不能整枝
机械合入本轮。需要时按提交、协议和真实依赖语义审查：

| 工作树 | 分支 / HEAD | 用途 |
|---|---|---|
| `ccpocket-worktrees/mobile-performance-audit-20260724` | `audit/mobile-app-performance-20260724` / `917afcf9` | 独立手机性能审计 |
| `ccpocket-worktrees/mobile-background-sync` | `feature/mobile-background-sync` / `d5c1ee29` | 有限后台同步宿主 |
| `ccpocket-worktrees/mobile-background-location-notify` | `feature/mobile-background-location-notify` / `8d6f206a` | Always Location 轻通知方案 |
| `/private/tmp/ccpocket-mobile-notifications` | `feature/mobile-notification-settings` / `3b48055f` | 分级通知设置 |
| `/private/tmp/ccpocket-codex-image-references` | `feature/mobile-codex-image-references` / `b2e6d45e` | Codex 图片引用 |
| `ccpocket-worktrees/mobile-unified-integration-20260724` | `integration/mobile-1.108.1-unified-20260724` / `6cfcef71` | 旧统一集成参考 |
| `ccpocket-worktrees/project-handoff-manual-20260724` | `docs/project-handoff-manual` / `41cdc65f` | 长期交接手册 |

另有 `/private/tmp/ccpocket-mobile-file-manager-session-polish` 的 worktree 元数据已标为
prunable，目录不存在。只可在确认分支、commit 和所需内容均已保留后清理元数据；
不要把“prunable”理解为授权删除分支或历史。

## B. 本轮已经形成的提交

按依赖顺序如下。当前分支未合回共享/稳定分支，未 push，未发布：

| 顺序 | commit | 已落地内容 | 当前判断 |
|---|---|---|---|
| 1 | `02128669` | 会话目录请求关联与权威就绪门禁 | 已实现，最终仍需连接页综合回归 |
| 2 | `6cddb80c` | 按 Bridge 身份隔离并持久化会话目录缓存 | 已实现 |
| 3 | `ac0f56c0` | 设置页管理普通缓存与已下载历史副本 | 已实现，最终需真机 UI 验收 |
| 4 | `b986cd13` | 文档确认所有会话分层自动更新 | 方向性方案 |
| 5 | `e956ee8c` | 文档纠正为 Bridge 主导增量推送 | 方向性方案 |
| 6 | `39022937` | Bridge 会话目录变化保留 durable identity | 已实现 |
| 7 | `6685185e` | Bridge 主动推送持久会话增量 | 已实现，未部署 live Bridge |
| 8 | `fcc4bc46` | Mobile 接收并持久化 Bridge 主动增量 | 已实现，未发布 |
| 9 | `ddfb1bed` | 从本地缓存立即打开会话，后台延后 runtime 绑定 | 已实现；发送/修改仍等权威 runtime |
| 10 | `167ec16e` | 点开运行会话只提升 Bridge 同步优先级 | 已实现 |
| 11 | `78f83eb1` | 统一当前过程展开身份、八行框、框内 thinking/tool、Guardian 三秒归属 | 已实现并通过定向回归 |
| 12 | `341b2a26` | `checkpoint:` 时间戳归入消息、操作栏和折叠摘要 | 已验证的 checkpoint；继续前先审查下述未完成点 |

### B.1 `341b2a26` 的准确边界

该 checkpoint 已完成：

- 删除 `ChatEntryWidget` 对每个 entry 无条件插入的独立居中时间胶囊；
- 用户消息时间进入气泡；
- 助手文字时间进入既有操作栏右侧；
- ToolUseSummary、历史过程、外层中间过程和当前工具摘要时间进入同一行；
- 折叠标题的时间位于箭头左侧；
- 状态/同步型 entry 不再制造空白时间行；
- 窄屏长文本与命令消息已有回归。

继续时仍应确认：

- 直接脱离过程分组渲染的 `ToolResultBubble` 是否也应在自己的箭头左侧显示时间；
- inferred error、特殊 plan/card、图片结果等可见消息的时间归属是否符合最终视觉；
- 真实 iPhone 字体缩放、中文/英文和长工具名下无溢出；
- 不要恢复独立时间行，也不要把同步时间冒充 Bridge 电脑接收时间。

## C. 用户最终确认的会话同步架构

这是当前最高优先级产品合同，覆盖后文较早、冲突的表述：

1. **所有 durable conversation 都是可直接打开、可阅读、可继续使用的。**
   UI 不再用“是否激活/Ready”决定会话是否可用。
2. **Bridge 是更新计算和调度的唯一主要拥有者。**
   Bridge 负责 provider/Codex Desktop 文件变化检测、目录 revision、cursor、
   history 读取、增量计算、去重、公平排队和客户端推送。
3. **Mobile 不为每个会话轮询。**
   App 在 interactive 前台建立一次订阅/恢复握手，Bridge 主动推送变化；Mobile
   只做轻量 reducer、SQLite 落盘、未读和当前可见 UI 更新。
4. **正在运行的会话实时更新。**
   无论运行时由 Bridge 托管还是电脑端 Codex Desktop 托管，都进入同一 durable
   增量链；live 和 history 回放按 canonical identity 去重。
5. **最近会话低延迟，冷会话低频补偿。**
   当前打开会话为 P0；running/Needs You/未读为 P1；至少最近常用 10 个为 P2；
   其他会话为 P3。冷会话的周期自适应，用户口述“一分钟”不是硬编码合同，但也
   不能退化成永不更新。
6. **runtime attachment 是内部发送机制，不是可见资格。**
   读取已有 durable history 时不应为了“激活”而 resume。首次发送若必须 attach，
   应在同一页面后台完成，不得丢草稿、滚动或折叠状态。
7. **iOS 后台不突破功耗和隐私边界。**
   普通后台和 location `notificationsOnly` 只接收轻量通知投影，不同步正文、
   Mirror、工具、文件或渲染树；回前台先恢复 interactive，再按持久 cursor 补齐。
8. **多客户端 cursor 独立。**
   Bridge 可共享解析和 revision，但一个客户端的 ack 不能推进另一个客户端水位。

当前代码已建立 Bridge 主动增量、Mobile 持久 reducer、焦点优先级和缓存打开的
基础；完整 `ConversationSyncScheduler` 的公平性、冷会话补偿、ack/backlog、
provider rewrite、跨多个新旧客户端和大规模性能仍需最终系统审计。

## D. 已取得的验证信号

本节只证明源码级定向验证，不代表 Bridge 已部署、App 已发布或真机已通过：

- 缓存立即打开/延后 runtime 绑定相关：定向 analyze 通过，相关测试共 178 项通过。
- 会话点开提升同步优先级：定向 analyze 通过，相关 UI 测试 44 项通过。
- `78f83eb1` 过程折叠：
  - 14 项 process disclosure 测试通过；
  - 相邻 layout/Guardian 测试 18 项通过；
  - 覆盖 13 个工具、八行内部滚动、增量更新不折回、前后台切换、Guardian
    三秒消失和窄屏无溢出。
- `341b2a26` 时间戳 checkpoint：
  - targeted analyze 无 error/warning；
  - `assistant_bubble.dart` 有 1 条仓库既有 `imageBuilder` deprecated info；
  - 时间戳、过程折叠、操作栏、工具摘要和工具结果相邻回归合计 48 项通过；
  - `git diff --check` 通过。
- 尚未为本轮最终 HEAD 做：
  - 全仓测试；
  - Bridge 全量 build/test；
  - Flutter 全量 analyze；
  - iOS Simulator 最新 HEAD 构建；
  - 物理 iPhone 验收；
  - IPA 构建、签名检查或安装；
  - live Bridge/Cloud/OTA/stable 发布。

## E. 尚未完成的工作与建议顺序

### E.1 先做当前源码收束

1. 审查 `341b2a26` 的特殊可见消息和直接 ToolResult 时间归属，形成非 checkpoint
   功能提交或后续修正提交。
2. 对“同一中间过程 + 工具 + 最终回复重复两次”取得真实故障会话的
   raw → Bridge → Mirror → reducer → render 五层证据；不要仅靠 Widget 层去重。
3. 复核 optimistic user entry 被 canonical entry 替换时 turn key、展开状态、
   scroll anchor 和时间 provenance 不漂移。

### E.2 完成会话目录与连接体验

1. 连接/自动连接期间保留 IP/机器页和可操作阶段，不再替换成无上下文全屏转圈。
2. transport ready、认证、capability、权威 session list 和 catalog metadata
   readiness 分开；只有当前 epoch 的权威结果才能首次进入首页。
3. 首页不能先整页 `(no description)`；使用持久缓存时必须标明缓存/同步状态，
   不能让用户误以为数据损坏。
4. 清除残留的 Ready/激活/挂起展示和“已有会话正在创建”文案；已有会话应显示
   正在加载/追平。
5. 验证最近会话排序、至少 10 个 hot 会话、逐项删除下载历史和普通缓存清理。

### E.3 完成会话内交互

1. 真正非模态、可拖动、贴边、折叠/展开都不遮断底层会话的悬浮小窗；内部复用
   已有会话 UI，承载运行子 Agent、官方 ephemeral Side Chat 和需处理事项。
2. Side Chat 使用官方 `thread/fork(ephemeral:true)` 和官方生命周期；不要硬编码
   用户口述的半小时，不新造持久会话类型。
3. 权限偶发回到 `on-request`、Plan 首次退出后审批消失、Goal thread ID、Spark
   额度圆环、运行蓝条/同步光晕等先复核真实事件线，再修 owning layer。
4. 完成消息未读蓝点、打开后清除和多客户端边界。

### E.4 通知、后台、文件与安全

1. 复核已有分级通知和 Always Location 轻通知源码，不重复实现；需要依次验证
   Cloud → Bridge → Mobile/基础 IPA，progress 默认关闭且必须显式订阅。
2. 真机验证通知中文、approval/question/progress/completion/failure、长按
   Allow/Reject、APS entitlement、AltStore 重签和系统回收。
3. 文件管理保留两套入口：
   - Agent 原有引用/超链接机制不改语义；
   - 用户手动文件管理单独存在；
   - 两者共用全盘只读、统一预览、下载和分享能力。
4. owner 模式允许认证后的全盘只读/预览；修改、上传、移动、删除必须由 Bridge
   通过密码或手机 Face ID/Secure Enclave 授权。密码/verifier 不进入热路径。
5. URL 直接交系统浏览器；本地 HTML 优先应用内安全预览；Quick Look 支持的格式
   优先 Quick Look，不支持或失败时回退本地预览器。JSON、HTML、下载和分享需用
   真实失败样本验收。
6. 对 Bridge/手机握手、路径规范化、symlink/TOCTOU、认证、速率/大小限制做完整
   安全审查，但不得因自用虚拟局域网就放弃写操作授权边界，也不得为安全检查
   引入消息热路径性能回退。

### E.5 多实例、官方更新与最终性能

1. Cockpit 多开 Codex 的两个 Home/来源必须显式建模；同一 durable thread 保持
   单写者，不做按时间或标题猜测的全量 JSON 合并。
2. 每次继续前重新核对 `upstream/main`；语义合并官方最新提交，禁止整文件
   ours/theirs 覆盖本地或官方行为。
3. 全功能完成后做一次全软件性能审查：
   Bridge watcher/history/JSONL、scheduler、公平队列、重复读取、Mobile SQLite、
   reducer、列表/Markdown/工具详情、动画 ticker、启动、CPU、内存、网络和电量。
4. 性能优化不能靠截断历史、减少真实同步、隐藏状态或停止实时反馈冒充修复。

## F. 不可越过的兼容、协作与发布边界

- 新旧 Mobile、Bridge、基础 IPA 与官方 provider/app-server 继续 additive protocol
  + capability negotiation；未知字段可忽略，未知工具有 generic fallback。
- canonical provider history 是事实来源；Mirror/SQLite 是可重建缓存，不反写原始
  rollout，不因 UI 异常删除会话数据。
- 一个用户可感知功能一个内聚 commit；不整文件覆盖官方热点，不混入大范围
  format/codegen 噪声。
- 当前 worktree 中发现用户或其他 Agent 未提交修改时必须先停下识别，不能
  reset/checkout/clean 覆盖。
- 未经用户明确授权，不得：
  - 合回共享或稳定分支；
  - push；
  - restart/replace 当前 Bridge；
  - 部署 Cloud；
  - 发布 owner OTA；
  - 晋级 stable；
  - 构建并安装真机 IPA；
  - rebase 或改写他人历史；
  - 删除旧分支、worktree、构建证据或会话数据。
- 发布门禁必须逐项区分：源码 → 集成 → Bridge build → Bridge deploy →
  Flutter test/analyze → Simulator → IPA → 重签/安装 → 真机 → owner OTA →
  用户批准 stable。
- 最终构建前后检查磁盘；同类 build、DerivedData、Pods、Dart/Flutter、Bridge
  dist、XCTestDevices 和 IPA 默认只保留最新一版、最多两版。只清理已确认可重建
  的精确路径，不使用宽泛 `git clean -fdx`。

## G. 接手后的最短安全起步命令

以下仅用于核对身份，不代表授权发布：

```zsh
cd '/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725'
git status --short
git branch --show-current
git rev-parse HEAD
git log --oneline --decorate 9e8078ba97fd85d5bdb38a1876d08eba6855b7d7..HEAD
git rev-parse upstream/main
```

预期功能源码 checkpoint 是：

```text
branch            = fix/mobile-comprehensive-v02-20260726
source checkpoint = 341b2a2690f830ed1070af6e153eb3350ece7c1b
```

恢复时分支 HEAD 应是该 checkpoint 之后的独立交接文档提交；若不是，先检查
`git log --oneline --decorate -20`，不要用 reset、checkout 或 rebase 猜测修复。

若任一项不同，先按现场状态更新本文，不要强行 reset 回交接点。

Flutter/Dart 工具链在交接时为：

```text
Flutter:
/Users/huyiyang/.shorebird/bin/cache/flutter/309dd6573a9fe716410489284cd325a34b950375/bin/flutter

Dart:
/Users/huyiyang/.shorebird/bin/cache/flutter/309dd6573a9fe716410489284cd325a34b950375/bin/cache/dart-sdk/bin/dart
```

## H. 完成交付格式

下一位 Agent 最终回报至少写明：

1. worktree、branch、起始基线、最终 HEAD；
2. 全部 commit 及依赖顺序；
3. 工作树是否干净，是否混入他人改动；
4. 每项用户需求对应的实际行为和 owning layer；
5. 新/旧 Mobile × 新/旧 Bridge × 新/旧基础 IPA 的兼容矩阵；
6. Bridge、Flutter、iOS、IPA 和真机的原始验证信号；
7. 未验证事实、剩余风险和发布顺序；
8. 保留/清理的构建产物、占用和磁盘回收；
9. 未经授权没有执行的 merge、push、部署、OTA、stable、安装和历史改写。

## 0. 使用规则与权威边界

1. 本文是方向性实施指南，不是对根因或修复完成的声明。
2. 每个问题必须分开记录：
   - 用户可见现象和期望；
   - 已由当前源码、Git、产物或运行态确认的事实；
   - 尚未取得证据的假设；
   - 实施前必须补做的取证；
   - 兼容、性能、回滚和验收边界。
3. 真正实施时必须在当时的统一集成 HEAD 上重新追踪完整调用链。若真实代码已经
   变化，或发现更深层原因，应更新本文并修正设计，不得为了照抄方案只修表面。
4. 疑似 bug 只有在事件顺序、连接身份、connection epoch、provider identity、
   本地缓存和运行对象都核对后才能修改；调查过程中顺带发现的问题先登记，不
   直接动手。
5. 官方 upstream、本地功能、运行中 Bridge、Cloud、基础 IPA、owner OTA 和
   stable 是不同状态。任何“已经合并”“已经连接”“已经可用”都必须注明所指
   层级。
6. 新旧 Mobile、Bridge、基础 IPA 与官方 provider/app-server 继续采用 additive
   协议和能力协商；不得用只适用于当前自用环境的快捷修复破坏官方可回放性。
7. 性能审查仍是整轮实施的最终阶段，同时也是每项设计的前置约束：不能通过
   无界轮询、全量重建、重复解析或隐藏真实状态来改善表面体验。

## 1. 本轮问题登记

### v02-001：启动时连接页提前消失，进入无信息的中央大加载

#### 1. 用户可见现象

- 刚进入 App 时，用户仍在 IP/Bridge 连接阶段，连接页就自动消失。
- 随后界面只剩中央的大型加载动画。
- 有时界面表现得像“已经连接并跳到后面”，但 Bridge 实际尚未完成可用连接，
  因而只能继续等待。
- 用户不需要这个脱离上下文的中间加载页。连接尚未完成时应继续留在原连接页，
  明确告诉用户正在连接哪台 Bridge、进行到哪一步、是否可取消或重试。

#### 2. 已确认的源码事实

当前 build 202 源码的冷启动链路是：

```text
SessionListScreen.initState
        │
        ▼
读取 SharedPreferences 中保存的 bridge_url
        │
        ├─ 有保存地址：立即设置 _isAutoConnecting = true
        │                  │
        │                  ▼
        │          整个 ConnectForm 被替换为
        │          Center(CircularProgressIndicator)
        │
        ▼
BridgeService.autoConnect -> connect
        │
        ├─ connection state = connecting
        ├─ WebSocket channel.ready 后 state = connected
        │   （这里只证明 WebSocket upgrade/transport ready）
        └─ SessionListCubit 在 connected 事件后请求 session_list
                            │
                            ▼
             BridgeService 收到 SessionListMessage
             才标记当前 connection epoch 权威就绪
```

- `_isAutoConnecting` 分支无条件覆盖整个连接表单，只显示中央转圈。
- 即使不是自动连接，只要展示状态为 `connecting`，当前代码也覆盖连接表单并
  只显示同一个中央转圈。
- v01 实施的 `SessionHomeConnectionGate` 已经修复了“WebSocket 一打开就直接
  展示会话首页”的事实错误：首次连接必须收到当前目标的权威 `session_list`
  才能展示已连接首页。
- 但该门禁只决定“能不能展示会话首页”，没有决定“等待期间怎样展示”。当
  transport 已 connected、但权威 `session_list` 尚未到达时，它把展示状态降为
  `connecting`，随后仍命中全屏转圈分支。
- 因此当前现象不是 v01 门禁完全失效，而是 v01 只完成了数据正确性门禁，
  遗留了连接阶段的 UI 状态设计：不再错误进入首页，却仍然错误地移走连接页。
- `BridgeService` 在 `channel.ready` 时发布 `connected`；当前枚举只有
  disconnected / connecting / connected / reconnecting，不能表达认证、能力
  握手、会话列表请求、会话列表已确认和兼容降级。
- `autoConnect()` 只表示“已发起连接”，返回 `true` 并不表示 Bridge 已可用。
- `_isAutoConnecting` 目前只在以下情况结束：
  1. 收到当前连接的权威 `session_list`；
  2. connection state 变为 disconnected；
  3. 根本没有可尝试的保存地址。
- 若 WebSocket 保持打开但没有返回可解析的 `session_list`，当前展示层没有
  权威就绪超时、阶段说明或恢复入口，中央转圈可能长期存在。
- `SessionHomeConnectionGate` 是 `SessionListScreen` State 内的内存对象，冷
  启动会重新创建，不会跨 App 进程借用上次 readiness。相同目标在同一页面生命
  周期内短暂重连时会保留已经建立的首页；切换规范化 URL 或 machine identity
  会清除 readiness。
- 空的 `sessions: []` 只要来自当前连接的合法 `SessionListMessage`，仍应算作
  权威完成；“会话为空”和“从未收到 session_list”不能混为一谈。

#### 3. Git 与运行态证据

- 中央转圈和 `_isAutoConnecting` 行为来自项目导入时已有的官方历史
  `2717842e`，不是 build 202 新增页面。
- v01 的连接门禁来自 `066172b3`，其测试覆盖了：
  - transport ready 不得进入会话首页；
  - 当前 Bridge 发出权威列表后才进入；
  - 同目标重连保留现有首页；
  - 切换目标必须重新取得权威列表；
  - 首次失败重连不得进入首页。
- 现有测试没有覆盖用户本次指出的展示要求：
  - 自动连接时连接表单必须仍可见；
  - transport connecting 时不得变成无信息全屏 spinner；
  - socket 已开但 session list 未到时的阶段、超时、取消和重试；
  - 冷启动旧 Bridge、错误 token、半开连接和不返回 session_list。
- 2026-07-26 只读核对时，官方 `upstream/main` 仍为
  `aa215a3b98a8035cba0e6bdd8005803f76041d66`，与 v01 登记一致。正式实施前仍需
  再次拉取并语义合并当时最新官方提交。
- 当前 Mac 实际运行的是
  `1.69.0-compat.6-4e611c6b` Bridge，而不是 build 202 源码对应的新候选；
  health 正常且当时有一个客户端连接。这个版本差异必须纳入真机复现，不能把
  “socket 上有客户端”当作新旧协议数据路径已经兼容。

#### 4. 尚未确认的部分

以下目前只是可能放大卡顿时间的分支，不作为已确认根因：

- 真机保存的 URL、token 或 machine identity 是否与当前运行 Bridge 完全一致；
- 当前那次中央加载是否停在 WebSocket、认证、`session_list` 解析，还是 recent
  catalog 的后续加载；
- 旧 Bridge 是否已返回了 build 202 能解析的 `session_list`，以及返回耗时；
- App 前后台切换、Tailscale/LAN 地址变化或 SSH tunnel 是否生成了第二次连接
  epoch；
- 物理设备日志中是否存在握手成功后立即断线、旧 token、协议错误或消息解析
  错误。

实施前应对一次真实复现采集有界诊断时间线，只记录阶段、目标的脱敏 identity、
connection epoch、消息类型和耗时，不记录 token、消息正文或文件内容。

#### 5. 目标交互

首次启动或冷启动自动连接时：

- 保留原有 IP/机器连接页，不导航到会话首页，也不替换成孤立的全屏 spinner。
- 保存地址可以自动尝试，但在对应机器卡片或连接面板内显示阶段：
  “正在建立连接”→“正在验证 Bridge”→“正在同步会话列表”。
- 用户始终能看到当前目标，并可取消自动连接、修改地址、选择另一台机器或重试。
- 只有当前 connection epoch 收到可解析的权威 `session_list` 后，才切换会话 UI。
- 权威空列表是成功状态，展示正常空会话首页；超时或协议不兼容不是空列表。
- 失败后留在连接页，以可操作错误说明代替永久转圈。

已经成功进入首页后的同目标短暂重连：

- 若本地仍有属于该目标的权威缓存，可保留首页，显示非阻塞重连状态，不闪回
  连接页。
- 若目标 identity 或 connection epoch 已切换，不得显示上一台 Bridge 的内容为
  当前权威数据。
- 是否继续展示旧缓存必须与“当前连接未就绪”视觉区分，不能显示成已连接。

#### 6. 拟采用的状态边界

实施时优先建立一个可测试的 presentation model，而不是继续用一个布尔值和四态
transport 枚举拼 UI。概念阶段至少包括：

```text
idle/selecting
autoConnectPreparing
transportConnecting
transportReady
awaitingAuthoritativeSessionList
ready
reconnectingWithCachedHome
failed/cancelled/incompatible
```

- transport 状态仍由 `BridgeService` 负责。
- application readiness 继续由当前目标、connection epoch 和权威
  `session_list` 决定。
- UI presentation 负责把上述事实映射到连接页、缓存首页或已连接首页。
- 不把“有保存地址”“autoConnect 返回 true”“WebSocket open”“有旧缓存”中的
  任一项单独当作 ready。
- 超时只结束等待并给出重试入口，不得伪造成功或清除可恢复的本地缓存。

具体是否新增公共连接阶段模型、沿用现有 gate，或将状态收束到 connection
coordinator，必须在实施时结合 Mobile/Bridge 最新源码和调用者影响面决定。

#### 7. 兼容与性能约束

- 旧 Bridge 若支持既有 `session_list`，继续走相同权威门禁，不要求新能力。
- 若未来增加显式 hello/ready ack，只能作为 additive capability；旧 Bridge
  仍必须通过既有消息完成。
- 不为等待状态增加高频轮询。优先复用连接事件和一次有界的 session-list 请求；
  重试需要退避、generation fencing 和取消。
- 连接页阶段变化只重建局部状态区域，不驱动会话列表、Markdown 或历史数据重建。
- 同一连接 epoch 的重复 `connected` 或重复 `session_list` 必须幂等。
- 不记录或展示 API key/token；诊断日志使用脱敏目标 identity。

#### 8. 实施前测试矩阵

至少补齐以下确定性测试后才能修改：

1. 冷启动、有保存地址、连接进行中：连接表单仍存在，阶段提示可见。
2. WebSocket ready、尚无 session list：仍在连接页，不展示会话首页。
3. 当前 epoch 收到空 session list：进入正常空首页。
4. 当前 epoch 收到非空 session list：进入会话首页。
5. 错误 token、连接拒绝、连接关闭、半开 socket、权威等待超时。
6. 自动连接期间取消、改选另一台机器；旧连接的迟到消息不得打开首页。
7. 同目标已就绪后的短暂重连：保留缓存首页并明确重连。
8. 冷启动不得继承上一进程 readiness。
9. 新 Mobile + 当前运行旧 Bridge；新 Mobile + 新 Bridge；无保存地址首次连接。
10. iPhone 前后台切换、LAN/Tailscale 地址和 SSH jump 连接路径。

#### 9. 验收标准

- 用户没有主动离开连接页前，App 不再用无上下文中央转圈替换整个页面。
- 会话首页只在当前目标的应用层权威数据就绪后首次出现。
- 任意失败路径都能回到可操作的连接界面，不会永久等待。
- 空会话与未收到会话列表有明确不同结果。
- 新旧 Bridge 兼容测试、Flutter 定向测试、iOS Simulator 构建和物理 iPhone
  真机复现通过后，才可标记完成。

### v02-002：把浮动按钮改成真正可展开、非模态的悬浮小窗

#### 1. 用户重新确认的产品定义

当前实现不是目标形态。目标不是“悬浮按钮 + 点击后弹出另一个窗口”，而是始终
位于会话页面上方、可以在自身范围内折叠和展开的悬浮小窗：

- 折叠时是贴边的小型入口或摘要，不妨碍页面操作；
- 点开后在原位置扩展为一个高信息密度的小窗，而不是打开底页、对话框或新路由；
- 展开后，用户仍可直接滚动、点击和输入底下未被小窗占据的会话页面；
- 小窗可拖动、贴边、部分隐藏并再次拉出；展开和折叠都不能制造全屏遮罩；
- 主要展示正在运行的子 Agent、官方临时会话及其状态；可酌情加入当前需要处理
  的批准、同步进度等短摘要，但不能把它变成第二个臃肿首页；
- 点进具体临时会话时继续复用项目已有的原生会话/侧边画布套件，只改变数据源和
  容器，不再造一套聊天界面。

#### 2. 已确认的当前实现

`AuxiliaryFloatingDock` 当前是固定 `48 × 48` 的可拖动按钮。点击后的主行为是
`showModalBottomSheet`，底页高度约为屏幕的 86%，内部再放“临时会话”和
“子 Agent”两个标签页。当前状态只保存按钮位置、是否半隐藏和是否正在拖动，
没有折叠摘要、展开小窗、窗口内滚动、窗口尺寸或非模态交互状态。

因此用户指出的差异是事实：

- 它的“悬浮”只发生在入口按钮上；
- 实际内容仍由模态底页承载，会遮住并中断原页面；
- 展开后无法同时操作原会话；
- 除了可拖动，和普通按钮打开页面没有本质的交互差异。

#### 3. 目标容器与交互边界

实施时应把它设计为会话页 `Stack/Overlay` 内的局部 surface，而不是
`Navigator` 路由或 modal：

```text
collapsed edge tab
        │ tap
        ▼
compact expanded panel
        │ 可在自身列表内滚动 / 可拖动 / 可折回
        └──────────────► underlying chat remains interactive outside panel bounds
```

- 窗口以安全区、键盘、横竖屏和当前输入栏为约束，拖动结束后自动收束到可见
  范围；不能永久掉到屏幕外。
- 展开尺寸应有上下限；内容超过窗口高度时只在窗口内部滚动，不让一次出现大量
  Agent/工具后把窗口无限拉长。
- 小窗外不得存在吸收触摸的透明全屏 barrier；只有实际可见窗口范围接收事件。
- 折叠态至少显示总数和最高优先级状态，例如“2 个运行中 / 1 个需处理”；展开态
  用紧凑行显示名称、类型、最近活动和状态。
- 关闭具体侧边内容后，临时会话仍留在小窗注册表中，直到官方生命周期真正到期
  或被显式结束；不能因为画布关闭而丢失入口。
- 展开状态、位置和贴边方向可在当前设备本地保存，但恢复时必须重新裁剪到当前
  屏幕和安全区；不把过期的运行状态持久化为事实。

#### 4. 性能与可访问性

- 小窗只订阅子 Agent/临时会话的轻量投影和计数，不订阅整段聊天正文。
- 用稳定 identity 和局部 selector 更新单行，不因流式正文 delta 重建整个小窗。
- 列表需要有界高度和惰性构建；动画只作用于 transform/opacity/size 的小区域，
  避免模糊、阴影和持续光晕造成整页离屏合成。
- 尊重 Reduce Motion、Dynamic Type、VoiceOver、键盘焦点和返回手势。
- 展开、拖动或贴边时不得抢占聊天列表的惯性滚动、输入框焦点或系统返回手势。

#### 5. 实施前与验收测试

实施前需先核对当前 side chat、官方临时线程、subagent registry 和侧边画布的真实
身份/生命周期，不能用 UI 条目自行推断线程仍存在。至少验证：

1. 折叠、展开、拖动、贴边、半隐藏、横竖屏和键盘出现/消失。
2. 展开时，小窗之外的聊天、输入框、工具折叠和页面滚动仍可操作。
3. 20 个以上条目时窗口自身滚动，尺寸不无限增长。
4. 流式输出和列表增量更新不重置窗口位置、展开态或内部滚动位置。
5. 关闭侧边画布后仍能从小窗找回尚有效的临时会话。
6. 临时会话过期、子 Agent 完成、Bridge 重连和 identity 切换后条目准确收束。
7. 新 Mobile + 旧 Bridge 时隐藏不受支持的类别，但不影响普通会话。

### v02-003：取消“激活/Ready”分层，重建会话事实与展示状态

#### 1. 用户确认的业务语义

- 所有可识别的持久会话都应是可直接点开、可继续使用的会话，不再分“未激活”
  “灰色 Ready”“橙色 Ready”这类可用性等级。
- `Working` 和“需要处理”仍是重要事实，但它们只表示当前活动与注意力，不表示
  该会话是否有资格被打开。
- 首页的会话条目应采用一个统一模型：会话始终可用，在其上叠加“正在运行”
  “需要批准/回答”“有未读”“正在同步”“离线缓存”等正交标记。
- 旧的“挂起、激活、驻留、最近会话、运行会话”逻辑可能仍散落在多个层次。
  实施前必须做一次完整全项目扫描，先重建事实模型，再删除或迁移旧逻辑，不能
  看见一个旧文案就直接隐藏。

#### 2. 已确认的当前源码事实

- 首页已存在 `UnifiedSessionListItem`，会按 provider 的持久会话 identity 合并
  running 与 recent 条目并统一排序。这一层结构应复用，不应重新造第三套列表。
- 但 UI 仍有 `SessionPrimaryStatus { working, needsYou, ready }`，并据此选择
  Working / Needs You / Ready 标签和顶条颜色。没有 runtime 的条目与有 runtime
  的条目仍走不同卡片分支。
- 当前 `Ready` 同时被用作“当前没有在跑”和“条目已可使用”的视觉含义，正是
  本轮需要拆开的概念。
- 当前代码中没有找到会话卡片直接显示“正在挂起”的固定中文文案。已确认存在的
  “暂停”主要包括：
  - Codex Goal 的权威 `paused` 状态；
  - App 生命周期 paused/hidden；
  - 文件传输暂停；
  - 后台通知说明中的“App 挂起”。
- 因此用户真机看到的“正在挂起”还不能仅凭静态字符串认定为某一条旧会话状态。
  它也可能是旧 Bridge 原始状态、Goal 暂停、pending action、旧产物或状态映射
  组合的结果。实施时必须抓取具体页面、条目 identity、消息类型和状态来源。

#### 3. 必须先完成的全项目业务扫描

正式修改前，建立一张从权威来源到 UI 的状态账本，至少覆盖：

| 事实层 | 需要核对的内容 | 不得混淆的概念 |
|---|---|---|
| Provider / app-server | 持久线程、当前 turn、Goal、临时线程生命周期 | 持久会话存在 ≠ 当前 turn 正在运行 |
| Bridge | runtime session、recent catalog、continuity、pending approval、重连 epoch | socket 存在 ≠ 历史已就绪 |
| Mobile 本地 | catalog cache、热缓存、完整本地副本、pending action、unread | 有缓存 ≠ 当前在线权威状态 |
| 页面状态 | loading、syncing、working、needs attention、offline/stale | 正在同步 ≠ 正在执行任务 |
| 辅助会话 | 官方临时会话、subagent、侧边画布容器 | 关闭画布 ≠ 结束线程 |

扫描必须追到每个枚举、协议字段、持久化键、排序投影、颜色/文案映射和旧测试，
并输出：

1. 唯一 identity 规则：machine/Bridge identity + provider + provider session ID。
2. 各状态的权威所有者、版本/sequence、有效期和重连清除条件。
3. 页面可见状态转换表，以及迟到消息和旧 connection epoch 的拒绝规则。
4. 仍有调用者的旧逻辑、已经不可达的遗留逻辑和可安全删除的生成/迁移路径。
5. 新旧 Mobile/Bridge/官方接口兼容矩阵。

只有完成这张账本，才能决定“正在挂起”究竟应删除、改名、迁入 Goal 卡片，还是
作为真实离线/暂停状态保留。合法的 Goal 暂停不能因为首页状态简化而被抹掉。

#### 4. 目标展示模型

会话卡片不再用互斥的 Ready/Working/Needs You 表达全部事实，而改为正交属性：

```text
ConversationAvailability: openable / unavailable-or-deleted
Activity: idle / running / compacting
Attention: none / approval / question / failed
Sync: current / syncing / offline-cached / stale / failed
Read: seen / unseen
```

- 对仍存在的持久会话，`openable` 是默认能力，不再要求先“激活”。
- `running`、`needs attention`、`unseen` 和 `syncing` 可同时存在，视觉优先级要
  明确但不互相覆盖。
- Bridge 断开时，已有缓存的会话仍可打开阅读，明确标为离线/可能过期；发送和
  需要在线权威的操作按连接状态禁用或排队。
- 旧 Bridge 没有某个新字段时采用保守兼容投影，不把未知状态伪装为 Ready。
- 最近使用排序继续以真实最新活动为主；缓存恢复时间、同步时间和“刚点开”不能
  篡改 provider 活动时间。

#### 5. 验收边界

- 首页不再要求用户先激活会话；任一已知持久会话可直接进入。
- Ready 不再作为和 Working 对立的业务状态；运行、注意、未读、同步分别可见。
- 重启、断网、重连、Bridge 切换和迟到消息不会把旧 Working/approval 标记带到
  错误会话。
- 用户复现的“正在挂起”取得可定位的事实来源并按上述状态账本处理；不能仅靠
  改文案通过。
- 旧 resident/activation UI 若被移除，要有 identity、缓存、恢复和兼容测试证明
  它已被新模型覆盖。

### v02-004：持久会话目录、最近会话热缓存与真正的增量同步

#### 1. 用户确认的目标

- 主会话列表能看到的所有会话及其最新摘要都应持久缓存到手机，不应每次启动、
  连接 Bridge 或展开项目时重新从零加载。
- 至少最近常用的 10 个会话要在手机保留最近内容；最终数量可以根据真机存储、
  内存和同步成本自适应，但不能低于满足本轮体验目标的基线。
- 已经同步过的时间段/ordinal/sequence 不得在下一次进程启动后重复下载和解析。
  Bridge 有增量时推送轻量变化，Mobile 事务性写入本地后局部更新。
- 用户点开最近会话时优先立即展示本地内容，后台只补当前缺失的增量；不再先等待
  数百条工具调用重复同步。
- “显示更多”应优先展开本地已知目录；只有本地确实缺少后续页时才向 Bridge
  增量请求。
- 设置中增加可理解的“清理缓存”，显示占用和清理范围。

#### 2. 已确认的现有基础与缺口

- 项目已有 SQLite Conversation Mirror，完整本地副本能跨进程保存，也有历史
  分页和增量 ordinal 基础。这是应优先复用/扩展的存储基础。
- 但完整副本目前是用户显式选择的 resident 行为，最多 8 个会话；它表示完整
  下载和自动同步，不等于本轮要求的默认“最近会话热缓存”。
- 现有 `ConversationMirrorService.removeLocalCopyTarget()`、存储层
  `listLocalCopies()` / `deleteLocalCopy()` 和会话内确认入口已经能删除一个完整
  本地副本；缺少的是设置页可用的全量投影、按占用排序、批量清理和统一状态管理。
  因此不得重写一套删除机制。
- 当前本地副本元数据已有 entry 数、字节数、项目路径、最后同步时间、自动同步和
  错误状态，但没有稳定保存完整的显示标题/摘要。设置页逐项列表需要和持久会话
  目录按 identity 关联，或只补一份明确可重建的显示投影，不能靠路径猜标题。
- `SessionListState.sessions` 仍是 server-loaded 内存列表。当前本地偏好只保存
  filter、project collapse、pin 等展示设置，没有持久的完整会话目录。
- `BridgeService` 的 recent sessions 也是进程内存。收到 catalog change 后，
  Mobile 会从 offset 0 重新请求一段有界列表，而不是把每个会话 delta 直接写入
  持久目录。
- 当前历史页和初始渲染预算中存在 200 条边界；另有一个“最多 500 页”的兼容
  保护用于向目标位置预加载。后者不是“最近 500 个工具调用”的业务定义。
  用户真机实际请求了多少页、多少外层消息和多少工具详情，实施前必须记录真实
  请求时间线，不能把不同常量混为一个根因。
- 当前没有全局会话缓存管理入口；只有单个完整本地副本的删除动作和若干进程内
  图片/命令缓存清理。
- “至少 10 个最近会话”不能通过把当前 full-resident 上限从 8 机械改成 10 实现。
  轻量目录、最近窗口热缓存和完整 resident watch 的成本不同，必须分别设预算。

#### 3. 建议的三层本地数据模型

避免再造相互竞争的数据库，把“目录、热缓存、完整副本”明确分层：

**A. 持久会话目录（所有已知会话）**

- 只保存轻量字段：稳定 identity、provider、项目/工作树、标题/摘要、权威最近
  活动时间、未读水位、最后已知 revision、是否归档/删除及必要兼容字段。
- App 冷启动即从本地展示；联网后按 revision 对账。
- 运行中、审批中这类易失状态必须带 connection epoch/有效期。进程重启后不可
  把上一次的 Working 当成当前事实。

**B. 最近会话热缓存（默认至少 10 个，真机压测后确定上限）**

- 保存最近外层轮次、可见中间输出、折叠结构和已取得的工具详情引用。
- 继续沿用 v01 的分层加载原则：初次渲染优先保证最近 5 轮及其外层输出可读，
  工具摘要/详情有界并按需展开；“存到了本地”不等于“一次性构建全部 Widget”。
- 已经请求并校验过的工具详情可按 ID/ordinal 持久复用，不能每次进入重新下载；
  超出显示预算的内容留在存储层，按需物化。
- 热度以 provider 活动时间、用户最近打开和未读/运行需要综合计算；不得仅因
  App 启动或缓存恢复而刷新排序时间。

**C. 完整本地副本 / resident**

- 继续表示用户显式下载的完整离线副本，可保留独立配额与完整性校验。
- 它不是首页的特殊“会话类型”，只是在同一个会话条目上的离线能力属性。
- 通用“清理缓存”默认不得悄悄删除完整副本；删除完整副本要单独列出、确认并
  说明不可离线查看的影响。

#### 4. 增量协议和一致性方向

- Mobile 每个目录条目和会话窗口保存权威 cursor/revision/ordinal 水位。
- Bridge 优先发送 catalog delta 或“revision 已变化”的轻量通知；新协议必须
  capability-gated、additive，并支持旧 Mobile。
- 新 Mobile 对旧 Bridge 回退为有界的 revision/list/history 对账，但只写入差异，
  不清空本地后重建。
- 会话历史按“已知水位之后”获取；重连、重复 push 和迟到页必须幂等去重。
- 当检测到截断、回滚、identity 改变或历史重写时，进入明确的局部重置/修复
  流程，不能把两个世代拼在一起。
- 列表摘要、未读水位和正文事务要么按明确顺序提交，要么用同一 generation
  fence，避免列表显示“已更新”但正文尚未落盘。
- Bridge/provider 仍是 canonical authority；手机缓存必须可重建，不得反向成为
  会话身份或历史真相。

#### 5. “清理缓存”设置

设置页应先计算并展示类别及大致占用，再允许清理：

- 一个“清理可重建缓存”入口：会话目录投影、最近消息热缓存、工具详情、预览和
  可重建缩略图；执行前显示预计释放空间和离线影响；
- 一个独立的“已下载会话历史”管理页：逐项显示标题/项目、大小、最后同步时间和
  自动同步状态，并支持逐项确认删除；
- 普通“一键清理缓存”不得提供或暗含“清除全部已下载历史”。以后若用户另行要求
  批量删除完整副本，应作为独立高风险功能重新确认；
- 传输中断点、用户设置、连接凭据、草稿和未发送队列不应被普通缓存清理误删。

清理后 App 应能从 Bridge 安全重建；离线时明确哪些内容暂不可用。清理过程需要
事务、取消/失败恢复和空间统计测试，不能直接删除整个数据库文件导致其他功能
一起丢失。删除正在打开、正在 watch 或正在分页的副本时，先取消对应请求和 watch，
再以 generation fence 拒绝迟到帧；视图可退回在线/无缓存状态，但不能闪退或把
已删除内容重新写回。

若以后明确增加完整副本的多选/批量删除，不能循环调用当前“单条删除后立即
`incremental_vacuum`”的路径；届时应提供一次事务内删除所选 rows、提交后只做
一次有界增量回收的批量 API。该未来能力不属于本轮当前要求。完整副本与普通
可重建缓存始终保持两个确认边界。

#### 6. 性能和验收指标

- 冷启动先显示本地会话目录，不等待 Bridge 才出现项目和会话。
- 最近至少 10 个会话在二次打开时立即出现最近可读上下文，后台只请求缺失增量。
- 对一个无新增消息的热会话，重启后进入不应重新请求同一批历史/工具详情。
- 目录有数千会话时，启动只读取列表所需投影，不反序列化所有正文。
- 收到一个会话 delta 时，只更新对应目录行、未读水位和该会话存储，不重建整个
  首页或其他会话。
- 内存、SQLite 大小、写放大、首屏时间、恢复同步时间、CPU/能耗和掉帧都要在
  真机基线/优化后对比；不能通过截断真实数据或不显示状态伪装性能提升。
- 旧 Mobile + 新 Bridge、新 Mobile + 旧 Bridge、新旧缓存数据库升级/回退以及
  Bridge identity 切换都必须有测试。

### v02-005：区分“创建、加载、同步”，只给真实消息/更新显示权威时间

#### 1. 已确认的问题

- 新建会话和恢复既有会话目前都只传一个 `isPending` 布尔值。
- pending 页面无论操作类型都使用同一个 `creatingSession` 文案，所以点开既有
  会话也会显示“正在创建会话……”。
- `ChatEntryWidget` 当前在每个可见 `ChatEntry` 前无条件插入时间戳，因此工具、
  状态、同步或其他非消息条目也可能得到独立时间。

#### 2. 目标语义

- 真正创建新线程：`正在创建新会话`。
- 第一次打开尚无本地正文的既有线程：`正在加载会话`。
- 已有缓存、正在追增量：立即显示缓存，在工具栏/列表局部显示
  `正在同步最新内容`，不得退回全屏 pending 页面。
- Bridge 重连或目录刷新：`正在重新连接/同步会话列表`，不能叫创建会话。
- 文案由明确的 pending operation kind / sync phase 驱动，不能再用一个 boolean
  猜测。

时间戳采用以下规则：

- 显示在真实用户消息、助手最终消息，以及产品确认需要展示的可见中间文本更新
  附近，精确到秒。
- 时间来源优先使用电脑/provider 收到该事件的权威时间，不使用手机同步落盘时间。
- 老历史缺失权威时间时可显示明确的近似时间或不显示，不能伪造精确值。
- 激活、恢复、同步、缓存命中、内部 tool bookkeeping 和列表刷新不单独插入
  消息时间戳。
- 同一可见消息只显示一次；折叠/展开和增量合并不能复制时间戳。
- 工具组/过程折叠行把时间放在右侧、展开箭头左侧，与“多个命令已完成”处于同一
  行；已完成组使用该组最后一个可见事件的权威时间，运行中组使用最新可见事件。
- 普通消息优先把时间放进气泡现有的右下或标题尾部空间；空间不足时允许在气泡
  内换行，但不得另占一条全宽分隔行。
- 思考、临时输出等无法自然内联的自由文本，使用紧贴正文的顶部 trailing 小字，
  与正文保持最小间距；不能把时间插到两个工具调用或两条分割线之间。
- 当前 Bridge 已为实时事件附加 `receivedAt`，Mobile 也保留
  authoritative/approximate provenance；本项主要调整布局和聚合语义，不重造
  时间来源。

#### 3. 测试和验收

1. 新建、无缓存恢复、有缓存恢复、离线打开、重连同步分别显示正确阶段。
2. 已有缓存时首屏正文立即可读，增量同步不会替换成“正在创建”。
3. 用户/助手消息显示电脑端权威 `HH:mm:ss`；同步时间变化不改变既有时间。
4. 工具详情、激活事件和缓存/同步状态不产生额外消息时间戳。
5. 历史分页、折叠展开、重复 delta 和 App 重启不会复制或重排时间。
6. 新旧 Bridge 缺失时间字段时采用兼容回退，不导致消息解析失败。
7. 增加布局/golden 验收：工具组时间位于 chevron 左侧，普通气泡和自由文本没有
   新增全宽时间行，Dynamic Type/窄屏下不遮挡内容且整体高度明显小于当前实现。

### v02-006：本批需求的实施顺序与“先审计、后重构”门禁

本批内容不能按 UI 现象逐项打补丁。用户确认实施后，建议按以下顺序推进：

1. **全项目状态、身份与来源审计**：完成 v02-003 的状态账本，真机定位
   “正在挂起”；同时记录打开会话时实际目录/历史/工具请求时间线，并完成
   v02-007 的 Codex Home、app-server 与 thread owner 盘点，以及
   v02-008～v02-010 的目录就绪、历史 single-flight 和 disclosure ownership
   审计。
2. **会话权威与单写者门禁**：在扩展缓存前先确定每个会话的来源身份和唯一写入
   所有者；禁止把两个 Codex Home 盲扫后只按 thread ID 合并。
3. **持久数据基础**：在现有 Mirror/SQLite 体系上实现会话目录和热缓存，建立
   revision、identity、generation 与清理边界。
4. **直接可用的会话模型**：把运行、注意、未读、同步从 Ready 可用性中拆开，
   迁移首页和恢复链路。
5. **局部交互调整**：实现真正的非模态悬浮小窗、正确 loading 文案和类型化
   时间戳；继续复用原有 side chat/subagent UI。
6. **回归与遗留清理**：只有调用链和测试证明新模型已覆盖后，才删除旧 activation、
   resident 分类展示或不可达状态；发现的业务 bug 先证实再修。
7. **完整性能审查**：功能完成后再做全 App 的 CPU、内存、SQLite、流式重建、
   首页目录、会话打开、后台增量、动画和能耗审查，并进行针对性优化。
8. **官方更新与发布**：重新获取并语义合并届时最新官方 commits，复跑新旧
   Mobile/Bridge、iOS Simulator/真机、通知/后台和 IPA 验收；未经确认不晋级
   stable。

每一步应按行为拆分可独立回滚的 commit。本文给出方向和已知边界，不限制实施时
基于更完整证据修正数据模型；但任何修正都要回写方案/decisions，并说明为何与
当前草案不同。

### v02-007：Cockpit 双 Codex 实例的会话权威、同步与并发写入安全

#### 1. 用户提出的问题

- 当前通过 Cockpit 同时运行了两个 Codex Desktop 实例。
- 用户需要确认两者是共用会话文件还是各写各的、Cockpit 所谓“同步”是否会造成
  冲突，以及 CC Pocket 最终读取哪一个实例。
- 本项只做只读取证和设计登记；当前没有修改 Cockpit、Codex、Bridge 或 Mobile
  的配置和代码。

#### 2. 当前这台 Mac 上已确认的存储拓扑

当前不是“两个窗口共用一套完整状态”，而是“两个独立索引库，加上一批指向同一
权威 rollout 的已导入记录”：

- 普通 Codex 使用 `/Users/huyiyang/.codex`。
- Cockpit 的 `team` 实例使用独立的
  `/Users/huyiyang/.antigravity_cockpit/instances/codex/f894427cc1c571f7`；
  Chromium user-data 也通过单独的 `--user-data-dir` 隔离。
- 两边的 `state_5.sqlite`、WAL、日志、目标和 `sessions/` 都是不同 inode，不是
  硬链接；Cockpit 实例仅把 rules、skills、AGENTS 等规则入口链接回默认目录。
- 两边当前各有 1,131 条 thread 记录。thread ID 集合相同，已导入记录的
  `rollout_path` 也相同；绝大多数实际指向普通
  `/Users/huyiyang/.codex/sessions/...`，而不是 Cockpit 自己的 `sessions/`。
- 两个 `sessions/` 目录内看起来各有一套 JSONL，但 Cockpit 目录中的文件是独立
  副本，不是实时镜像。以当前协调会话为例，Cockpit 副本是主文件前 18,580 行的
  严格旧快照；普通目录的主文件随后又追加了 480 行。
- 当前普通主文件共 19,060 行，没有发现无法解析的 JSON 行；两套 SQLite 的
  `integrity_check` 均通过。两边已有 3 条相同 thread 的标题/更新时间/归档等
  元数据不一致。结论是“目前没有发现文件已经损坏”，而不是“结构天然安全”。

上述数字是 2026-07-26 的现场快照，不能作为以后固定常量。

#### 3. Cockpit 当前版本的“同步”到底是什么

当前安装的 Cockpit Tools 1.3.14 的本地配置中，`autoSyncThreads=true`。已安装
程序和 v1.3.14 对应源码确认，它实际提供两类不同语义的操作：

1. **“同步所有实例记录”是停机后的事件行级全量合并。** 它递归扫描每个 Home 的
   `sessions/` 和 `archived_sessions/`，按 thread ID 分组；同 ID 的多份 rollout
   会整文件读入，按完整 JSON 值或原始行去重，提取可识别时间戳后重新排序，再把
   结果写回所有来源。它会备份 `session_index.jsonl`、
   `.codex-global-state.json` 和被覆盖的旧 rollout，但不会直接备份
   `state_5.sqlite`、WAL、SHM。同步后再调用各目标 Home 的官方 app-server，
   触发元数据重建。
2. **“复制到某实例”或导入包是缺项复制。** 目标已存在相同 thread ID 时直接
   跳过，不做事件合并。此前“已存在的 thread 不覆盖”的结论只适用于这一类操作，
   不能用于描述“同步所有实例记录”。

自动全量同步只在启动前发现全部实例已停、停止最后一个实例后，或关闭全部实例后
触发；手动界面也会在有运行实例时拒绝。底层同步函数本身没有绝对禁止运行中调用，
所以其他调用入口仍必须守住停机门禁。

当前普通目录的活跃 rollout 已继续增长，而 Cockpit 自己的副本仍停留在旧时间点，
且两个 Home 都没有出现全量同步生成的 `backup-*-instance-thread-sync` 目录。
因此它不是运行中 app-server 之间的实时事务同步；现场更准确的解释是“创建实例时
复制出的旧快照尚未完成一次全量同步”。全量同步虽会合并同 ID 的事件行，但其
“完整 JSON 去重 + 时间戳排序”没有 thread owner、因果 revision 或业务级冲突
判定，仍不能作为并发双写的冲突解决器。

当前两套 `sessions` 的逻辑规模各约 26 GiB，最大 rollout 约 2.81 GB。同步算法
会多次整文件读取，并同时持有行、去重键和输出；在当前数据规模下，自动全量同步
有显著 I/O、内存和卡死风险。完整架构、算法和可迁移审计方法记录在
`notes/cockpit-codex-multi-instance-architecture_v01_20260726-012035.md`。本结论
绑定当前本机安装版；升级 Cockpit 后必须重新核对源码和现场状态。

#### 4. CC Pocket 当前读取哪一份

当前 Bridge 的源码和运行配置给出了明确答案：

- `packages/bridge/src/sessions-index.ts` 的 `listCodexSessionFiles()` 固定扫描
  `homedir()/.codex/sessions`；会话名、权限配置等其他 Codex 辅助文件也固定写在
  `homedir()/.codex`。
- `packages/bridge/src/codex-transport.ts` 启动 `codex app-server` 时继承 Bridge
  的环境。当前运行的 Bridge LaunchAgent 没有设置 `CODEX_HOME`，因此仍使用普通
  `/Users/huyiyang/.codex`。
- 当前会话 identity 没有 `codexHomeId` / Cockpit instance ID 这一维。若以后
  直接增加第二个扫描根并仍只按 provider + thread ID 去重，同一 thread 的主本
  和旧快照会发生碰撞，选择哪个文件还可能取决于目录遍历顺序。

所以现阶段 CC Pocket 的事实权威是普通 `~/.codex`，不是“随机选择两个实例”。
这也带来一个缺口：若在隔离的 Cockpit Home 中创建了真正的新 thread，而它尚未
停机同步到普通目录，CC Pocket 不会看到它。

#### 5. Codex 自身的并发边界与风险判断

官方 Codex app-server 的 `thread/resume` 会从 rollout JSONL 恢复线程；官方
`RolloutRecorder` 以 read + append 打开已有文件并逐行写入、刷新。当前源码没有
显示针对同一 rollout 的跨进程独占文件锁。`ThreadManager` 可以阻止同一个
app-server 进程内重复加载同一 thread，但从实现结构推断，它不能替两个彼此独立
的 app-server 建立全局所有权：

- <https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md>
- <https://github.com/openai/codex/blob/main/codex-rs/rollout/src/recorder.rs>
- <https://github.com/openai/codex/blob/main/codex-rs/app-server/src/request_processors/thread_processor.rs>

据此分级：

- **只运行两个实例、各自操作不同 thread：风险较低。** 新 thread ID 不同，
  主要问题是 CC Pocket 可见性和 Cockpit 停机同步延迟。
- **两个实例同时恢复并发送同一个 thread：高风险。** 两个 app-server 都可能
  认为自己是当前运行对象，事件、turn 和元数据会按不同进程的时序交错；追加
  模式只能降低直接覆盖概率，不能提供语义单写者或冲突解决。
- **两边同时重命名、归档、删除同一 thread：中高风险。** 即使 rollout 正文没坏，
  两套独立 SQLite / index 的目录状态也会分叉。
- **Cockpit 停机同步：不能当并发安全机制。** 全量同步会合并同 ID 的事件行，
  但只有完整 JSON 去重和时间戳排序，无法识别哪个 turn、审批或元数据版本才是
  业务权威，也无法还原两个 app-server 并发写入的因果顺序。

当前没有观察到 JSONL 损坏，不能据此宣称未来并发写同一会话安全。反过来也不能
仅因为两个进程都打开了同一文件就断言它们已经同时写坏；需要区分读取/监听和
真正发送 turn。

#### 6. 在正式修改前的临时使用规则

1. 暂时把普通 `~/.codex` 视为 CC Pocket 和共享会话的唯一权威 Home。
2. 可以同时运行两个 Codex 实例，但同一个 thread 在同一时刻只能从一个实例发送
   消息、审批或继续任务；另一个实例最多只读查看。
3. 不要在两边同时对同一 thread 做重命名、归档、删除或 fork 后回写。
4. 不要在 Codex 运行时手工复制/覆盖 `state_5.sqlite`、WAL 或 rollout JSONL。
5. 当前不要点击“同步所有实例记录”；并建议先在 Cockpit UI 关闭自动同步会话。
   本次只做调查，尚未替用户修改该设置。需要导入 Cockpit 独有的新 thread 时，
   先做可恢复备份，并在副本或改进后的流式同步实现上验证；不能直接拿当前约
   52 GiB 逻辑数据做首次试验。
6. 若发现同一 thread 两份 JSONL 已经不是“严格前缀 + 新尾部”关系，应只读保存
   两份证据并停止自动覆盖，由工具做结构化冲突审计；不要文本拼接。
7. 单独“复制到实例”遇到相同 thread ID 会跳过，也不能用来追平一个已存在但落后
   的副本。

#### 7. 后续实现方向：显式来源 + 每会话单写者

本项应先于 v02-004 的持久目录/热缓存实施，否则手机可能把错误来源永久缓存。
建议目标不是“把两个目录都扫一遍然后合并”，而是：

- 建立显式 Codex Source Registry。每个来源保存稳定 `codexHomeId`、实例名、
  规范化 Home 路径、状态库和 app-server 连接方式。
- 会话内部身份至少包含 machine/Bridge identity、provider、`codexHomeId` 和
  thread ID；旧客户端仍通过 capability-gated 回退到单一默认 Home。
- 每个 thread 建立唯一 owner/lease。Bridge 恢复或发送 turn 前确认写入所有者；
  其他实例只能只读或明确把所有权转交，不能各自启动 app-server 写同一 rollout。
- Bridge 启动 app-server 时显式传入与该来源一致的 `CODEX_HOME`；历史读取、会话
  名、权限配置和追加操作也必须解析到同一来源，不能一半读默认 Home、一半写实例
  Home。
- 聚合目录可以统一展示，但去重必须先识别“同一来源”“严格前缀副本”“内容已经
  分叉”三种情况。严格前缀只能选择权威，不复制成两个会话；分叉必须标记冲突，
  禁止自动拼接或静默覆盖。
- Cockpit 全量同步只作为外部导入信号，CC Pocket 不把它当事务协议或因果合并
  协议。必要时提供只读冲突检测器和来源诊断页，但普通无冲突场景不增加用户操作
  负担。
- 为避免性能回退，不得在每次列表刷新时扫描两套共约 52 GiB 的 JSONL。优先读取
  各自 SQLite/index 元数据、文件 revision/mtime/size 和增量尾部；正文只按需读。

#### 8. 实施前测试与验收矩阵

1. 两个临时 `CODEX_HOME`：不同 thread、相同 thread 的严格前缀副本、真正分叉
   副本分别识别正确。
2. 两个 app-server 同时请求恢复同一 thread 时，第二个被拒绝、降为只读或通过
   显式转交接管，不能静默双写。
3. owner 崩溃、Bridge 重启、lease 超时和转交晚帧不会形成双 owner。
4. 一个实例创建新 thread 后，在 Cockpit 尚未停机同步时，CC Pocket 明确标识
   来源和可见性，不把“没找到”误报为删除。
5. 重命名、归档、删除和 fork 在双 Home 下保留来源身份；全量事件合并与目标
   缺项复制都不能掩盖冲突。
6. 旧 Mobile + 新 Bridge、新 Mobile + 旧 Bridge 仍维持默认单 Home 语义。
7. 数千 thread、两个 Home、数十 GiB rollout 下测量目录首屏、增量索引 CPU、
   内存、磁盘读取和电量；禁止以全量双目录轮询换取表面实时性。

### v02-008：连接后会话摘要必须就绪，首页不能先显示整页 “no description”

#### 1. 用户可见现象与本轮决定

- 点击连接 Bridge 后进入主会话列表，所有卡片会先显示
  `(no description)`，稍后才出现真实摘要。
- 这会让用户误以为会话丢失、索引损坏或 Bridge 读错了数据源。
- 用户允许在进入首页前短暂加载，但本方案不采用固定等待 1～2 秒。固定延迟在
  快设备上白等，在慢连接上仍会穿透；应等待真实的目录就绪条件，并显示当前阶段。
- 本项与 v02-001 是同一条连接门禁的下一层：`session_list` 运行态快照就绪不等于
  `recent_sessions` 会话目录、摘要和当前筛选结果已经就绪。

#### 2. 已确认的当前调用链

- `SessionHomeConnectionGate` 只检查 transport connected 和当前连接的权威
  `session_list` generation。收到运行对象快照后即可放行 connected 首页。
- 完整主列表由另一条 `recentSessionsStream` 驱动；`SessionListState` 只有收到
  第一份 recent response 后才把 `isInitialLoading` 设为 false。
- `HomeContent` 在 initial loading 期间若已经有 runtime rows，仍可能先渲染这些
  行，而不是保持完整 skeleton。
- `RecentSession.displayText` 在 summary 和 firstPrompt 都为空时直接返回字面量
  `(no description)`。因此这里不是 provider 把所有摘要删了，而是 UI 把
  “当前尚未取得元数据”和“权威确认的空会话”折成同一占位文案。
- 现有 Bridge/Mobile 的 recent catalog 只在进程内缓存；同目标短重连可能暂时
  保留，切换目标会清空，App 冷启动也没有可直接显示的持久目录。

#### 3. 目标就绪模型

连接首页至少区分以下互不替代的阶段：

```text
transport
  └─ current-connection runtime snapshot
       └─ current target + filter 的 catalog snapshot
            └─ 可选：recent hot-content reconciliation
```

- **有属于同一 Bridge/machine identity 和筛选条件的持久目录缓存**：首页可立即
  显示真实缓存标题/摘要，同时用非阻塞小型状态提示“正在同步会话列表”。新空值
  不得覆盖已有摘要，除非带当前 generation 的权威删除/清空事实。
- **首次连接且没有缓存**：保持连接页中的“已连接，正在读取会话列表”阶段，或
  显示有明确 loading/progress 语义的会话 skeleton；不得渲染一屏
  `(no description)`。收到当前 query 的 authoritative response 后再进入正常首页。
- **权威返回零项**：显示“当前筛选下没有会话”，不能继续转圈，也不能显示损坏
  占位。
- **目录请求超时/失败**：显示可重试、可诊断的失败状态，并保留已确认的连接事实；
  不能把超时当空列表或自动跳到消息页。
- **单个真实空会话**：可显示“空会话/暂无消息”。“摘要尚未加载”“会话确实为空”
  和“摘要解析失败”必须是三个不同状态。

catalog readiness 必须携带 Bridge identity、connection epoch、provider/filter、
request ID 或 query generation。旧连接、旧筛选和旧机器的迟到 response 不得
解除当前首页门禁。

#### 4. 性能与兼容边界

- 不为了首屏就绪读取正文或解析工具详情；只取目录投影。
- 有缓存时不增加阻塞等待；没有缓存时等待的是实际响应，而不是任意动画时长。
- 新 Mobile + 旧 Bridge 可用一次有界 recent list response 作为就绪边界；新
  catalog generation 字段采用 additive capability。
- 会话目录缓存必须按 machine/Bridge identity 分区，不能在两个 Bridge 或
  v02-007 的两个 Codex Home 之间混用。
- 不用每次 runtime status 更新重新请求目录；runtime 状态和 durable catalog
  可在投影层按 identity 合并。

#### 5. 测试与验收

1. 首次连接：runtime snapshot 先到、recent catalog 后到，期间不出现任何
   `(no description)` 卡片。
2. 有缓存重连：真实缓存摘要立即出现，迟到空 runtime metadata 不覆盖它。
3. 空列表、筛选无结果、单个空会话、目录超时分别显示不同状态。
4. Bridge A 的迟到 catalog 不能放行或污染已切到 Bridge B 的首页。
5. 快连接不被固定延迟拖慢；慢连接不在固定秒数后穿透门禁。
6. 首页可交互时必须已经满足“有同目标缓存”或“当前 query 权威返回”之一。

### v02-009：紧凑时间戳、可感知的八行过程框与统一展开状态

#### 1. 已确认的三个根因

1. `ChatEntryWidget` 当前在每一个可见 entry 顶部无条件插入居中的独立
   `_TimestampWidget`，并带上下间距。这正是时间戳出现在工具之间、占据大量高度
   的直接原因；现有测试只验证 `HH:mm:ss` / `~HH:mm:ss` 文本，没有验证位置。
2. `_ProcessDetailsViewport` 已经按“8 个紧凑行高”和屏幕高度 55% 取较小值，
   内部也可滚动；但它没有边框、底色、上下溢出提示或足够明显的 scrollbar，
   用户难以感知那是一块独立可滚动区域。
3. 当前活动回合在 streaming 与 persisted 两条渲染路径之间切换：
   - 有 transient stream 时，layout 故意不生成 persisted `currentSegment`；
   - persisted 过程框只在非 streaming 路径显示；
   - live 展开 key 使用 `live:<turn>`，persisted 使用 `entry:<turn>`。
   因此工具 → 思考 → 新工具的增量转换会让过程框消失、思考回到“当前进度”，
   随后又出现一个过程框。局部 `Set` 没有一定被清空，但渲染 owner 和 key 已换，
   用户看到的效果仍等同于被折叠。

#### 2. 统一活动回合过程面

每个 durable turn 只允许一个稳定的 process surface：

- key 使用 provider/turn 的稳定 identity，不再包含 `live:` / `entry:` 这种渲染
  来源前缀；
- persisted 工具、live 工具、live thinking 和已落盘的中间输出进入同一有序
  过程模型，按稳定 item/sequence 合并；
- **折叠时**，“当前进度”可以展示最新 thinking/tool 的单行摘要；
- **展开时**，thinking、工具调用、工具结果和对应风险提示都留在过程框内；框外
  的“当前进度”不再重复显示 thinking；
- 最终 assistant 回复仍使用普通最终消息组件，不因为过程框展开而复制到框内；
- 新增 delta、history replacement、Mirror reconcile、工具转 thinking、thinking
  转工具都只更新框内内容，不改变用户展开意图；
- 只有用户显式收起、切换 durable 会话、执行全局折叠，或结构经 identity 校验
  确认已经失效，才允许清除展开状态。

这需要先把 live/persisted process ownership 统一到 projection/reducer 层，
不能只在 Widget 中把两个 key 改成相同字符串，否则重复项和迟到事件仍会争抢。

#### 3. 八行过程框的视觉和滚动规范

- 最大高度仍是当前宽度、Dynamic Type 和屏幕安全区下约 8 个紧凑工具行的容量，
  不是只保留 8 个数据项；更多内容通过框内纵向滚动查看。
- 思考文本可能比工具行高，因此使用“等价 8 个紧凑工具行的最大高度”而不是伪称
  永远恰好露出 8 个语义 item。
- 增加静态、低成本的圆角底色和 1px/物理像素边界；只有内容可滚动时显示明显的
  scrollbar，并可用顶部/底部轻微渐隐或阴影提示还有内容。
- 渐隐不能使用持续动画、每帧 shader 重建或大范围 backdrop blur。滚动状态改变
  时才更新，Reduce Motion 下保持静态。
- 边框与背景要在明暗主题、高对比模式和 Dynamic Type 下可辨识，但不抢正文层级。

#### 4. 时间戳与过程框协同

- 工具组摘要时间按 v02-005 放到右侧 chevron 左边；框内每个工具默认不再额外
  占一整行时间。
- 只有确实需要区分发生顺序的 thinking/工具详情才在自身 trailing 位置显示小字；
  不用时间戳代替 canonical sequence 排序。
- 增量更新只能继承原事件时间，不能以“框重新出现/本地重建时间”刷新。

#### 5. 必须新增的回归

1. 展开当前过程框，依次注入 tool use → thinking delta → tool result → 新 tool；
   同一 viewport 和同一 expansion key 始终存在。
2. expanded 时 thinking 只在框内出现一次；collapsed 时只在当前进度出现摘要。
3. canonical history 替换 live provisional 项后，展开状态、滚动位置和 anchor
   均保留，且没有重复工具/最终回复。
4. 9 个以上工具及长 thinking 在框内滚动；边界、scrollbar/overflow affordance
   可见，外层聊天列表不被一次展开撑得极长。
5. 时间戳不出现在两个工具之间的独立全宽行；窄屏和大字体下不遮挡 chevron。
6. 对长会话测量增量更新的 build/layout、滚动掉帧和内存；装饰层不得引入持续
   repaint。

### v02-010：会话目录同步、查看、增量追平与“激活”业务逻辑全局审计

#### 1. 本项范围和关键结论

本项不是一次大重写授权，而是把用户要求的“所有会话随时可点开”和现有运行时
机制重新分层。首轮静态调用链审计已经确认：

- **所有会话可直接查看/使用，不等于把所有会话都 resume 成 active runtime。**
- 当前前台恢复会先取权威 `session_list`，随后对
  `BridgeService.sessions` 中每个 active runtime 请求 history，并并行对账最多
  8 个 resident。若机械地把整个目录都变成 active，会把当前有界路径放大为
  全会话 history 风暴。
- 正确方向是：所有 durable conversations 都有本地目录和可打开的轻量/热缓存；
  只有发送消息、审批、明确需要 live stream 或 provider 要求时，才建立/接管
  runtime attachment。

后续实施前仍要在届时 HEAD、真实 Bridge 日志和真机时间线上重新审计。下列是本次
已经取得的方向性证据，不限制实施时发现更深层问题后修正。

#### 2. 当前目录同步链路与已确认风险

当前链路大致是：

```text
Codex/Claude 会话文件变化
  → Bridge SessionCatalogMonitor debounce / revision
  → Mobile catalog changed
  → Mobile 再请求当前筛选的 recent prefix
  → Bridge 重新列目录并投影 metadata
  → Mobile 替换 prefix、保留旧 tail
```

已确认的事实和问题：

- Bridge watch 当前采用约 750ms debounce、2.5s 最小间隔和 15s retry；Mobile
  另有约 250ms debounce、单 in-flight + dirty latch、15s timeout。基本防抖已经
  存在，不应再叠加无界 timer。
- Codex catalog refresh 仍可能递归枚举整个 `~/.codex/sessions`，并为最多 200
  个需要摘要的会话做有界头尾解析。当前文件规模尚未撞到 watcher 上限，但活跃
  rollout 连续写入时，约每 2.5 秒重复目录枚举/metadata 解析仍是可避免的成本。
- metadata fallback 中存在“对每个文件匹配 wanted IDs”的多重查找，最坏可能接近
  files × wanted IDs；应先以 canonical rollout path/thread ID 建索引。
- Mobile 的 catalog refresh 只替换已请求 prefix 并保留旧 tail。若 tail 中的
  会话被删除、归档或改变，而它不在本次 prefix 内，旧条目可继续残留到更深层
  全量/筛选刷新。
- top-level/filter 的 Bridge 工作已有每 WebSocket generation 保护，但 append、
  project 和 catalog response 缺少贯穿协议的显式 request/query identity；
  Mobile 仍过度依赖当前 scope 和本地状态推断迟到响应属于谁。
- watcher 达到目录上限时覆盖可能退化，当前接口没有足够清晰的健康状态告诉
  Mobile“实时目录 watch 已不完整”。这不是本机当前故障，但属于未来规模风险。
- same-target reconnect 可保留进程内 recent list，App 冷启动和 target switch
  没有持久目录；这与 v02-008 的首屏空摘要直接相连。

#### 3. 当前查看/激活/history 链路与已确认风险

- 点击既有 recent session 目前立即调用 `SessionResumeCoordinator.resume()`，
  Bridge 随即执行 resume；UI 再打开一个 `pending_resume_*` 路由。也就是说
  “查看已有会话”和“激活 provider runtime”仍是同一个动作。
- Codex/Claude pending screen 各自复制了一套 binding/subscription 逻辑，且一个
  `isPending` boolean 同时代表 create 和 resume，所以恢复会话显示
  `正在创建会话`。两端重复代码也容易在错误、取消、迟到 session_created 和
  draft 迁移上漂移。
- Conversation Mirror 的本地 bootstrap 目前在 `ChatSessionCubit` 和
  runtimeSessionId 已存在后才启动；它不能单独支持“先离线打开 durable thread，
  再按需 attach runtime”。
- `ChatSessionCubit` 会依次恢复 Bridge 进程内 runtime 消息、尝试本地 Mirror，
  再按情况请求 canonical history。同一内容可能经过多条 decode/merge 路径。
- 当状态长期停在 `starting` 时，当前 3 秒 periodic timer 会持续请求 history；
  Mirror bootstrap 成功也只延迟两个 tick。若 resume 丢失或状态永不收束，会形成
  无明确总次数/截止时间的重复请求。
- history 请求不只来自 chat cubit，还来自 Desktop continuity tracker、Mirror、
  foreground/background coordinator、手动刷新和错误恢复。`BridgeService` 有
  pending/active 展示集合，但没有真正的 per-session request single-flight；
  同一会话的多个 delta 请求会重发，后来的调用还会覆盖之前记录的
  `allowFullFallback` 策略。
- 前台 background-sync coordinator 会先刷新权威 runtime list，再对所有 active
  runtime 并发 history reconciliation；后台只对已有 cached sequence 的 active
  runtime 发送 delta-only。它处理的是运行对象，不是 durable catalog 的所有会话。
- Desktop list continuity watch 只覆盖活跃 Codex runtime，并在首页 tracker 与
  打开聊天的 cubit 之间转移 watch ownership；反复进入/退出会话可能产生
  unwatch/rewatch、ack retry 和 displaced ownership 竞态。
- `ProcessStatus.fromString()` 对未知未来状态直接回退 `idle`，
  `sessionVisualStatusFor()` 又把其他未知 raw status 显示为英文 `Ready`。这会把
  官方新增状态静默伪装成可用/空闲，既是兼容风险，也解释了为什么当前“Ready”
  不能再承担会话可用性语义。

#### 4. 已确认 bug、设计缺口与暂不下结论项

| 分类 | 当前结论 | 处理原则 |
|---|---|---|
| 首页全是 no description | 已确认 readiness gap | v02-008 按真实 catalog generation 修 |
| 既有会话显示“正在创建” | 已确认 create/resume 被一个 bool 合并 | 改为类型化 operation |
| starting 每 3 秒无限请求 history | 已确认无总截止/退避 | single-flight、deadline、指数退避 |
| 多调用者覆盖 history fallback 策略 | 已确认共享 map 的 latest-writer 行为 | 建 per-session arbiter |
| catalog prefix 保留陈旧 tail | 已确认当前替换算法可能发生 | delta delete 或 generation/page 对账 |
| 进入会话会立刻 resume | 已确认当前产品耦合 | durable view 与 runtime attach 分离 |
| 未知 provider status 显示 Ready | 已确认兼容回退过强 | 保留 raw/unknown，不伪造 idle |
| “正在挂起”具体触发序列 | 尚未取得真机事件线 | 实施前加结构化 phase/epoch 诊断复现 |
| 同步后重复消息/折叠异常的所有根因 | 已确认多来源竞争，未证明只有一个根因 | 按 stable identity 逐来源重放验证 |

#### 5. 目标业务分层

每个会话至少拆成六个正交事实，任何一个都不能再叫“是否激活”：

```text
Durable identity   provider + thread + machine/source
Catalog snapshot   title/project/activity/archive/revision
Local content      none / hot window / full copy + cursor
Runtime attachment detached / attaching / attached / stopping
Work status        idle / running / needs-you / compacting / unknown
Sync status        cached / catalog-sync / history-delta / live / degraded / error
```

- 首页“所有会话都可用”来自 durable identity + catalog/local content，不来自
  runtime attachment。
- 卡片主状态只突出 Working、Needs You、未读、同步/离线等正交事实；普通空闲会话
  无需再显示一层橙/灰 `Ready` 分类。
- 未知未来 work status 保留 raw value 并显示中性兼容状态，不直接变 idle。
- 运行蓝条只由 authoritative work status 驱动；刷新光晕只由真实 catalog/history
  sync transaction 驱动，二者不互相冒充。

#### 6. 目标协调器和唯一所有权

不要求一次替换全部代码，但最终应形成以下单一所有权边界：

1. **SessionCatalogRepository**
   - 持久保存按 machine/source 分区的目录投影；
   - 接收 snapshot/delta，维护 revision、删除墓碑和 query generation；
   - 首页只订阅投影，不自己发目录请求。
2. **ConversationContentStore**
   - 在现有 Mirror/SQLite 基础上区分 hot window 与 full copy；
   - 以 turn/item/tool identity、ordinal/cursor 幂等写入；
   - 为未 attach runtime 的会话提供立即可读的本地窗口和按需旧页。
3. **HistorySyncArbiter**
   - 每 durable conversation 同时只有一个 provider history flight；
   - 合并多个 reason，保留 dirty latch、优先级、deadline、connection epoch；
   - interactive foreground 可升级 background delta-only，但 background 请求不能
     降低一个已经确认的 foreground fallback 权限；
   - 结果只提交给发起 generation，迟到帧不得重开已清理缓存或覆盖新连接。
4. **RuntimeAttachmentController**
   - 阅读不 attach；发送、审批或需要 live provider 行为时才 attach；
   - create、open、attach、resume、reconnect、stop 是明确 operation kind；
   - 同一 durable thread 服从 v02-007 的单写者/owner 边界。
5. **WatchRegistry**
   - App 级集中管理 active runtime、hot cache 和 full copy 的 watch leases；
   - 页面只是订阅者，进入/退出页面不直接夺取 server watch ownership；
   - 有界并发、引用计数、connection epoch 和 retry 统一管理。
6. **ConversationProjection**
   - live、history、Mirror、optimistic echo 进入一个 stable-ID reducer；
   - canonical sequence/ordinal 决定顺序，手机接收时间只用于显示；
   - disclosure、anchor、未读和当前过程框绑定 stable turn/item，不绑定 list index
     或数据来源。

#### 7. 前台、后台与“全部自动同步”的准确边界

- **App 在前台但会话未打开**：所有仍存在的会话都进入分层内容更新调度，而不只
  接收目录摘要。最近热会话、运行中/Needs You/未读会话持续接收内容尾部 delta；
  长期未活动会话也要低频检查 durable revision/cursor，发现变化后再取正文增量。
  多会话更新采用有界串行或小并发，不能为每个 catalog entry 构建
  `ChatSessionCubit`、Markdown Widget、完整工具树或常驻 provider runtime。
- **当前打开会话**：最高优先级 history single-flight + live stream；只构建
  viewport 所需内容，展开详情按需加载。
- **iOS 普通有限后台/BGAppRefresh**：只对已有 cursor 和允许的有界集合做
  delta-only，尊重系统 deadline；没有 cache 不退回 full history。
- **用户开启定位 notification-only 模式**：保持既定隐私/功耗边界，只投递轻量
  通知，不在后台同步正文、Mirror、文件或工具。回前台后 interactive first，
  再按 cursor 追平。
- **进程被 iOS 回收或用户 force-quit**：不承诺实时正文同步；下次启动从持久目录
  和热缓存立即展示，再增量 catch-up。

因此“后台自动刷新”不能被实现成所有会话常驻 runtime，也不能被曲解成“只有点开
或发送后才更新”。正确体验来自覆盖全部 durable conversation 的分层调度、持久
cursor、Bridge 轻量变化信号和前台/机会性后台的有界增量追平。

#### 8. Bridge 目录性能方向

- 文件 watcher 尽可能报告 changed path/thread identity；Bridge 维护按
  path + inode/size/mtime/revision 的 metadata cache，只重算变化项。
- 优先使用官方 app-server/SQLite/index 的结构化元数据，JSONL 只做有界尾部校验
  和兼容 fallback；不得每个 revision 扫描 v02-007 的多套数十 GiB Home。
- 协议增加 capability-gated `catalog_delta`、delete/tombstone、requestId、
  queryGeneration 和 source identity；旧 Mobile 继续接 snapshot。
- 保留周期性低频 reconciliation 处理 watcher 丢事件，但要有抖动、预算和健康
  telemetry；不能用高频全树轮询兜底。
- watcher 覆盖退化、解析失败、revision gap 和 source 冲突要显式上报 degraded，
  不能继续让 UI 假装“已同步”。

#### 9. 实施与回归门禁

1. 先建立只读事件时间线：连接、catalog request/response、runtime attach、
   history reason、cursor、generation、Mirror/watch、UI phase；日志必须有界脱敏。
2. 用相同真实长会话分别重放 live-only、history-only、Mirror-only 和三路交错，
   证明 stable identity reducer 后再迁移 UI。
3. 先引入 arbiter/typed phase，再移除分散 timer 和页面 watch ownership；禁止
   同时大改存储、协议和渲染而无法定位回归。
4. 旧 Bridge fallback、旧 Mobile snapshot、无 Mirror、离线、切换 Bridge、
   两个 Codex Home、provider truncate/rename/archive/delete 都要覆盖。
5. 压测至少包含：数千目录项、10 个热会话、8 个 full resident、一个超长活动
   会话、连续工具/思考流、前后台快速切换和网络抖动。
6. 指标至少记录 catalog 首屏/稳定完成时间、重复请求数、读取字节、SQLite 写放大、
   history decode 次数、Widget rebuild、CPU、内存、滚动帧、前台追平时间和电量。
7. 功能全部完成后执行 v01 Phase 8 和本方案 v02-006 的全 App 性能/安全审查，
   并在当时的最新官方 upstream 上做语义合并和完整兼容回归。

### v02-011：第二轮目录深审——请求身份、状态单写者与扫描成本

#### 1. 本轮结论

第二轮审计确认，当前目录问题不是只给首页补一个 loading 就能解决。Mobile 的
筛选状态、请求身份、response metadata 和分页状态之间存在多个“分别正确、组合
后可能错配”的边界；Bridge 则仍把多个来源的全量扫描、offset 分页和有限 watcher
拼在一起。若只遮住 `(no description)`，迟到响应、重复扫描、陈旧 tail 和错误
排序仍会继续发生。

本节登记的是开工前必须先修正的事实边界，不授权现在直接重写目录层。

#### 2. Mobile `SessionListCubit` 已确认的一致性缺口

1. **recent payload 与 metadata 不是原子快照**
   - `recentSessionsStream` 只向 Cubit 发送 `List<RecentSession>`；
   - Cubit 收到列表后，再从 `BridgeService.lastRecentSessionsMessage` 读取
     `hasMore`、offset、scope、projectPath 等元数据；
   - stream 是异步 broadcast，若两份 response 紧邻到达，列表 payload 可能和
     全局“最后一份 message”不属于同一个请求。
   - 后续必须让 typed response envelope 一次携带 rows、scope、requestId、
     queryGeneration、revision、cursor 和 source identity，禁止从旁路全局变量
     拼接一次状态提交。

2. **持久筛选恢复晚于首次网络请求**
   - Cubit 构造时先订阅/工作，再异步读取 provider、named-only、pin、collapse
     等偏好；
   - 恢复出的筛选可以先改变 UI，但首次 recent request 可能已经按
     all-provider / 非 named-only 发出；
   - 因而界面筛选和已装入的数据短时间可能不一致，现有测试只验证值被恢复，没有
     验证恢复后的第一份网络结果属于同一 query。
   - 目标是先完成最小偏好恢复，再创建首个 query generation；或者在恢复完成时
     明确废弃之前 generation 并重发，不能只改 UI。

3. **筛选存在第二来源**
   - `selectProject()` 没有把当前项目作为完整 Cubit state 的唯一事实；
   - 后续请求仍读取 `BridgeService.currentProjectFilter` 这类可变旁路状态；
   - search debounce 期间 UI query 已改变，旧 query response 仍可能结束 loading
     并替换列表。
   - provider、named-only、project、search、archive/source 等必须形成不可变
     `CatalogQueryKey`，response 只有与当前 key + generation 完全一致才可提交。

4. **分页状态缺少 flight 身份**
   - 顶层 `loadMore` 虽有 `isLoadingMore` 展示字段，但没有统一的
     has-more / same-flight / duplicate-tap guard；
   - project page 用当前列表中“原始 path 完全相等”的数量计算 offset，规范化路径、
     worktree alias 或迟到 merge 都可能造成错位；
   - project page 没有自己的 requestId、deadline 和 retry identity，response
     丢失时 loading path 可长期残留；
   - offset pagination 面对正在变化的目录，本身会在页间插入/删除时重复或跳过。
   - 新协议优先使用 snapshot revision + opaque cursor；旧 Bridge fallback
     必须把同一 query 的 offset 请求串行化并在 response 后做 stable-key 去重。

5. **身份键仍有 raw ID 漏口**
   - 本地改名投影仍可能只按 `sessionId` 匹配，没有把 provider/source 放入键；
   - Bridge 合并 Claude/Codex 扫描结果时也存在按 raw `sessionId` 去重的路径；
   - 两个 provider 或两个 Codex Home 出现相同 ID 时，可能误改名或丢掉其中一个。
   - 所有目录、pin、rename、unread、cache、page merge 的最小键必须是
     `machine/Bridge + sourceHome + provider + providerSessionId`。

6. **项目集合和 exhaustion 含义被混用**
   - 空的 project-history response 当前不能权威清掉旧项目集合；
   - `accumulatedProjectPaths` 主要做单调 union，被删除或迁移的项目会残留；
   - 顶层 `hasMore=false` 会把当前已出现的项目都标成 project page exhausted，
     但“顶层总页结束”不证明每个项目自己的页都结束；
   - prefix refresh 会保留旧 tail，被归档、删除或改项目且不在新 prefix 的会话
     可能继续存在。
   - project catalog、top-level catalog 和各 project cursor 必须分别有 revision、
     authoritative-empty 与 tombstone 语义。

7. **断线重置把用户偏好当成传输状态**
   - 当前断线会调用 `resetFilters()`，清空列表并把 provider/named-only 重置；
   - 同一个 Cubit 生命周期内重连不会重新恢复偏好；
   - 现有测试还明确要求“disconnect reset 清空 sessions、回到 skeleton”，这与
     本轮“同目标保留持久目录、保留用户筛选、非阻塞重连”相冲突。
   - 断线只能结束当前 flights、标记缓存 stale/degraded；不能清掉用户选择或同目标
     已验证缓存。切换 machine/source 才切换到另一个缓存分区。

8. **偏好写入缺少顺序保证**
   - pin、collapse、filter 等多处持久化是 fire-and-forget；
   - 快速连续切换可能让较早的异步写在较晚状态之后完成。
   - 采用单写者串行队列或 versioned snapshot write；进程内 UI 仍可乐观更新，但
     持久结果必须最终收敛到最新 revision。

#### 3. Bridge 目录与 watcher 已确认的性能/兼容缺口

1. `SessionCatalogMonitor` 和 `sessions-index` 多处固定读取
   `~/.codex` / `~/.claude`，没有统一服从显式 `CODEX_HOME`、Cockpit instance
   Home 或 v02-007 的 source registry。即使 App Server 连接了另一 Home，文件
   catalog 仍可能读普通 Home。
2. watcher 总数上限为 1024，安装顺序大致是 Claude projects、Codex root、
   Codex sessions。前面的目录先占满时，后面的 Codex 目录可能没有 watch；
   retry 每 15 秒继续尝试，但 cap 不会自行恢复，容易形成“反复扫描但覆盖仍不完整”
   的静默退化。
3. all-provider recent path 会并行执行：
   - 一次包含 Claude + Codex rollout 的全目录扫描；
   - 一次 Codex `thread/list`。
   合并时优先保留 `thread/list` 的 Codex 结果并丢掉 rollout 重复项，因此很多
   Codex rollout metadata 工作是重复成本，还可能影响 `hasMore` 推断。
4. `getAllRecentSessions` 为一个小 page 仍可能扫描全部相关 Claude project、
   Codex session tree，解析 index/JSONL 头尾，再对完整过滤结果排序后 slice。
   在多 Home、数千 thread 和持续写入下不能作为每次 catalog revision 的常规路径。
5. 当前 offset page 没有 snapshot token；目录在 page 1 与 page 2 之间变化时，
   结果可重复/跳过。server generation 主要保护 top-level/filter，catalog、
   append、project response 仍缺独立 request identity。
6. watcher cap、解析失败、source Home 不一致和索引 fallback 当前没有足够明确的
   health/degraded 投影给 Mobile；UI 可能继续显示“已同步”。

#### 4. 目标目录协议与本地单写者

建议以 v02-010 的 `SessionCatalogRepository` 为唯一写入者，最小契约如下：

```text
CatalogQueryKey
  machineId + bridgeInstanceId + sourceHomeId
  + provider + project + search + named/archive filters

CatalogEnvelope
  queryKey + connectionEpoch + requestId + queryGeneration
  + catalogRevision + snapshot/cursor + rows + tombstones + health
```

- Bridge 新能力优先发送 revisioned snapshot/delta；旧 Bridge 继续用
  recent snapshot，但 Mobile 将其包进本地 generation 并串行提交。
- watcher 只负责产生“某 source 可能变化”的信号，目录 repository 才负责一次
  有界 reconciliation；禁止页面、filter Cubit、runtime tracker 各自重扫。
- `thread/list` 可提供的 Codex metadata 不再同时重复 rollout 全扫；仅对
  app-server 缺失、兼容旧数据或需要补字段的候选做有界 fallback。
- watcher 根目录来自显式 source registry；cap 达到时选择可预测的高价值根并
  上报 degraded，同时以低频、有预算的 reconciliation 补偿。
- 首页排序每次按权威 activity timestamp + stable tie-breaker 重算投影；不能
  因“旧行原位置替换”把刚更新会话留在列表底部。
- authoritative empty、delete/archive/move 必须能删除旧投影；不得只做 union。

#### 5. 必须新增或改写的目录回归

1. 持久 provider/named-only 偏好在首个 query 前恢复；旧首个 response 不得污染。
2. search debounce 中旧 response 先到、后到两种顺序都不能结束新 query loading。
3. list payload 与 response metadata 连续交错，证明 envelope 原子提交。
4. Bridge A → Bridge B、普通 Codex Home → Cockpit Home 的迟到 response 被拒绝。
5. Claude/Codex 或两个 Home 使用相同 raw session ID 时均保留，rename/pin 不串线。
6. authoritative empty project history 能清旧项目；top-level exhaustion 不误标
   每个 project cursor。
7. mutable catalog 的两页之间插入、删除、归档和改 project，不重复、不漏项。
8. project page 丢包、超时、重复点击和规范化路径 alias 均能收束。
9. 断线/同目标重连保留筛选和缓存；切换目标只切换分区，不混用。
10. watcher cap、根目录后出现、`CODEX_HOME` 切换和 degraded health 有确定性测试。
11. all-provider 目录基准记录 scan count、读取字节和 JSONL fallback 数；Codex
    `thread/list` 命中时不得再做等价全树工作。

### v02-012：第二轮查看深审——阅读、运行时附着与历史同步状态机

#### 1. 已确认的当前耦合

当前点击一个 recent conversation 的真实路径是：

```text
tap recent
  → register PendingSessionBinding
  → Bridge resume
  → navigate pending_resume_<requestId>
  → full-page “creating session”
  → session_created(runtimeSessionId)
  → rebuild screen/cubits under the new runtime ID
  → restore runtime cache / Mirror / provider history
```

这条路径解释了三个用户可见现象：

- 既有会话也显示“正在创建会话”；
- 没有 runtime attachment 就不能先阅读已缓存内容；
- resume ID 到达后以新的 `ValueKey(sessionId)` 重建页面所有者，局部展开、滚动和
  current-process 状态容易丢失。

普通 `PendingSessionBinding` 已经能在新 Bridge 上按 exact request ID 关联，并对
旧 Bridge 做有界唯一 fallback，这是应保留的基础；但 Codex/Claude 页面仍有各自
的兼容 listener 路径，主要按 project/durable ID 推断，同项目并发 resume 时仍
需要证明不会误认。

#### 2. Runtime cache 与完整副本不能代替 durable view

- `SessionRuntimeStore` 以 Bridge runtime session ID 为键；同一 provider thread
  每次 resume 产生新 runtime ID 时，不能自然复用上一 attachment 的进程内缓存。
- Conversation Mirror 能按 durable provider ID 找完整手机副本，但 bootstrap
  发生在 runtime screen/cubit 创建以后；它只覆盖用户下载的 Codex 副本和有界
  resident 集合，不是所有 catalog conversation 的默认阅读层。
- 因而“所有会话随时点开”必须新增 durable view identity 和 hot-content store，
  不能靠提前 resume 所有会话，也不能只扩大 resident 上限。

目标打开路径应为：

```text
tap durable conversation
  → open ConversationView(durableIdentity)
  → immediate catalog + local hot/full content
  → optional foreground delta reconciliation
  → only on send/approval/live need: RuntimeAttachmentController.attach
  → migrate live ownership without replacing durable screen identity
```

UI phase 至少要类型化为：

- `openingLocal`：读取本地目录/正文；
- `reconciling`：已有正文可读，追平增量；
- `offlineReadable`：有缓存但 Bridge 不可用；
- `attachingRuntime`：发送或审批前正在建立 provider runtime；
- `creatingNew`：仅真实新建线程；
- `unavailable/retryableError`：明确失败和重试，不永久 pending。

#### 3. History 请求没有真正的 per-conversation flight

已确认：

1. `ChatSessionCubit` 在 `starting` 状态每 3 秒继续请求 history，没有固定重试数、
   总 deadline 或指数退避；resume/状态丢失时可无限重复。
2. history 请求还来自 foreground/background coordinator、Desktop continuity、
   Mirror、手动刷新和错误恢复。
3. `BridgeService` 的 pending maps 以 session 为键，不以 request 为键。后来的
   调用会覆盖 `allowFullFallback`；response 也没有 request ID / since echo /
   connection generation，旧结果可先结束新 flight 的“正在同步”展示。
4. 现有测试明确要求“后来的 background delta-only 请求取消先前 foreground
   full-fallback 资格”，即 codify latest-writer-wins。该契约与本方案相反：
   interactive 请求可以提升已有 background flight，但 background 请求不得降低
   已确认的 interactive 权限。
5. 旧 Bridge 对 `get_history_delta` 返回的 unsupported error 可能没有 session
   scope；当前 fallback 会处理所有 pending sessions。一个旧能力错误不应同时
   改变多个会话的策略或触发 history 风暴。

`HistorySyncArbiter` 应采用合并而非覆盖：

```text
one durable conversation → at most one provider flight

effective reason/permission
  = highest current priority
  + earliest safe cursor
  + monotonic fallback permission within the flight
  + deadline + connection epoch + request generation
```

- `interactive/open/send/approval` 优先级高于 foreground warm、background
  delta-only 和低优先级预取。
- 新高优先级调用可升级/标 dirty；低优先级调用不能降级正在进行的高优先级 flight。
- 新 Bridge 通过 additive requestId/generation 原样回显；旧 Bridge 每会话严格
  single-flight，unscoped unsupported 只改变 capability 状态，并由 arbiter 对
  符合条件的会话逐一有界处理。
- 超时结束当前等待并保留可重试状态，不伪造空 history；迟到 response 只能进入
  与其 generation 匹配的 reducer。

#### 4. Message ownership 与 history replacement 风险

- `messagesForSession()` 当前会把 `pair.sessionId == null` 的消息暴露给每一个打开
  的 chat cubit。解析错误、旧协议 unscoped error 或基础设施提示可能同时进入
  多个会话的处理路径。基础设施事件应进入 connection/error channel；只有有
  明确 owner 的 transcript item 才能进入会话 projection。
- `SessionRuntimeStore` 对有 sequence 的 history delta 有良好水位和排序基础，
  应保留；但无 sequence 消息仍按到达追加，重复旧事件可能产生重复项。
- legacy `HistoryMessage` 会整体替换 runtime store 并把 seq 水位重置为零；新旧
  capability 切换、迟到 legacy snapshot 和新 delta 交错需要 generation fence。
- `ChatSessionCubit` 为保留本地 user 图片/时间，在没有 UUID 时还会以
  `text:<message text>` 建索引。两轮完全相同的问题会覆盖同一个 map key，可能把
  前一轮的图片字节或时间赋给后一轮。现有测试覆盖有 UUID 的重复 prompt 和重复
  assistant text，但没有覆盖“两个无 UUID 同文 user、各自不同图片/时间”的替换。
- live/history/Mirror/optimistic echo 仍有多套 weak-equivalence/保留算法；不能
  再通过增加一个 text fallback 修补。最终以 stable item/turn identity、provider
  ordinal/sequence 和明确 provisional→canonical mapping 收束。

#### 5. 必须新增或改写的查看/历史回归

1. 有 hot/full cache 的既有会话在无 runtime 时立即可读，且不发送 resume；
   首次发送消息时才 attach，页面 durable key、滚动和展开状态不变。
2. 无本地正文的既有会话显示“正在加载/同步”，从不显示“正在创建”。
3. create/open/attach/resume/reattach 分别有 requestId、取消、deadline、重试和
   迟到结果测试；同项目并发操作不能互认。
4. starting 永不结束、socket 半开、旧 Bridge 不支持 delta 时，请求数有界且 UI
   可恢复，不每 3 秒永久轮询。
5. foreground interactive 与 background delta-only 以两种调用顺序交错，最终
   有效权限遵循优先级，不遵循最后写入者。
6. 两个会话同时 pending delta，收到一次 unscoped unsupported error，不产生
   多会话无界 full-history fallback。
7. old response、new response、Mirror snapshot、live tail 以所有可能顺序交错，
   只有当前 generation 提交，同一 item 不重复。
8. 两个无 UUID、文字相同但图片/时间不同的 user turn 经 canonical replacement
   后仍各自保留正确元数据。
9. parse/infrastructure error 无 session owner 时只显示一次全局诊断，不进入所有
   chat transcript。
10. runtime ID 迁移不得重建 durable screen；草稿、选择、锚点、过程框和未读水位
    都按 durable identity 保留。

### v02-013：缓存管理与紧凑过程 UI 的复用边界

#### 1. 设置页缓存管理不重复实现已有删除能力

当前已经存在：

- `ConversationMirrorStore.listLocalCopies()`：能列出所有完成的本地副本，包括暂停
  auto-sync 的副本；
- `ConversationMirrorService.removeLocalCopyTarget()`：会先取消目标请求，再调用
  store 删除，并清理 metadata、syncing 和 paging cursor；
- recent/running 会话菜单与会话内 resident 面板已经能删除单个副本。

当前真正缺少：

- Settings 中的统一“存储与缓存”入口；
- service 面向设置页的**全部** local copies 投影。目前公开的
  `residentMetadata` 只返回 `autoSync && hasLocalCopy`，会漏掉暂停同步但仍占空间
  的副本；
- 可理解的标题。Mirror metadata 只有 provider/session key、project path、
  entry count、bytes、lastSyncedAt、error，没有 title/summary；设置页必须按
  durable identity 与持久 catalog join，不能拿路径或第一条正文临时猜；
- 总占用、按类别占用、清理进度、失败恢复和测试。

因此实施时：

1. **一键清理可重建缓存**
   - 清理 catalog 可重建投影、recent hot window、按需工具详情、预览/图片/diff
     等明确列出的 cache；
   - 不删除完整下载副本、草稿、未发送队列、连接凭据、设置、传输断点或授权材料；
   - 清理完成后首页可以降级为在线重取或空 skeleton，但迟到 frame 不得复活旧代。
2. **已下载会话历史管理**
   - 单独列出全部 full copies，显示标题/项目/provider/source、大小、条目数、
     最后同步、自动同步状态和错误；
   - 每项独立确认删除，复用现有 `removeLocalCopyTarget()`，不再写第二套 SQL/
     cancellation 逻辑；
   - 正在打开、同步或离线阅读的副本删除时，先撤销 watch/flight，再让视图安全
     降级，不闪退、不显示已删正文。
3. 普通清缓存与副本删除必须是两个不同的 destructive scope；文案明确实际释放
   的空间和可重新下载性。
4. 若以后增加“清除全部已下载历史”，必须用一次有界批事务/批次 vacuum 和进度，
   不能循环 N 次单删造成 N 次 vacuum；本轮用户当前要求的逐项删除无需默认提供
   该危险快捷键。

#### 2. 时间戳迁移采用 semantic owner

`ChatEntryWidget` 的通用顶部 `_TimestampWidget` 必须退出“所有 entry 的默认
装饰”角色，但时间事实本身保留：

- 普通 user/assistant 气泡由气泡 footer/trailing 自己显示；
- tool/process 折叠摘要把时间放在最右侧、chevron 左边；
- 自由中间文本无法内嵌时，可在正文上方用紧凑 leading/trailing label，间距尽量
  小，不能生成居中的全宽分隔行；
- process frame 内的工具默认用组/事件时间和 canonical 顺序，不在每两个工具间
  插时间；
- approximate `~` provenance 继续保留，但不得因 local re-render 更新成当前时间。

现有 `message_timestamp_test.dart` 只断言 `03:04:05` 和 `~03:04:05` 存在，会
允许任何糟糕布局继续通过。必须改成结构/位置测试，并在窄屏、Dynamic Type、
中英文长摘要下证明时间不遮挡 chevron。

#### 3. 当前过程框复用与必须推翻的测试假设

现有八行 viewport、内部滚动、reading-position anchor 和 process layout cache
都是可复用基础。不要重新写聊天树。但需要修正：

- `_expandedCurrentProgress` 目前按 `entry:<turn>` / `live:<turn>` 两个渲染身份
  保存；stable durable turn key 才是唯一 expansion owner。
- live path 的 thinking/details 与 persisted tool viewport 是两个 surface；必须
  合并成同一 current-process viewport。
- 已有“incremental output keeps current progress expanded”测试只覆盖 persisted
  路径继续追加和 App lifecycle，没有覆盖用户复现的
  `entry expanded → streaming thinking → live key → persisted tool` 身份切换；
  另一个 live 测试甚至明确要求 live stream 使用独立 surface。实施时必须改写
  这条旧契约，而不是为了让旧测试通过继续保留双 surface。
- 八行框增加静态边界、底色、溢出 fade/scrollbar 时只监听 overflow/scroll
  状态；thinking delta 不得让整个 outer list 和装饰层每帧重建。

#### 4. 本轮文档完成门禁

本轮只完成调查与方向文档，不代表以下事项已经实现：

- catalog protocol/repository、hot cache 或设置页；
- durable view/runtime attachment 分离；
- history single-flight/request correlation；
- 时间戳迁移或 unified current-process viewport；
- Bridge 部署、官方更新合并、IPA、OTA 或真机验收。

正式实施前先把本节列出的旧测试中“有意维护旧行为”的断言改成新业务契约，再按
小提交逐层迁移；每一层都要保留旧 Bridge fallback，不能通过整文件覆盖官方代码。

### v02-014：全需求覆盖矩阵、版本优先级与剩余证据

#### 1. 状态定义

本节用于证明长需求列表没有在多轮讨论中丢项。状态只描述当前证据，不能理解为
发布完成：

- **保留并复核**：当前分支已有对应实现和回归，后续大重构时必须保留并重跑；
- **重开**：v01 曾实现或测试过一部分，但用户的新反馈证明最新产品契约仍未满足；
- **待实施**：方向和 owning layer 已明确，用户尚未授权本轮业务修改；
- **待部署/真机**：源码或产物已有，但当前 live Bridge、Cloud、签名或物理设备
  没有证明整条链路可用；
- **待事件线取证**：已确定排查层次，但缺少真实出错会话/真机事件顺序，不能先
  假定某一个根因。

#### 2. 会话首页、同步、缓存与运行时

| 用户要求 | 当前权威证据与结论 | 方案归属 | 状态 |
|---|---|---|---|
| 连接 Bridge 时不要提前跳离 IP/机器页，也不要只剩无上下文中央转圈 | v01 已加 transport→`session_list` gate，但 auto-connect/connecting presentation 仍替换连接表单 | v02-001；v01 2A.2、9.1 | 重开 |
| 首页不能先出现整页 `(no description)` | runtime snapshot 和 recent catalog 是两条不同 readiness；当前 gate 只证明前者 | v02-008、v02-011 | 待实施 |
| 所有持久会话都可直接点开，不再分未激活/Ready | 当前 recent tap 仍先 resume 并创建 `pending_resume_*` runtime screen | v02-003、v02-010、v02-012 | 待实施 |
| 会话列表像 Codex Desktop，一套列表显示 running/未读/下载等正交状态 | v01 已有 unified projection 和 durable 排序；v02 要移除残留的 Ready/activation 语义 | v01 4.1、4.4；v02-003 | 重开并保留基础 |
| 已下载会话不占顶部独立区域，只显示勾号 | unified list 和本地副本勾号已有实现 | v01 4.1、4.4 | 保留并复核 |
| 最近使用的会话排最上面 | v01 已修 running `Map` 插入顺序；第二轮发现 client incremental replace 和多 source merge 仍可能不重排 | v01 2A.2、4.4；v02-011 | 重开 |
| 所有会话目录和摘要跨启动缓存 | 当前 recent catalog 仍主要是进程内；冷启动无持久目录 | v02-004、v02-010、v02-011 | 待实施 |
| 至少最近常用 10 个会话保留最近上下文，重启只追增量 | 当前 Mirror full resident 最多 8 个，且不等于默认 hot window | v02-004、v02-012 | 待实施 |
| App 前台未点开会话时也持续更新；久未使用会话低频检查而非永不更新 | v01 metadata-only catalog 已存在；覆盖全部 durable conversation 的分层内容调度、持久 cursor 和集中 watch owner 尚未形成 | v01 4.3、4.4；v02-010、v02-015 | 待实施 |
| iOS 后台刷新不能变成所有会话 full runtime | 已明确有限后台 delta-only、location notification-only 不同步正文，回前台再追平 | v02-010.7；`docs/mobile-background-sync.md` | 保留边界 |
| 设置里一键清缓存，已下载历史逐项删除 | 单个 Mirror 副本删除链已有；Settings 全部副本列表、标题关联、空间统计和普通缓存清理缺失 | v02-004、v02-013 | 待实施 |
| 已有会话显示“正在加载/同步”，只有新线程显示“正在创建” | Codex/Claude 当前共用 `isPending`，resume 仍显示 creating | v02-005、v02-012 | 待实施 |
| 会话消息同步、排序、折叠整体稳定 | 第二轮已定位 request identity、single-flight、projection、stable disclosure 等 owning layer | v02-010～v02-013 | 待实施 |
| 双 Cockpit/Codex 实例的目录和同步不能互相污染 | 已确认两套 Home 是独立副本/旧快照风险，当前 Bridge 多处仍硬编码普通 Home | v02-007、v02-011；multi-instance note | 待实施 |
| 运行蓝条与 history 同步光晕分开且低开销 | v01 已实现小 selector、ticker 停机和 `RepaintBoundary`；新 arbiter 后须重跑状态语义 | v01 9.4、14；v02-012 | 保留并复核 |

#### 3. 历史窗口、折叠、过程框与消息时间

| 用户要求 | 当前权威证据与结论 | 方案归属 | 状态 |
|---|---|---|---|
| 首屏最近 5 个根回合及轻量中间输出，工具详情自动预算 200 | turn-aware envelope/detail 和 additive capability 已在 v01 实现 | v01 5.1、5.4 | 保留并复核 |
| 向上滚动继续加载更早回合，折叠详情按需取 | keyset/ordinal page 和每次最多 8 个工具详情已有实现 | v01 5.2～5.4 | 保留并复核 |
| 一个展开工具组最多约 8 行，更多内容框内滚动 | viewport/内部滚动已有；用户反馈证明边界和溢出提示不足 | v01 6.2；v02-009、v02-013 | 重开 |
| 增量更新不能把已展开过程收起 | v01 撤掉部分隐式 collapse；当前 `entry:`→`live:` identity 切换仍让框视觉消失 | v01 6.1；v02-009 | 重开 |
| 展开后 thinking、工具和结果始终在同一个框中 | live thinking 与 persisted tool viewport 当前是两个 surface | v02-009、v02-013 | 待实施 |
| 折叠时当前进度可显示思考摘要，展开后外面不重复 | owning rule 已明确，当前 live path 仍可把 thinking 放回外层 | v02-009 | 待实施 |
| 中间过程/工具/最终回复偶发整段重复两次 | 已确认应逐层比对 raw→Bridge→Mirror→reducer→render，尚无真实故障会话四层快照 | v01 2A.1、6.3；v02-012 | 待事件线取证 |
| 每条消息显示电脑接收时间到秒，不用同步时间冒充 | `receivedAt`/`sourceTimestamp` 和 provenance 已实现 | v01 2A.5、9.3 | 保留并复核 |
| 时间戳尽量融入消息/工具摘要，不能占独立整行高度 | 通用 `ChatEntryWidget` 仍在每个 entry 顶部插独立时间组件 | v02-005、v02-009、v02-013 | 重开 |
| Guardian 风险归到被批准工具下，当前只显示一条并 3 秒消失 | tool identity 归属和限时视觉提示已有实现；统一 process surface 后需防重复 | v01 8.3；v02-009 | 保留并复核 |
| Plan 首次退出未选择后审批不能消失 | Bridge pending ledger 与 Mobile 重叠恢复已有修复 | v01 8.2 | 保留并复核 |

#### 4. Side Chat、悬浮窗、权限、Goal 与额度

| 用户要求 | 当前权威证据与结论 | 方案归属 | 状态 |
|---|---|---|---|
| Side Chat 使用官方 ephemeral thread/fork，不造持久类型，不硬编码口述半小时 | app-server `thread/fork(ephemeral:true)` 路径和 capability 已接入，复用普通会话 UI | v01 7.1、2A.3 | 保留并待部署复核 |
| 关闭 Side Chat UI 后仍能找回尚存活 child | auxiliary registry 方向已有，真实 live Bridge 生命周期仍须验证 | v01 7.1～7.2；v02-002 | 重开 |
| 悬浮窗点开后自身展开成非模态小窗，不是按钮弹 modal sheet | v01 实物仍是 floating button + `showModalBottomSheet`，不符合重新确认语义 | v02-002 | 待实施 |
| 权限不能在进入/激活会话时莫名回到 `on-request` | v01 已修 unknown 被默认值污染和 resume override；若 build 202 仍出现，需抓 resolved settings/revision 事件线 | v01 2A.4、8.1 | 保留并待事件线复核 |
| 新建会话不再报 `No thread ID available for goal lookup` | Goal 等 durable thread + authoritative init 后读取的修复已有 | v01 8.4 | 保留并复核 |
| 选择 5.3 Spark 时额度圆环自动切 Spark 卡片 | exact model ID selector 已实现，旧 Bridge 有兼容回退 | v01 2A.3、9.2 | 保留并复核 |

#### 5. 通知、未读、本地化与后台保活

| 用户要求 | 当前权威证据与结论 | 方案归属 | 状态 |
|---|---|---|---|
| action/question/completion/failure/progress 通知本地化，过程通知真正生效 | Bridge/Cloud/Mobile 源码已有分级与 ack；progress 默认关闭，当前 live Bridge 缺 capability | v01 10.1～10.5 | 待部署/真机 |
| 通过 Always Location 保活，仅收轻量 Bridge 投影并在本地通知 | 新原生宿主、协议和 Mobile gate 已合入 build 202；iOS 回收/force-quit 仍不保证 | v01 10.1～10.2、10.5 | 待部署/真机 |
| 会话完成后首页显示未读蓝点，打开可见后清除 | durable unread ledger 和蓝点代码已有，跨设备不冒充已实现 | v01 10.3、10.5 | 保留并待真机 |
| 通知长按 Allow/Reject | native category/action、opaque identity 和 Bridge 权威复核已有；需要签名设备真实验证 | v01 10.4～10.5 | 待部署/真机 |
| 手机固定文案中文化，不引入本地模型/API 翻译 | 产品方向明确；命令、代码、路径和 provider 原文保留 | v01 12；decisions | 保留并最终扫描 |

#### 6. 文件、预览与安全

| 用户要求 | 当前权威证据与结论 | 方案归属 | 状态 |
|---|---|---|---|
| 手动文件管理和 Agent 文件引用保留两套入口，但共用读取/预览能力 | 现有 artifact candidate/hyperlink 必须复用，不能再写路径正则 | v01 11.1、2A.6 | 保留并复核 |
| owner 模式全盘可读，项目外 Agent 引用不再 `path_not_allowed` | authenticated unrestricted read 代码已有；当前 live Bridge 未配置 API key/`*`，所以尚未上线 | v01 11.2～11.3 | 待部署 |
| 文件修改/上传/删除必须密码或 Face ID 由 Bridge 授权 | password verifier、Secure Enclave challenge 已覆盖当前存在的 upload mutation；未来新增 move/delete 必须复用 | v01 11.4 | 保留边界并待真机 |
| JSON/HTML/网页能正确预览，Quick Look 失败回本地预览，并有下载/分享 | 统一路由和代码已有；用户仍见失败，必须核对实际安装 build、Bridge capability、文件类型和 native dismissal 事件线 | v01 11.5；v02-006 | 待事件线/真机 |
| 整个 Bridge/手机握手做安全审查但不把密码哈希放热路径 | 私有 HTTP/WebSocket auth、limits、symlink/TOCTOU 边界已有；当前 live Bridge 仍监听全接口且无 API key | v01 11.2～11.4、19.1 | 待部署复核 |

#### 7. 实施纪律、官方更新、性能和兼容

| 用户要求 | 当前权威证据与结论 | 方案归属 | 状态 |
|---|---|---|---|
| 确认根因后顺手修确定性 bug，不能见现象就改 | owning-layer、最小回归、旧客户端和迟到帧纪律已登记 | v01 13；v02-006 | 持续门禁 |
| 所有功能完成后做全软件性能审查和优化 | v01 已对 build 202 做过一轮；v02 的目录/cache/arbiter/process 重构完成后必须重做，不沿用旧数字 | v01 14、19.2；v02-006、v02-010 | 待实施后执行 |
| 合并官方最新 commits，同时保持新旧客户端和官方兼容 | `1907a42c` 已合官方 1.109.2；2026-07-26 复核 upstream/main 仍为 `aa215a3b`；开工前再次检查 | v01 3、16～19；decisions | 当前基线已对齐，开工复核 |
| 不重复实现已有能力，不整文件覆盖官方热点 | Side Chat UI、artifact parser、Mirror delete、history cursor、pending correlation 等复用点已明确 | 全文，尤其 v01 2A、v02-010～013 | 持续门禁 |

#### 8. v01 与 v02 的优先级

- v01 是 build 202 当时的已实施/已验证历史账本，不能删除或改写成“从未做过”。
- v02 是 build 202 真机/实际使用反馈后的当前产品语义。两者冲突时：
  1. 连接页 presentation、catalog readiness 采用 v02-001/v02-008；
  2. 悬浮按钮/modal sheet 采用 v02-002 的非模态展开小窗；
  3. Ready/activation、持久目录和 durable view/runtime attach 采用
     v02-003/v02-004/v02-010～012；
  4. 时间戳位置、八行框边界和 thinking/tool 统一 surface 采用
     v02-005/v02-009/v02-013；
  5. 普通一键清缓存只清可重建数据，完整下载历史只逐项删除；不沿用前文曾扩大到
     “一键清除全部下载历史”的草案。
- “v01 有 commit/测试”只能证明旧合同曾通过，不能证明 v02 新合同已经完成。
- 实施时若当前源码与本矩阵不同，以重新取得的事实为准，先更新矩阵和回归夹具，
  再修改 owning layer。

#### 9. 仍缺但已明确收集方式的证据

以下项目尚不能靠静态代码或模拟器宣称完全理清，实施开始时必须优先补证据：

1. 用户真机所见“正在挂起”的完整 status/raw provider/runtime/投影时间线；
2. 一条真实“中间过程 + 工具 + 最终回复重复两次”会话的 raw、Bridge、Mirror、
   reducer 和 render 五层快照；
3. build 202 或届时新 build 上权限再次变 `on-request` 时的 override、indexed
   factual settings、official init 和 connection epoch；
4. JSON/HTML/Quick Look 失败样本的 MIME/UTType、大小、Bridge preview kind、
   native `canPreview` 与 fallback 结果；
5. 当前物理 iPhone 的通知权限、Always Location、native capability、Bridge ack、
   live mode、最后 notification event 和系统回收状态；
6. AltStore 重签后的 APS、Secure Enclave/Face ID、通知 action 和后台 entitlement；
7. Cockpit 两个 Home 对同一 durable thread 出现真正分叉写入时的 owner、revision
   和冲突样本；在此之前不能把全量 JSON 合并描述成安全同步。

这些不是允许无限拖延的模糊项：对应诊断字段、采集层次和验收结果已经写明。缺少
真实样本时先实现无副作用、有界、脱敏的诊断和 generation/request correlation，
再复现；不得先按文本、时间或 project path 猜测并删除数据。

### v02-015：最终确认——所有会话分层自动更新，运行时不再代表可用资格

#### 1. 本轮纠正

用户明确否定“未点开时只能阅读旧历史，首次发送才开始更新”的解释。最新产品
语义是：

- 不再向用户区分“已激活/未激活”；所有仍存在的 durable conversation 始终可打开、
  可阅读、可继续使用。
- 所有会话都属于自动更新集合，不能因为没有 runtime attachment 就永久停在旧
  历史。`runtime attachment` 只允许作为 provider 发送/live stream 所需的内部
  机制，不能成为目录、缓存、后台增量或 UI 可用性的前置条件。
- 当前打开的会话在进入时立即做一次最高优先级追平，并在打开期间保持实时增量。
- 最近使用、正在运行、Needs You、未读或近期发生变化的会话，在 App 前台即使没有
  打开，也要持续做内容尾部增量同步。
- 数天未活动的冷会话仍要周期性检查。用户口述的“一分钟”是节奏示例，不是硬编码
  合同；最终周期要根据目录规模、Bridge 变化信号、网络、电量、前后台状态和真机
  数据自适应，但不得退化成永不检查。

#### 2. 调度模型

建立 Bridge 拥有的单一 `ConversationSyncScheduler`，输入为持久目录、
runtime/Desktop activity、Needs You、各客户端已确认 cursor、最近 provider 活动、
文件/官方事件变化和 Bridge 健康状态；输出为面向已订阅前台客户端的有界 history
delta 推送。Mobile 不为每个会话建立轮询 timer，也不逐项发“有没有更新”的探测：

```text
P0  当前打开 / 发送前 / 审批前
    立即提升优先级，取消等待；先按已知 cursor 拉 delta，再进入 live。

P1  正在运行 / Needs You / 新未读
    由 Bridge change signal 触发，辅以短周期有界补偿。

P2  最近活跃热集合（至少最近常用 10 个）
    App 前台持续增量，多个会话串行或极小并发；目标延迟为秒级。

P3  其余冷会话
    低频只检查 revision/cursor；仅在变化时拉正文 delta，不解析/构建 UI。
```

- 队列在 Bridge 按 durable identity 去重，同一会话最多一个计算 flight；新触发
  只升级优先级或设置 dirty latch，不能叠加重复 history 读取。
- 调度采用公平轮转和每轮字节/条目/耗时预算，防止一个超长会话饿死其他会话；
  解析、revision 比对、增量计算和跨客户端结果复用尽量留在 Mac。
- Bridge 能取得 changed thread identity 时优先事件驱动；对不能可靠 watch 的冷
  会话才在 Bridge 端分桶、抖动、低频检查。Mobile 不做 N 会话轮询。
- Mobile 进入 interactive 前台后发送一次带本地 cursor 摘要的订阅/恢复握手；
  Bridge 主动推送变化并按 ack 收束 backlog。重连时只补 cursor 缺口，不让手机
  重复下载已确认内容。
- 只有 storage/reducer 在后台工作；没有打开的会话不得构建 Markdown、工具详情、
  图片、diff 或聊天 Widget。
- App 进入 iOS 普通后台时继续服从既有系统 deadline 和 delta-only 预算；用户开启
  location notification-only 时仍只收轻量通知，不能用本节要求突破既定隐私和
  功耗边界。回前台后 scheduler 立即按优先级追平。

#### 3. 与 runtime attachment 的关系

- provider history/delta 能按 durable thread 读取时，后台同步直接使用 durable
  identity，不为读取而 resume。
- provider/旧 Bridge 只能对 runtime 取增量时，可维护一个有界、可回收的内部 lease
  或使用兼容 resume，但该事实不得改变首页排序、颜色、Ready 标签或用户操作流程。
- 首次发送可能需要建立/接管 runtime，但 attachment 在同一 durable screen 内完成；
  不能重建页面、丢草稿、滚动、展开框或先弹出“正在创建会话”。
- 会话已经存在 live runtime 时直接复用；不能为同一 durable thread 建第二个写者。

#### 4. 验收

1. 两个以上近期会话同时变化时，即使用户停留在首页或另一个会话，Bridge 也会在
   有界队列中依次计算并主动推送；列表摘要、未读与正文 cursor 同一 generation
   收敛，Mobile 不发逐会话探测。
2. 当前打开会话的同步不被冷会话队列阻塞，进入后立即提升到 P0。
3. 数天未打开的会话在低频检查发现 revision 变化后自动更新，而不是必须先点击。
4. 数千会话下无 N 个 Cubit、N 个常驻 runtime 或 N 个高频 timer；记录实际队列
   延迟、重复请求、读取字节、CPU、内存和电量。
5. Bridge 断线、切换、迟到结果和 provider rewrite 不串会话、不复活旧缓存。
6. 新 Mobile + 旧 Bridge 保持有界兼容；旧 Mobile + 新 Bridge 不受新 scheduler
   协议影响。

#### 5. Bridge 推送与 App 生命周期边界

- Bridge 托管 runtime 的 live event 和电脑端 Codex/Desktop 写入统一进入同一
  durable reducer；若同一条 canonical item 已经由 live path 送达，后台内容推送
  只确认 cursor，不再重复发送正文。
- App 前台且 delivery mode 为 `interactive` 时订阅内容增量；Bridge 可以主动推送
  正在运行、近期活跃和冷会话校验后发现的变化。
- App 未打开某会话不影响订阅；“当前打开”只提升该 durable identity 的优先级并
  请求立即补齐，不能成为是否接收更新的开关。
- App 进入既有 location `notificationsOnly` 或被 iOS 挂起时，Bridge 停止正文/
  Mirror/工具内容推送，只保留既定轻量通知投影。回前台先恢复 `interactive`，
  再用持久 ack cursor 补齐。
- 一台 Bridge 同时连接多个新旧客户端时，每个客户端独立维护有界 cursor/ack；
  解析结果和 revision 可共享，但不能让一个客户端的 ack 推进另一个客户端水位。

## 2. 后续讨论登记方式

从本轮对话开始，每个新增问题按 `v02-002`、`v02-003`……追加到本文。若用户
修改产品定义，以最新确认语义为准，同时保留旧定义为何被替代的记录。待所有
问题讨论与调查完成后，再统一整理依赖关系、实施批次、提交边界、完整性能审查、
官方更新合并、Bridge/Cloud/IPA 发布顺序和最终验收矩阵，并由用户确认后开始
修改。
