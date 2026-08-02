# CC Pocket 项目交接手册

> 这是接手 CC Pocket 时的核心入口，只记录长期有效的工作规则、用户要求和架构边界。
> 当前版本、PID、端口、正在安装的 IPA、临时分支和发布进度都必须现场复核，不能从本文推断。

## 0. 先记住这些固定入口

| 入口 | ID / 路径 | 用途 |
|---|---|---|
| CC Pocket owner OTA 发布会话 | `019f8e9d-2490-79c0-817c-87e3eb93ea2f` | 反复执行 Mobile 发布、owner OTA 和发布证据核验；这是正常持久 Codex 会话，不是一次性 sub-agent |
| 当前权威源码工作树 | `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/current` | 后续开发、审计和发布交接的默认源码入口；任务仍需现场核对 branch、完整 HEAD 和 clean 状态 |
| 仓库总规则 | `CLAUDE.md` | 官方仓库规则和本文入口 |
| 长期产品决策 | `decisions.md` | 已采纳、废弃和待迁移的项目决策 |
| 本手册 | `docs/PROJECT_HANDOFF.md` | Agent 分工、兼容、发布、验证和核心产品约束 |
| Bridge 本地生产发布 SOP | `docs/bridge-local-production-release-sop.md` | 强制的 Bridge-only 本机候选、切换、回滚和验收流程；不授权其他发布层 |
| owner 文件、统一会话与本地翻译实施参考 | `docs/owner-file-access-preview-and-local-translation-plan.md` | 合并全盘只读、统一预览、文件变更二次授权、固定中文化、Apple 本地翻译，以及统一会话列表和前台全会话轻量增量同步；内容完整但实现前必须重新核对源码 |
| 全面修复与性能收束主方案 | `plans/mobile-comprehensive-remediation_v02_20260726-004125.md` | 当前权威方案；v01 已被它取代。源码行为已收束到 `fa3aa6db`，其后仅有台账/交接文档提交；物理设备、Bridge/Cloud 部署、签名 IPA 与 owner/stable 仍是独立门槛 |
| 本轮源码收束报告 | `reviews/SOURCE_CLOSURE_REPORT_20260728.md` | 记录 `3fb83d12..fa3aa6db` 的 29 个行为提交、最终源码门禁、兼容边界和仍未越过的设备/部署门槛 |
| 仓库、历史分支与工作树单线收束计划 | `plans/repository-branch-convergence_v01_20260728-190833.md` | 盘点 72 个本地分支和 19 个 worktree，区分已包含、语义整合、已取代、独立工具与两个脏工作树；当前为 draft，用户确认前不执行合并、清理、部署或发布 |

### 0.1 发布会话的使用规则

- 固定标题：`CC Pocket owner OTA 发布`。
- 用户只授权过上述发布会话。`019f8ff9-0945-72a3-a29e-c17df6f112e5`
  不是用户授权的协调入口，禁止向它或其他历史任务主动发送消息、完成回报、部署命令或
  纠正消息。旧文档或旧任务中相反的要求均已作废。
- 只有用户当次明确要求把构建、部署或发布交给发布会话时，当前任务才可以向
  `019f8e9d-2490-79c0-817c-87e3eb93ea2f` 发送一次完整交接；普通开发、审计、提交或
  状态登记不得自行联系任何其他任务。
- 默认保留该会话当前的模型和 reasoning effort；只有用户明确指定时才覆盖，不能由协调
  Agent 在恢复命令中顺便改写持久会话配置。
- 后续发布优先恢复上述会话，不能每次重新开一个发布 sub-agent，避免重复发布和丢失发布上下文。
- 每次恢复时仍要明确传入当次的绝对 worktree、branch、完整 HEAD、基础 IPA 版本、Shorebird release、目标通道和预期产物；不能沿用旧临时目录或旧版本事实。
- 该会话历史 cwd 是日期 worktree，只是旧任务宿主，不是源码权威。项目选择器显示该名称
  也不能用来推断当前源码；该旧 worktree 已清理，实际命令必须使用交接中的当前绝对
  worktree。若会话仍无法切换 cwd，应停止并报告，不能重建旧目录或从其他 checkout 猜基线。
