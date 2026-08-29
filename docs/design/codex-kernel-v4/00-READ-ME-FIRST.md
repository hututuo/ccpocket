# CC Pocket Codex Kernel v4 本地完整设计

状态：`LOCAL_DESIGN_IN_PROGRESS / PHASE1_AND_PHASE2 / IMPLEMENTATION_NOT_AUTHORIZED`

本目录以 `CCPocket-Codex-Kernel-Redesign-20260829` 为待修订正文基线，结合 v4 审查输入、当前源码和历史需求，完成 Phase 1 核心修订与必要接口，以及 Phase 2 全部产品功能设计。

当前任务只授权设计、机器合同、验证器、事实实验规划、实施计划和审核包；不授权生产代码切流、数据库迁移、Bridge/App 启动、`8765`、部署、IPA/OTA、安装或发布。

## 固定方向

- 默认保留原 Codex Session Kernel 和正确不变量，只做有证据的最小修订；
- 不建立 V2/Mirror/legacy runtime fallback；
- Claude 仅不可达 typed unfinished seam；
- 52 项是产品保留账本，不是 52 个模块或 52 套完整合同；
- Phase 1 冻结核心和实际需要的最小接口；
- Phase 2 默认保留用户效果并复用当前模块；
- 最终输出必须是累计可读的完整设计，不是补丁说明集合。

## 输入

- v4 审核输入 ZIP：`/Users/developer/Documents/Downloads/CCPocket-Codex-Kernel-Redesign-20260829-baseline-amendment-two-stage-v4-final-20260830.zip`
- 解包目录：`/Users/developer/Documents/Downloads/CCPocket-Codex-Kernel-Redesign-20260829-baseline-amendment-two-stage-v4`
- 当前源码基线：`main@a706200233c55cc82d7a17e433f80f132d0f280d`
- tree：`ac85f620445151f45eda856f55f4b96ee442f41a`

冲突优先级：当前用户决定与本目录已接受 ADR > v4 审查收口 > 当前源码/实验事实 > 仍有效历史需求 > 原始设计。

