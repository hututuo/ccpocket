# CC Pocket 托管来源、会话状态与消息一致性终验

> 状态：`final-candidate`
>
> 记录时间：2026-07-31 06:02:22 +0800
>
> 起始基线：`c5b55b73ec479345a17bfd88f87cda4099db70dc`
>
> 代码终验候选：`583222be2bc77741896c416e7c82644052cb23c1`
>
> 实施分支：`fix/mobile-provider-state-consistency-20260731`
>
> 最终目标分支：`integration/mobile-session-sync-v2-20260730`

本文按用户原始问题逐项核对真实实现，不把“测试通过”“模拟器构建成功”“Bridge
已经部署”“IPA 已安装”混为一件事。本文记录的代码候选未重启生产 Bridge、未发布
OTA、未生成交付 IPA、未安装物理 iPhone，也未 push 或发布 stable。

## 1. 需求完成台账

| 原始要求 | 实现与证据 | 状态 |
|---|---|---|
| 三套互相切换的“处理中”收束为一个左上状态，来源只区分 Desktop/app-server 与 Bridge | `569f4593` 统一状态/托管来源；`d1e361ae` 收束单一卡片；`5eb0ecc9` 映射 Bridge 启动中；`45fa4047` 保持 durable 卡片身份和重排状态。Mirror 下载/同步仅保留独立动作反馈，不再成为第三套运行状态 | 已完成且自动验证 |
| Codex Desktop 托管会话可读、状态正确、能安全发送/引导、时间正确、悬浮窗不消失 | `38e0556a`/`fffe558a` 复核来源身份；`07dad30a` 保留外部活跃状态；`44fd509a`/`6ddc8c18` 透传源时间；`db0772d6` 稳定 detached 悬浮窗；`8b4d60fa`/`30986e0c` 仅在确有 turn 所有权时 steer；`583222be` 以 `providerThreadId + codexSourceId` 只读查询未附着会话的子 Agent | 源码完成；外部 owner 正在运行的 turn 只可安全排队到下一轮，不能伪造实时 steer |
| 实时增量期间消息顺序稳定，退出重进不再成为“修复”方式 | `7c5facab`/`658f4fc4` 固定实时、分页、Mirror 顺序边界；`81a8d598` 索引历史锚点；`175a9b7e` 直接投影同步增量；迟到 generation、重复 stable ID 和 optimistic echo 均有回归覆盖 | 已完成且自动验证 |
| 会话进入按“无有效进展”而非固定墙钟超时 | `0022fba2` 增加 request-correlated 真实阶段；`579cba4b`/`09ff2a76` 以有效进展续期；`8c9c0fa2` 分离预检与响应预算；`92c01487` 只在停滞时超时，重复 heartbeat 不续期，绝对上限仅作安全诊断 | 已完成且自动验证 |
| 自动批准由 Bridge 托管，手机退出后仍可运行 | `419a70a3` 明确独立 app-server 所有权边界；`3cd6f840` 区分配置与实际生效；`d1f7a493` 按 `codexSourceId + threadId` 隔离持久策略，旧 v1 无 source 数据 fail-closed | Bridge 持有路径完成；外部私有 app-server 的审批不能被本 Bridge 抢占 |
| 修复 “different Codex source”，同机不同 IP 不拆缓存，真异源仍拒绝 | `38e0556a` 刷新权威来源身份；`fffe558a` 恢复前按认证目录复核；`8dfb510a` 增加来源切换诊断。身份仍为认证后的 `bridgeInstanceId + codexSourceId + providerThreadId`，不使用标题、项目路径或 IP | 已完成且自动验证 |
| 修复发送后 “Bridge sent an unreadable response”，错误不得污染无关会话 | `10f4a542` 拆分 parse/apply 故障；`bc941394` 将无归属坏帧限制到全局诊断，并让 history/delta 错误携带目标 `sessionId` 与稳定 `errorCode` | 已完成且自动验证 |
| 排队消息显示 Bridge 接纳与 provider 接纳两个独立勾 | `55e11bfa` 增加两阶段协议；`5aa8556c` 展示阶段；`eaf3d454` 处理队列与上游回执；`5d838117` 恢复持久 outbox 的权威去重。第一勾不再由 socket write 冒充，第二勾只由 provider RPC/权威 echo 推进 | 已完成且自动验证 |

## 2. 第二轮独立审计修复

第一次独立复审在 `92c01487` 找到两项仍可在当前边界内修复的问题和一个所有权边界：

1. **无归属错误广播到所有会话**
   - `bc941394` 后，无法证明 `sessionId` 的帧错误只进入全局诊断；
   - 有明确目标的错误只进入目标会话；
   - Codex history failure 使用净化文案和 `history_read_failed`，delta 缺会话使用
     `session_not_found`；
   - 不再把底层 RPC 原始正文泄漏给 Mobile。
