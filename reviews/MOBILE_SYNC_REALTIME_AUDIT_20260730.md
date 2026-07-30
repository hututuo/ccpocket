# Mobile 会话实时状态与列表稳定性审计

Status: source and automated verification accepted; physical-iPhone visual
acceptance pending.

## 用户现象与根因

本轮针对以下同一链路中的现象复核：

- Desktop/Cockpit 明明有运行中的 Codex 会话，Mobile 首页却没有 Working；
- 点开持久会话后仍需再次等待 attach/刷新，最新一轮没有实时出现；
- 状态重算时列表每一两秒跳动，Working 短暂置顶后又消失；
- 同名会话可能看起来落入同一份或错误的历史。

代码事实表明，既有 v2 同步只可靠覆盖 Bridge 自己拥有的 runtime。独立 Desktop
进程写入 rollout 时，Bridge 并没有把“全部 durable thread 的运行事件”持续接入
v2 状态；旧的近期监控上限也把“是否展示 Working”和“是否保留实时正文 watcher”
混在了一起。另一方面，基线中的 durable identity 修复已经禁止按标题/项目绑定，
但状态源缺失仍会让用户误以为打开了错误或过期内容。

## 实际修复

`33ab6f1edb7aae5f688cd5ce4f2fdbbb0403a487` 完成：

1. 复用 `CodexRolloutMonitor` 接入独立 Desktop/Cockpit rollout 活动；
2. 首次目录同步对所有 durable Codex thread 进行一次有界 64 KiB 尾部检查；
3. 保存全部已发现 Working，实时内容 watcher 仍限制为最多 32 个；
4. 对 v2 客户端回放当前 turn seed，旧 continuity 客户端不改变；
5. active runtime/Need You 保持高于外部 rollout 推断，idle runtime 不再压掉
   外部 Working；
6. 当前 turn 缓冲限制为每 thread 256 条或 512 KiB；
7. 修正 user/thinking 去重，避免合法思考增量被错误合并；
8. 复用共享只读 app-server，不为每个热历史查询重建进程；
9. 取消每五秒全目录历史扫描式 watchdog；
10. 使用 generation、`observedAt` 和终态台账拒绝迟到状态复活；
11. 普通 idle recent 的默认常驻 watcher 从 10 降为 0；
12. 修复 session path 缺失时的 `O(missing × files)` 查找，索引按 generation
    复用并用目录指纹发现新 rollout。

`4f24fbe2250fcd97ffe600534aa1db6db425f353` 语义合入官方
`upstream/main@0c260954`（Mobile `1.111.1+206`、Bridge `1.69.5`），保留官方
生成图片缩略图、图片重历史分块和依赖更新，同时保留本地私有缓存、协议上限、
旧客户端和本地图片兼容。Mobile 源码版本继续单调递增为 `1.111.1+209`。

## 正确性与兼容审计

- 独立复审未发现本轮范围内剩余 P0/P1。
- durable identity 继续使用 provider thread ID，不使用标题或项目名。
- legacy Mobile 继续走既有 continuity；新状态和 seed replay 只加到 capability
  gated 的 v2 流。
- 所有 Working 状态与最多 32 个实时内容 watcher 分离；第 33 个以后不会丢
  Working，只会降级为两分钟 rediscovery 后补内容。
- 旧 generation、旧 observedAt 和终态后的迟到 Working 会被拒绝。
- Claude 外部实例的实时 rollout 未纳入本轮；Claude 的既有 Bridge-owned 路径
  未改变。
- 独立 Desktop app-server 的 Need You 没有 rollout 权威映射，仍明确记录为
  能力边界，不从正文推断。
- 两小时内仅有 response 活动的 rollout 仍可能被启发式判断为 Working；这是
  非阻断已知偏差，后续应由 app-server 权威状态替代。

## 验证与性能

- Bridge 定向回归：3 files、165 tests passed。
- 官方图片冲突回归：185 tests passed。
- Bridge 全量串行：96 files、1,887 tests passed；TypeScript build 和 native
  file-browser helper 通过。
- Mobile 生成图片回归：15 tests passed；定向 analyze 无问题。
- 304 个真实 catalog 条目的目录基准：median 33.24 ms、p95 54.05 ms、
  max 59.82 ms。
- 1,500 条合成目录：priority p50 17.81 ms / p95 24.55 ms，complete p50
  30.64 ms / p95 39.86 ms；首次历史读取 14，重复同步为 0；provider 最大并发
  2；最大帧 57,586 bytes，总发送 799,201 bytes。
- 正式 runtime smoke（322 catalog/status）：legacy 完成 9.75 s，capable 完成
  3.42 s；两者均发现 3 个 Working；最大帧 65,246 bytes，低于 64 KiB 上限。

## 结论与剩余门禁

本轮服务端源码、自动测试、性能基准和真实数据源协议 smoke 通过。Bridge 已能把
独立 Desktop/Cockpit 的 Working 与当前 turn 增量提供给现有 build 208，无需
先安装新 IPA。部署时手机未连接（`clients=0`），因此 Mobile 列表不跳、点开后
实时追平、同名会话显示正确及视觉排序仍需物理 iPhone 复验。
