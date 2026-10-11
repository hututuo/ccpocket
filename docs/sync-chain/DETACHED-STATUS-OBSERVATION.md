# Detached status观察职责

C1k将原ChatSessionCubit的status时间、业务签名与本地commit receipt移交
`apps/mobile/lib/features/chat_session/state/detached_status_observation.dart`。
它只记录已通过原入口资格核对的观察，不授予控制权限，也不决定overlay应当显示或退休。
源码批次 `659d44926b7a66e4161aed68344198dcca5c79ee`，父C1j观察修正
`337c5c5a3d0b30569f5ca76a4de30f8d2cd49b49`；完整门禁与当前断点见[过程账本](PROCESS.md)和[精确收据](ACCEPTANCE.json)。

| 责任 | 唯一owner | 事实边界 |
|---|---|---|
| observedAt、13字段签名、local receipt | DetachedStatusObservation | record一起更新；clear一起失效，不留第二套Cubit字段 |
| 旧时间/同stream旧票拒绝、相同业务观察、重复观察的票刷新 | DetachedStatusObservation | 时间严格isBefore；票仅比较同source/subscription，不比较UUID或跨streamseq |
| provider/thread/source/runtime核对及receipt资格 | ChatSessionCubit原status入口 | 模块接收已核对的事实，不复制Bridge身份与权限逻辑 |
| suspend后的fresh receipt重建authority lease | ChatSessionCubit原完整接纳分支 | duplicate观察不等于可以早退；已撤lease且有有效新票仍走原owner应用 |
| mutation、control、queue接纳/退休、视觉和历史fallback | 原Cubit/原queue/原页面 | 模块getter提供观察事实，不另造权限或通知总线 |
| SQL写入与receipt产生 | 原Repository / SyncService | 事务结束且仍当前才生成本地票，JSON/数据库不保存票 |

签名保留activity、attention、result、runtimeAttachment、source、confidence、原始observedAt字符串，
以及attentionRequestId、executionHost、activeTurnId、controlState、authorityGeneration、runtimeSessionId。
顺序、空字符串编码和分隔符与原Cubit完全相同；解析后的UTC时间仅用于原时间比较。
模块没有stream、timer、异步writer或完整Cubit引用。

## 原生命周期接点

| 原入口 | observation处理 | Cubit仍负责的行为 |
|---|---|---|
| updateDetachedLiveRuntime的实际binding变化 | clear | 失效旧authority、取消旧订阅并绑定新runtime |
| updateDetachedProviderStatus(null) | 原条件下clear | 状态未知与权限撤销；不改变原条件/emit顺序 |
| _adoptDetachedProviderSource | clear | 原source/视觉/settings/authority失效 |
| suspendDetachedProviderProjection | 保留时间/签名/票 | 已提交事实仍可读，控制lease与mutation被撤销 |
| 相同业务status，无票cached读 | refreshReceipt(null) | 清本地顺序证明；完全相同观察不恢复已撤lease |
| 已撤lease后的合格新票 | 原完整接纳后record | 同sub严格后继或新sub低seq仍按原资格恢复 |

overlay stale判断仍先要求当前lease和同source/sub/runtime的严格后继receipt，
再走原严格墙钟回退；exact authority+turn先应用的规则不变。
diagnostic字段名和history fallback条件保持原接口。

## 验证与回退

抽取前后沿同一93项公开/实际receiver输入验证；没有新增镜像模块实现的测试。
完整Mobile、静态诊断逐项比较、变更格式、固定源码只读独立复核分别登记在E094/supplementalC1k。
Bridge、协议、SQL、SessionList/Updater、测试与依赖输入保持父提交相同。
观察设施的C1j修正与本结构批分别提交；回退结构批恢复原字段和比较，不撤先前C1h/C1j行为修复或接收合同。
回退时同步更新当前入口与owner表，历史接受记录继续保留。

C2 Bridge按领域抽取、D旧兼容退役仍未完成。R47完整旧/未来authority策略、R45 visual 256/257、
R49缺runtime ID旧组合与历史UNKNOWN各自开放，不能借观察owner抽取宣称整个重构结束。
