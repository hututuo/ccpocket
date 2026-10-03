# Runtime 队列的职责与抽取入口

quarantine 已迁到 RuntimeOverlayQuarantine 唯一 owner，visual pending 仍由原 Cubit 持有（E058）。
十三项公开 queue 契约保护容量、预算与退休；future turn 两项 red 已在原接点窄修（E054/E055）。
完整产品/测试输入 `da3d3f6` 的 Mobile 3370 PASS / 4 SKIPPED、Bridge 2546 PASS / 1 SKIPPED，
原七黑盒、typecheck/format 与固定 SHA 独立复核通过；最终 analyze 的测试写法复查见 E060。
这些是选定源码门禁，历史 R29 和 `095cab00` 全量失败的直接归因仍未知。
queue-only authority 留存是原有且未审定的策略，不能从当前十三项契约推断所有 authority 替换会清队列。
C1f新增R50：真实producer status已入SQL但页面尚未观察authority时，原quarantine合法等待、原Updater接纳后单次canonical接替。
固定84493fc6的71项选定组合/目标静态/独立复核通过（E073）；产品未改，完整3396/4仍在16196f05。
这关闭的是未观察authority的正向等待。随后C1g在实际Bridge同public ID replacement与catalog capacity/public ACK组合通过（R52）；
旧A生产pending在ACK后退休，新B在完整status之后单次wire。
C1h又证明Mobile已收到旧A/尚未观察B的真实red→green（R54），纯本地commit receipt严格后继可退休旧事件，合法未来事件另有R55保护。
固定4e6d3d4a完整3412/4与83项通过；cached-only/跨订阅和overlay自身await-after尚未证明，完整R47仍开放。

## 两套队列不能合并

| 对象 | 现在的唯一 owner | 暂存原因 | 容量与当前溢出动作 | 出队条件 |
|---|---|---|---|---|
| visual pending | ChatSessionCubit 的 preserved turn / validation pending / pending visual list | runtime 重绑或首次 source 确认时，旧可见输出仍保留，新 delta/completion 尚不能归属同一 turn | 256 个消息；第 257 个触发原 visual reset，再按顺序 replay 已缓存加新消息；此策略仅是现状，边界契约尚未审定 | 当前 active、result=none 且带 turn ID；同 turn 保留旧输出，不同 turn 清旧输出再重放；terminal 不重放 |
| runtime overlay quarantine | RuntimeOverlayQuarantine 的 overlayId→event/bytes map 与总 bytes | source/runtime envelope 已合法，但当前 authority/turn 还未匹配 | 32 个 event / 64 KiB 编码消息预算；超限拒绝新消息，保留已有队列 | exact authority+activeTurn 匹配；先 remove 再走原 validated apply；明确旧时间/observer/runtime 则 remove+reject |
| visible runtime overlays | 原 Cubit state.entries、runtime assistant aliases 与 overlay tracking | 已验证的临时条目等待 canonical 消费或终态退休 | 独立 32 条 / 64 KiB，按现有 trim 规则裁剪旧呈现行 | canonical exact alias 消费或原 runtime/authority/turn reconcile |
| accepted overlay event IDs | 原 Cubit 的已应用 ID set | 防重放，不是正文队列 | 128 个 ID，移除最旧已应用 ID | runtime tracking reset；不能拿 quarantine 去重代替它 |
| stream pending | StreamingStateCubit 的 text/thinking buffers、flush timer、inputRevision | 合并高频 UI 发布 | 原 32ms 起步与长度阈值 cadence；不在本批改策略 | flush 发布、reset/close 取消 timer；revision 在 append 接受时推进 |

前三者可以同时使用“32条/64KiB”等数字，但约束的是不同对象。
quarantine 的 rejection 不能改成 visible trim 的 eviction；visual overflow 的 replay 也不能移植给 quarantine。
terminal ticket 只保存 generation/source/inputRevision，用于防止过期清流；没有另一份正文或控制 authority。

## 原入站接点与取消责任

