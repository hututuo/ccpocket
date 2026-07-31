# Mobile 发送队列与 Desktop 会话事实修复

状态：`verified-source-candidate`

日期：2026-07-31

## 范围与基线

- 工作树：
  `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-desktop-runtime-queue-fix-20260731`
- 分支：`fix/mobile-desktop-runtime-queue-20260731`
- 起始基线：
  `integration/mobile-session-sync-v2-20260730 @ 4fcdcd25ef96658a9137ddc4bb85a13c1b84f0a0`
- 已验证代码提交：
  `9cde3249`（修复：分离消息回执并同步 Desktop 会话事实）
- 本轮只修改 Dart、TypeScript、测试和项目文档；没有 Swift、Xcode、
  Info.plist、Podfile、数据库 schema 或破坏性 wire 变更。

## 用户可见状态契约

发送行为必须分成三个不同事实，不能再复用同一个 `queuedInput` 外观：

1. 普通在线发送
   - 消息立即留在聊天气泡中，初始显示发送中；
   - Bridge 接收后显示一个勾；Provider 后续接收仍用于内部交付确认，但普通
     消息气泡不因此变成双勾；
   - ACK 再慢也不能因为固定 600 ms 定时器被搬到“下一轮排队”面板。
2. 真正离线的本地 outbox
   - 只有 WebSocket 断开、消息尚未进入 Bridge 时，才显示“已在本地排队”或
     “等待重连”；
   - 本地 outbox 与 Bridge 业务队列保持不同身份。
3. Bridge 权威下一轮队列
   - 只有 `conversation_queue` 或 `input_ack(queued:true)` 证明正在排下一轮后，
     才使用输入框上方的队列面板；
   - 普通 optimistic 气泡按 `clientMessageId` 原子迁入队列面板；
   - 新 Bridge 使用 `clientMessageId`；旧 Bridge 若缺失该字段，只允许用唯一、
     同文本的在途消息关联，不能在存在歧义时猜测；
   - 队列面板内 Bridge admission 为一个勾，Provider acceptance 为两个勾；
     在途发送不得提供无法真正撤回 Bridge 输入的假编辑/假取消按钮。

在线持久会话附着同样属于普通发送。只有实际断线时才显示本地排队文案；附着时
已经存在 Bridge 队列且发送被阻止时，待发送草稿不得被提前删除。

## Desktop 托管会话事实

- 首页已有的 `conversation_sync_v2` 状态现在同时投影到 detached durable
  详情页；只读打开仍不会 `resume`、不会取得 writer ownership。
- 状态按 provider、durable thread ID 和 `observedAt` 做二次围栏；迟到状态和历史
  fallback 不能覆盖更新的 Desktop Working/Compacting/Need You 事实。
- Detached 详情从 source-scoped catalog 读取真实 model、effort 和 service tier。
  缺失 effort 时保持 unknown，工具栏不能再用新会话默认值伪造 `high`；真实
  `ultra` 会按目录事实显示。
- Bridge 目录刷新只做一次有界 metadata enrichment；5 秒状态 watchdog 只读
  app-server 状态，不重复扫描 rollout。当前机器只读基准为 293 个目录会话、
  291 个可解析 metadata：目录读取约 640 ms，定向 metadata enrichment 约
  178 ms。
- 独立 Codex Desktop app-server 拥有活跃 turn 时，Mobile 和 Bridge 都拒绝
  `set_codex_model` / `set_codex_speed`。Bridge 在 mutation 前主动建立并刷新
  rollout monitor；无法证明 ownership 时 fail closed。若拒绝发生在 Mobile
  乐观更新之后，Mobile 恢复 catalog/runtime 中的真实 model、effort 和 tier，
  避免把 Desktop 的 `ultra` 写回成旧值。
- 这不声称独立 app-server 支持跨 owner live steer。只读缓存继续可用；输入仍按
  既有 Bridge 队列进入下一轮，除非未来官方提供可验证的 ownership/control API。

## 兼容边界

- 新 Mobile + 新 Bridge：使用完整状态投影、三段发送状态和外部 owner 保护。
- 新 Mobile + 旧 Bridge：普通发送不再伪装队列；旧 queue snapshot 缺少
  `clientMessageId` 时仅做唯一安全关联；无 v2 状态时保持既有降级。
- 旧 Mobile + 新 Bridge：协议字段不变；Bridge 端外部 owner 设置保护仍然生效，
  并返回 session-scoped `codex_settings_owned_elsewhere` 错误。
- Claude 的在线附着同样不再误报本地排队；Codex 专属下一轮队列行为不扩散到
  Claude。
- 同一会话允许保存多个未完成普通发送，页面重建会按原顺序恢复；一个 assistant
  结果只结算一个 pending，不能把同会话其他在途消息一起吞掉。
- 本轮没有 schema/API/native-Dart 迁移，可从代码层独立回滚。

## 验证证据

- Mobile 最终收束复验：发送/BridgeService/队列面板/durable preview/mode bar
  共 `271` 项通过。
- Mobile 全量：`2765` 项通过，`4` 项环境跳过，exit 0。
- Bridge 最终单 worker 全量：`96` files / `1949` tests 通过；TypeScript
  build 和原生 file-browser helper build 同时通过。默认并行全量曾仅有一个
  既有 `session-catalog-monitor` 的 `fs.watch` 2 秒时序用例抖动；该文件隔离
  `8/8` 通过，单 worker 全量也通过，因此没有把并发红项伪装成 clean。
- Flutter 全量 analyze：0 error / 0 warning；52 条 info-only diagnostics；
  targeted analyze 中本轮文件仅出现 5 条既有 `prefer_initializing_formals` info。
- 为避免 Flutter 3.44.7 formatter 把基线旧排版机械重写上千行，最终文件保留
  基线排版；最小差异版本经 formatter 归一化后与全量测试通过版本逐字节一致，
  并在差异收束后再次通过 analyze 和 271 项定向回归。
- `git diff --check`：通过。

## 尚未越过的交付门禁

- 本文只证明源码与自动回归；尚未替换生产 Bridge、发布 owner OTA、安装 IPA 或
  完成物理 iPhone 视觉/行为验收。
- 因为 Mobile 修改为 Dart-only，理论上可进入现有 build 210 的 Shorebird owner
  patch；Bridge 的 TypeScript 保护必须单独构建并切换 runtime。
- 实际发布继续交由固定发布会话
  `019f8e9d-2490-79c0-817c-87e3eb93ea2f`，发布前必须重新核对 clean HEAD、
  当前 owner base、生产 runtime、PID/listener、回滚点和手机在线状态。
