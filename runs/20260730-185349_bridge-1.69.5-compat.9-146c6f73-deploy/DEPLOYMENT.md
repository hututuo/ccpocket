# CC Pocket Bridge compat.9 部署记录

## 结果

- 源码分支：`integration/mobile-session-sync-v2-20260730`
- 源码提交：`146c6f73010fcfd483aa2467ba4cb5e074633f9a`
- 运行时：`1.69.5-compat.9-146c6f73`
- 运行时路径：
  `/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.5-compat.9-146c6f73`
- 当前进程：PID `96010`
- 唯一监听：`127.0.0.1:8765`
- 健康检查：`ok`
- 版本接口：`1.69.5-compat.9`
- 直接回滚运行时：`1.69.5-compat.8-4f24fbe2`

本次只修改 LaunchAgent 的 `BRIDGE_CLI_ENTRY`，保留原来的 host、端口、
API key、公开 URL、允许目录、文件传输和会话配置。未修改 Mullvad、
Tailscale、TCP Serve、手机缓存或会话权威数据。

## 本次行为修复

- Mobile 启动进度由粗粒度百分比改为 17 个真实事件阶段，覆盖传输打开、
  WebSocket ready、能力发送、目录请求、frame 收到、envelope 解码、
  model 校验、authority 接受、身份绑定、目录发布，以及 v2 同步的
  subscribe、begin、catalog、status、timeline、priority checkpoint 和完成。
- 圆形指示器保持独立、持续旋转；确定性百分比和线性进度单独显示，不再把
  `60%` 静态进度环误看成 Flutter 卡死。
- 日志记录连接 epoch、阶段、进度、耗时、page/progress scope、generation、
  sequence 和分页进度；线程只写哈希范围，不记录消息正文、路径、凭据或
  API key。
- v2 进度只在 Mobile SQLite 提交成功后推进；重复 `sync_begin` 和背压续传
  不得让进度从高位倒退。
- Prompt History 从首页权威启动关键路径移出，在应用 ready 后低优先级执行；
  同一 Bridge 的不同 IP 按 Bridge/source 身份去重，并优先复用主 socket。
- Prompt History 增加 revision 跳过、可选 `requestId` 关联和旧 Bridge
  快速失败；legacy 超时后隔离该连接代次，防止迟到结果污染下一次请求。
- Bridge 为全局 timeline 页面附加可选 `phase`、`timelineIndex` 和
  `timelineCount`，旧 Mobile 会忽略这些加法字段。

## 构建与验证

- Bridge 全量：`96` 个测试文件、`1888` 项通过。
- Bridge 定向协议回归：`459` 项通过。
- Mobile 全量：`2666` 项通过、`4` 个既有环境 skip、`0` 失败。
- Mobile 定向启动、同步与 Prompt History 回归：最终复审覆盖 `102` 项，
  全部通过。
- Flutter analyze：`0 error / 0 warning`，保留 `52` 个仓库既有 info。
- targeted analyze：`No issues found`。
- `git diff --check`：通过。
- 独立代码复审：Approve，无 P1/P2。

## 运行时校验

候选先在 `127.0.0.1:18766` 隔离启动，完成 health、version、legacy 和
capable v2 smoke 后才切换正式 LaunchAgent。

正式端口切换后：

- legacy smoke：目录 `322`、状态 `322`、Working `3`、timeline 页 `118`，
  完成约 `13.04 s`；
- capable smoke：目录 `322`、状态 `322`、Working `3`、权威特殊状态 `3`、
  timeline 页 `118`，完成约 `4.21 s`；
- conversation sync 最大帧约 `65,215 B`；
- capable Prompt History 返回 `317` 条，相关请求具备关联和 revision 跳过。

首次冷启动可能产生 catalog/status scoped reset，原因是 Bridge 进程启动后
外部状态发现尚在预热；稳定后不会把同一目录对象重复发布为两个权威版本。

## 完整性

- `dist/cli.js`：
  `e12c180058a8a6979df899daa8c09cd70c24046bd03d61509991d35893c07a17`
- `dist/websocket.js`：
  `56aeab1486f545ce7cb6c5066bf353cc572cca4bb4ce2e59abdeee580ca5d`
- `dist/local-features/conversation-sync-v2.js`：
  `1bfc228943f9d8a711d21a53f283566e2b0241c5fd67fb476e973b7758c03ce0`

## 回滚

完整回滚材料位于：

`/Users/huyiyang/Library/Application Support/ccPocket Bridge/backups/20260730-185349_bridge-1.69.5-compat.9-146c6f73-deploy`

候选与正式 smoke 的原始证据位于：

`/Users/huyiyang/Library/Application Support/ccPocket Bridge/deployment-evidence/20260730-185349_bridge-1.69.5-compat.9-146c6f73-deploy`

回滚只需恢复切换前的 LaunchAgent plist，重新加载
`com.ccpocket.bridge`，再确认：

- `/version` 返回 `1.69.5-compat.8`；
- `/health` 返回 `ok`；
- 只有一个 `127.0.0.1:8765` listener。

## 构建收束

- 仅保留当前 `compat.9` 和直接回滚 `compat.8` 两个运行时。
- 被替代的 `compat.7` 和两份中断的依赖安装目录已移入废纸篓，可恢复。
- 未清空废纸篓，因此磁盘可用空间暂未计入约 `524 MiB` 的可回收量。
- 本记录不等同于物理 iPhone 验收；Mobile owner OTA 安装后仍需观察真实
  17 阶段日志、目录进入和 v2 timeline 提交行为。
