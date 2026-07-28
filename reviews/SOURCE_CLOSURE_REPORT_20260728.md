# CC Pocket 综合修复源码收束报告

日期：2026-07-28

## 1. 身份与结论

| 项目 | 值 |
|---|---|
| 工作树 | `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-v03-20260728` |
| 分支 | `fix/mobile-comprehensive-source-closure-20260728` |
| 本批起点 | `3fb83d12cf883c18d187d312cea8bc8f90d572cc` |
| 最后行为源码 | `fa3aa6db715bcfe47f4d93a3b090e18e508ef164` |
| 行为提交数 | 29 |
| 其后提交 | 仅需求台账、验证记录和交接文档 |
| 官方上游 | `upstream/main@829621364b730b866e0c39b27d0aab868084f2aa`（`1.109.3+202`） |
| 本地版本 | `1.109.3+205` |

结论：本轮能够由源码和自动化证明的实现、性能、安全及兼容收束已经完成。
这不等于 Bridge/Cloud 已部署、签名 IPA 已生成、物理 iPhone 已安装或
`owner` / `stable` 已发布。逐项产品完成度仍以
`REQUIREMENT_LEDGER_20260727.md` 为准。

## 2. 行为提交顺序

1. `45b19301` 移动端：完善会话目录启动恢复与连接隔离
2. `d801b220` Bridge：文件写入授权缺失时默认拒绝上传
3. `22e05642` 移动端：区分未知与已确认的 Codex 权限状态
4. `c8256234` perf(bridge)：避免全 provider 目录重复扫描 Codex
5. `809edaed` Bridge：回收已删除会话目录监视配额
6. `07e67200` 移动端：汉化会话环境与系统状态标签
7. `3b6731f8` perf(mobile)：避免镜像分页触发全局重建
8. `306aa368` Bridge：限制会话内容同步缓存字节
9. `8aaacef3` perf(bridge)：会话内容目录仅读取索引元数据
10. `61b59a39` perf(bridge)：合并慢客户端未确认的会话修订
11. `3676f4f5` 移动端：完整对账会话目录缓存尾部
12. `bc3f640d` 移动端：通知清理失败时保持启动可用
13. `595f9695` 移动端：修复窄栏运行会话状态溢出
14. `a1f88ece` test(mobile)：修正本地化界面夹具
15. `c56e1c35` test(mobile)：稳定会话连续重试验证
16. `fac56c47` 移动端：按 Bridge 稳定身份复用跨 IP 数据并隔离离线队列
17. `8aabde45` 兼容：支持顺序实例共享 Codex 会话来源
18. `170621dd` 修复：按 Codex 来源隔离手机消息缓存
19. `0e6d2525` 文档：记录 Codex 共享会话来源边界
20. `9019b372` 移动端：收束文件传输后台任务生命周期
21. `013c58d3` 移动端：按 Bridge 来源隔离未读路由与通知
22. `78c0d011` Bridge：为通知携带会话来源身份
23. `e50a3c82` Bridge：收束 Codex 输入与协议帧生命周期
24. `d0075f22` 移动端：按官方活动标记识别运行中子 Agent
25. `c1d96f8b` 移动端：兼容未来桌面连续性事件
26. `1685aefc` Bridge：为核心 Codex 回合增加归属与超时防护
27. `d667ef07` 移动端：兼容未来文件节点类型
28. `399e980c` 移动端：降低镜像增量补丁内存开销
29. `fa3aa6db` Bridge：降低空闲会话连续性轮询频率

这些提交按 owning layer 和用户可感知行为拆分，可逐项审查和回退；不要机械
整枝覆盖未来官方热点文件。

## 3. 关键收束

- 启动与目录：修复初始目录事件顺序、连接代隔离、完整目录尾部对账和元数据
  首屏路径；普通 idle 不再伪装 Ready，unknown 保留真实未知语义。
- 同步与身份：稳定 Bridge 身份可跨 IP 复用；目录、Mirror、消息缓存、未读、
  路由、深链和通知都按 Bridge/Codex 来源隔离。当前保证顺序实例共享同一
  Codex 来源，不宣称并发外部写入者安全。
- 生命周期：回收目录 watcher、限制内容缓存字节、合并慢客户端 ACK；Codex
  输入、协议帧、核心 RPC、回合归属、临时图片和文件传输后台任务均有明确
  generation、超时或 teardown。
- 性能：provider 目录避免重复全扫描；内容目录走 metadata-only；Mirror
  分页和增量 patch 避免全代 Dart 物化；空闲 continuity 降低兜底轮询频率。