- 该会话只负责用户当次授权的机械发布、发布前后通道快照和发布证据，不负责复杂语义合并。
- 源码与验证完成后，协调 Agent 应一次性发送包含全部允许/禁止边界、精确 HEAD、提交、
  Bridge SOP、OTA lineage 和回滚条件的完整任务，然后停止自行部署和逐步纠正。发布会话
  自己执行门禁、构建、切换、回滚与证据记录；只有遇到真实阻断或需要新增授权时才回报。
- 同一交接中可以同时授权 Bridge 和 owner OTA，但必须分别验收、分别报告；Bridge 成功
  不代表 OTA 成功，OTA 上传成功也不代表物理手机已经应用。默认仍禁止 stable、IPA、
  Cloud、Desktop 配置、网络和会话数据变更。
- 第一次遇到新流程要先人工跑通，再逐步脚本化确定性步骤。脚本负责检查和执行，模型负责解释冲突、原生差异、未知警告、lineage、签名和兼容风险。
- 项目级审批使用 `on-request` 和当前 reviewer。禁止用
  `--dangerously-bypass-approvals-and-sandbox`、`--ignore-rules` 或显式 `never` 恢复
  发布会话；这些覆盖会让项目中的 prompt 规则失效或把安全门禁整体绕过。
- 默认只发布 `owner`。`stable` 晋级、回滚、替换基础 IPA、安装真机和任何无法撤销的发布动作都必须得到用户单独明确授权。
- `019f8f65-adaf-74b0-bcff-65217586b2ee` 是误建且已归档的会话，不能当作发布入口。

如需从 CLI 恢复，使用：

```zsh
codex exec resume \
  --all \
  019f8e9d-2490-79c0-817c-87e3eb93ea2f \
  '<写明本次 worktree、HEAD、基础版本、目标通道和发布任务>'
```

## 1. 谁负责什么

### 用户

- 决定产品行为、视觉是否合格、是否安装真机、是否发布或晋级 stable。
- 动画和动态交互的最终视觉验收交给用户；Agent 完成构建后直接说明“现在请看哪一处”，不要用昂贵而不可靠的自动视觉检查替代用户判断。
- 用户要求先给 IPA 时，先交付已经完成验证的 IPA，再继续非阻塞性优化。

### 当前执行任务

- 掌握全局分支、基线、依赖和交错文件。
- 审核实际 diff、测试和兼容矩阵，决定 cherry-pick / 语义合并顺序。
- 统一安排官方更新、本地功能、Bridge 部署、Mobile 发布和最终验收。
- 不能仅凭 worker 的“已完成”结论合并，也不能未经用户指示把结果转发给历史任务。

### 实现 Agent

- 在独立 worktree 和任务分支工作。
- 只修改自己的任务范围；不得回滚或顺手提交其他 Agent 的改动。
- 未经授权不得合入共享分支、push、发布、替换运行服务、安装 App、rebase 或改写他人历史。
- 完成后在当前任务内向用户回报；未经用户明确指定，不向任何其他任务主动发送消息。

### 发布会话

- 复用累计的发布上下文，执行可审计的 Mobile/OTA/IPA 发布流程。
- 确认源码身份、基础版本、Flutter/原生边界、签名、owner/stable 前后状态和实际产物。
- 发现源码不干净、基础 lineage 不符、原生差异、未知 Shorebird 警告或上传状态不明确时必须停止并在当前任务内交给用户判断。

## 2. 产品与数据的基本架构

- Codex/Claude 官方运行时、app-server、CLI 和原始持久化记录是会话事实来源。
- Bridge 负责连接 provider、协议兼容、历史重建、实时状态、去重、能力协商和适合后端更新的策略。
- Mobile 是版本化宿主，负责交互、渲染、本地缓存、离线体验和 iOS 原生能力。
- 手机和 Codex Desktop 应呈现同一个会话、同一种运行状态和同一套有效配置，不能各自推测一份状态。
- 本地 Mirror/SQLite 是可重建缓存，不得反过来覆盖 canonical history。
- Bridge 不得向 Mobile 下发任意 Dart、Swift、JavaScript 或可执行代码。App 只调用基础 IPA 已内置且经 capability 声明的能力。

## 3. “兼容、独立、方便跟官方更新”的含义

用户要的是语义可合并，不是要求每项本地功能都能机械地一次 revert 后还原官方 tree：

