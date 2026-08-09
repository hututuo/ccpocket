# CC Pocket 单仓库收束记录

状态：`accepted`

时间：2026-08-09 14:48 +08:00

## 目标与结论

CC Pocket 后续唯一 Git 项目根目录固定为：

`/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-compat`

该目录现在直接检出本地 `main`，不是 detached HEAD。后续 Codex 项目、普通开发任务和新 worktree 都必须以这个绝对目录为项目根，不再把上层 `/Users/huyiyang/AI agent/Codex`、日期型 worktree 或发布任务的旧 cwd 当作源码权威。

本轮没有合并互不相关的历史树，也没有用旧分支覆盖当前源码。最新产品线 `8ba48922025b188c991fa0e9ae273cdd8e45a516` 作为收束基线，随后只增加两组仓库治理提交：迁入旧运维仓库的已跟踪记录，以及归档 CC Pocket 专用局域网代理源码。运行中的 Bridge、LaunchAgent、共享 app-server、手机数据、Cloud、OTA 和 IPA 均未修改。

## 收束前现场

- 主源码 Git 公共目录：`ccpocket-compat/.git`。
- 注册检出：22 个，包括 detached 主检出和 21 个 linked worktree。
- 普通本地分支：22 个。
- `ccpocket-worktrees/current` 有 5 项未提交审计文档；其余 CC Pocket worktree 干净。
- 另有一个独立小仓库 `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket`，保存 2026-07 的 Bridge/网络运维记录。
- system-tools 还挂有一个 CC Pocket 局域网代理任务 worktree；它的专用提交位于 `c4aae8fa8c08e06898181aafe33919478a6a9077`。

## 分支审计结果

### 已是当前线祖先

以下任务分支的 tip 已直接存在于最新产品线历史中，因此删除普通分支不会丢代码：

- `feature/session-reliability-and-tasks-20260808`
- `fix/audit-report-remediation-20260808`
- `fix/lan-readiness-recovery-20260808`
- `fix/architecture-review-remediation-20260807`
- `fix/conversation-sync-stability-20260806`
- `fix/compaction-input-queue-20260804`
- `fix/mobile-toolbar-batch-settings-20260804`
- `fix/settings-runtime-consistency-20260803`
- `fix/mobile-status-projection-stability-20260803`
- 原 `integration/ccpocket-current` 的产品源码部分

### 已有 patch-equivalent 实现

对下列分支逐个运行 `git cherry -v <latest> <branch>`。功能提交均返回 `-`，即 patch-id 已在最新线存在；旧分支名不再承担实现所有权：

- provider 用户/turn 身份统一
- session index revision 原子提交
- compact 后有界历史与分页重试
- 连接进度和停滞 watchdog
- 轻量用户消息历史
- 悬浮待办
- Mirror 坏帧容忍
- Subagent 活动对账
- durable settings 项目路径与原子保留

两份只存在于旧 durable-settings 分支的历史故障说明，以及 `current` worktree 的旧业务审计文档，没有合入当前产品树；它们只保存在归档引用中，避免过时结论重新成为当前权威。

## 可恢复归档

本轮删除普通分支前，先为原 22 个分支 tip 建立：

`refs/archive/ccpocket/consolidation-20260809/branches/*`

旧独立运维仓库完整 `main` 历史保存在：

`refs/archive/ccpocket/consolidation-20260809/legacy-ops-main`

其中已跟踪且经过秘密扫描的 6 个文件迁入 `archive/legacy-ops-repository/`。旧仓库里被忽略的早期 plist 备份和一次性运行日志没有进入 Git；它们已被更晚的生产回滚链替代，因此随旧仓库移除。

CC Pocket 局域网代理的脚本、测试和发布记录迁入 `archive/system-tools-lan-proxy/`。原 system-tools tip 另保存在：

`refs/archive/system-tools/ccpocket-lan-proxy-20260809`

需要恢复某个旧任务时，使用显式新分支名，例如：

```bash
git branch recover/<name> refs/archive/ccpocket/consolidation-20260809/branches/<archived-name>
```

不要把整个归档分支机械合回 `main`；应重新审阅后只提取仍有价值的语义。

## 收束后结构

只保留两个同仓库检出：

1. 主项目：`ccpocket-compat`，分支 `main`。
2. 固定发布任务兼容检出：`ccpocket-worktrees/architecture-review-remediation-20260807`，分支 `release/ccpocket-local`。

第二个路径名称保留是为了不让既有固定发布任务失去 cwd；它已切到当前代码，不再承载旧 architecture-review 分支。发布任务仍须按每次授权重新核对 `main`/release HEAD、生产 runtime、回滚点和发布渠道。

其余 20 个 linked worktree 和 20 个任务分支已移除。收束前 `ccpocket-worktrees` 为 4,146,184 KiB，收束后为 138,728 KiB，释放约 3.82 GiB 的重复检出和可重建依赖材料。

## 后续规则

- Codex Desktop 只添加 `ccpocket-compat` 这个 Git 根作为 CC Pocket 项目。
- 新功能从 `main` 创建短任务分支或 Codex worktree；验证完成后回到 `main` 收束。
- 固定发布任务只使用 `release/ccpocket-local`，不作为开发基线。
- `upstream` 继续只用于 fetch 和选择性审阅；本地 `main` 是独立产品线，不能执行无审查的 pull/整树覆盖。
- 归档引用不显示为普通任务分支；确认长期无恢复价值前不做 Git GC 级永久清除。
- system-tools、全局 skill 和系统 LaunchAgent 仍归各自项目仓库；这里只保留 CC Pocket 专用源码或审计副本，避免把所有全局工具塞入 App 源码仓库。