2. **未附着 Desktop durable 会话把 thread ID 当 runtime session ID**
   - `583222be` 增加 capability `detached_subagents_read_v1`；
   - 请求只携带 `ownerSessionId + providerThreadId + codexSourceId`，没有伪造
     runtime `sessionId`；
   - Bridge 在 `runtime.getSession()` 前分流，来源不一致时在启动 provider reader
     前失败；
   - 只调用有界 `thread/list`、`thread/turns/list`、`thread/items/list` 读取，
     不调用 `thread/resume`、`thread/start` 或 `thread/fork`，不取得 writer；
   - attached 旧路径不变；新 Mobile + 旧 Bridge 明确显示 unsupported；旧 Mobile +
     新 Bridge 继续使用原 attached 协议；
   - 列表最多检查 20 页/2,000 项，历史响应最多 400 条/512 KiB，超限明确标记
     `truncated`。
3. **外部 Desktop app-server 正在持有 turn**
   - 官方当前没有跨独立 app-server 的显式写入权转移接口；
   - 本实现不会强杀、重启或抢占 Desktop owner；
   - 普通输入由 Bridge 可靠排队，在外部 turn 结束并重新附着后进入下一轮；
   - UI/两阶段 ACK 不宣称它已实时 steer；
   - 若未来要求真正实时引导，必须使用同一个共享 app-server 或官方提供、且能验证
     owner 的控制通道。

严格检查历史大区间 `c9499403..HEAD` 会命中
`backups/20260730-073655_bridge-1.69.4-compat.5-00ee7c18-deploy/README.md`
的一处基线前尾随空白。它不在本任务 `c5b55b73..HEAD` 的增量中，属于发布备份
证据，不修改归档来制造“全历史干净”的假象，登记为非阻断 P3。

## 3. 最终自动验证

### Bridge

- 全量：`96` 个测试文件、`1946` 项全部通过；
- pretest TypeScript build 通过；
- darwin native file-browser helper 构建通过；
- `git diff --check c5b55b73..HEAD` 通过。

### Mobile

- 全量：`2750` 项通过，`4` 项按仓库既有条件跳过，`0` 失败；
- `flutter analyze --no-fatal-infos`：`0 error / 0 warning`；
- `52` 条仓库既有 info 单独登记，没有伪装为零诊断；
- Flutter `3.44.7`；
- iOS Simulator Debug：`Xcode build done 104.8s`，生成
  `build/ios/iphonesimulator/Runner.app`；
- iOS device Release no-codesign：`Xcode build done 124.7s`，生成
  `build/ios/iphoneos/Runner.app`；
- Release 元数据：`com.k9i.ccpocket`、`1.111.1+209`、最低 iOS `15.0`、
  `arm64`、约 `66.4 MB`（`du` 约 `64 MiB`）；
- `5fbf671a` 后没有 iOS、plugin 或 pubspec diff，因此此前同一原生树的
  RunnerTests `27 passed / 0 failed` 仍适用；本轮没有用重复 XCTest 构建冒充新增
  原生验证。

本任务未改 `functions/`，因此没有部署或重复运行 Cloud Function 发布门禁。

## 4. 性能终验

Bridge 最终候选：

- 真实 state DB 目录 `306` 项：median `34.29 ms`、p95 `40.45 ms`、
  max `106.82 ms`；
- 合成 `1500` 项：priority p95 `19.77 ms`、complete p95 `33.46 ms`；
- 合成 `10000` 项：priority p95 `48.99 ms`、complete p95 `73.67 ms`；
- 首次历史读取 `14`，无变化重连 `0`，实时更新 `1`；
- 同时 provider history 读取最多 `2`；
- 最大物理帧 `57,586 B`，低于 `64 KiB`；
- 1500 项单轮最大发送 `807,617 B`，低于 `1 MiB` 未 ACK 预算。

Mobile SQLite 最终候选：

- 1500 项目录写入 `249.89 ms`；
- 目录读取 p50 `5.69 ms`、p95 `17.44 ms`；
- 200 项热窗口打开 p50 `0.77 ms`、p95 `3.67 ms`；
- 2000 项 staging 写入 `331.21 ms`；
- staging 峰值 RSS 增量约 `2.98 MiB`；
- 数据库约 `3.92 MiB`；
- 查询计划使用 `conversation_hot_entries_order` 索引。

历史现场基准曾有 2/5 次 app-server 冷尾 p95 超过 500 ms（约
`547.95/731.40 ms`）。最终这次真实目录 p95 为 `40.45 ms`，但不能用一次暖态结果
否认冷启动尾延迟；该风险继续作为 app-server/磁盘冷态观测项，不构成本轮同步或
Mobile 缓存回归。

旧性能分支 `audit/mobile-app-performance-20260724@917afcf9` 的 7 个提交相对当前
候选均为 patch-equivalent（`git cherry` 全部为 `-`），无需把旧树机械合入。

## 5. 兼容矩阵

