# CC Pocket 手机端性能审计（2026-07-24）

## 审计边界

- 基线提交：`169155edb1922a51e3ab54e6d68462d4dc3e20cc`
- 独立分支：`audit/mobile-app-performance-20260724`
- 独立 worktree：`ccpocket-worktrees/mobile-performance-audit-20260724`
- Flutter：`3.44.0`；Dart：`3.12.0`
- 重点：长会话渲染、流式输出、会话镜像、本地存储、冷启动和应用级重建。
- 兼容边界：不修改 Bridge 协议、消息模型、镜像数据库 schema、折叠层级或 OTA/宿主接口。

本轮采用静态调用链审计、定向单元/Widget 回归测试和合成数据微基准。微基准运行于 macOS
Flutter test/debug 环境，只用于比较算法数量级；真实 iPhone 的首帧、掉帧、RSS 和能耗仍应使用
profile build 与 Instruments 验收。

## 已实施的优化

### 1. 流式输出按帧合并并隔离重建

问题：

- 每个文本或思考 delta 都执行一次不断增长的字符串拼接并发布状态。
- 当前进度区域的任意 delta 会重建整个区域；只更新思考时也会重新构建 Markdown。

改动：

- `StreamingStateCubit` 保留首个 delta 的即时反馈，后续以最长 32 ms 周期合并。
- 文本、思考、流式状态拆成独立 `BlocSelector`；折叠的思考更新不会重建 Markdown。
- `reset` 和 `close` 会取消计时器并丢弃已失效的待发布内容。
- 测试可显式传入 `Duration.zero`，保持依赖同步语义的状态/布局测试确定性。

10,000 个 8 字符 delta 的合成测试：

| 模式 | 状态发布次数 | 总耗时 |
|---|---:|---:|
| 每个 delta 立即发布 | 10,000 | 283,933 µs |
| 32 ms 合并 | 2 | 43,708 µs |

合并模式的总耗时包含约 40 ms 的等待窗口，因此主要收益应看状态发布从 10,000 次降为 2 次。

### 2. 复用文件路径后缀索引

问题：

- 每个可见消息气泡、计划卡和流式重建都会针对同一个项目文件列表重新
  `split/sublist/join`，构造完整路径后缀集合。

改动：

- 使用弱引用 `Expando` 按 `FileListCubit` 的不可变列表快照缓存后缀集合。
- 以单次斜杠扫描替代多次数组切片和 join。
- 返回不可修改集合，防止某个气泡污染共享索引；列表快照被释放后缓存可回收。

5,000 条路径、20 次查询的合成测试：

| 模式 | 总耗时 | 每次平均 |
|---|---:|---:|
| 每次重建索引 | 122,192 µs | 6,109 µs |
| 同一快照复用索引 | 6,515 µs | 325 µs |

同一快照下约减少 94.7% 的查询耗时。

### 3. 工具输出预览只扫描可见行

问题：

- 折叠卡只显示 5 行，但旧实现会对数 MB 工具输出执行完整 `split('\n')` 并分配所有行。

改动：

- 新增有界行预览函数，只寻找前 N 个换行符。
- 保持尾随换行、是否存在更多内容和展开行为与旧逻辑一致。

2,288,889 字符、100,000 行、20 次预览的合成测试：

| 模式 | 总耗时 |
|---|---:|
| 完整 split | 177,936 µs |
| 有界扫描 | 330 µs |

该数据集下约减少 99.8% 的预览计算时间，并避免分配 100,000 个行字符串。

### 4. 镜像尾部分页改为 ordinal 范围查询

问题：

- 镜像初始窗口通常从 `entryCount - 200` 开始；SQLite 的 `OFFSET` 仍需步过此前所有索引项。

改动：

- 利用活跃 generation 的连续、零起始 ordinal 不变量，以
  `ordinal >= requestedOffset ORDER BY ordinal LIMIT ...` 直接定位。
- 公共 API、返回顺序和 ordinal 连续性校验不变。

100,000 行、读取末尾 200 行、40 次查询的内存 SQLite 合成测试：

| 模式 | 总耗时 | 每次平均 |
|---|---:|---:|
| OFFSET | 261,039 µs | 6,525 µs |
| ordinal 范围 | 15,241 µs | 381 µs |

该数据集下约快 17.1 倍。

### 5. 镜像启动清理从小型 staging 集合出发

问题：

