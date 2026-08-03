# CC Pocket 业务逻辑审计后的收敛实施计划

- 状态：`accepted / source-verified / release-pending`
- 审计输入：`/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/current/notes/business-logic-code-audit_v02_20260803-133209.md`
- 过程输入：`/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/current/runs/20260803-124550_ccpocket-business-logic-audit/WORKING_REPORT.md`
- 最新源码基线：`fix/mobile-status-projection-stability-20260803@b28cae1346b11d543fd51a2350a19eafdcca9a72`
- 本轮核心实施线：`fix/settings-runtime-consistency-20260803`
- 边界：源码、测试和候选集成；生产 Bridge、OTA、IPA、设备、Cloud 和 stable 是独立门禁。

## 1. 报告审查结论

修订版报告对源码基线的纠正是必要且正确的：不能把
`integration/ccpocket-current@4d0f58df` 当成仓库最新 Mobile 源码，也不能用相同的
Bridge package version 推断两个分支行为相同。手机设置投影结论必须包含
`e92750fe`、`c0c22101` 和 `b28cae13`。

以下报告结论已有直接代码证据，进入实施：

1. 私有 Codex runtime 的 model/reasoning/speed 原来先更新 Bridge 内存并广播成功，
   `thread/settings/update` 只在后台 best-effort 执行，没有把 durable 结果带回 Mobile。
2. 私有 Codex resume 已读取索引 settings，但新客户端省略显式 Plan override 时，创建
   runtime 仍可能用默认 `planMode=false` 覆盖索引中的 `collaborationMode=plan`。
3. Mirror Mobile parser 对 `notModified` 和 inline item 列表的类型错误缺少局部容错。
4. Subagent activity summary 与详情 list snapshot 是两种事实，当前可见面板可能需要
   revision 驱动的有界对账。

以下结论需要修正措辞或延后：

- Side Chat 当前产品入口和 floating dock 已明确使用 ephemeral 实现；Bridge registry
  也只注册普通/ephemeral handler。Persisted handler 未注册，当前不是一条活跃运行路径。
  Persisted wire/parser/pane 仍是旧客户端兼容和历史遗留，不能仅因文件存在就断言线上
  capability 冲突，也不能在未做旧 Bridge 矩阵前直接删除。
- ephemeral child 的 registry 是 Bridge 级共享事实，但 Mobile 已按父 durable thread
  过滤。是否再按设备/client 隔离属于产品契约，不是无需判断即可修的 parser bug。
- 生产 runtime、源码、IPA 和物理手机映射不闭合是发布/复现门禁，不等同于某一源码
  业务缺陷；必须在最终候选发布阶段单独闭合。
- 大规模 `ConnectionCoordinator`、`CodexSettingsSnapshot` 或目录 owner 重构是后续架构
  收敛，不应与本轮有证据的修复混成一个不可回滚提交。

## 2. 任务拆分

### A. 主线：设置持久化结果

Owner：主协调 Agent。

实现约束：

- 私有 runtime 仍允许旧 app-server 通过 `turn/start` override 完成普通下一轮；不得为
  追求 durable 语义而直接删除这个兼容能力。
- Bridge 必须等待 `thread/settings/update` 的真实结果后再发送设置 ACK，避免 Mobile
  先收到新值、随后又被 provider 旧完整快照覆盖。
- ACK 增加 additive `settingsPersistence=durable|runtime_only`；旧 Mobile 可忽略。
- shared attached 和 detached durable writer 成功 ACK 明确标为 `durable`。
- Mobile 解析结果并记录脱敏诊断；不得记录 prompt、正文、路径或原始 thread id。
- runtime-only 不能伪装为 durable；它仍表示当前 Bridge runtime 的下一次普通 turn
  override 已接受。

集成提交：`b2def0dafc039f6ef1955ea4c89e9968c390b8ac`。

验收：持久化完成前无成功 ACK；成功为 durable；旧 app-server/失败为 runtime-only；
共享路径仍为 durable；旧客户端忽略新增字段；Bridge build、相关 Bridge/Mobile 测试和
targeted analyze 通过。

### B. 主线：Plan resume fallback

Owner：主协调 Agent。

规则：

- 新客户端省略 `planMode` 是“保留 provider setting”，不是“关闭 Plan”。
- request 明确 `planMode` 或 legacy `permissionMode=plan` 时，请求优先。
- 请求未覆盖时，采用 authoritative index 中合法的 `collaborationMode`。
- 索引也未知时保持 undefined，让官方 runtime 决定；不得制造假 Default。

集成提交：`f153e7cf396e7fb054dc4a36209593da6827da26`。

验收：索引 Plan 保留、索引 Default 保留、显式关闭优先、旧无字段 runtime-owned、
approval/restart 既有回归不退化。

### C. Luna Max：Mirror 坏帧局部容错

隔离线：`fix/mirror-frame-tolerance-20260803`。

规则：

- 容器和 payload bounds 先于逐项解码；不得用“跳过坏项”绕过大小上限。
- `notModified` 缺失/错误不得通过直接 cast 终止 socket；采用事件语义对应的安全默认或
  局部失败。
- inline entries/deletes 混有坏项时只丢弃坏项并计数；全坏或影响 revision 连续性的
  patch fail closed，不能推进 revision。
- 错误 scope、generation、base revision 和 request correlation 继续严格拒绝。
- 不修改 Bridge wire 名、SQLite schema、Swift 或 Cloud。

验收：合法、混合坏项、全坏、bounds、错误 scope/revision、watch 保留和 scoped reset
均有回归；targeted test/analyze/diff-check 通过。

