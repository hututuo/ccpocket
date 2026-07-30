# CC Pocket 托管来源、会话状态与消息一致性修复方案 v01

> 状态：**active**
>
> 创建时间：2026-07-31 00:50:52 +0800
>
> 实施工作树：
> `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-provider-state-consistency-20260731`
>
> 实施分支：`fix/mobile-provider-state-consistency-20260731`
>
> 起始基线：
> `c5b55b73ec479345a17bfd88f87cda4099db70dc`
>
> 上一阶段权威集成分支：
> `integration/mobile-session-sync-v2-20260730`

本方案是仓库与历史分支收束完成后的下一阶段实施约束。它登记用户在真机上新确认的
问题，并把 Codex Desktop/app-server 托管与 Bridge 托管两条路径放回同一条
`provider → Bridge → protocol → Mobile cache/reducer → UI` 链路审计。本文不是凭
现象指定补丁位置；实际修改前仍必须以当前源码、运行日志和可复现测试确定根因。

## 一、用户确认的问题

### 1. 三套互相冲突的“处理中”

当前界面同时可能出现：

1. 会话卡片左上角的普通“处理中”；
2. 左上角“处理中”旁再出现电脑图标；
3. 下载按钮左侧的另一枚“处理中”。

状态还会在刷新时互相切换。用户要求最终只保留一个左上角状态区域，并只区分两个
**运行托管来源**：

- Codex Desktop/app-server 正在电脑端托管运行；
- CC Pocket Bridge 正在托管运行。

“是否已下载”“Mirror 是否正在同步”“app-server 是否已加载 thread”都不是第三种
用户可见运行状态，不能再用“处理中”表达。普通 idle 会话不显示 Ready。

### 2. Codex Desktop/app-server 托管路径功能不完整

真机现象包括：

- 打开 Codex 托管会话时可能加载失败；
- 正在运行状态缺失、错误或闪烁；
- 运行时发送引导/steer 可能失败；
- Codex 托管消息的真实时间戳错误，而 Bridge 托管路径正确；
- Codex 托管会话内悬浮窗入口会消失。

必须核对两条托管路径是否经过不同的身份、历史、发送、状态和 UI composition
实现。目标不是把 Codex 托管伪装成 Bridge 托管，而是在统一的内部模型下保留明确
的托管来源，并保证两边具备相同的阅读、引导、悬浮窗和时间语义。

### 3. 实时增量导致消息排序错乱

一个正在更新的会话进入后，增量历史加载可能使消息顺序错乱；退出再进入会暂时恢复，
下一次刷新又可能错乱。必须审计稳定 ID、turn/item ordinal、revision、generation、
optimistic entry 替换和 SQLite/reducer commit 顺序。时间戳只能用于显示和最后的
tie-breaker，不能用到达顺序或全量按时间重排代替权威结构顺序。

### 4. 会话进入超时必须按“无进展”判断

当前固定墙钟超时不适合不同大小的上下文。改为：

- 每次完成真实阶段、收到有效分块、提交一页、revision 前移或已有可见数据增加时，
  更新 `lastMeaningfulProgressAt`；
- 只有连续一段时间没有任何有意义进展，才判定 stalled；
- 总体仍保留较大的绝对安全上限，避免服务器持续发送无效心跳造成永久等待；
- 进度动画必须由独立 ticker 正常运行，网络/解析/SQLite 工作不得阻塞 UI isolate；
- 超时 UI 保留当前本地内容，并提供重试、诊断和返回，不清空可用缓存。

具体 idle 窗口和绝对上限必须由基准、测试和真机日志决定，不能只换一个固定数字。

### 5. 自动批准由 Bridge 持有

自动批准策略、持久化、监督和实际批准必须在 Bridge 端运行，手机退出前台或断开后
仍然生效。Mobile 只负责配置、显示和显式关闭。必须保留安全边界：

- 用户显式按会话开启；
- Bridge 持久化并在重启后恢复；
- 对不能由当前 Bridge/app-server 所有权回答的外部 Desktop 请求，必须明确显示
  degraded/unsupported，不能伪造已批准；
- 审批事件和自动批准结果需要可审计且不得泄露敏感正文。

### 6. Codex source 归属错误

需要定位并修复：

`This conversation belongs to a aifferent Codex source.`

