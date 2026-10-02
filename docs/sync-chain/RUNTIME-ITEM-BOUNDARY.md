# Runtime 完成信号与可见过程消息

状态：C1b 产品全量曾暴露 R35，定位中；观测输入 d0f164e5 全量 PASS 不是行为修复。
最新证据见 PROCESS E036–E037。

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
  所以焦点缺失能够解释漏信号；pending subscribe 期间遗漏焦点仍须确定性 red 证明。
  对照另存 `c1b-runtime-overlay-focus-comparison.json`，不是凭成功重放关闭问题。

R35 与旧 R29 的“完整中间过程折叠等待”是不同失败阶段；没有证据证明两者同因。
也没有证据将 R35 归因于 Git tip 修复、机器负载或测试随机性。

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

1. 保留当前失败与成功原始 trace；优先在原 Service 控制 subscribe 已发送、syncBegin 尚未接受的顺序，
   在中间设置/切换/清除焦点，验证接受后实际发送的焦点与当前意图一致。
   同时保护 source/generation/旧订阅/dispose，已携带同一焦点不产生重复请求。
   若此竞态不能复现，再继续 sessionMessage 资格门、authority sequencing、队列容量和丢弃接点观测。
2. 用可控事实建立确定性 red：不能靠重跑变绿宣布修复，也不能放宽 source/authority fence、
   接受普通 runtime 正文、延长等待或删可见性断言。
3. 定位真实 owner 后另记行为修复与 green；再固定 SHA 全量检查和独立复审。
   若未能归因，应继续明确列为 FAIL 历史/未知项，不能以重放 PASS 关闭。
4. 在此之前，后续 runtime 隔离队列结构抽取只作计划；C1b 的 canonical admission 保护可以保留，
   但整条运行/展示链不能宣称已正确通畅。