- 官方代码与本地扩展的行为归属清楚；
- 一个用户可感知功能形成内聚 commit、测试和兼容说明；
- Bridge、Mobile、native、协议变更按真实依赖拆分；
- 与官方热点文件只保留少量稳定接缝，不为“可拆”制造层层 adapter 和散乱 feature flag；
- 官方更新先读懂上游语义，再保留双方行为，不能整文件选 ours/theirs；
- 格式化、codegen 和依赖噪声不能混入功能提交；
- 旧 App、旧 Bridge、新 App、新 Bridge的组合必须明确：支持、能力降级、隐藏入口，或提示更新基础 App。

新增协议字段默认可选、可加、可忽略。功能是否可用以 capability 为准，不能只看一个总版本号。未知未来字段保留 generic fallback，不能静默丢弃。

## 4. 更新边界与发布门禁

### 4.1 哪些优先放后端

优先由 Bridge 解决：

- provider/app-server 协议漂移；
- session 状态、watch、排队、guide/steer 和运行时所有权；
- live/history/Mirror 的统一语义转换和去重；
- lineage、工具类型、模型目录和旧客户端兼容下转换；
- 电脑端持续执行的自动审批策略。

通常需要 Mobile/基础 IPA：

- 新布局、交互、动画和本地数据库行为；
- iOS Quick Look、分享、通知、定位、拖放、文件选择等原生能力；
- 新 entitlement、插件、Swift、原生依赖、Flutter engine、Xcode 配置或需打包的新资源。

纯 Dart 改动只有在与当前 Shorebird 基础 release 严格兼容时才能 OTA。原生变化必须生成新的基础 IPA；Shorebird 可能不报错而忽略原生差异，因此不能把“patch 命令成功”当作能力已更新。

### 4.2 完成状态必须分开

以下是不同门禁，前一项不能冒充后一项：

1. 源码已实现；
2. commit 已审核并集成；
3. Bridge 已构建；
4. Bridge 已部署且实际 HTTP/WebSocket/协议检查通过；
5. Flutter 测试与 analyze 通过；
6. 模拟器构建、安装、启动成功；
7. IPA 已生成并通过包结构、架构和签名检查；
8. IPA 已由 AltStore/AltServer 重签并安装；
9. 真机启动和行为验收通过；
10. owner OTA 已发布，并在真机重开后确认生效；
11. 用户明确批准后，指定 patch 才能晋级 stable。

普通设备固定 `stable`；用户自己的设备使用 `owner`。owner 验证失败不能用 stable 覆盖问题，也不能未经授权自动回滚。

## 5. 会话、同步和历史的硬约束

### 5.1 身份与分支

- 会话、下载记录、常驻策略、fork、自动审批和本地缓存使用 durable provider thread ID；标题和消息文本不能做唯一主键。
- 相同标题的两个会话必须独立。
- Fork 使用 provider lineage；父子共享继承前缀是正常现象，不能因此合并历史。
- 当前正在运行时，旧回复仍可 fork；只有不具备稳定落点的最新临时输出不能 fork。
- 未经证明，不修改或删除原始 rollout、Codex 会话文件和 canonical history。

### 5.2 Desktop 与手机连续性

- Desktop 发出的消息、运行状态、流式回复、思考、工具、问题和完成状态要同步到手机。
- 用户不应必须打开会话页才开始同步。已激活且运行中的会话由 Home 的有界 watcher 跟踪；打开会话后转交 watcher，再做增量对账。
- 正在运行不等于禁止手机输入；在 provider 支持时，手机应提供与 Desktop 一致的排队、取消/修改排队和 guide/steer。
- 每次重连使用新的 generation；旧 session list、watch ack 和延迟帧不能重新取得所有权。
- iOS 后台不持续渲染流式内容；后台只保留系统允许的通知/轻量事件，回到前台后按 durable ID 和 sequence 增量补齐。

### 5.3 完整历史不等于一次渲染全部

- 完整下载表示本地有耐久副本，不表示 Flutter 一次挂载全部消息。
- 当前设计边界为每会话最多 100,000 个 normalized entries / 64 MiB；页面只挂载约 200 条可渲染 envelope。
- History 索引覆盖所有真实用户轮次；远距离跳转先显示加载状态，读取目标附近窗口，再定位。
- 大 JSONL、tool result 和 Mirror 使用有界流式、分页或增量读取。
- 性能修复不能靠静默截断历史、降低产品上限、显示零值或 metadata-only 冒充完整内容。
- 折叠状态下不构造和解析昂贵的工具详情；用户展开时再按 ID 加载。

