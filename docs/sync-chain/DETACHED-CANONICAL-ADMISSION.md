# V2 detached canonical 候选的准备与接受

范围为 C1b，起点/红灯/行为修复见 PROCESS E030–E032，结构实现见 E033，
History 解码提示副作用的独立复审与修复见 E034–E035，最终门禁见 E041。
canonical 行为源码仍与 `2f64e383` 一致；本批最终产品 `ce51e280` 另含 Service 焦点窄修，
测试/fixture 输入固定 `adf337ea`：Mobile 3333 PASS / 4 SKIPPED，无新增诊断。
十五项 canonical/handler 保护和十七项焦点保护属于不同责任；焦点快照仍在 Service，
不向纯 candidate 添加 generation、subscription 或 transport 状态。

| 责任 | 唯一归属 |
|---|---|
| source、revision、SQLite 原子提交、epoch 与 read ownership | 原 Service/Repository/C1a reader |
| exact identity、ordered canonical 与 overlay 合成 | 既有 projectDetachedTimeline，不新增 reducer |
| 一次候选的投影、整体接受条件、原 canonical 的 client receipt 证据 | 既有 detached_timeline_projection 模块中的不可变 candidate |
| History 只读解码与合法应用后的提示确认 | 原 ChatMessageHandler.prepareHistory / commitPreparedHistory |
| 当前 overlay 筛选、诊断、应用状态、draft/alias 清理、分页与 UI | 原 Cubit owning path |

候选是一次同步调用的纯输入/输出对象，不是新增 Bloc/Widget 状态，也不保存 future、timer、
generation 或 writer。它不持有 Page/Cubit/Service/Repository；别名与内容合并继续使用原窄回调。
不要把本地 draft 的文本或 merge 后补齐的 client ID 当作新的投递收据：
待消费的关联 ID 必须来自本次原 canonical 输入，且只在整体接受后提供。

## 完整接点与契约

1. 原 handler.prepareHistory 只读解码后，复用原 reducer 的 canonical 身份扫描，生成不可变 candidate。
   canonical 列表与 alias 索引在本次调用中只准备一次；该阶段不筛选/应用 runtime overlay，
   也没有 draft/alias、paging、state 或 handler 的“提示已显示”写入。
2. public updateDetachedPreviewHistory 在 paging/状态应用之前判定 candidate；
   duplicate canonical 拒绝整个候选，保留 last-good 设置、审批、队列、分页与未证实的 outgoing 状态；
   拒绝的 Git tip 不得抑制后续有效 error。
3. 合法候选沿原 _applyUpdate → V2 merge 接缝传入；原入口先执行既有 runtime 归属/过滤，
   再筛选当前 outgoing/runtime overlays，用 candidate 的 canonical 列表/索引完成原 overlay 合成。
   每次 compose 复制工作列表/索引，不改变 candidate 或另一份结果；不提前捕获可能被原入口过滤的 overlay。
   其他已有 merge 调用者在原分支就地准备候选，保持原兼容范围。
4. draft/本地 outgoing ID 只消费候选中的原 canonical client 证据；assistant alias 只消费原 canonical entries。
   rejected candidate 不提供 receipt 消费计划；正常合法 commit 与重放仍按原稳定身份合并。
   原 _applyUpdate 完成后，handler.commitPreparedHistory 才确认该合法历史中的 Git tip；
   既有 live system / 普通 handle(History) 仍按原入口确认，已接受提示不因后续拒绝被重置。
5. legacy empty、paged mirror/shared weaving、runtime source/authority、数据库与 wire 保留各自 owner。
   raw history 的解码和应用也不获得新的 canonical 写权。

新契约用原 Cubit/public history/draft 入口验证；纯 candidate 用例仅补无副作用与证据来源边界。
真实 SQL/原页面和原 Bridge/RPC 黑盒负责重放接受链，Provider fixture 与设备验收分开。
结构最终必须通过相同输入重放、全量 Mobile 门禁和独立固定 SHA 复审。

## 回退

行为修复与结构分别提交。结构回退需保留 E032 的整体 admission 及四个红灯保护，
保留 draft/同正文不同 client 的两个正向契约；不能回到 E031 红灯状态作为候选。
E035 的 handler 修复与 V2 prepare/应用后确认接点一起保留，Git tip 两项原 Cubit 和三个 handler 保护须通过。
候选接口若有后续行为依赖，先在隔离 checkout 适配再回退结构；不操作 main、设备或运行服务。