以及当前源码中的同义错误。会话身份必须使用经过认证的
`bridgeInstanceId + codexSourceId + providerThreadId`，IP、标题和项目路径都不能
成为会话主键。换 LAN/Tailscale 路线不得产生新数据源；真正不同的 Codex source
不得被静默合并。错误文案拼写也需修正，但不能用改文案掩盖归属判定错误。

### 7. Bridge 不可读响应

发送新消息时可能出现：

`Bridge sent an unreadable response.`

必须取得 Mobile 请求、Bridge 原始响应、协议解析和具体 provider 操作的同一
`requestId/clientMessageId` 证据。新旧协议响应需加法兼容；已被 Bridge 接受的请求
不能因为后续响应解析失败而被重复发送。

### 8. 排队消息需要两阶段回执

运行中追加的排队消息显示两个独立勾：

1. 第一勾：Bridge 已确认接收并持久/可靠挂入该会话的队列；
2. 第二勾：Bridge 已将任务成功交给 provider/app-server，新 turn 或 steer 已被
   权威确认。

两勾不能用本地 socket write 成功冒充。协议必须携带稳定
`clientMessageId`、队列 item ID 和阶段；重连、重试和重复 ACK 均幂等。失败或取消
应显示明确状态，不得把第一勾回退成“从未发送”，也不得在第二阶段未知时显示双勾。

## 二、已确认的当前代码证据

以下是开工时已由源码索引确认的事实，后续不得退回凭 UI 猜测：

- `RunningSessionCard` 先用 `sessionVisualStatusFor(...)` 生成统一状态标签；
- 同一卡片又用 `externalDesktopTurnActive` 强制把 raw status 当作 running，并额外
  加 `Icons.computer`；
- 同一行还独立渲染 `ConversationMirrorRunningBadge(session: session)`；
- 因此用户看到三套“处理中”有真实代码来源，不是单纯的文案重复；
- `SessionInfo` 同时携带 runtime `status`、`externalDesktopTurnActive`、
  `queuedInput`、provider 和 Codex settings，多来源尚未形成单一可审计投影；
- Bridge 已存在 `auto_approval_state_v1`、持久状态文件和 Bridge-side supervisor，
  所以本轮重点是核对所有托管来源是否真正接入，而不是再写一套手机端批准器；
- source 不匹配错误当前至少由 Conversation Mirror 的来源校验抛出，仍需继续追踪
  为什么发送/打开路径会把同一真实来源判成不同来源。

## 三、目标内部契约

### 3.1 状态与托管来源分离

统一会话投影至少包含：

```text
activity:
  idle | working | compacting | systemError | unknown

attention:
  none | approval | question | permission | form

executionHost:
  bridge | desktopAppServer | unknown

mirrorSync:
  idle | syncing | stalled | failed

runtimeAttachment:
  notLoaded | loaded | ownedElsewhere
```

用户可见的左上角主状态优先级仍为：

`Need You > Working/Compacting > Error > 完成未读 > 无标记`

其中 `executionHost` 只决定“电脑端 Codex”或“Bridge”这一枚来源标识，不再制造第二
个 Working。`mirrorSync` 只驱动同步光晕/诊断，不得显示成第三套“处理中”。

### 3.2 两条托管路径共享的产品能力

无论 `executionHost`：

- 目录身份和缓存键相同；
- 打开先显示 SQLite 中的最新内容；
- 状态走同一投影；
- 最新增量走同一 reducer；
- 消息时间使用 provider/电脑接收的权威时间；
- 会话级悬浮窗按 canonical parent thread ID 过滤，不按 runtime session 是否存在；
- 正在运行时可依据能力使用 steer/guide；
- 不支持或 owned elsewhere 时给出结构化原因，不返回模糊“不可读响应”。

### 3.3 权威排序

排序键固定为：

```text
source generation
→ thread revision
→ turn ordinal
→ item ordinal
→ chunk sequence
→ stable ID
```

每个会话串行提交，不同会话可有界并行。迟到 generation 直接丢弃；相同 stable ID
执行幂等 upsert；缺 base revision 只补该会话 gap。渲染层不得用当前 list append
顺序补救协议/数据库的结构缺失。

### 3.4 发送与排队状态

```text
localDraft
  → submitting
  → bridgeAccepted       // 第一勾
  → providerAccepted     // 第二勾
  → authoritativeEcho
  → completed
```

还需支持 `failedRetryable`、`failedTerminal`、`cancelled` 和 `unknownAfterReconnect`。
旧 Bridge 只返回单阶段结果时保留兼容 UI，但不得伪造第一、第二阶段的精度；可显示
单一 legacy sent 状态。