- **新 Mobile + 新 Bridge**：使用统一状态、source-scoped auto approval、两阶段
  ACK、结构化错误和 detached subagent 只读能力。
- **新 Mobile + 旧 Bridge**：保持旧状态/发送/attached subagent 行为；无法证明
  新精度时明确降级，不伪造第二阶段或 detached 数据。
- **旧 Mobile + 新 Bridge**：新增字段和能力均为 additive；旧客户端忽略它们，
  原 session/history/input 路径不变。
- **新旧 app-server**：优先有界分页；不支持分页时不退回无界 whole-history read；
  read-only 打开不 resume。
- **Claude / legacy rollout**：没有改变其 canonical history 或 writer 语义；
  Codex source 门禁不按标题或路径误套到 Claude。
- **同一 Bridge 的多个 IP/域名**：路线只负责连接，认证后的
  `bridgeInstanceId + codexSourceId` 复用同一缓存。
- **两个独立 Codex app-server**：可共享只读历史；writer ownership 仍由实际
  owner 决定，不能由 CC Pocket 猜测或抢占。

## 6. 分支语义映射

- `audit/mobile-app-performance-20260724`：所有 7 个提交已精确 patch-equivalent。
- `fix/mobile-session-continuity-hardening@dd247e06`：
  - Desktop continuity 已由当前线 `09cf060e`、`33ab6f1e`、`f51fc32e` 等祖先语义
    覆盖；
  - 配置保留、快速重连 fence、context compaction ring 分别由
    `5770ac32`、`31db336e`、`b6ace2f3` 覆盖；
  - 官方 ephemeral Side Chat 由 `a1a22249`、`41729eec` 覆盖；
  - 旧 persisted/modal Side Chat `22466768` 已被产品决策废弃；
  - 不整枝合入旧 transport/tree，只登记语义吸收与废弃项。
- `fix/remote-altserver-signing@feaef763`：独立部署工具线，含 5 个有效独有提交，
  不进入本轮 Mobile/Bridge 集成，也不删除。

所有待清理普通分支会先保存精确
`refs/archive/ccpocket/provider-state-consistency-20260731/*` 引用，再以一个明确
“tree unchanged”的 ancestry-only merge 登记语义吸收/替代；之后仅用普通
`git branch -d` 删除。脏工作树、独立 AltServer 线、`main`、兼容锚和历史回滚锚
不在删除范围。

## 7. 分支与工作树收束

- `integration/mobile-session-sync-v2-20260730` 已从 `c5b55b73` fast-forward
  到验收与文档提交 `a69f70d2`。
- `856a0d6e` 以 `ours` 策略登记 15 条已吸收/替代支线的真实祖先关系；合并前后
  tree 均为 `a55955d4a6662361f6730995b07ea6e67c8d46e7`，源码树没有变化。
- 16 个被清理普通分支的原 tip 均保存到
  `refs/archive/ccpocket/provider-state-consistency-20260731/*`。
- 16 个普通任务分支全部在集成分支视角确认可达后，使用普通
  `git branch -d` 删除；未使用 `-D`。
- 9 个完成的任务 worktree 在确认无 tracked 修改后使用非强制
  `git worktree remove` 移除。主任务树中两个未跟踪项均是指向权威集成 worktree
  依赖目录的符号链接，核对目标后只解除链接。
- 精确清理约 `4,645,120 KiB`（约 `4.43 GiB`）可重建 worktree/构建/依赖材料；
  磁盘可用空间从约 `61 GiB` 增至约 `64 GiB`。
- 最终保留普通分支仅为：
  `integration/mobile-session-sync-v2-20260730`、`main`、
  `compat/artifact-download`、`backup/pre-upstream-1.67.4-20260719` 和独立
  `fix/remote-altserver-signing`。

## 8. 独立复审与完成边界

最终独立复审结论为：

- `0 P0 / 0 P1 / 0 P2 / 1 P3`；
- `bc941394` 的错误隔离和 `583222be` 的 detached subagent 只读能力均确认关闭
  第二轮 P2；
- 原五个 P2（来源时间、停滞超时、单一 durable 卡片、稳定惰性重排、
  source/thread-scoped 自动批准）没有回归；
- 外部 app-server owner 的实时 steer 按已确认所有权边界处理，不再列为缺陷；
- 唯一 P3 是上述基线前 backup README 空白；
- **复审决定：批准快进最终集成分支。**

仍需物理设备或发布阶段验证的事项：

- 真机上 Bridge-hosted 与 Desktop-hosted 状态/来源视觉；
- 外部 Desktop turn 结束后的排队消息进入下一轮；
- 长历史冷启动与极端网络抖动；
- 真机悬浮窗拖动、折叠和 detached subagent 阅读；
- OTA、AltStore IPA、后台通知、APNs/FCM 和物理 iOS 行为。

这些门禁不否定源码与自动验收完成，也不能被源码/模拟器结果冒充。生产 Bridge
在本阶段保持原样。
