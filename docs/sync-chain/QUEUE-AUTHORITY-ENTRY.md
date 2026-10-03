# 下一入口：queue-only authority 的生产与消费顺序

本入口由固定16196f05的只读源码梳理产生，未修改产品，也没有宣称策略正确。

## 现有事实

- Cubit _reconcileDetachedRuntimeOverlayForStatus 在没有已呈现overlay tracking时早退。
- 原flush只在runtime/observer身份有效后，对当前authority+turn精确匹配apply；明确stale才reject，其他bounded pending等待。
- Bridge publishRuntimeOverlay按实际runtime snapshot/turn/authority构造envelope；每客户端必须已订阅交互焦点及overlay能力。
- runtimeOverlayAuthorityIsSequenced要求statusProjection的authority/turn匹配，且该subscription已发送或正在排队同一statusState。
- Bridge sendPendingRuntimeOverlays在发送前/await capacity后复核sequenced，并以runtimeOverlayAuthorityIsSuperseded退休其pending。
- Bridge的superseded predicate对authority不等直接返回true；Cubit queue-only侧并非同一策略。两侧是不同阶段、不同owner，不能直接统一。

## 为什么尚不能改

UUID不同不能说明未来或过期。Bridge status先发送、SQL先提交、页面status已应用是三个时间点。
需要证明旧authority或future authority在当前生产者与真实FIFO下确实可达，而不是给Mock任意时间戳复制实现。
现有E055只证明同authority的future turn；有visible owner的authority反向输入不能扩张到queue-only。

## 下批事实与最小证据

1. 固定Bridge源码/锁文件，记录runtime snapshot的handle、authority、turn和生命周期失效顺序；日志不含用户正文。
2. 保留实际subscription、statusState/sequence、overlay sequence/observedAt、SQL提交及原页面状态接纳点；不把两个queue的计数当同一预算。
3. 利用既有隔离Bridge fixture在原接点设置有限gate，分别尝试新authority status消费落后、旧authority事件等待后退休；不替换生产receiver或删除原期限。
4. 若由真实producer生成相应interleaving，才从其事实给public/黑盒预期；否则记录不可达的证据及仍未知的边界。
5. 策略行为red→green另提交，再讨论owner结构；32/64KiB拒绝新事件、remove-before-apply、原十三项queue契约、26项权限与原七黑盒保留。

## 并列未知

R29历史FAIL与095cab00完整FAIL的直接归因仍未知；visual pending 256/257与无runtime ID的旧V2远端归属也未验收。
真实Provider/设备/生产/发布各自NOT_RUN，不能借源码门禁关闭。

源码入口：Bridge conversation-sync-v2.ts 的 publishRuntimeOverlay / runtimeOverlayAuthorityIsSequenced / runtimeOverlayAuthorityIsSuperseded / sendPendingRuntimeOverlays；Cubit 的 _reconcileDetachedRuntimeOverlayForStatus / _flushPendingDetachedRuntimeOverlays / _detachedRuntimeOverlayIsProvenStale。
