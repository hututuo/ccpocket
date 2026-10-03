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
| R09 | 真 Bridge → JSON → Dart → SQLite → Cubit/layout | 与 Provider fixture 的稳定 ID/顺序/内容相符 | PASS 84493fc6四文件8条真实接收链（另3条process清理不计接收链），原七黑盒未改；C1f的71项组合通过。原七条亦在16196f05全量3396/4执行；旧mutation/R35/fixture启动FAIL保留；E064/E065/E073 |
| R10 | stdio JSON-RPC 模式 | 不旁路生产 RPC 解码/分发 | PASS 基线 full-page；E002 |
| R11 | SQLite 关闭重开 | durable 内容可恢复 | PASS 基线 receiver；E002 |
| R12 | 全 Mobile analyze/tests | 无新增 error/warning/回归 | PASS 16196f05 clean 全量3396 PASS / 4 SKIPPED及固定SHA review；8178295d仅删unused test import，26项PASS、完整analyze 0 error/warning、1017既有info逐项同E041。C1f只新增测试/文档，84493fc6的71项、目标文件analyze无诊断/format/独立review通过，未重跑全量。原analyze warning FAIL、095cab00 FAIL及89084bcb review P2/red保留；E064/E065/E073 |
| R13 | 真实 Provider 新事件 | 原始记录与 Bridge/cache/page 对照 | NOT_RUN |
| R14 | 模拟器 / 真机 / 生产 | 各自独立验收 | NOT_RUN；本轮原生 UI 自动化工具不可用为 BLOCKED，不能用 VM widget host 代替设备验收 |
| R15 | 调度退避、失败预算、取消计时器、旧回调 | 1/2/4 秒重试、4 次失败封顶；取消后无重试，旧完成不清新 owner | PASS 抽取后四个 scheduler 用例；E007 |
| R16 | 普通 PR CI 的黑盒前置条件 | Mobile job 自行构建 Bridge，再运行 Flutter tests | PASS 本地 YAML/顺序检查；云端 CI NOT_RUN；E008 |
| R17 | older send/Provider/事务前失败、游标停滞 | 原错误结算、pending/flight 清理、原窗口/cursor 保留；不拆其他订阅；repeated non-null cursor 写入前拒绝 | PASS 六项 Service 修复/保护；三个基线 FAIL 保留；E012/E013 |
| R18 | older deadline、成功/失败、旧 handle、single-flight、dispose join | 15 秒恰好失败；终态取消 timer；旧 handle 不清新 owner；取消后已开始的本地工作仍 join | PASS 九项 fake-clock lifecycle，含 scoped queued reset；E015/E017 |
| R19 | 原页面自动加载两页 older turns | 原页面/updater/Cubit 保持；Provider ID/顺序、最新内容保留、cursor 1→2→null、加载终态 | PASS 真实 Bridge/RPC/SQLite/原页面，mutation 漏通知 FAIL 保留；E014/E020；Provider fixture 范围 |
| R20 | thread reset 的 preparing / queued / sent | 三阶段旧操作失效；其他 thread/source 不受影响，后续新调用可用 | PASS 三阶段 read-barrier / late-reply / pure lifecycle；准备/排队红灯保留；E013/E016/E017 |
| R21 | 已开始 older mutation 的提交/读取与同源订阅替换交错 | 本地 epoch/update 仍通知当前分区；原错误保留；旧 transport 不复活；其他 source/dispose 不通知 | PASS 六种 success/error × same-source/other-source/dispose，以及 current-sub post-commit read error；三个基线 FAIL 保留；E016/E019/E020 |
| R22 | Bridge 全量/build/typecheck 与 fixture 变化 | 无 Bridge 回归，隔离 fixture 可启动/关闭 | PASS da3d3f6 clean 全量2546 PASS / 1 SKIPPED，124 files PASS；Node22 noEmit、E053实际build通过；C1e按相同Bridge/dependency tree继承，非本批重跑。错误package-local TypeScript命令FAIL单独保留，编译器未执行；E059/E064/ACCEPTANCE.json |
| R23 | 页面读取中的 commit/dirty/epoch 推进 | 不短暂接受旧窗口/错误；合并必要 follow-up，最终与 SQL 一致 | PASS 十三个真实 SQL 页面契约与八个 lifecycle 保护、最终全量；E023/E025/E026/E029 |
| R24 | 旧 source/thread、invalidate/dispose 的成功/error/finally | 旧结果/错误不能替换页面或清理新 owner/dirty；dispose 无后续 UI/读取 | PASS 旧 source error 基线 FAIL→fix；线程切换与 dispose 正反路径，最终全量；E023–E026/E029 |
| R25 | 当前读失败/Retry/后续 commit | last-good 可读；当前错误可重试；后续通知仍更新 | PASS 原 SQL 页面 Retry 交互与后续真实 commit；E023/E029 |
| R26 | V2 complete empty / legacy empty | V2 可清 canonical；legacy SQL empty 保留 last-good UI | PASS 原 V2/v1 receiver、真实 SQL 与原页面；E023/E025/E029 |
| R27 | A-next 提交后切 B，读丢弃，再认证 A 且不重发正文 | 受 source fence 阻止的 dirty 保留并实际补读，显示 SQL 的 A-next | PASS success/error 两个基线 FAIL→fix；八个生命周期含 deferred dirty，最终全量；E027/E028/E029 |
| R28 | durable 冷读期间 passive runtime 绑定，后续 canonical commit | durable reader 保持有效，冷窗口与后续 commit 均更新同一页面；runtime 不写 canonical | PASS 正向 SQL 页面用例与最终全量；E028/E029 |
| R29 | full-page 完整中间过程折叠的并发组合时序 | 原页面在实际输入完成后呈现正确 fold/count | FAIL 历史 E024 等待超时保留，原因未归属；旧订阅已有焦点及 A/B/final 完成帧。当前 adf337ea 同四文件默认并发 50 PASS，不作因果关闭；完整默认并发/云 CI NOT_RUN；E042 / R29-FOLD-ENTRY |
| R30 | duplicate canonical 的整体接受 | 不提前应用设置、审批、queue 与 paging | PASS 原 Cubit 四项稳定 red → green；E031/E032/E035，全量中均通过 |
| R31 | draft/exact client receipt 与同正文不同身份 | 原 canonical 的合法关联才消费；重放不重复；不消费他人 draft | PASS 原 Cubit/draft 两项正向保护；E031/E035 |
| R32 | candidate 输入、compose 与证据来源 | 准备输入冻结，compose 不修改；overlay enrich 不产生 canonical receipt | PASS 四项纯 candidate 保护；E033 |
| R33 | rejected History Git tip | 未显示的 tip 不抑制下一条有效 error；已接受 tip 仍去重 | PASS 原 Cubit 1 red → green + 1 正向，handler 三路径保护；E034/E035 |
| R34 | 原 handler / shared mirror / SQL reader 兼容 | 普通 History/live tip 保留，原分页/读取/布局契约通过 | PASS 分项收据 447 用例通过但一次命令有错文件加载 FAIL；正确分页文件另 15 PASS，不伪装单次总数；E035 |
| R35 | 第二条 runtime commentary 的独立可见性 | canonical A/B 已提交时结束对应 transient，B 独立可读 | PASS 确定性原页面交错：旧 Service 同症状 FAIL，修复仅补一条匹配 focus 后原 A/B/final/fold/恢复 PASS，hold/release字节顺序一致；最新七个黑盒在3396项全量中通过，关闭选定交错；旧两次FAIL保留；E040/E041/E064 |
| R36 | subscribe 发送→接受之间设置/切换/清焦点 | 接受后只补发最新且当前的意图，同首帧不重复；旧源/订阅/dispose 无补发，失败 transport 清理 | PASS 窄修后十七项、相关157/91项及最终全量；原7 PASS / 9行为FAIL保留，覆盖V2/V1原消息及真实SQLite；固定产品/fixture 独立复审无剩余可证明 P0–P2；E038–E041 |
| R37 | 已确认当前 turn 的 idle 先于最终 runtime completion 的 consumer delivery | 当前终态退休 transient；canonical 前/后到达均 A/B fold、final 在外；晚到旧完成不重启，运行中/旧身份仍隔离 | PASS 21项terminal保护中的选定窗口、原三文件七黑盒及最新全量；held-final完整轨迹核对stream结束和final在外。原red/敏感性FAIL保留；E043–E060。历史R29归因仍未知 |
| R38 | bootstrap idle / 未入库 completion 与终态清理 | 未确认 turn 的 idle 不抢走新 delta；filter 在 alias reset 前执行，runtime completion 无 canonical 写权 | PASS 两项行为red→green、原receiver未改、最新全量。E044首修缺口和dcf0b086完整3340 PASS/4 SKIPPED/1 FAIL保留；E045/E048/E059 |
| R39 | 旧 terminal 接纳晚于新 raw delta / coalesced pending delta | 旧终态不能清后来的增量；下一次匹配 socket+committed idle 仍能结束流 | PASS raw/coalesced text/thinking、reset revision与原终态保护，21项terminal及最新全量通过；两项red保留，尚非真实双turn/设备回放；E047/E048/E059 |
| R40 | turnless working / 暂缺 provider projection 后的 socket 完成 | 当前 bridgeRuntime 权威 idle 与未变化 socket ticket 可退休流；普通 idle、无权威、外部 host 不取得新清流资格 | PASS 原公开red→green、身份/置信度补强及原七黑盒/最新全量；与095cab00完整原页面FAIL的直接关系尚未证明；E049–E060 |
| R41 | A→B→C，B 状态在 C socket idle 前/后才被投影 | 新清理须核对远端 runtime 身份，不让同源旧缓存退休 C 正文；C 后续合法终态仍结束 | PASS 二十一项terminal及七黑盒/最新全量，固定review无本次新增P0–P2；三项red保留。已知ID的控制接纳另见已闭合R48，无ID远端归属仍R49；E052/E053/E059/E065 |
| R42 | status runtime 身份的 Bridge 生产 / JSON / SQLite | 来自真实 runtime snapshot；round trip 保留；appServer/失效转换不继承；旧字段缺失可读 | PASS producer、JSON及SQLite close/reopen、同时间身份签名、Bridge186相关契约与新build、七黑盒；全Bridge/全Mobile及固定review通过，red保留；E052/E053/E059 |
| R43 | quarantine条数/UTF-8预算/去重/失效/close | 32条/64KiB；拒绝新超限，既有FIFO保留；删除/flush/reset退休bytes，迟到不复活 | PASS 十三项公开queue保护、相关回归、七黑盒/3396项最新全量与单owner复核；authority反向测试要求已有visible owner，queue-only另列R47；原fixture错误FAIL保留；E054–E060/E064 |
| R44 | T2 event先入隔离队列，随后退休T1显示 | 同source/runtime/authority、时间不旧的T2不被T1退休清空；原flush验证后应用 | PASS direct T2与先旧terminal两项public契约、3396项最新全量；两项red保留。同binding/authority范围，不扩张到future authority或真实双turn；E054/E055/E059/E064 |
| R45 | visual pending 256/257策略 | 对照provisional visual原则审定溢出/重放/completion副作用 | NOT_RUN；只登记原现状，暂不迁移此队列；RUNTIME-QUEUE-ENTRY |
| R46 | 正确runtime的unknown/unavailable快照保留旧idle | 保留的activity不取得新terminal清理资格；后续authoritative idle仍结束 | PASS 21项terminal+13项queue共34项及最新全量，原20 PASS/1 FAIL red保留；E056/E057/E059 |
| R47 | queue-only authority replacement / future authority waiting | 分清已失效旧authority与合法未来authority；不能从有visible owner的测试推断一律清理 | NOT_RUN完整策略：实际同public ID replacement能产生新opaque authority已由源码定位；C1f真实producer的未观察authority合法等待另列R50 PASS。replacement callback+capacity待ACK与Mobile旧/新消费组合尚未共同证明，不据R50改策略；QUEUE-AUTHORITY-ENTRY / E073 |
| R48 | 已知runtime身份的旧缓存与原mutation lease | 控制/设置/审批目标必须属于当前已证明owner；旧B既不能授予C权限，也不能替换合法C或取消其image lease；无binding仍只读 | PASS 选定契约：16行为red→green与cold-start两项candidate red→green，26项新契约/相关313项、16196f05全量3396/4及固定review通过；8178295d最终静态复查通过。无ID旧组合归属另列R49；E061–E065 / RUNTIME-AUTHORITY-ENTRY |
| R49 | 无runtime身份字段的旧V2 / appServer组合 | 维持合法兼容用途，不伪造remote ID，不把原generation/source规则当完整远端归属证明 | NOT_RUN：旧V2合法lease、legacy idle、Desktop detach与durable target保护PASS；缺字段的连续A→B→C远端归属仍未证明，独立策略入口，E063 |
| R50 | 实际producer authority已提交、页面尚未观察 | 合法事件仍bounded quarantine且无mutation；原Updater接纳一次，canonical在同页单次接替 | PASS 固定84493fc6真实Bridge/RPC/SQL/Service/SessionList/原Updater，status37→overlay38及三段轨迹身份匹配；错误提前拒绝敏感性FAIL、完整hash恢复后4项PASS。不是同IDreplacement或真实Provider验收；E066–E073 |
| R51 | 新测试owned harness的READY失败清理 | 超时、非法JSON、缺必需字段时取消订阅、只回收captured child并等待exit；不遗留自己的进程 | PASS 3条真实Node keepalive合同，timeout及两条协议red保留，84493fc6的71项组合/目标静态/固定review通过。共享helper/原七黑盒/生产服务未变；E069–E073 |

R09/R10 的最上游是隔离 Provider fixture，使用真实 Bridge、协议、SQLite 和页面相关代码；
即使 PASS，也只证明接收闭环，不冒充 R13/R14。

结构抽取前必须覆盖对应行为变化、取消和重放；纯粹复制 implementation 的测试不作为额外证据。
