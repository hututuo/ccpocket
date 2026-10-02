# R29 入口：完整过程折叠等待

状态：历史 FAIL 保留，原因未归属。当前有限默认并发重放 50 PASS，不能关闭旧问题。
本入口是 C1b 后的下一批调查，尚未开始 runtime 状态抽取。
当前产品 `ce51e280`、完整测试输入 `adf337ea` 的最终源码门禁见 PROCESS E041。

## 已有证据与不能推断的结论

所有原始文件在 `/Users/developer/AI agent/Codex/_tmp/ccpocket-sync-chain-20261001/`。

| 输入 / 收据 | 实际结果 |
|---|---|
| E024 / c1-source-error-fence-green | HEAD `5d69872d87b7d42984032848814127e7e6b029e4`，页面 source-error fence 未提交 diff；默认并发四文件，41 PASS / 1 FAIL，28.092 秒 |
| c1-error-fence-full-page-isolated | 旧 full-page 单独 1 PASS，12.030 秒，不覆盖组合失败 |
| E042 / c1b-r29-default-concurrency-probe | clean `adf337ea`，原四文件名组合、默认并发，50 PASS，17.398 秒；非旧代码/输入 |

旧 trace：`c1-error-fence-traces/2026-10-01T03-25-20.443Z-a8aecef3-live-segments/`。
旧 A、B、final 可见性均 PASS，下一阶段 final-outside-collapsed-process 等待完整过程折叠 FAIL。
前一阶段 rows 有 user/A/B/final；FAIL 快照只有 sync 状态，缺少后来添加的 SQL/Cubit/layout disclosure 事实。
初始 subscribe 已携带目标 focused；wire 三个 runtime_overlay 的 assistant ID 为 A/B/final，
sequence 27/59/76，runtime/authority/turn 身份一致。
`c1b-r29-historical-evidence-inventory.json` 保存精确 receipt、stage、帧摘要及原文件 SHA。

这是“wire 有完成帧，最终 fold 未成立”的观察；帧存在不等于 Service/Cubit 接受。
它与 R35 的缺少 wire focus / 第二条 commentary 可见性 FAIL 不同，没有同因证据。
也没有证据判定为宿主负载、偶发或原测试错误。当前 PASS 仅说明本次重放没有复现。

## 所有权与本批允许范围

1. 原 `conversation_full_page_test.dart` 负责页面行为与失败事实；沿用已加入的 SQL/Cubit/disclosure 快照。
   原 `_waitForPage`、内容/身份、fold/count、展开与恢复断言全部保留。
2. 如仍缺关键事实，只在隔离 harness 或原入站路径加只读观测，登记观测执行成本。
   记录 original Bridge `sessionMessage` 实际资格与 status，不能用早于该监听的 origin 回调代替。
3. Service 仍校验 source/subscription/generation/sequence 并转发 runtime_overlay；
   原 Cubit 拥有 runtime pending、authority、canonical 合并与 streaming 更新，
   `features/chat_session/widgets/chat_process_layout.dart` 拥有 layout 的 turn/过程折叠判断。
4. SQLite 与 C1a reader 是 canonical 事实与读取所有者；runtime 正文不新增写权。
   本阶段不搬动 queue、handler、reader，不更换页面或重建控制链。

## 下一批执行顺序

先核对 HEAD/status，读 HANDOFF 的当前产品原则和相关 decisions；以 PROCESS 当前断点为版本入口。
首轮只重放原四文件组合，保持默认并发，将新 trace 存到独立目录。变量与工具身份先按 RUNBOOK 设置：

```bash
cd "/Users/developer/.codex/worktrees/sync-chain-20261001/ccpocket-compat/apps/mobile"
CCPOCKET_CHAIN_TRACE_PARENT="/Users/developer/AI agent/Codex/_tmp/ccpocket-sync-chain-20261001/r29-next-traces" \
  "$CCPOCKET_FLUTTER_BIN" test --no-pub --reporter expanded \
  test/codex_durable_preview_read_test.dart \
  test/durable_session_preview_test.dart \
  test/blackbox/conversation_full_page_test.dart \
  test/blackbox/conversation_live_segment_receiver_test.dart
```

实际运行用新的 receipt/log label，不重复覆盖该路径已有运行；记录精确 cwd/HEAD/diff/工具/并发度。
有限重放已经 PASS 时，不为凑出结论反复重跑；优先补以下可对照事实：

| 层 | 同一交错需要保留的事实 |
|---|---|
| wire / Bridge 资格 | 原始 assistant/status、实际 sessionMessage runtime/authority/turn、订阅 focus、sequence |
| Service | 哪个事件已接收/接受/拒绝，拒绝原因；当前 generation/source/subscription 与顺序 |
| canonical / reader | SQL 有序稳定 ID/index/hash、commit epoch 与 C1a read ticket/dirty/接受结果 |
| Cubit / streaming | 当前 runtime authority/turn、canonical/overlay/pending 身份、transient/stream 状态与 completion/idle 顺序 |
| layout / 页面 | 原 turn identity、active/current/final/intermediate indices、process count、可见正文及 fold 状态 |

SQL/UI 采样跨 await，不宣称原子；在证据中保留采样先后，不能依据异步快照制造矛盾。
确认完成/idle 是否被接受后，再判断是事件归属、canonical 合并、stream 退休、layout 阈值还是宿主采样。
一旦定位到 owning path，建立可控交错的原页面 red，固定输入只改变该行为，再验证 green 与旧 red 敏感性。
未复现或证据不足时保留未知，写明最后到达层和具体缺口。

## 进入结构抽取的门禁

先证明所选 runtime 窗口的正确结果，以及 source/authority/turn 切换、dispose、队列丢弃和完成后清理。
每个状态只能有一个 owner，不能把 entire Cubit/Service/Page 传给 helper，再保留两套状态。
行为修复与结构提交分开，原页面、V1/V2 焦点十七项、C1a 读取、canonical 十五项均须通过；
受影响全量检查、固定 SHA 独立 review、地图/矩阵/过程/回退同时更新。
不延长 15 秒内部等待或 60/120 秒外层期限，不删 fold/count 断言，不以 refresh/重建页面取得 green。
真实 Provider/设备/生产/云 CI 继续单独验收；本入口不授权部署、安装、merge/push 或发布。