## 6. 会话界面的核心行为

- 历史回合的“中间过程”是外层容器；每个临时 assistant 输出与它后续的思考/工具构成一个 segment。
- 工具结果按 tool-use ID 回到发起它的 segment，不能错挂到下一段临时文本。
- 最终回复在中间过程之外。
- 当前正在生成的最新临时文本以“当前进度/当前状态”显示在外面；其下只显示最新工具摘要，详情点击后再加载。
- TODO/plan 是与当前进度同层的实时卡片，项目勾选应原位更新；内部 `update_plan` 不能长期冒充“正在使用的工具”。
- 展开折叠必须在布局阶段保持点击标签的视觉锚点，并向下铺开；不能先跳动再用 scroll correction 拉回。
- 恢复或重新激活会话默认折叠全部历史中间过程；More 菜单提供“一键全部折叠”。
- 工具摘要默认只说明“做了什么”；命令、代码和长结果只在展开后加载。文件修改摘要只显示文件名和行数。
- 模型、思考强度、权限和 sandbox 的工具栏选择必须与 session 实际配置一致。未来设置可下一轮生效，同时保留明确的立即重启选项。
- Codex 引用本地图片时，Mobile 应显示同一图片；缺失或不可访问时给出清楚降级，而不是空白。
- Warning 可关闭；频繁 system/continue/config 提示要合并或抑制，不淹没聊天记录。

## 7. 权限、自动审批、通知和后台

- 权限切换要区分“下一轮生效（不中断）”和“立即重启”；不能声称未来设置影响了当前 turn。
- 恢复会话时以该 session 的真实配置恢复工具栏，不能无故回到 `on request` 或 `default`。
- 原生权限能力可提前纳入宿主 capability，但系统授权提示必须由明确用户动作触发。
- 自动审批只能有一个权威判断和一种紧凑 UI；外层显示汉化后的风险与结果，具体指令按需展开。
- 即使用户允许自动审批，也要保留风险分级、可审计记录和可立即关闭的入口。
- 自签名/免费签名是否具备远程推送能力必须用真机 entitlement、provisioning profile、系统注册结果和实际通知验证，不能从 Xcode 配置推测。
- 如果远程推送不可用，前台/应用内通知和回前台增量同步仍应正常；不能以“始终定位”伪装常驻网络后台。

## 8. 文件、预览和传输

- Codex 正常输出真实文件路径；Bridge 负责识别、安全映射并发出 Mobile 可点击的结构化链接。
- Agent 路径提取、Bridge artifact 映射、手动文件管理与 Agent 引用共用的
  `ArtifactPreviewScreen`、以及 Flutter 分享/下载都已经存在，不得重复实现。
  iOS 预览改为由设备上的 `QLPreviewController.canPreview` 做系统优先分流；
  JSON 属于 `public.text` 路线。Quick Look 不支持或启动失败时自动回落到有界
  本地预览器，未知二进制仍保留下载和分享。预览关闭后返回页仍要可左滑返回。
- owner 自用部署允许在 macOS 实际授权范围内全盘浏览、读取、预览和下载；
  文件入口明确分为手动文件管理和 Agent 文件引用两套。Agent 的原有工具机制
  不改，但它引用的本地路径由 Bridge 转成超链接后，预览和下载必须复用手动
  文件管理的 owner 全盘只读权限，不能再因位于 project 或旧允许目录之外而
  报 `path_not_allowed`。Mobile 直接发起的新建、写入、覆盖、移动、重命名、
  上传落盘和删除则由 Bridge 通过文件变更密码或 Secure Enclave + Face ID
  签名做一次性二次授权，不能相信客户端自报 `faceIdPassed`。完整设计见
  [`docs/full-disk-read-mutation-authorization.md`](full-disk-read-mutation-authorization.md)。
