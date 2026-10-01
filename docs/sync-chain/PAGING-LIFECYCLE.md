# B2：单种 older-turn 分页生命周期

起点：`03539df14e84d2fc0677e3556eafdd4008cd9255`，源码等同 E010 的 `45a4498a`。
本页记录本批契约、状态归属与回归入口；处理的是 older turns，不泛化所有 RPC。

## 当前路径与身份

`CodexSessionScreen._loadOlderDurableHistory` 调用 `SyncService.loadOlderTurns` 并提供页面 data-source identity。
Service 以 target/provider/session 合并 flight，交给与 latest repair 共用的
`_enqueueHistoryOperation`，再从 SQLite 读取 revision/cursor。请求中传 subscription/requestId，
等待表保存 generation、target/provider/session、expected revision/cursor 与 completer。

有序 receiver 校验全局 source/subscription/sequence 后匹配请求。
Repository.prependConversationTurnsPage 以本地 expected revision/cursor 原子接受内容，
Service 结算结果、原通知出口推进 epoch、最后累计 ACK；页面用原回调重读。
source 是分区身份，focus 是页面意图；只读翻页不取得 Provider writer ownership。
已经开始的本地 mutation 与 transport generation 是不同事实：同源订阅替换后，
仍当前且未 dispose 的 cache partition 会收到本地更新，旧 generation 的 syncUpdates/ACK 仍被丢弃。

## 本批正确性契约

| 事件 | 请求终态 / 权限 | 回归入口 |
|---|---|---|
| 正常回复 | 事务接受后 loaded=true，hasMore 与 cursor 一致；旧前缀和最新可读内容保留 | 既有 Service / Repository + B2 真实原页面 |
| 同目标同时调用 | 单个 flight；历史请求仍与 latest repair 串行 | 既有并发保护 + lifecycle tests |
| send / Provider error | 原请求失败并移除；不得留 spinner、吞错误或接受后续同 requestId 回复 | B2 请求级 Service / lifecycle |
| 本地 commit/read exception | 原错误结算该分页；事务回滚保留窗口/cursor；提交阶段不确定时通知当前观察者重读，不拆其他订阅或误报 loaded | B2 事务前 / 提交后 read 红灯 |
| non-null next cursor 重复 | 明确失败，保留原窗口与 cursor；不能成功后不断再请求同页 | B2 repeated-cursor 红灯 |
| deadline | 请求从等待表移除，future 失败；迟到回复不得重新取得尚未开始的写入权 | B2 timer / late reply |
| subscription replacement | 中断旧 attempt；最多重试一次，等待新订阅，旧帧不能结算新请求 | 既有替换用例 + lifecycle |
| thread reset | 失效覆盖准备、排队及已发送的旧操作；其他 thread 的 paging 与订阅继续 | B2 三阶段 scoped reset 红灯 |
| source / background / dispose | 按原生命周期取消，不写其他分区；dispose 等待已开始的本地工作结束 | 既有 fence/dispose + B2 cancellation |
| 相同回复重放 | pending 已结算后无重复写入/通知，累计序列照原协议处理 | B2 late/replayed reply |

取消前已开始的 SQLite 事务与取消后才到达的网络回复不同：事务是原分区的本地工作，
必须 join 并诚实记录；本批不能通过提前 dispose DB 或强行回滚已提交事实制造“取消成功”。

## 抽取边界与推进条件

新模块只拥有 older-turn 的 single-flight、immutable pending context、deadline、终态和取消。
Service 保留认证身份、订阅重试策略、同会话共享串行、请求参数、Repository 调用、通知及 ACK。
Repository 保留 revision/cursor 和内容预算的写入权威；不新增数据库、通知总线或全局 coordinator。

先在原路径补失败用例并修行为，再独立抽取。15 秒 response deadline、8 秒新订阅等待、
最多两次 attempt、limit 1–20 都保持现状；策略调整需要另一个行为批。
每个 promise/completer 只结算一次，计时器/等待表/flight 清理与创建必须一起移动。

E015 已迁移到 `older_turns_paging_lifecycle.dart`；结果类型独立保存并由原 Service export，
调用方 import 无需改变。dispose 从模块取得仍在执行的 flight，等待本地工作结束。
E016 复现 reset 准备/排队缺口及提交后 snapshot read exception 漏通知；E017 行为提交修正。
flight 在进入共享队列前取得 scoped operation，Service 在开始读取前和读取返回后检查其存活；
thread reset 失效同 target/provider/session 的 operation，保留 wire pending 的 generation fence。
正在等待新订阅的 flight 也属于该 thread；普通 subscription replacement 仍按既有两次尝试继续。
没有永久 per-thread tombstone；operation 随 flight 完成回收，新调用取得新身份。
异常路径复用已有 cache invalidation/epoch，传输当前性检查后通知观察者重读，保留原错误。
这不声称事务一定提交；事务前异常时只会重读原窗口，不新增数据库权威或改变 Repository 接口。
E019/E020 补齐提交期间订阅替换：上述异常路径和成功路径的本地通知改按当前 cache partition
且未 dispose 检查；transport timeline/ACK 保持 generation 检查。其他 source / dispose 的保护也有回归。

完成条件：定向 red → green；timer/cancel/旧结果归属保护；相同真实 Bridge/RPC/SQLite/原页面
分页输入的内容与 cursor 一致；全 Mobile analyze/tests 与独立源码 review；更新过程账本与回退依赖。
真实 Provider、设备、云 CI 和生产部署继续分别记 NOT_RUN。
