# Codex 页面缓存读取生命周期

范围：C1a；起点与中间证据见 PROCESS E022–E028，最终门禁见 E029。
已完成迁移并关闭 source error / deferred read 缺口；固定验证源码为
`151c04752e0ce00568c73a6d9522bfe09c6a107c`。

## 谁拥有哪一层

| 状态/动作 | 所属位置 |
|---|---|
| 分区、来源权威、cache commit epoch、SQLite window | 既有 SyncService/Repository |
| 当前读 ticket、dirty 合并、失效与清理 | `DurablePreviewReadLifecycle` |
| 当前 route/thread/source 判断、调用原 window read | CodexSessionScreen |
| last-good snapshot、cachedAt 比较、setState、Snackbar/Retry | CodexSessionScreen |
| 空窗口兼容、canonical/overlay 合并、稳定条目与渲染 | 原 DurableSessionPreviewUpdater/ChatSessionCubit |

ticket 只保存读取起点的 target fingerprint、durable thread 和 Service 给出的本地 epoch。
它是不可变的操作句柄，以对象身份核对 owner；不发送到 Bridge，不生成 canonical revision，
不代表 SQL 事务、runtime attachment 或 provider authority。helper 无定时器、Future、Widget、
Cubit、Repository、缓存窗口和数据源解析依赖，也不形成另一套展示状态。

## 接受与清理契约

1. 无 active ticket 时开启读取。已有读取时把通知/重试合并为 dirty；不并发开启同页重读。
2. success 和 error 共用接受入口：ticket 必须仍归属此生命周期，route/thread/source 仍当前，
   cache epoch 没有推进且没有合并的 dirty 通知。过时结果或错误不能进入页面。
3. dirty/epoch 变化只要求一次 follow-up；跟进读期间再有新提交则仍可继续合并，
   不丢已提交事实，也不为无变化生成永久轮询。
   若 immediate follow-up 因 source conflict 暂时不可执行，dirty 保留到真正 `begin`；
   重新认证不能仅因已加载过同分区就跳过该工作。`needsRead` 只表示本地未消费读取意图。
4. finally 仅能退休自己的 ticket。invalidate、换目标或 dispose 后，旧 success/error/finally
   均不能接受结果、清理新 loading 或抢走新 dirty。
5. restart/canonicalization、didUpdateWidget 的目标与 attachment 变化、session_created、dispose
   全部调用同一生命周期；SQL 不做伪取消，迟到读取通过 owner 检查丢弃。
6. 真正当前的失败保留 last-good，页面给出 Retry；成功读取按原 cachedAt/null 保护接受。
7. 权威 session list 被动绑定 runtime 只改变 receipt/control/overlay，不改变 durable
   canonical reader；显式 attachment 转换的失效接点不能机械套用在被动观察路径。

页面仍在调用前检查数据源和 expected target；接受阶段复核一次。
Service 通知与 epoch 的真实性由原 receiver 处理，helper 不增加第二个通知/写入入口。

## 已有证据与剩余验证

`codex_durable_preview_read_test.dart` 的十三个契约来自真实 SQLite；barrier 只暂停原查询之后的
返回或注入边界异常。incoming-event fixture 证明 Service/SQL/页面，不证明真实 WebSocket/RPC。
原四个黑盒补上真实 Bridge/RPC（隔离 Provider fixture）→SQL→原页面链路。
legacy empty 在 SQL 中可为空但保留 last-good 可见内容；V2 complete empty 清理 canonical，
保持既有协议兼容，不调整数据库 schema 或 wire。

最终全量以 `--concurrency=1` 重放上述页面、四个黑盒、八个 lifecycle 与其他 Mobile 回归：
3300 PASS / 4 SKIPPED；全量 analyze 0 error/warning，1017 既有 info 无新增，固定 SHA review 通过。
原 full-page 折叠等待发生过并发组合超时；后续单独/串行重放通过，原因仍未归属，
失败收据保留，不能把最终串行 PASS 写成并发/云 CI 通过。
真实 Provider、原 Simulator/真机、生产 Bridge、发布和安装状态独立为 NOT_RUN；
原生 UI 自动化工具不可用为 BLOCKED。后续定位入口见 C1B-ENTRY。

## 回退与接手

行为修复 E024/E028 与结构迁移 E026 分开提交。若结构回退，保留来源错误检查、deferred read
和十三个新页面契约；E028 依赖 E026 接口，须先在隔离 checkout 适配行为再回退结构。
先在隔离 checkout 验证这些契约，再选整合方案。E023/E027 都是红灯版本，不能作运行候选；
E026 结构 checkpoint 尚有后来定位的 source-return 缺口。
更改单种 canonical/overlay 展示投影前，先读取本契约、原 updater/Cubit 和 C1B-ENTRY，再登记 C1b。
