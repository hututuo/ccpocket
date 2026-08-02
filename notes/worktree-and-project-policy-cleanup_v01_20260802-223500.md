# CC Pocket 工作树与项目策略清理记录

状态：`accepted`

## 目的

收束 2026-07-30 至 2026-08-02 多 Agent 开发留下的日期 worktree、普通分支、临时构建和错误的项目审批组合，同时保留所有独有源码和可回滚证据。此次清理不部署新 Bridge、不发布 OTA、不修改 Cloud、VPN、Codex Desktop 配置或用户会话数据。

## 权威入口

- 当前工作树：`/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/current`
- 当前分支：`integration/ccpocket-current`
- 收束起点：`e4583b5039d3e96ad842c6f7de5db245f9d73816`（Mobile `1.111.1+214`）
- 项目审批修正：`f1d18745`
- 恢复的过程展开 UI：`0a374184`
- 文档边界：`fad932ee`

## 审计后处理

- 所有登记的日期 worktree 分支均已确认进入当前线，或先创建精确 archive ref。
- 旧项目配置的未提交状态保存为 `ec485ba34c6be7c50052b7f03e8174ea18aa5472`。
- 旧并行 UI 工作树的未提交状态保存为 `8e84406f6e2886fff29f719bd8f1b0a68de99fab`；其中有价值的三文件改动已移植到当前线并通过 14 项 Widget 测试和定向 analyze。
- `refs/archive/ccpocket/worktree-cleanup-20260802/*` 共 17 个 ref，覆盖所有删除的普通分支 tip、两个 dirty snapshot、旧 primary detached HEAD 和 build-214 发布 tip。
- 普通本地分支只保留 `integration/ccpocket-current` 与历史 `main`。
- Git 注册 worktree 只保留：
  1. `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-compat`（detached Git store checkout）；
  2. `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/current`（唯一开发 worktree）。
- 主仓库 detached HEAD 已对齐到当前已验证提交，避免从古老 checkout 误判源码。

## 可恢复清理与独有补丁

- 大体积旧 worktree、candidate、依赖和 scratch 没有永久删除，而是移动到：
  `/Users/huyiyang/.Trash/CCPocket-cleanup-20260802-222000`
- 废纸篓中约 2.8 GiB；清空废纸篓前仍可恢复，也不会立即释放全部物理空间。
- 当前源码工作树约 275 MiB；系统当时约 40 GiB 可用。
- 旧 AltStore scratch clone 中只有三个真实源码改动。已提取为
  `patches/altserver-remote-install_v01_20260802-221939.patch`，源 AltStore HEAD 为
  `56854e66fef2eac32dad88dcbad1dc131d430e60`，补丁 SHA-256 为
  `a81ffea29ac38932c845ac4d9b11fef757b04d058bb7915878a63f951b041de7`。
  对源 HEAD 的 `git apply --check --cached` 通过。该补丁只是独立证据，未合入 CC Pocket。
- `/tmp/ccpocket-bridge.log` 和 `/tmp/ccpocket-bridge.err` 是在线 LaunchAgent 的当前日志，未删除；其余少量 smoke 文本也不是注册 worktree，不以清理它们换取表面整洁。

## 项目审批根因与固定流程

上游项目规则把 Node、npm 和 Flutter build 标为 `prompt`，旧后台发布又用 `AskForApproval=Never` 或绕过审批参数启动。这会在命令创建前直接拒绝，而不是构建工具本身失败。当前策略为：

- `.codex/config.toml` 固定 `approval_policy = "on-request"`；
- 确定性的 Bridge/Functions 本地测试构建、Flutter 测试分析和本地 iOS build 使用精确 allow；
- 任意 Node、依赖安装/发布、服务切换、Cloud deploy、Shorebird 发布/晋级、Git remote/destructive 操作继续 prompt；
- 发布任务禁止使用 `--dangerously-bypass-approvals-and-sandbox`、`--ignore-rules` 或显式 `never`；
- 旧持久发布任务的 cwd 只是历史元数据。每次任务必须在交接中提供当前绝对 worktree、branch 和完整 HEAD；无法切换就停止，不得从旧目录构建。

`codex execpolicy check` 已验证 Bridge build/test 和 Flutter iOS build 为 allow，而 Functions deploy、Shorebird promote、任意 Node 和 Git push 保持 prompt。

## 交付物和在线服务核对

- Downloads 只保留当前与一个回滚 IPA：build 214 与 build 213。
- build 214：`CC-Pocket-1.111.1-build214-shared-thread-settings-e4583b50-AltStore.ipa`
  - 大小：24,135,052 bytes
  - SHA-256：`598d5fb06e2f0461541288904eeadcf177d46d58565390b00d8469d2d06defc5`
  - Bundle ID：`com.k9i.ccpocket`
  - 版本/build：`1.111.1` / `214`
  - Runner：arm64；ZIP 安全与完整性通过；无 `_CodeSignature`、无 `embedded.mobileprovision`。
- 旧隔离 shared-runtime pilot 与 18765 监听已停止；它不是生产服务。
- 生产 `com.ccpocket.bridge` 配置和 runtime 未被本轮修改。收尾时在沙盒外只读验证：版本 `1.69.6-compat.12`、`status=ok`、`applicationReady=true`、daemon runtime ready、Action Broker ready；loopback 8765 与既有 LAN proxy 均存在。

## 回滚与恢复

- 删除分支的 tip：从对应 `refs/archive/ccpocket/worktree-cleanup-20260802/<name>` 创建新分支。
- dirty worktree：从 `mobile-tiered-config-wip` 或 `parallel-bugfix-a-process-disclosure-wip` archive ref 恢复。
- 大体积目录：清空废纸篓前从上述 Trash 目录移回原路径。
- AltServer 独有代码：在 AltStore `56854e66...` checkout 中先运行 `git apply --check`，再人工审查该补丁；不能直接当成当前 CC Pocket 提交。