## 四、实施台账

| 原始问题 | 当前状态 | 主要核对链 | 完成门禁 |
|---|---|---|---|
| 三套“处理中” | 已确认实现偏离 | status projection、external desktop、Mirror badge | 只保留一个主状态和一个来源标识 |
| Codex 托管打开失败 | 调查中 | catalog identity → history/read/resume → Mobile binding | 新旧 app-server、缓存/在线打开测试 |
| Codex 托管状态错误 | 调查中 | app-server status event → Bridge projection → card | working/idle/unknown/ownedElsewhere 测试 |
| Codex 托管 guide 失败 | 调查中 | message intent → steer/start → ownership → response | 正在运行与空闲两种路径测试 |
| Codex 托管时间戳错误 | 调查中 | provider timestamp → protocol → SQLite → ChatEntry | 两托管来源一致的真实时间测试 |
| Codex 托管悬浮窗消失 | 调查中 | canonical parent ID → registry → composition | 两托管来源及增量重建后保持 |
| 增量排序错乱 | 调查中 | generation/revision/ordinal → SQLite → reducer | 迟到、重复、分页交错、重进一致 |
| 固定超时 | 调查中 | loading phases/progress events/UI timer | 进度持续不误超时，无进展可恢复 |
| 自动批准离开手机失效 | 部分已有 | Bridge policy/supervisor/ownership | Bridge 断开手机后测试及边界文案 |
| different Codex source | 调查中 | machine/source/thread identity and migration | 同源多路线通过、真异源拒绝 |
| unreadable response | 调查中 | request/response parser/error envelope | 所有 send/steer/queue 响应结构化 |
| 排队消息双勾 | 未实现完整语义 | queue persistence/provider ACK/Mobile UI | 重连幂等与两阶段状态测试 |

## 五、提交顺序

计划按行为拆分；实际文件和内部算法以调查结果为准：

1. `docs: 登记托管来源与会话一致性实施方案`
2. `协议：统一会话活动状态与执行托管来源`
3. `移动端：收束卡片状态与悬浮窗身份`
4. `Bridge：修复 Codex source 归属与运行时操作`
5. `会话：稳定增量排序与真实消息时间`
6. `移动端：按有效进度判断会话加载停滞`
7. `Bridge：补齐自动批准托管来源覆盖`
8. `协议：增加排队消息两阶段回执`
9. `审计：记录兼容、性能和真机验收结果`

如果调查证明多个症状同源，可合并相邻提交；不得把无关行为、生成物、部署记录和
格式化混入同一提交。

## 六、兼容与性能边界

- 所有协议字段必须 additive/capability-gated。
- 新 Mobile + 旧 Bridge 保留旧单阶段消息发送和旧状态显示，但不伪造新精度。
- 旧 Mobile + 新 Bridge 忽略新增 host/ACK 字段，原消息路径保持可用。
- 新旧 app-server 通过适配器映射；不支持 steer 或状态事件时明确降级。
- Claude/legacy rollout 不得因 Codex 修复回归。
- 不按 IP 拆分同一 Bridge，也不合并真正不同的 `codexSourceId`。
- 不增加逐会话高频轮询、全历史重排或每帧全列表重建。
- 排序和两阶段 ACK 采用索引、稳定 ID、局部 upsert，不让内存随总历史线性增长。
- 动画与进度计时器离屏、idle 或页面销毁后必须停止。

## 七、验证与完成标准

### 自动验证

- Bridge 定向与全量测试、TypeScript build、native helper build；
- Mobile 定向与全量测试、Flutter analyze；
- SQLite migration/index/query-plan 和乱序/迟到/重复压力测试；
- iOS Simulator Debug/Release；
- `git diff --check`；
- 新旧 Mobile/Bridge/app-server/Claude 兼容矩阵；
- 独立代码复审和性能扫描。

### 运行与真机门禁

源码和模拟器通过不等于已部署。最终必须分开报告：

- 源码完成；
- Bridge 候选构建；
- 实际 Bridge 重启；
- OTA 或 IPA 构建；
- 物理 iPhone 状态、排序、悬浮窗、超时和双勾验收。

未经用户后续明确授权，不在本分支自行 push、发布 stable、安装真机或不可逆清理。
发现经证实的同链路 bug 可以一并修复，但必须先记录根因和回归证据。