源码入口集中于 `apps/mobile/lib/features/chat_session/state/chat_session_cubit.dart`：

| 接点 | 责任 | 迁移时必须保留 |
|---|---|---|
| updateDetachedLiveRuntime | generation 推进、旧 tagged subscription cancel、新 session fence；有旧流时标记 pending validation | durable session ID 不变；控制/审批先失效；旧回调不能产生新 ticket 或重放 |
| _adoptDetachedProviderSource | 首次权威 source 确认可保留 provisional visual；两个已知不同 source 清理旧 runtime | source/current lease 与 canonical reader 分开；首次确认不等于替换 |
| _bufferDetachedVisualMessageUntilTurnValidation | 只收 delta/thinking/live assistant completion | 原消息顺序、256/257 现状、停止/关闭检查；不收控制或 History 进入该队列 |
| _validateDetachedVisualTurn | 没有 turn ID 则继续隔离；同/不同 turn 与 terminal 分别处理 | buffered replay 在原 _applyDetachedVisualMessage；不得制造 turn ID 或提前给 control lease |
| _onDetachedRuntimeOverlay | provider/thread、认证 Bridge/source、runtime/origin、rejected authority、message turn、dedup 的 admission | 不把完整 Cubit/Bridge/Service 传给 queue helper；admission 保留唯一位置 |
| _quarantineDetachedRuntimeOverlay | insertion order、byte/count rejection 与只读统计 | duplicate ID 不计两次容量；超限不淘汰先前消息；不发送 ACK 或写 SQL |
| _flushPendingDetachedRuntimeOverlays | exact authority+turn先apply；当前合法同stream commit receipt严格后继或原时间事实证明stale才删除；其他pending | 复制队列迭代、remove-before-apply；无receipt/跨订阅不得冒用顺序；回调/重入后不保留负bytes，R54/R55 |
| _resetDetachedRuntimeOverlayTracking | 默认清 queue/bytes、accepted IDs 与原 tracking | suspend/source/binding/close/显式提交经原完整 reset；已核对同binding/authority的可见turn退休只清visible tracking，原flush再判pending；不能只迁走map留一份bytes |
| _reconcileDetachedRuntimeOverlayForStatus | 分类并清旧 runtime rows / aliases / tracking | 仅有已呈现tracking才核对其authority mismatch；queue-only早退，非匹配且未证明旧的消息继续隔离；在visual reset清alias前执行 |
| close | cancel subscriptions、reset overlay tracking 后 Cubit close | 回调检查 isClosed；StreamingStateCubit 的 flush timer 由其自己的 close 退休；不承诺未经验证的同步 join |

Service 继续独占 wire subscription/generation/sequence/FIFO/cache commit/ACK；
Repository 继续独占 canonical SQL 写入；C1a reader 继续持有 dirty/read ticket/current-source。
Runtime queue helper 不取得任一层权威，不能把普通 assistant 正文绕过 durable guard。

## 已有证据与缺口

已有 `chat_session_cubit_test.dart` 的 public 契约覆盖 source 身份、turnless overlay 拒绝、
quarantine 等待精确 authority、suspend/rebind、shared observer 和已呈现 overlay 的 count/byte 上限。
visual 同 turn、旧 ID 未知、首次 source 确认、不同 turn、idle 和审批撤权也已有原用例。
`detached_terminal_streaming_test.dart` 的二十一项与 held-final 原页面覆盖选定 terminal 窗口；
JSON/真实 SQLite 与 Bridge producer 另保护可选 runtime 身份的生产、剥离和持久化。
十三项 queue 契约覆盖下列已证明边界，具体 red 与同输入 green 见 E054–E060：

- 32/33 条、含中文的精确 65536 bytes 与单条 65537 bytes，拒绝新超限且保留已有 FIFO；
- duplicate 不重复计预算，accepted replay 不重新入队，stale 删除与 flush 后准确释放 bytes；
- source/runtime/suspend、close 迟到保护，以及有 visible owner 的 authority 替换；
- T1 已呈现、T2 先隔离时，直接 T2 working 和先 T1 terminal 两种顺序都保留合法 T2；
- 旧 turn 已被时间证明过期时删除；canonical user 在各反向输入中保留。

