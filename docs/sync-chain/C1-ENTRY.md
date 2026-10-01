# C1 入口：先收敛页面的异步缓存重读

状态：C1a 已从 clean `38c4240e54496a4dd504ea6d029d457d78a90bfb` 开始，接点盘点和基线重放中。
本入口描述范围与契约，当前进展见 PROCESS 的 E022 及后续条目；不以旧页面测试代替新范围的验证。

## 选定接缝

先处理 `apps/mobile/lib/features/codex_session/codex_session_screen.dart` 的
`_loadDurablePreview` / `_retryDurablePreviewLoad` 及其生命周期接点。
真实路径为 SyncService updates → 原 SQLite window read → 页面接受/丢弃结果 →
`ChatSessionCubit.updateDetachedPreviewHistory`。当前页面同时保存 loading、dirty、read generation、
target fingerprint、已显示窗口与错误提示，容易只修成功出口而漏掉 error/finally 或 route 切换。

C1a 只验证并收敛这组异步读取状态。Cubit 的 canonical/overlay 合并、发送控制、权限、
UI 布局和 Bridge handler 留待各自批次，不与读取状态一同重写。
模块名称/接口在契约测试明确之后决定；不能为了抽取而把整页对象传入 helper。

## 读取结果的契约与证据

| 场景 | 必须观察到的结果 | 证据方式 |
|---|---|---|
| A 读取期间提交 B | 页面不短暂回退到 A，最终显示 B | 在真实 SQLite read 返回处 hold/release，记录已挂载页面内容 |
| 一个读取期间重复通知 | 合并必要的后续读取，最终使用最新 epoch；不能吞通知或无限重读 | 可控读 barrier + 实际内容/调用界限 |
| 旧 thread/source/route 的读或错误晚到 | 不能替换当前页面，也不能展示旧目标的错误或清理新目标的 loading | 切换目标后释放旧读取/错误；检查内容和交互终态 |
| 重读失败 | 保留 last-good，可见错误能重试；后续成功不沿用旧错误 | 注入读取边界错误，不模拟业务窗口 |
| V2 authoritative empty / 旧 Bridge empty | 前者允许清理旧 canonical，后者保留最后可读内容 | 独立协议版本用例，避免把 null/empty 混为一谈 |
| partial / older page 通知 | 原挂载页面更新，稳定身份/顺序、coverage/cursor 与 SQLite 一致 | 沿用并加强真实 Bridge/RPC/SQLite/原页面黑盒 |

这里列的是要证明的契约，不宣称现状全部正确。先定位既有用例能覆盖什么、哪些需要补红灯。
上游仍是隔离 Provider fixture 时必须明示；真实 Provider、设备和生产状态继续分别记录。

## 状态与权威归属

- Service/Repository 继续判断数据源身份、分区、事务、cursor/coverage 和 cache epoch；
  页面不能用读 generation 或本地观察 token 创建另一套 canonical revision。
- 候选读取生命周期仅拥有一次读取的 owner、dirty 合并、清理与旧结果失效；
  读取调用、目标当前性、epoch 获取用窄接口提供。
- 接受结果后的 setState、Cubit 投影、Snackbar/Retry 留在页面 owning path。
- 如果纯重读抽取需要同步移动 canonical/overlay 合并或写入权，暂停扩大范围，先补链路事实。

## 执行顺序与完成门禁

1. 核对 B2 最终源码 SHA/status，读 HANDOFF 与相关 decisions；登记新的账本起点和范围。
2. 读取上述调用和接点；重放 B2 四个接收/原页面用例及既有 durable preview 回归，列缺口。
3. 新契约先稳定 red → 独立行为 fix；不能把旧输出当正确基线。
4. 冻结行为后完整迁移选定读取状态；相同输入再跑原页面，确认未靠刷新/重建掩盖漏通知。
5. 完成 Mobile 全量 analyze/tests、相关黑盒、独立 review；UI 改动按 mobile-automation 验证，
   工具/设备不可用时诚实记录 NOT_RUN/BLOCKED，不借用静态门禁声称运行验收。
6. 更新地图、矩阵、过程记录与逆序回退依赖，再评估 C1b 的单种展示投影。

B2 的 E020 已说明本地 cache mutation 与 transport generation 需要分别判断。
C1a 的接点盘点要检查成功/error/finally，以及其他分页是否有相同交错；
其他路径尚无此时序的专门证明，不能直接把两个 older 出口的修正机械套遍所有通知。

回退保持本批新增回归保护，优先回退独立结构提交并适配已修复行为；
不得直接退到红灯 checkpoint，也不得触及原 main、运行 Bridge 或已安装应用。