- 每次打开镜像数据库都对整个 entries 表执行 `DELETE ... WHERE NOT EXISTS`。
- 数据库允许增长到数百 MiB，即使没有中断传输也会支付全表扫描成本。

改动：

- 先读取通常为空或很小的 staging generation 集合，只删除这些明确中断且非活跃的
  shadow generation。
- staging marker 与 shadow 写入位于同一事务；正常激活流程仍主动删除旧 generation。
- 保留 active-generation 防护，遇到不一致数据时优先保留最后可用副本。

### 6. 缩短首帧关键路径并收窄全局重建

改动：

- 语法高亮定义/主题加载和文件传输 orphan 清理改为首帧后执行。
- 延迟高亮完成后清空首帧 fallback span 缓存，再触发一次重建，避免深链接代码块永久使用旧缓存。
- `MaterialApp` 只监听主题、语言、正文缩放和代码字体设置；FCM 等运行状态改用独立 listener，既避免无关全局重建，也保留代码字体的实时刷新。
- Prompt History 对同一 Bridge 的并发同步使用 single-flight，避免网络抖动导致重复 WebSocket
  和重复全量写库。

## 已确认但本轮未直接修改的热点

以下问题收益可能更大，但需要 Bridge/协议、数据库 schema 或列表架构的独立设计和压力测试，
不适合混进本轮低耦合提交：

1. 首页会为最多 30 个空闲 Codex 会话建立 continuity watch；每个 Bridge monitor 还包含文件 watcher
   和 750 ms 轮询。应改为 active/visible/recent 优先、延迟冷历史和自适应空闲轮询。
2. 镜像每个小 patch 仍会在写事务内扫描整个 active generation。应改为 touched id/ordinal
   点查和 metadata 增量，但需完整覆盖删除、重排与完整性回退。
3. Bridge resident watch 会长期保留完整消息 snapshot。应研究只保留 hash/ordinal diff index，
   并在传输后释放正文。
4. 用户消息索引使用 `json_extract(message_json, '$.type')`，大历史仍是 O(N)；优化需要数据库
   schema/file-version 边界。
5. 首页 recent/active 去重存在 O(recent × active) 派生计算，项目分组也会构造较大的固定 children；
   应在 Cubit 中建立稳定派生状态并逐步迁移到 builder/sliver。
6. 其他中优先级项：mDNS 生命周期、运行时 Google Fonts、Git 图片 diff 缓存字节上限、
   Artifact 下载进度按 chunk 重建、会话状态动画和 Max/Ultra 火焰的真机能耗。

## 兼容性与回滚

- Bridge、旧 App、消息类型和能力协商没有变化。
- 镜像 schema 与数据库文件名没有变化；分页只替换等价 SQL。
- 折叠结构、展开锚点、当前进度信息结构和工具映射没有变化。
- 每项优化按功能拆分提交，可单独 revert；不需要整体撤销或修改官方代码接口。

## 验证清单

- 流式合并：首 delta 即时、文本/思考不混合、reset 不发布过期尾包。
- 长中间过程：外层折叠、13 个工具展开锚点、当前进度和全局收起。
- 路径语法：相同列表快照复用、不同快照隔离、共享集合不可修改。
- 工具预览：短文本、边界行、尾随换行、100,000 行大文本。
- 镜像：中断 generation 清理、250 条分页、offset-without-limit、重启保留。
- 启动兼容：延迟高亮缓存失效、文件传输完整测试、Prompt History single-flight。
- 定向回归：上述相关测试共 347 项通过。大并发组合运行时，一个文件传输恢复用例曾触发
  30 秒测试超时；该文件单独完整复跑 54 项全部通过，失败用例单独复跑也通过，判定为测试
  进程资源竞争而非稳定回归。
- 最终 selector 修正后，代码字体设置和延迟高亮缓存的 4 项定向测试再次通过。
- 静态检查：`flutter analyze --no-pub` 无 error/warning；仓库现有 49 个 info。
- 构建门槛：iOS Simulator debug build 通过；完整首次构建 617.1 秒，最终改动后的增量构建
  38.5 秒。

合并前仍建议在真实大历史会话上完成 Flutter profile + Instruments 验收，重点观察：

- 流式运行时 UI/raster frame time 与 Markdown build 次数；
- 10k/100k 镜像的首次打开、跳转历史轮次和 RSS；
- 冷启动 time-to-first-frame；
- Max/Ultra 动画开启时的 CPU、GPU 与能耗。