- Mac 与手机互传上限 15 GiB，预览上限 2 GiB；小文件用小块，大文件自适应到较大块，支持断点续传、校验和原子落盘。
- 发送前先检查 iPhone/Bridge capability；旧版本不展示无法完成的入口。
- 手机主页接收拖放时默认发送到电脑；会话输入区接收拖放时默认作为会话附件。
- 默认/非 owner 部署继续使用经授权的电脑目录；owner 全盘只读模式仍必须经过
  canonical path、symlink、遍历和文件身份检查。手动文件管理与 Agent 引用
  共用该只读 authority 和预览/下载管线；写操作额外执行二次授权、
  no-overwrite/原子落盘和执行前身份复核。
- 项目路径在允许目录之外时应返回明确错误和修复建议，不能无限重试。
- 上述 owner 文件能力、预览、本地翻译，以及统一会话列表与轻量增量同步的合并
  实施参考见
  [`docs/owner-file-access-preview-and-local-translation-plan.md`](owner-file-access-preview-and-local-translation-plan.md)。
  它是尚未实施的参考设计，后续任务必须先核对实际代码，不能机械照抄其中的
  capability、channel、状态机或实施顺序。

## 9. Git、worktree 和官方更新

开始任何实现前：

1. 确认真实仓库绝对路径、当前 branch、完整 HEAD、remote 和 `git status --short`。
2. 读取当前任务相关的 `CLAUDE.md`、本文和 `decisions.md`。
3. 多 Agent 并行时，为每个任务建立独立 worktree 和分支；worktree 路径使用绝对路径。
4. 记录起始基线；发现他人未提交改动时不能覆盖、stash、提交或“顺手整理”。
5. 运行问题先核对真实 PID、二进制、plist/入口、监听端口、日志和手机连接目标，再重启或部署。

提交按用户可感知行为和真实依赖拆分，使用 Conventional Commit。提交前检查 diff 与 status，排除构建产物、缓存、formatter 噪声和无关改动。

官方更新的正确顺序是：

1. 读懂上游 release/commit 的行为变化；
2. 在干净基线上集成上游；
3. 对热点文件做语义合并；
4. 回放本地窄 commit；
5. 运行 Bridge、Flutter、协议和历史回归；
6. 再由当前任务根据用户授权决定是否进入发布流程。

## 10. 最低验证与完成回报

### Bridge 改动

- 相关单元/集成测试；
- TypeScript build；
- 真实 WebSocket 协议、断线重连和旧客户端降级；
- 部署任务才检查单进程、监听、HTTP、WebSocket、Tailscale/局域网和日志。

### Mobile 改动

- 相关 Flutter tests；
- `flutter analyze`；
- iOS simulator build、install、launch；
- 交互/动画由用户视觉验收；
- 涉及性能时，模拟器只能做初筛，最终看真机。

### 历史与同步改动

- 短会话、超长会话、同名会话、fork、工具密集、运行中、断线重连、完整下载和远距离跳转；
- 同时对比 raw provider history、Bridge normalized 输出、Mirror 和 Mobile 可见结果；
- 不只用合成 fixture 证明真实数据问题已解决。

### 完成回报必须包含

1. 任务目标和实际完成范围；
2. repo/worktree 绝对路径、branch、起始基线；
3. 全部 commit 完整 SHA、顺序和依赖；
4. `git status --short` 与不属于自己的改动；
5. 关键文件和行为；
6. 执行过的测试、构建和原始通过/失败信号；
7. 剩余风险、冲突和建议合并顺序；
8. 旧/新 App 与 Bridge、协议、历史/存储数据、native-Dart 边界及上游基线兼容性；
9. 明确区分源码、部署、OTA、IPA、安装、真机和 stable 的完成状态。

实现 Agent 完成后只在当前任务内向用户回报，并保留分支和 worktree 供审核。
禁止自动向 `019f8ff9-0945-72a3-a29e-c17df6f112e5` 或任何其他历史任务发送消息。

## 11. 什么才算完成

只有当用户要求的那一层门禁真实通过，才可以说“完成”：

- 修代码：实现、测试、提交和兼容说明完成；
- 开后端：指定版本真实部署、单实例且协议可用；
- 给 IPA：交付可定位的 IPA，并说明签名与真机状态；
- 更新前端：owner 补丁真实存在、设备重开后确认生效；
- 合并：当前任务审完实际 diff、测试与依赖，并得到相应授权后集成；
- 发布 stable：必须有用户当次明确批准。

如果仍缺真机、视觉、安装、网络、签名或用户授权，只能报告“已到哪一层、还差什么”，不能用“应该可以”替代证据。
