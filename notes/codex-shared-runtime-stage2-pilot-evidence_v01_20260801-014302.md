# CC Pocket 共享 Codex 运行时 Stage 2 Pilot 证据

> 状态：`automated-pilot-passed / awaiting-user-observed-desktop-pilot`
>
> 分支：`feature/codex-shared-runtime-20260731`
>
> 适用范围：仅 Stage 0–2。此记录不授权生产 Bridge、Desktop 常态切换、Mobile、OTA、IPA、Cloud 或 stable 变更。

## 1. 隔离边界

- Pilot 根：`/private/tmp/ccp-sr-501`，目录 `0700`。
- Bridge 候选：`1.69.6-compat.12`，仅监听 `127.0.0.1:18765`。
- 生产 Bridge 始终保持 `1.69.5-compat.11.c64bf5ed`、PID `11545`、唯一监听 `127.0.0.1:8765`。
- Pilot daemon 使用 Desktop 自带 Codex `0.146.0-alpha.9.2` 的私有真实副本：
  `/private/tmp/ccp-sr-501/codex/packages/standalone/current/codex`。
- 源与副本 SHA-256：
  `68474c6192406b8a0278243c8283b87a84798a69fb498f30c3715861f8082542`。
- daemon socket：
  `/private/tmp/ccp-sr-501/codex/app-server-control/app-server-control.sock`，device `16777230`，inode `101796358`。
- 身份准备只复制真实 `CODEX_HOME/auth.json` 到隔离根并写入哈希清单；未复制 config、sessions、state DB、MCP 或真实历史。
- 没有调用 `daemon bootstrap`，没有修改 LaunchAgent、Mullvad、Tailscale、生产 API key、Mobile、Swift、Cloud 或发布配置。

## 2. 自动 L0

真实候选在 2026-08-01 完成：

- 新建 canary Codex thread：`019fb93c-d1eb-7b01-8394-4f5ba5d2914f`；
- 真实 turn：`019fb93c-d83c-7ec2-8a6d-598f1f6ab04b`；
- 模型严格返回 `PILOT_OK`；
- 第二个独立认证 WebSocket 同时看到会话和完成；
- control 诊断环只出现 1 次 `thread/started`、1 次 `turn/started`、1 次 `turn/completed`；
- Bridge attachment 停止后，以 `thread/resume(excludeTurns:true)` 中性恢复；客户端没有收到 `past_history`，provider thread ID 不变；
- 总耗时 `8426 ms`。

观察者未为取得 turn 事件而 resume 线程。全局 control 保持只做 initialize/initialized；真正拥有线程的 Bridge attachment 只向诊断环投递脱敏 thread/turn ID 和状态，不投递标题、路径、正文、工具参数或 token。

## 3. Bridge 重启连续性

第一次候选 Bridge 退出后：

- `18765` 监听消失；
- 生产 `8765` 仍是 PID `11545`；
- Pilot daemon socket device/inode 仍为 `16777230/101796358`。

同一 worktree 候选再次启动后，对同一 provider thread 做中性 resume 并完成真实 turn：

- Bridge runtime session：`0a6f3c0b`；
- turn：`019fb93e-7bbf-7923-a123-7cdaed41666d`；
- 模型严格返回 `PILOT_RESTART_OK`；
- daemon inode 保持 `101796358`；
- 总耗时 `2035 ms`。

这证明“只重启 Bridge，不停止 daemon”时，已完成 thread 可继续使用；它不等于已经验证 Desktop 侧栏自动出现。

## 4. 活跃 turn 重新附着

对同一 thread 启动长输出 turn，在 `turn/started` 已确认且尚未完成时主动关闭原 Bridge attachment，然后立即从同一 daemon 重新附着：

- 原 Bridge session：`0a6f3c0b`；
- 新 Bridge session：`90edb65a`；
- 同一 active turn：`019fb93f-fb3b-7780-bca9-d40aa4f96ce9`；
- 新 attachment 权威显示 `running`；
- 新 attachment 收到该 turn 的匹配 `turn/completed` 和最终 `ACTIVE_PILOT_END`；
- daemon inode 仍为 `101796358`；
- 总耗时 `67404 ms`。

这证明当前 Pilot 能在不重启 app-server、不重放旧 settings 的情况下接管同一活跃 turn 的后续生命周期。

## 5. 自动测试

- 合并后定向回归：`14 files / 615 tests` 全部通过。
- Bridge 全量回归：`102 files / 2035 tests` 全部通过。
- TypeScript build 和 native file-browser helper build 通过。
- `git diff --check` 通过。
- 全量首跑唯一失败是既有 `session-catalog-monitor` 测试在同一文件上并发启动两个 `appendFile`，macOS 没有产生 watch 事件。该夹具不符合项目的单 writer 合同；改为同一 debounce 窗口内顺序追加后，隔离连续 3 次 `8/8` 通过，随后全量 `2035/2035` 通过。

## 6. 已知边界与下一门禁

- 当前不支持共享拓扑中的 external current-time 多 subscriber；检测不到明确请求所有权时继续 fail closed。
- 完整 Action Broker、持久请求台账、Mobile 状态协议、通知与常态生产温和切换仍属于 Stage 3+。
- Candidate 日志中的 Claude model/app/plugin 元数据读取失败是隔离环境缺少 Claude API key/Cloudflare 条件的非阻断噪声；Codex canary 本身正常完成。
- Desktop GUI 环境尚未修改，Desktop 尚未重启到 Pilot daemon，手机尚未连接 18765。
- 下一步必须由用户参与：短时切换 Desktop、完整退出并重开、验证没有 stdio 私有 app-server、验证 Desktop 侧栏自动出现同一 canary thread、双方各发一轮并实时可见。无论成功或失败，随后恢复 private 环境；用户确认前禁止进入 Stage 3。
