# 会话重试与旧缓存回退修复记录

状态：source-verified / release-pending / physical-device-pending

## 现场现象与证据

- 2026-08-07 09:23，Codex 会话仍能收到实时工具活动，但消息列表顶部持续显示红色“重试”。该按钮的实际控件是 `local_history_retry`，属于更早历史分页，不是失败消息重发。
- 生产 Bridge 日志在同一连接中记录了 `conversation_turns_page`、多次内容 ACK，以及订阅取消/重新订阅；该线程的 `thread/items/list` 不可用时会回退 `thread/turns/list`。
- 用户随后从 Desktop 继续会话时，手机曾显示新进度，之后又回到旧缓存窗口。源码确认缓存读取在途时即使收到更新通知，旧读取结果仍会先被渲染，再发起一次补读。

## 根因

1. `loadOlderTurns` 同时承担“向上加载旧轮次”和“修补未完成的最新轮”。运行中的会话天然可能有未完成最新轮，因此历史分页会被错误改道到最新轮修复，失败后只留下无法推进的重试按钮。
2. Codex 与 Claude 的 durable preview 都会在 SQLite 读取期间记下 dirty，但旧读取完成时仍先应用结果，造成旧窗口闪回。
3. detached runtime 换绑时，若旧状态尚无精确 `activeTurnId`，后续确认仍有活跃 turn 也会被当成不同 turn 清除可见实时输出。
4. provisional route 首次获得权威 source fingerprint 时复用了“真实 source 更换”的清理路径，也会清除已经显示的实时输出。

## 修复边界

- 新增独立 `repairLatestTurn`；普通 `loadOlderTurns` 只使用既有 older-turn cursor，最新轮是否完整不再阻断向上分页。
- 同一 target 的 older paging 与 latest-turn repair 串行提交；`turns_page` 修复保留已分页的负索引前缀及其 cursor，不会把刚加载的旧轮次删除。
- Codex 与 Claude preview 在读取期间出现新 commit 时拒绝应用旧结果或旧错误，只执行合并后的后续读取；同一 target 内还以本地 `cachedAt` 拒绝倒退。
- `cacheCommitEpoch` 在缓存更新广播前递增，读取结果即使先于广播 listener 返回，也会按读取代次被拒绝。
- runtime 换绑后，两个已知且不同的 turn id 仍会清除旧视觉状态；旧 id 未知只代表缺证据，活跃状态不会再清空画面。
- 首次 source fingerprint 确认保留视觉状态；两个已知且不同的 source 之间切换仍执行原有隔离清理。
- 全部改动为 Dart-only；无 Bridge 协议、SQLite schema、Swift、Cloud 或原生能力变化。

## 验证

- Mobile 定向 3 文件共 239 项通过。
- 新增回归覆盖：运行中最新轮不阻断 older-turn paging；并发 repair 不删除已分页前缀；缓存 commit 广播前的旧读取不闪现；旧 turn id 未知时 runtime rebind 保留实时输出；首次 source 确认仍服从 terminal 状态且真实 source 更换会清理旧输出。
- targeted analyze：0 error / 0 warning；仅 2 条仓库既有 `prefer_initializing_formals` info。
- `git diff --check` 通过。

物理 iPhone 仍需验证：运行中向上翻页、点击红色重试、Desktop 继续输出、切出/切回 App、短暂断线重连后，最新可见内容不得回退或消失。
