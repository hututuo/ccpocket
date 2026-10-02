# V2 detached canonical 候选的准备与接受

范围为 C1b，起点/红灯/行为修复见 PROCESS E030–E032；当前为结构设计，最终门禁另记。

| 责任 | 唯一归属 |
|---|---|
| source、revision、SQLite 原子提交、epoch 与 read ownership | 原 Service/Repository/C1a reader |
| exact identity、ordered canonical 与 overlay 合成 | 既有 projectDetachedTimeline，不新增 reducer |
| 一次候选的投影、整体接受条件、原 canonical 的 client receipt 证据 | 既有 detached_timeline_projection 模块中的不可变 candidate |
| 当前 overlay 筛选、诊断、应用状态、draft/alias 清理、分页与 UI | 原 Cubit owning path |

候选是一次同步调用的纯输入/输出对象，不是新增 Bloc/Widget 状态，也不保存 future、timer、
generation 或 writer。它不持有 Page/Cubit/Service/Repository；别名与内容合并继续使用原窄回调。
不要把本地 draft 的文本或 merge 后补齐的 client ID 当作新的投递收据：
待消费的关联 ID 必须来自本次原 canonical 输入，且只在整体接受后提供。

## 完整接点与契约

1. 原 History handler 解码后，用当前 non-past entries 筛选既有 outgoing/runtime overlays，
   调用现有 reducer 一次，生成不可变候选；准备阶段没有 draft/alias、paging 或 state 写入。
2. public updateDetachedPreviewHistory 在 paging/状态应用之前判定 candidate；
   duplicate canonical 拒绝整个候选，保留 last-good 设置、审批、队列、分页与未证实的 outgoing 状态。
3. 合法候选沿原 _applyUpdate → V2 merge 接缝传入；本次同步应用复用同一个投影。
   其他已有 merge 调用者在原分支就地准备候选，保持原兼容范围。
4. draft/本地 outgoing ID 只消费候选中的原 canonical client 证据；assistant alias 只消费原 canonical entries。
   rejected candidate 不提供 receipt 消费计划；正常合法 commit 与重放仍按原稳定身份合并。
5. legacy empty、paged mirror/shared weaving、runtime source/authority、数据库与 wire 保留各自 owner。
   raw history 的解码和应用也不获得新的 canonical 写权。

新契约用原 Cubit/public history/draft 入口验证；纯 candidate 用例仅补无副作用与证据来源边界。
真实 SQL/原页面和原 Bridge/RPC 黑盒负责重放接受链，Provider fixture 与设备验收分开。
结构最终必须通过相同输入重放、全量 Mobile 门禁和独立固定 SHA 复审。

## 回退

行为修复与结构分别提交。结构回退需保留 E032 的整体 admission 及四个红灯保护，
保留 draft/同正文不同 client 的两个正向契约；不能回到 E031 红灯状态作为候选。
候选接口若有后续行为依赖，先在隔离 checkout 适配再回退结构；不操作 main、设备或运行服务。
