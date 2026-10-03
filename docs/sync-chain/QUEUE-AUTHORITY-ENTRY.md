# Queue-only authority 的生产、提交与页面接纳

本入口起于固定16196f05的只读梳理。C1f只添加测试和过程证据：冻结输入84493fc6，
产品lib/Bridge/锁文件与16196f05相同；完整门禁仍在旧输入，不宣称全部replacement策略正确。
本批71项组合、目标静态/格式、敏感性及独立复核见[过程E066–E073](PROCESS.md) / [门禁记录](ACCEPTANCE.json)。

## 实际producer的身份与生命周期

| 原源码接点 | 已核对的事实 | 对R47的含义 |
|---|---|---|
| SessionManager.replaceCodexSession / createSession（session.ts 624、908） | replaceSessionId复用public ID，创建新CodexProcess；sessions map更新、旧process stop及sync通知沿原入口发生 | 同binding/public ID不保证同authority；不能以binding是否变化独自决定旧队列 |
| CodexProcess constructor / prepareLaunch / finalizeStoppedState（877、2931、2804） | authority由实际UUID生成，启动/失效可轮换；runtime snapshot读取当前getter | UUID是opaque identity，无大小/时间排序语义 |
| WebSocket runtime snapshot / statusFromRuntime（websocket.ts 2223、4026） | bridgeSessionId来自summary.id，authority来自当前实际process | 生产authority与public runtime ID是两项事实 |
| V2 runtimeSessionChanged / publishRuntimeOverlay（1111、1144） | replacement通知同步刷新projection，实际snapshot构造overlay envelope | handler异步runSync等待期间仍可能收到新的runtime变化，须验证组合顺序 |

上述文件均在packages/bridge/src下；V2为local-features/conversation-sync-v2.ts。
C1f原Bridge tree为 `61fda2bdb14f2325a96957186dcc6ac0ade3f4e6`；C1g只新增测试/harness使整个tree变化，
293个既有Bridge文件逐项blob不变，生产文件/依赖继承证明见c1g-final-input-identity.json。
只读producer审计为证据目录中的c1f-bridge-producer-audit.json；它没有执行新测试。

## status排队与capacity的当前责任

- runtimeOverlayAuthorityIsSequenced（1789）要求statusProjection的authority/turn匹配，
  且subscription已经发送或正在排队同一statusState；pendingStatusState不是Mobile ACK或页面已应用。
- publishRuntimeOverlay（1640）调度异步runSync；refreshCatalog（2689）与status发送（3057）有await，
  status可以等待原capacity；runtimeSessionChanged在这些等待期间更新projection。
- sendPendingRuntimeOverlays（1880）在await capacity前检查superseded，在await后再次检查sequenced/superseded。
- superseded（1842）在当前authority缺失时保留；已知不同authority则退休；同authority的不同active turn亦退休。
  无active turn且working/compacting仍可等待，其他terminal分支按真实observedAt关系判断。
- ACK处理（2498）提交原acked statusState、唤醒capacity waiters；它不证明Flutter页面已接纳。

Bridge与Cubit处理不同阶段的queue。Bridge有当前producer失效事实；页面可能尚未观察该事实。
两侧容量/identity判断不能因名称相同便合并成一个通用queue。

## 原消费链与C1f的实证

Service的_v2MutationTail串行接受wire。完整status batch先await真实Repository的SQLite事务，
再publish syncUpdates；SessionList先applyCommittedStatusDelta更新map，再异步通知原Updater。
Updater读取当前status并调用原Cubit接点。wire sent、SQL committed、page applied是三个边界。

C1f复用原stdio JSON-RPC Provider fixture与真实Bridge/SessionManager/Service/Repository/SessionList/Cubit。
仅延迟本用例状态Updater的挂载，先同时等待实际session_list handle和Provider system/init，再发真实item。
canonical屏障订阅原timeline通知并读SQL确认该assistant已提交；没有重排wire或替换receiver。

| 实际阶段 | 原入口观测结果 |
|---|---|
| status已发送并入SQL，page还未观察authority | 匹配status sequence37先于overlay38；实际runtime/authority/turn一致；pending=1、bytes>0，无mutation权限 |
| 挂载原DurableSessionPreviewUpdater | 精确authority+turn被原flush接纳，pending/bytes=0，assistant只出现一次 |
| 原canonical window接替 | 同一Updater state identity；同assistant仍单条，runtimeOverlayCount=0 |