- 安全：文件写入授权状态缺失时 fail closed；读取/预览与修改授权仍是不同
  边界；新协议字段只做 additive/capability-gated 扩展。
- 未来兼容：未知 Desktop continuity 事件不被错误 ACK；未来展示型文件节点
  安全映射为 `other`，但 mutation、授权和路径校验仍严格拒绝未知语义。

`9019b372` 还修复了一个真实的测试与产品生命周期问题：旧
`FileTransferService.dispose()` 没有等待或取消恢复/重试后台任务，临时存储已经
删除后旧任务仍可能迟到运行。现在后台操作被跟踪，重试可取消，`close()` 会等待
订阅和任务结束，并用 generation fence 拒绝迟到结果。

## 4. 最终源码门禁

所有下列结果都来自与最后行为源码相同的独立验证工作树；其后的修改只涉及本文、
交接入口和台账。

| 门禁 | 结果 |
|---|---|
| Bridge 全量 | 95 个测试文件，1836 项通过 |
| Bridge Desktop continuity 专项 | 2 个文件，46 项通过 |
| Bridge Codex process 专项 | 150 项通过 |
| Mobile 全量 | 2572 项通过；4 项外部 SSH smoke 因环境未配置跳过 |
| Mobile 关键专项 | 7 个文件，229 项通过 |
| Mobile analyze | 0 error、0 warning、52 条既有 info |
| iOS Simulator Debug | Xcode 31.3 秒，成功生成 `Runner.app` |
| Git whitespace | `3fb83d12..HEAD` 的 `git diff --check` 通过 |
| 官方更新 | fresh fetch 后 `upstream/main` 仍为 `82962136`；`c2cc8379` 与 `97fb5aab` 均为当前分支祖先 |

Mobile 的 4 个跳过项需要外部 SSH smoke 环境，不是失败。Simulator
`Runner.app` 不是 IPA，也没有证明 APS entitlement、Face ID、Always Location、
Quick Look 真机行为或后台能耗。

## 5. 兼容矩阵

- 新 Mobile + 旧 Bridge：新增来源、连续性和文件节点能力均通过 capability
  或安全 fallback 降级；旧端不会被要求理解未知主动帧。
- 旧 Mobile + 新 Bridge：新增字段为 optional/additive；Bridge 不主动向不支持
  的旧端推送必须理解的新语义。
- 新旧 Codex 来源：durable provider/thread identity 是主键；运行时 ID、IP、
  项目路径、Ready/active 不是会话身份。
- Mirror/SQLite：仍是可重建副本，不写回 canonical provider history；本轮没有
  破坏性数据库迁移。
- 官方更新：本地能力集中在窄接缝与可回退提交。后续仍需按语义合并官方更新，
  不能用 ours/theirs 整文件覆盖。

## 6. 仍未越过的门槛

1. 没有部署新的 Cloud Function 或 Bridge，也没有切换运行中的 Bridge。
2. 没有为当前源码生成、签名或安装新的 IPA；已安装的 build 204 早于本轮多项
   深链、安全、通知、来源隔离和性能提交。
3. 没有发布 `owner` OTA，更没有晋级 `stable`。
4. 物理 iPhone 仍需验收：通知分级/去重/长按操作、Always Location、Face ID、
   JSON/HTML/Quick Look、文件下载分享、弱网重连、动画帧率与能耗。
5. 旧 Bridge + 新 App、新 Bridge + 旧 App 的真实进程组合仍需发布候选阶段验证；
   当前只证明源码 fallback 与自动测试。
6. 用户曾见的“中间过程/工具/最终回复整段重复”没有可复现事件线。若再次出现，
   先采集 `raw/provider → Bridge → Mirror/SQLite → reducer → render`，再修改
   owning layer。
7. 真正同时运行多个外部 Codex/Cockpit 写入者需要跨进程 source registry、
   lease 和冲突协议。用户当前明确顺序使用，因此它是未来能力，不是本轮源码
   完成声明的一部分。

## 7. 下一步门禁顺序

1. 用户确认进入可安装候选后，基于本分支生成高于 build 204 的新 IPA。
2. 先做 IPA 结构、架构、签名/entitlement 审计，再由用户决定是否安装物理设备。
3. 需要通知闭环时按 Cloud → Bridge → Mobile 的顺序部署，并保持旧端 fallback。
4. 真机验收通过后才考虑 `owner`；只有用户再次明确授权，指定 patch 才可晋级
   `stable`。