集成提交：`8096e67d`、`bfb56c7f`。根审查曾发现首版测试没有真正等待 reset，且
`_finishPending` 仍会提前释放 watch；补丁已改为显式保留 watch ownership，并验证 reset
真实发出后原 watch 仍可继续接收合法 patch。

### D. Luna Max：Subagent list/activity 对账

隔离线：`fix/subagent-activity-reconciliation-20260803`。

规则：

- activity summary 只触发 scoped refresh，不凭 activeCount 猜具体 agent 状态。
- 面板可见且 activity revision 前进时，每个 revision 最多触发一次有界 list refresh。
- refresh in-flight 时只合并一次 pending；完成后若 revision 仍落后再补一次。
- 面板不可见时不轮询；重新可见时按 revision gap 对账。
- provider thread、codexSourceId、connection generation 或 parent 变化时拒绝迟到结果。
- 旧 Bridge 无 watch 时保留手动刷新和原有 snapshot 行为。

验收：active→done、可见/不可见、in-flight+pending、target 切换、旧 generation、旧 Bridge
fallback 和性能边界均有测试。

集成提交：`d8ae7d72`。activity count 只用于折叠态即时数量，Active/Done 的逐项归属始终
来自 list snapshot；页面不可见时不启动详情轮询。

## 3. 本轮不直接执行的项目

### Side Chat 收束

本轮只登记，不删除：

- 正式 UI 继续 `EphemeralSideChatPane` + 原生会话前端 + 非模态 floating dock。
- `persisted-side-chat` handler 不得重新注册。
- 后续单独做旧 Bridge capability 矩阵：若没有受支持旧版本仍广告
  `persisted_side_chat_v1`，可删除 Mobile persisted pane；否则将其标为 legacy adapter，
  不作为新产品入口。
- 是否给 ephemeral registry 增加 device/client owner scope，要先决定“多设备共享同一临时
  child”还是“每设备独占”；在此之前只保留 parent/source fence，不猜产品语义。

### 大型架构重构

本轮不把 BridgeService、SessionListCubit、ChatSessionCubit、Mirror 和目录全部合并为
新 coordinator。待本轮修复和真机证据稳定后，再以状态 owner、knownness、authority、
revision 和 operation result 为边界逐步抽取；每一步必须有旧 Bridge/Claude/离线兼容。

## 4. 集成与验证顺序

1. 审查 Luna 分支实际 diff、测试质量和范围；不重复跑其已通过的同一套验证，除非报告
   不完整、测试可疑或集成冲突。
2. 以 `fix/settings-runtime-consistency-20260803` 为候选集成线，按以下顺序语义接入：
   Plan fallback → settings persistence ACK → Mirror tolerance → Subagent reconciliation。
3. 集成后运行相关 Bridge/Mobile 组合测试、Bridge build、targeted analyze、
   `git diff --check`；最终发布前再交由固定 Luna Max 发布任务跑全量和打包。
4. 更新 `CONTEXT.md`、`PROJECT_INDEX.md` 和本计划状态，登记完整 HEAD、提交顺序、
   兼容矩阵、源码/部署/OTA/IPA/设备门禁。
5. 不直接合入稳定分支、不 push、不部署、不发布。用户另行授权后，固定发布任务只接收
   一次完整的 exact worktree/branch/HEAD/rollback/允许与禁止范围。

## 4.1 实际集成结果（2026-08-03）

- 候选分支：`fix/settings-runtime-consistency-20260803`。
- 集成 HEAD：以最终台账记录为准；功能序列为
  `f153e7cf → b2def0da → d8ae7d72 → 8096e67d → bfb56c7f`，计划文档提交
  `0e57c3f5` 位于其中但不改变运行行为。
- Bridge 设置/Plan 组合回归：3 项通过；TypeScript 与 native helper build 通过。
- Mobile 设置 ACK、Mirror、Subagent 组合回归：123 项通过。
- Targeted analyze：0 error、0 warning；仅 2 条基线已有的
  `prefer_initializing_formals` info。
- Dart format 与 `git diff --check` 通过，候选工作树干净。
- 未执行全量测试、iOS 构建、IPA、OTA、生产 Bridge 切换或物理设备验收；这些仍属于固定
  发布流程的后续门禁。

## 4.2 当前生产运行门禁（2026-08-03 复核）

生产仍运行 `1.69.6-compat.15-b7bdeb7b`。loopback Bridge 和 LAN proxy 各自监听既有
地址，并非两个 Bridge 实例；但 `/readyz` 返回 HTTP 503，原因为
`shared_runtime_control_unavailable` 与 `action_broker_writer_unavailable`。因此后续发布任务
不能仅凭端口、`/version` 或 `/health` 的进程存活断言共享运行时可用，必须先恢复 daemon
control/Action Broker，再做真实设置 mutation 和手机链路 smoke。本轮未重启或修改生产。

## 5. 最终验收矩阵

- private Codex + 新 app-server：durable ACK，重启/resume/Goal continuation 保持设置。
- private Codex + 旧 app-server：runtime-only ACK，普通 Bridge-started 下一轮仍使用 override。
- daemon/shared Codex：durable writer ACK；当前 turn authority 不被设置操作抢占。
- 新 Mobile + 旧 Bridge：新增 ACK 字段缺失仍兼容，既有设置路径不崩溃。
- 旧 Mobile + 新 Bridge：忽略 additive ACK 字段，既有 system subtype 不变。
- Plan：索引 Plan/Default、显式 override、无索引、restart/approval 组合。
- Mirror：合法、混合坏项、全坏、超界、wrong scope/revision、重连。
- Subagents：当前主会话隔离、active→done、不可见、重连/source 切换、旧 Bridge。
- 交付：源码 HEAD、Bridge runtime/hash、Mobile build/patch、owner channel 和物理设备分别记录。