runtime snapshot、RPC item/completed、wire、SQL读取断言与页面三段轨迹已核对，见
c1f-final-validated-wire-sql-page-audit.json。临时错误策略“event authority不同于page当前值便删除”
在固定84493fc6输入上按预期FAIL：pending应1、实际0；finally恢复完整产品hash且Git clean，恢复后4项PASS。
该实验未提交/部署，证据仅证明R50正向等待有保护，不证明旧authority应如何退休。

Cubit _reconcileDetachedRuntimeOverlayForStatus没有已呈现tracking时仍早退。
原flush先对exact authority+turn匹配apply，再仅按已证明stale规则删除；source/runtime/suspend等原reset各自保留。
因为same-ID replacement不必触发binding change，R50及已有visible-owner反向测试不能关闭完整R47。

## C1g：同ID替换与catalog capacity的实际组合合同

既有component证据分别位于session.test.ts的stable-ID replacement、codex-process.test.ts的stop authority轮换，
V2 tests的status先于overlay、terminal drop及bounded capacity gate；它们没有共同执行真实replacement callback。
部分用例的MockCodexProcess或手工runtime snapshot也不能代替实际新UUID生成。

1. 固定真实SessionManager、WebSocket/V2 handler与锁文件；仅扩展隔离fixture或新测试控制入口，保留原七黑盒。
2. 让actual process A生产overlay并停在原capacity/ACK等待，记录pending事实；经原replacement入口创建process B。
3. 断言public runtime ID相同、实际authority不同；B的projection来自原同步callback，无UUID排序或手造墙钟。
4. 释放/ACK有限gate，检查旧A事件不会取得新的wire发送权，新B合法事件仍可发送；保留原sequence和期限。
5. 再接真实Mobile/SQL与原页面观察延迟，分别证明已经失效旧A和页面尚未观察的新B，不能只看Bridge是否发出。
6. 如果真正产品行为与可判定事实不符，先保存red，再在原owner窄修；结构迁移另提交。
   32/64KiB拒绝新事件、remove-before-apply、13项queue、26项权限、21项terminal、原接收黑盒必须继续成立。

步骤1–4已在固定911a4f60由actual CodexProcess、SessionManager、Bridge/V2 handler和raw RPC共同执行（R52）。
A pending于原catalog capacity处，actual同public ID replacement创建B及新UUID；B status41页164–204先于overlay205，
仅public ACK恢复，旧A无wire，pending map/bytes与budget/waiters在close前归零。
新harness由既有tsx直接加载实际TS源码，原fixture/预算/producer/control均未替换；catalog seed仅提供可重复的容量输入。
错误“不同authority仍保留A”敏感性按预期FAIL（pending0→1）；finally恢复原产品SHA256及clean后完整Bridge重放2547/1。
目标语法/类型和固定SHA只读review通过，原始FAIL、恢复及trace见E074–E077 / supplementalC1g。

## 下一批C1h：实际Mobile旧A与未观察新B

步骤5–6仍NOT_RUN：先让实际A overlay经过原wire/Service/SQL并处于无visible owner的quarantine，
再用原replacement入口产生同public ID的B。分别检查B刚替换尚无新notification、B真正产生新item后两个窗口。
source、binding、producer authority、status observedAt与page接纳各记录实际值，不能为了得到red手造时间/authority。
有限延迟只控制原Updater观察时机，不重排wire、不改SQL/consumer、不删合法新B。
若旧A是否失效尚缺消费方可用的事实，先记录未知；若实际事实已能判定且行为错误，保存red再在原owner窄修。
R47完整策略及overlay专用capacity await-after replacement仍NOT_RUN；此入口不是清理所有不匹配authority的正确性证明。
READY timeout/非法JSON/缺字段的owned子进程清理已另列R51，scope限新增测试，不触碰生产Bridge。

## 并列未知

R29历史FAIL与095cab00完整FAIL的直接归因仍未知；visual pending 256/257与无runtime ID的旧V2远端归属也未验收。
真实Provider/设备/生产/发布各自NOT_RUN，原生UI自动化工具不可用仍BLOCKED，不能借源码门禁关闭。
