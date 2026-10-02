# Runtime 完成信号与可见过程消息

状态：R35 已定位并窄修：旧 Service 在固定原页面交错下重现同一 B 可见性 FAIL，
修复 Service 同输入 PASS；十七项焦点/兼容保护通过。
最终产品 `ce51e280` / 测试输入 `adf337ea` 的 Mobile 3333 PASS / 4 SKIPPED，
Bridge 2546 PASS / 1 SKIPPED、静态门禁与独立复核通过；尚不据此整体验收运行链。
最新证据见 PROCESS E036–E042；观测输入 d0f164e5 的旧全量 PASS 本身不是行为修复。

V2 detached 中，canonical history 来自 Service → SQLite → 原页面/Cubit。
实时 delta 留在 handler/StreamingStateCubit；assistant item 完成经带 source、runtime、
authority、turn 的 runtime_overlay 关闭流式累积，并按 exact identity 与 canonical 合并。
普通 runtime 的 assistant 正文仍被 durable guard 拦截，不能为得到可见结果增加第二个写入者。

## 已经观察到的事实

- `2f64e383` 的串行全量在第二条 commentary 可见性上 FAIL；同源码单独重放 PASS。
- 加页面失败快照后的三文件五个黑盒组合又有 4 PASS / 1 FAIL，失败阶段相同。
- 失败现场 SQL 有序 user/A/B 的 ID、index、hash 与正文正确；原 Cubit 同样有 user/A/B。
- 页面仍把 `First live commentarySecond live commentary` 作为一个 transient current output；
  两个已提交 assistant 都进入折叠，无法找到一份独立 B。status=running、runtime overlay event count=0。
- 上一次成功/失败的 Bridge canonical B payload 相同。成功轨迹先有 B 的 runtime_overlay，
  失败轨迹没有该事件。这个差异指出完成信号路径，尚不证明哪个生成/发送条件有错。
- 两次 FAIL 的初始 subscribe 没有 focused，之后没有 focus 请求；失败时客户端 diagnostic 却有目标焦点。
  两次全量 PASS 的初始 subscribe 都带目标 focused，并有 A/B runtime_overlay。
  Bridge `publishRuntimeOverlay` 只向 interactive、capability 支持且 focusedKey 匹配的订阅发送，
  所以焦点缺失能够解释漏信号；E038 已确定性证明 pending subscribe 期间遗漏补发。
  对照另存 `c1b-runtime-overlay-focus-comparison.json`，不是凭成功重放关闭问题。

## 已确定的 owning path 缺陷

V2 subscribe 与 V1 content subscribe 均在实际发送时取一次 `_focused`。
修复前，发送后 setFocusedConversation 在 active ID 尚空时只更新本地意图；pending ID 令 ensureSubscribed 返回。
syncBegin/subscribed 接受时没有补发，因此本地 diagnostic 与 wire focus 可长期不一致。
发送前变化、返回首帧焦点、普通 active/dedup 与 dispose 的正向保护通过；
发送后的设置/清除/替换订阅/send-error 保护失败。范围与回退见 E038–E040 / R36。
修复只在匹配接受、首次 await 前核对实际发送快照与当前焦点；相同不发，不同使用原协议 focus。
Bridge authority/focus fence 与 V2 durable writer 均保留。

## 原页面确定性交错与敏感性证明

隔离 fixture 启动前启用 bootstrap gate；捕获并验证 subscribe 已实际发送且无 focused，
首个 matching syncBegin 与该订阅后续 V2 帧尚未下发；挂载原页面，验证本地焦点已设置且 active 仍空。
随后原样 FIFO 释放，不造状态或跳过协议 fence。页面继续所有原 A/B/final、fold 与恢复断言。
旧 Service：Second live commentary 可见性 FAIL，SQL/Cubit 正确、transient A+B、没有 focus 请求。
修复 Service：仅一条匹配 focus，A/B/final 与全部后续原断言 PASS。
两个输入都 hold/release 七帧，按 subscription/sequence/sha256 核对字节与顺序完全相同。
source swap 备份与 finally 恢复另留收据，修复 Service 已与 ce51e280 一致。
恢复后的三个黑盒文件共六项 PASS；这关闭了选定 pending window 的行为因果。
新的 clean 输入已通过全量；产品与 fixture 分别独立只读复核，无剩余可证明 P0–P2。
原完整页面外层在修改前后均为 120 秒，partial/older 场景为 60 秒，页面等待均为 15 秒。
没有通过延长等待获得 green。敏感性和最终门禁收据分开，不能把 dirty source swap 当 clean 输入。

