# 回归矩阵与证据边界

状态只用 PASS / FAIL / NOT_RUN / BLOCKED；每次运行保留命令、退出码、源码身份和原始日志。
已有旧 CI/设备收据仅作历史参考，不计作本分支验证。

| ID | 场景 | 预期 | 当前状态/入口 |
|---|---|---|---|
| R01 | 部分 turns_page 提交 | cache epoch 与通知推进；新条目可读取；complete 仍 false | PASS 修复后；基线 FAIL 证据保留；E002/E003 |
| R02 | 完全相同缺口/内容重放 | 不重复自动请求 | PASS 包含执行中重放；E004 |
| R03 | 同 canonical revision 后续内容/缺口变化 | 必要修复仍可执行 | PASS 修复后；两种基线 FAIL 保留；E002/E004 |
| R04 | 修复运行期间发生变化、缓存观察延迟 | 合并 dirty；较早提交观察先于较晚 repair reply，成功后不丢变化 | PASS 144 项相关回归与最终全量；E004/E009/E010；E008 全量 FAIL 保留 |
| R05 | focus/manual refresh/transport/reset/dispose | 旧结果不生效；新焦点不接管旧 flight，无计时器与等待泄漏 | PASS 新增两种返回焦点顺序及跨会话刷新、最终全量；E005/E009/E010；设备仍 NOT_RUN |
| R06 | 删除列表 64/2000/2001 边界 | entries/deletes 按各自预算 | PASS 相关 protocol 回归；E002/E004 |
| R07 | 历史/最新修复并发 | 保留已提交前缀、顺序与分页游标规则 | PASS Service/Repository 相关回归；E004 |
| R08 | 错误 source、订阅、sequence | fence / bounded recovery / last-good | PASS Service 回归与既有 blackbox 故障链；E002/E004 |
| R09 | 真 Bridge → JSON → Dart → SQLite → Cubit/layout | 与 Provider fixture 的稳定 ID/顺序/内容相符 | PASS 四个黑盒用例含 partial-summary / older-pages 原页面更新；两种漏通知 mutation FAIL 证明敏感；E006/E014/E020 |
| R10 | stdio JSON-RPC 模式 | 不旁路生产 RPC 解码/分发 | PASS 基线 full-page；E002 |
| R11 | SQLite 关闭重开 | durable 内容可恢复 | PASS 基线 receiver；E002 |
| R12 | 全 Mobile analyze/tests | 无新增 error/warning/回归 | PASS 最终产品源码 f735ac6b：3279 tests PASS、4 SKIPPED；analyze 0 error/warning；两处测试样式修正后 1017 既有 info、无新增，87 相关 tests PASS；E010/E018/E021，历史 FAIL 保留 |
| R13 | 真实 Provider 新事件 | 原始记录与 Bridge/cache/page 对照 | NOT_RUN |
| R14 | 模拟器 / 真机 / 生产 | 各自独立验收 | NOT_RUN |
| R15 | 调度退避、失败预算、取消计时器、旧回调 | 1/2/4 秒重试、4 次失败封顶；取消后无重试，旧完成不清新 owner | PASS 抽取后四个 scheduler 用例；E007 |
| R16 | 普通 PR CI 的黑盒前置条件 | Mobile job 自行构建 Bridge，再运行 Flutter tests | PASS 本地 YAML/顺序检查；云端 CI NOT_RUN；E008 |
| R17 | older send/Provider/事务前失败、游标停滞 | 原错误结算、pending/flight 清理、原窗口/cursor 保留；不拆其他订阅；repeated non-null cursor 写入前拒绝 | PASS 六项 Service 修复/保护；三个基线 FAIL 保留；E012/E013 |
| R18 | older deadline、成功/失败、旧 handle、single-flight、dispose join | 15 秒恰好失败；终态取消 timer；旧 handle 不清新 owner；取消后已开始的本地工作仍 join | PASS 九项 fake-clock lifecycle，含 scoped queued reset；E015/E017 |
| R19 | 原页面自动加载两页 older turns | 原页面/updater/Cubit 保持；Provider ID/顺序、最新内容保留、cursor 1→2→null、加载终态 | PASS 真实 Bridge/RPC/SQLite/原页面，mutation 漏通知 FAIL 保留；E014/E020；Provider fixture 范围 |
| R20 | thread reset 的 preparing / queued / sent | 三阶段旧操作失效；其他 thread/source 不受影响，后续新调用可用 | PASS 三阶段 read-barrier / late-reply / pure lifecycle；准备/排队红灯保留；E013/E016/E017 |
| R21 | 已开始 older mutation 的提交/读取与同源订阅替换交错 | 本地 epoch/update 仍通知当前分区；原错误保留；旧 transport 不复活；其他 source/dispose 不通知 | PASS 六种 success/error × same-source/other-source/dispose，以及 current-sub post-commit read error；三个基线 FAIL 保留；E016/E019/E020 |
| R22 | Bridge 全量/build/typecheck 与 fixture 变化 | 无 Bridge 回归，隔离 fixture 可启动/关闭 | PASS 67fbef1a：2546 tests PASS、1 SKIPPED，124 files PASS；build/noEmit PASS；最终产品 Bridge tree 完全相同，继承收据；E018/E021 |

R09/R10 的最上游是隔离 Provider fixture，使用真实 Bridge、协议、SQLite 和页面相关代码；
即使 PASS，也只证明接收闭环，不冒充 R13/R14。

结构抽取前必须覆盖对应行为变化、取消和重放；纯粹复制 implementation 的测试不作为额外证据。