不能把上面证据扩张为：

| 缺口 | 下一批需要验证的结果 |
|---|---|
| queue-only 的已退休 authority 与未来 authority | 无 visible owner 时不能用本次反向测试推断应清或应等；先找 producer/status 顺序及失效证据，再审定策略（R47） |
| future authority/turn 在旧 terminal 前到达 | 同source/runtime/authority的T2公开契约已闭合；R50只证明尚未观察authority的正向等待，不证明已有旧authority的replacement；真实Provider双turn仍NOT_RUN |
| visual 256/257 overflow、buffered completion/control 副作用 | 先对照 provisional visual 的产品原则；不能照抄现在的 replay 当正确预期 |
| close 后迟到 observer/raw callback 与未 flush thinking | 原关闭契约仍成立，不能因为 state owner 搬动复活旧输出或产生 side effect |
| 两个真实 Provider turns、后台/长会话 | 原始 Provider record→wire→SQL→原页面逐层对照；fixture/public 双 lane PASS 不代替 |

## 已抽取范围与下一批

本批先建立 public Cubit 保护，以外部消息身份/UTF-8 字节与规范化编码预算断言，
没有通过私有方法 spy 证明实现。行为缺口在原接点 red→green 后独立提交，再迁移 owner。
后续仍须保留原断言；未明策略不能照抄进 helper 后宣称正确。

已实现的首个结构模块是 `RuntimeOverlayQuarantine`：仅拥有 insertion-order map 与 bytes，
输入为overlay ID、原event、已由原预算编码计算出的bytes；返回accepted/duplicate/capacityRejected。
固定FIFO snapshot复制迭代窗口，不复制或另持一份正文；原flush在apply前remove。
authority/source/time eligibility、apply、accepted-ID 去重、visible rows 与控制权继续在原 owning path。
它不持有页面、Cubit、Service、Repository 或 Bridge，也不再计算第二套 payload 编码。
map、bytes、remove、clear已一起迁移，原状态已删除；clear/flush/close接点仍经上表的Cubit原出口。
文件：apps/mobile/lib/features/chat_session/state/runtime_overlay_quarantine.dart；不新增异步close/join。

visual pending 暂不迁移；256/257 与 future terminal 策略未证明前不把两种 queue 做通用 coordinator。
C1e已完成已知runtime身份的原mutation接纳契约（R48），缺字段的完整远端归属仍R49。
Bridge组合已补R52（E077），固定911a4f60全量重放2547/1、类型/语法及敏感性恢复通过；首次catalog监听timeout另留R53。
C1h已按[authority生产/消费入口](QUEUE-AUTHORITY-ENTRY.md)闭合实际Mobile两个窗口与十项顺序合同（R54/R55 / E083）。
下一C1i补overlay自身await-after，另审cached-only/订阅切换；R47仍开放，暂不搬visual pending。
每次结构提交保持原消息、容量、deadline 与拒绝行为；新增策略另起行为批。
同输入的 public 契约、原七黑盒、全 Mobile/analyze/format、固定 SHA 独立复核及回退依赖共同验收。
Bridge 或 fixture source 未改时用精确 Git tree/lock 对象继承既有门禁，不把继承写成重跑。

## 接手与回退

先核对 PROCESS 的当前断点与 HEAD/status，不能将红灯 checkpoint 当运行候选。
C1c 修复涉及原 Cubit、StreamingStateCubit、status 协议/Bridge producer 与二十一项 terminal 测试；先保留行为保护再讨论结构回退。
quarantine 结构回退必须迁回完整 map/bytes/add/remove/clear，原 admission/alias/terminal 顺序保留。
保存每条 red 收据、冻结输入与最终 clean 门禁；源码 PASS、Provider/设备、Bridge 部署与发布分别报告。