R35 与旧 R29 的“完整中间过程折叠等待”是不同失败阶段；旧 R29 订阅已有焦点，
wire 有 A/B/final 三个 runtime_overlay，没有证据证明两者同因。
也没有证据将 R35 归因于 Git tip 修复、机器负载或测试随机性。

## 焦点快照的唯一所有者与完整接点

快照只属于原 SyncService，不新增 lifecycle/reducer，也不持有页面或 Repository。

| 接点 | 必须保留的行为 |
|---|---|
| V1/V2 subscribe 实际发送 | 保存与 payload 同一份 focus，绑定 generation/request/target/Bridge/source/协议 |
| pending 期间 set/clear/切换 | 只更新原本地意图；最新值包含 null，不累计待发送列表 |
| 当前 subscribed/syncBegin 接受 | 在首次 await 前消费匹配快照；不同才用原消息补发，原焦点不重复 |
| 旧请求/来源/代次的回复 | 原 fence 拒绝，不消费当前快照；V1 无 pending request 的 late subscribed 忽略 |
| stop/transport loss/dispose、发送/读取/V1 订阅错误 | 退休快照，不令旧意图接管新订阅 |
| focus 补发错误 | 走原 transport loss，早退，不继续 bootstrap SQL/notify/ACK；重试仍携带当前意图 |
| 原 active focus/manual refresh/readmark/自动修复 | 保持原 owner 与流程，不借焦点补发改变 canonical writer |

改任一接点时先跑 `subscription_focus_admission_test.dart` 的十七项，
再跑原 Service、scheduler、paging、durable/canonical 与六个黑盒；命令见 RUNBOOK。
回退必须保留这些保护，不能仅删 snapshot 字段或接受 hook 来取得编译通过。

## 本批新增观测

原 full-page 黑盒在 PASS/FAIL 保存 SQL canonical 原始行、原 Cubit rows/runtime projection、
renderedText 与 disclosure 的 active/transient/current/final/intermediate indices。
失败快照出错会另外记录 snapshotError，不能替换原失败。原断言、15 秒等待、输入和页面 owner 保留。
presentation 在 SQL await 前采样，不将两者宣称为原子快照。

隔离 live-segment fixture 在原 provider message 旁保存 `runtime-overlay-origin.jsonl`：
assistant ID/turn、process status/active turn 与原 Bridge runtime adapter facts。
它只观察已有对象，不注入 authority、不延迟通知、不改生产 dispatch。观测调用本身有执行成本，
有观测时 PASS 不证明没有观测时的问题已经修复。
该回调早于 SessionManager 的生产监听接收；若后者有异步排队，实际 sessionMessage 条件可能已变化。
origin 快照能佐证输入，不能单独证明资格门通过。独立只读复核确认原断言/路由不变。

## 下一步与停止扩大范围的条件

1. E041 的 fixed SHA 全量及两项独立复审已完成；保留全部旧 FAIL、source-swap 恢复与最终收据。
2. 后续若出现不同条件的漏完成信号，保留 source/runtime/authority/turn、wire focus 与 SQL/UI 快照，
   分别核对 sessionMessage 资格、authority sequencing、队列容量与丢弃，不自动套用本次归因。
3. 旧 R29 complete-fold 按 [独立入口](R29-FOLD-ENTRY.md) 定位；当前默认并发四文件 50 PASS，原因仍未归属。
   真实 Provider/设备/后台/长会话仍单独建立证据。
4. 后续 runtime 隔离队列结构抽取只在所属窗口结果与取消责任证明后评估；
   不放宽 fence、不接受普通正文为 canonical writer、不延长等待或删除断言。
