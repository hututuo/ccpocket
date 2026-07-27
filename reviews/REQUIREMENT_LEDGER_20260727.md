# CC Pocket 原始需求实现台账

最后核对：2026-07-28
当前分支：`fix/mobile-comprehensive-v02-20260726`
核对源码基线：`97fb5aab`
产品语义权威：`plans/mobile-comprehensive-remediation_v02_20260726-004125.md`

## 使用规则

本台账以用户原始要求和 v02 总方案为准。`COMPLETION_REPORT_20260727.md`、
`FINAL_REPORT_20260727.md` 只证明对应审查批次曾完成，不能替代产品需求验收。

状态含义：

- **已验证**：当前源码存在，并有本轮或仍适用的自动回归证据；
- **代码完成，待设备/部署**：源码和自动验证已完成，但真实 Bridge、Cloud、
  基础 IPA、签名或物理 iPhone 尚未证明；
- **部分完成**：已有关键基础，但仍有用户可见语义或深层稳定性缺口；
- **未实现**：当前源码尚未提供用户要求的行为；
- **实现偏离/回归**：存在实现，但与用户最终确认语义不符；
- **待事件线取证**：静态代码无法证明根因，必须采集真实故障链后再改。

## 1. 首页、会话目录、缓存与持续同步

| 原始要求 | 方案位置 | 当前提交/源码证据 | 当前状态 | 验证证据与剩余门槛 |
|---|---|---|---|---|
| 连接 Bridge 前不能自动跳离 IP/机器页；不能用无上下文中央加载替换连接页 | v02-001、v02-008 | `session_list_screen.dart` 的 `_SessionListConnectionUiGate`；`271e2d9b` 隔离连接代次并确认外部深链 | **已验证** | presentation gate 回归覆盖未就绪、升级中、重连、旧连接迟到与外部深链确认；仍需真机弱网视觉复核 |
| 初始 `session_list` 即使早于“已连接”事件到达，也必须继续请求 `list_recent_sessions`，不能卡在“已连接、正在进入会话” | v02-001、008、011 | `dfc83aa7` 的 `SessionCatalogBootstrapGate`；`351d0444` 以连接 epoch 校验 recent catalog 权威性；`576c90a8` 分配 build 204 | **代码完成，待设备/部署** | 两种事件顺序、重复代次、selection pending 共 54 项 Home 回归通过；同目标重连目录 41 项 BridgeService 回归通过。build 204 IPA 已构建审计，待 AltStore 安装和真机确认 |
| 外部会话深链在解析异常或连接流关闭后必须退出加载态，不能永久转圈 | v02-001、006、008 | `5ca11c83`；`SessionLinkCubit` 失败安全状态；`BridgeService.resolveSessionLink` 处理连接流关闭 | **已验证** | 两个定向文件 48/48 通过，覆盖 resolver 抛错和连接状态流无元素；该提交晚于 build 204，需后续安装包再做设备验收 |
| 首页不能先显示整页 `(no description)` | v02-008、v02-011 | 目录 readiness 与缓存 projection 已分离；会话目录先使用持久摘要再接 live | **已验证** | 目录/连接定向回归已通过；仍需大目录真机首屏计时 |
| 所有持久会话都能直接打开和继续使用，不再要求先“激活” | v02-003、010、012、015 | `15f08b93`、`4f7ff483`、`92d6a46b`；`PendingSessionBinding`；Codex/Claude screen | **已验证** | 直开、缓存预览、后台 attach、页面租约和幂等投递回归通过 |
| 普通 idle 不显示 Ready；working/needs-you/unknown 是正交事实，unknown 不能伪装 Ready | v02-003、014、015 | `15f08b93`、`4c215776`；`session_visual_status.dart` | **已验证** | 状态模型 267 项相关回归通过；unknown 原值保留 |
| 最近使用会话排在上面；已下载只显示勾号，不占独立顶部区域 | v02-003、004、011 | unified session projection、download marker、排序 reducer | **已验证** | 排序与投影回归已保留；需真机长目录视觉复核 |
| 目录和摘要跨启动缓存；至少近期会话无需每次重读 | v02-004、010～012 | `SessionCatalogCacheRepository`、conversation hot windows；`b5963c63`、`2b08c02b`、`a1ecfb1f` | **已验证** | SQLite round-trip、代次、损坏快照退避及重开回归通过 |
| 最近至少 10 个热会话保留尾部窗口，重连只追增量 | v02-004、012、015 | hot-window 上限 2000、cursor/revision、`ConversationContentSyncService` | **已验证** | hot-window replace/patch、known revisions、重连 cursor 回归通过 |
| App 在前台但未点开会话时也自动更新；热会话秒级、冷会话低频；计算主要放 Bridge | v02-010、011、015 | `packages/bridge/src/local-features/conversation-content-sync.ts`；Mobile subscribe/ack；`b0255c68` 公平保留 Claude/Codex 目录监视容量；`93d02cf1` 调度优先级老化 | **部分完成** | provider monitor 与正文 scheduler 两层饥饿路径均由红测复现后闭环；超大目录扫描成本、provider rewrite 和真实多会话延迟仍需性能审计 |
| 当前打开会话优先追平，但不能阻塞其他会话；Mobile 不能创建 N 个轮询 timer | v02-015 | Bridge scheduler + Mobile 单服务订阅；无 per-card timer；`93d02cf1` | **已验证** | 红测证明旧实现持续 focused 更新会让另一会话到第 21 次才读取；优先级老化后限制在第 4 次以内，7 项 content-sync 回归通过；最终真实多会话压力计时仍归入总性能门禁 |
| 设置中一键清可重建缓存；已下载完整历史逐项删除 | v02-004、013、014 | `15e946b5`、`704b5e09`；`cache_management_screen.dart` | **已验证** | 12 项缓存/设置回归通过；标题读取从 N 次 SQL 降为每 300 项一批 |
| 已有会话显示“加载/同步”，只有新线程显示“创建” | v02-005、012 | durable-open 与 pending binding 路径分离 | **已验证** | 会话直开和 pending attach 回归通过；真机文案扫描仍待本地化批次 |
| runtime 长期停在 `starting` 时不能每 3 秒无限重读历史；弱网恢复仍要可重试 | v02-010、012 | `502b4252`；一次性退避 timer、断线暂停与重连预算 | **已验证** | 红测把旧实现虚拟 5 分钟内的 101 次请求固化；现为初始 1 次加最多 4 次指数退避，离线期间 0 次新增、重连后恢复有限预算；ChatSessionCubit 147 项全通过 |
| 同一会话并发增量对账必须 single-flight；后台请求不能降级前台完整回退权限；重连不能让旧 socket 的请求吞掉新请求 | v02-010～012 | `7d62f978`；`BridgeService` 的连接代次、升级式 fallback 与 dirty follow-up | **已验证** | 旧实现三个并发调用会发送 3 次 delta，且最后一个后台调用可覆盖前台回退权限；现同一连接只发 1 次，响应后至多补 1 次 dirty follow-up，使用已更新 cursor。后台单独请求仍不做全量回退，前台权限只能升级；同目标重连重新发送并隔离旧代。Bridge usage + legacy fence 53 项、定向 analyze 与 diff check 全通过 |
| 双 Cockpit/Codex 实例不能串目录、续接、未读或缓存 | v02-007、011 | `bc0601b7`、`a35cc591`、`b5963c63`；Bridge identity 分区 | **部分完成** | Mobile/Bridge 分区和迟到帧隔离已有；`CODEX_HOME`/来源注册表与真正双写冲突策略仍未完整实现 |
| 运行蓝条与“正在同步历史”的光晕分别表达，且动画低开销 | v02-010、012、014 | 小 selector、独立 sync state、`RepaintBoundary` | **代码完成，待设备/部署** | 代码与 Widget 回归已有；需真机动画、CPU/能耗和可读性验收 |

## 2. 历史、折叠、渐进披露与时间

| 原始要求 | 方案位置 | 当前提交/源码证据 | 当前状态 | 验证证据与剩余门槛 |
|---|---|---|---|---|
| 首屏保留最近 5 个根回合和轻量中间输出，工具详情默认预算 200 | v01 5.1、5.4；v02-014 | turn-aware history envelope、`history_tool_details` capability | **已验证** | Bridge parser/websocket 与 Mobile history 相关套件通过 |
| 向上滑按 keyset/ordinal 增量加载；折叠详情按需取 | v01 5.2～5.4；v02-012 | history page/tool-details 协议与请求关联 | **已验证** | 分页、迟到响应、断线终止及工具详情回归通过 |
| 展开的工具过程最多约 8 行，框内滚动，并有清楚边界 | v02-009、013 | `ChatProcessLayout`、bounded process viewport | **已验证** | process disclosure 回归覆盖高度、滚动和两层结构；视觉仍需用户验收 |
| 增量更新、分页和 thinking 切换不能把用户展开状态收起 | v02-009、012～013 | `8d04d5ed`；partial→canonical turn key alias migration | **已验证** | 29 项布局/披露测试通过，含分页前后 13 个内层 disclosure 保持展开 |
| 展开后 thinking、工具和结果在同一个框内；折叠时才在当前进度显示摘要 | v02-009、013 | unified process surface 与 current-progress selector | **已验证** | process tree/viewport 回归通过；流式真机会话视觉待复核 |
| 中间过程/工具/最终回复不能整段重复两次 | v02-010、012；v02-014.9 | canonical identity、history generation、dedup state | **部分完成** | 多条已知重复路径已修；仍缺用户真实故障会话的 raw→Bridge→Mirror→reducer→render 五层快照 |
| UUID 回填和原地历史修订必须让断线/后台客户端收到，且不能靠追加重复消息实现 | v02-010～012 | `e984ca36`；通用 history mutation reset revision | **已验证** | 红测证明旧实现只改旧 seq，`getHistorySince` 永远返回空 delta；现仅在 UUID/时间确有变化时推进 revision，并通过旧客户端已支持的 reset snapshot 返回原位置的单份消息；相同回声不重复推进版本 |
| 两条无 UUID、文本相同的用户消息不能互相串图片或时间来源 | v02-010～013 | `f70db62d`；历史替换时的强身份优先、按出现顺序单次消费 | **已验证** | 红测中旧单值 text map 让第一条 `[1,2,3]` 图片错误变成第二条 `[4,5,6]`；现 UUID/clientMessageId 优先，文本仅作一次性顺序兜底，两个明确不同的强身份不强并；ChatSessionCubit 148 项通过 |
| 消息显示电脑实际接收时间到秒；时间紧凑融入消息，不占整行 | v02-005、009、013 | `receivedAt` provenance、`ChatMessageTimestamp`、`e0fa43f0` | **已验证** | 混合 ISO 时间比较和多类消息布局回归通过；长文本视觉待验收 |
| Guardian 风险归到对应工具下，只显示最新一条并 3 秒消失 | v01 8.3；v02-009 | approval tool identity + timed notice | **已验证** | `guardian_approval_notice_test.dart` 等回归保留 |
| Plan 首次退出未选择后，审批仍能恢复 | v01 8.2；v02-014 | Bridge pending ledger、Mobile pending merge | **已验证** | plan permission restart 和重叠恢复回归通过 |

## 3. Side Chat、悬浮小窗、权限、Goal 与额度

| 原始要求 | 方案位置 | 当前提交/源码证据 | 当前状态 | 验证证据与剩余门槛 |
|---|---|---|---|---|
| Side Chat 必须调用官方 ephemeral thread/fork，复用已有会话 UI，不自造持久会话类型或硬编码口述过期时间 | v01 7.1；v02-014 | `c5d29d39`；Bridge ephemeral capability；原生会话 pane | **代码完成，待设备/部署** | Side Chat 定向回归通过；需新 Bridge 与真实 Codex app-server 验证官方生命周期 |
| 关闭临时会话后，在官方仍存活期间能从辅助入口找回 | v01 7.2；v02-002 | auxiliary registry；`1d99e1cd` 按 Bridge 隔离 | **已验证** | 12 项 registry/Bridge 切换回归通过 |
| 真正非模态、可拖动、贴边收纳、点开原地展开的小窗；展开时仍能操作底层会话 | v02-002 | `6041395b`、`a3d87745`；`auxiliary_floating_dock.dart` | **已验证** | in-tree overlay、拖动、贴边 pull-tab、位置持久化 4 项 Widget 回归通过；需用户视觉验收 |
| 进入/附着会话不能把权限莫名改回 `on-request` | v01 2A.4、8.1；v02-003 | unknown factual state 保留、Side Chat 不伪造、`4c215776`；`4528efa8` 禁止把未知审批策略伪造成 `on-request` | **已验证** | collaboration-only 原地更新和重启两条专门回归通过；若真机仍再现，说明是另一条 override/indexed settings/connection epoch 路径，必须先采集事件线再改 |
| 新建会话不再报 `No thread ID available for goal lookup` | v01 8.4；v02-014 | Goal 延迟到 durable thread authoritative init | **已验证** | Goal/codex controller 回归通过 |
| 选择 5.3 Spark 时额度圆环自动用 Spark 卡片 | v01 9.2；v02-014 | exact model ID usage selector | **已验证** | usage service/widget 回归保留；旧 Bridge 有兼容 fallback |

## 4. 通知、未读、本地化与后台

| 原始要求 | 方案位置 | 当前提交/源码证据 | 当前状态 | 验证证据与剩余门槛 |
|---|---|---|---|---|
| approval/question/completion/failure/progress 分级通知真正生效并本地化 | v01 10.1～10.5；v02-014 | Bridge projector、Cloud filter、Mobile notification preferences；`967210ff`、`029eb93c` | **代码完成，待设备/部署** | FCM 后台 handler 已提前到 `runApp` 前注册，未知冷启动生命周期也会先挂接 BGAppRefresh handler；Bridge/Mobile/Cloud 定向测试已有；progress 默认关闭，必须显式开启；真实 Cloud/Bridge/FCM/APNs 未重新部署验证 |
| Always Location 后台保活时只收轻量投影，不解析/渲染正文；回前台增量追平 | v01 10.1～10.2；v02-015 | background-location host、delivery mode、notification-only whitelist；`b84a926a` | **代码完成，待设备/部署** | 后台协商现在以 Bridge 返回的真实 active work 为准，并处理 capability 晚到；Simulator/单测证明接线；物理 iPhone 权限、系统回收、低电量、温控、AltStore entitlement 未验收 |
| 会话完成后列表显示未读蓝点，打开可见后再清除 | v01 10.3；v02-014 | durable unread ledger；`bc0601b7` 按 Bridge 隔离 | **代码完成，待设备/部署** | 多 Bridge ledger 回归通过；需真实通知→列表→打开闭环 |
| 长按通知可 Allow/Reject，Bridge 最终权威复核 | v01 10.4～10.5 | iOS notification category/action + opaque identity；`3226eafb` | **代码完成，待设备/部署** | 小数秒 action 解析已回归；物理 iPhone 长按动作、Face ID/签名待验 |
| FCM 与定位保活 WebSocket 不能让同一事件重复弹两次 | v01 10；v02-014～015 | `e53dfb82` 增加 additive `deliveryId`/本地展示 ACK、750 ms FCM 安全兜底和 WS-token 关联；`84f2db77` 让 Cloud 只排除已确认本地展示的 token | **代码完成，待设备/部署** | Bridge 相关 431 项、Cloud 24 项、Mobile 16 项与 5 文件 analyze 全通过；本地展示失败或旧 Mobile 无 ACK 时仍发送 FCM。旧 Bridge/旧 Cloud 忽略加法字段且不丢通知；真正去重需 Cloud、Bridge 与新 Mobile 全链部署，并在物理 iPhone 验证前后台各只出现一次 |
| 手机固定 UI 文案中文化；命令、代码、路径和 provider 原文不机械翻译 | v01 12；v02-014；decisions | `5562e535`、`5cd90b8f`、`50e60902`、`f23c9187`、`b431221c`、`932f8bec`、`bfe4bd5a`、`72a96edc`、`b197f0d6`、`77305280`、`6e2b46fb`；ARB + feature strings | **部分完成** | 会话状态/审批、Explore、Git、文件传输、slash command、二维码、截图、工具活动/运行过程，以及主题、许可、Bridge 设备、终端名、Codex 权限/沙箱/速度和辅助语义已补四语言。会话轮次、渐进工具详情、完整 Diff、首页/输入框拖放和悬浮临时会话原先的中英二选一也已补日/韩并移除所有实际二元分支；扫描剩余 6 个 `_zh` 均属于同时含 `_ja/_ko` 的四语言类。ARB 四语言键集由回归强制一致，57 个生成器会静默忽略的中文死键已移除且仍可从 Git 历史恢复；新增/相关 56 项回归、Home 54 项及 14 文件 analyze 通过，只有既有 Markdown `imageBuilder` deprecation info。剩余领域错误映射和其他长尾固定文案仍需量化扫描后收口 |

## 5. 文件、预览与安全

| 原始要求 | 方案位置 | 当前提交/源码证据 | 当前状态 | 验证证据与剩余门槛 |
|---|---|---|---|---|
| 手动文件管理与 Agent 引用保留两套入口，但共享同一读取、预览、下载和分享能力 | v01 11.1；v02-014 | artifact registry/candidate、file browser、统一 preview route；`c4b3174d`；`6f6797e9` | **部分完成** | 既有路径自动链接未重复造轮子；无行号 Agent source 引用在 iOS 优先进入与手动文件管理相同的 Quick Look/WebView/下载/分享页；带行号引用保留精确 File Peek，并可从标题栏进入统一预览。旧 Bridge 不支持 artifact resolve 时仍退回 File Peek；通用 artifact HTTP 下载与 File Browser 可续传下载仍是两种实现，待在不牺牲断点续传的前提下收束 |
| owner 模式允许全盘只读，项目外引用不再 `path_not_allowed` | v01 11.2～11.3 | authenticated unrestricted read；`ba839504` 未认证安全回退 | **代码完成，待设备/部署** | 新旧 Bridge fallback 已测；实际运行 Bridge 的 API key/`*` 配置仍需核对 |
| 修改/上传/删除必须密码或手机 Face ID，由 Bridge 授权；密码失败不可重连绕过 | v01 11.4 | Argon2id verifier `60bc259d`；native biometric challenge；`e95f1772` | **代码完成，待设备/部署** | 7 项 auth 测试覆盖并行失败、断线重连和限流；物理 Face ID/Secure Enclave 待验 |
| 受限目录不能借项目、附加写目录或工作树符号链接穿出授权根；全盘 owner 模式不受误伤 | v01 11、19；v02-006 | `25b37014`、`47e2dc81`；真实路径校验、受管工作树成员校验 | **已验证** | 漏洞均先由红测复现；WebSocket + worktree 两文件 289/289 通过，覆盖 start、Git diff、附加写根、客户端工作树、未注册删除目标和前缀碰撞；`allowedDirs=[]` 的既有全盘兼容套件保持通过 |
| JSON、单文件 HTML、网页 URL 正确分流；Quick Look 失败走本地/WebView；提供下载/分享 | v01 11.5；v02-006、014 | `3c1985e5`、`435c3613`、`a4ecdf58`、`c4b3174d`；`56393144`；`5e1a72d0`；`6f6797e9`；artifact preview/File Peek | **部分完成** | `.json/.html` 路由、本地大文件 Quick Look、过期 token 自动续签和条件入口回归通过；iOS WKWebView 不提供 request/response URI 的主页面 401/403/404/410 已能进入错误页并续签；Bridge 给 Mobile 的文本预览限制为 512 KiB、单行限制为 64 KiB，1 MiB 单行 JSON 不再整段进入手机布局；Agent source 也已接入同一 Quick Look→WebView fallback 与下载/分享页。Mobile 预览/Quick Look/source/File Peek 39 项、Bridge WebSocket 253 项通过；两套下载实现、无 artifact 身份的 File Peek 大文件错误入口、压缩 JSON 和真实设备失败样本仍待统一/取证 |
| Agent 输出的内联图片、绝对 URL、data URL 与相对 Bridge 路径都能正确预览 | v01 11.1、11.5；v02-006、014 | `3ac720fe` 的 `resolveImagePreviewUrl` | **已验证** | 已有 scheme 不再被错误拼接 Bridge 地址，协议相对和无斜杠相对路径统一解析；7 项图片边界回归通过 |
| Explorer/Git 的旧 Bridge 无 requestId 时也不能串项目或无限加载 | v02-006；全局兼容门禁 | `f1f0dd04`、`3fc46236`、`935b5604`、`f8438e15`、`8374d105` | **已验证** | Explorer 16 项、Git 44 项、Bridge parser/websocket 411 项相关回归通过 |
| Bridge/手机握手做全面安全审查，但不把密码哈希放热路径，不破坏旧客户端 | v01 11、19；decisions | Origin gate、API key、路径/TOCTOU、Argon2、capability fallback；`25b37014`、`47e2dc81` | **部分完成** | 受限项目/附加写根/工作树的 symlink 与成员校验已闭环；审批参数绑定、auto-approval state、下载 token 与协议级重放等仍需逐项判定，且不能违背用户明确的 owner 全盘只读需求 |

## 6. 稳定性、兼容、官方更新与最终门槛

| 原始要求 | 方案位置 | 当前提交/源码证据 | 当前状态 | 验证证据与剩余门槛 |
|---|---|---|---|---|
| 发现确定性 bug 可顺手修，但必须先找 owning layer 和红测，不能见现象就改 | v02-006；PROJECT_HANDOFF §9 | 本轮窄提交、request/generation/Bridge partition 回归 | **持续门禁** | 所有新增修复继续要求先证实、再改、再定向回归 |
| 会话同步、排序、折叠和进程重启整体稳定 | v02-010～013 | generation fence、half-open continuity、outbox、dedup、pagination alias、`b0255c68`、`93d02cf1`、`502b4252`、`7d62f978`、`e984ca36` | **部分完成** | watcher/provider、公平队列、starting history、delta single-flight 已闭环；Desktop 接管现保留 live history/revision/identity 并消费已预取 canonical history，销毁同步 exit 也不能再回写死会话。legacy full-history 仍无 requestId，真实重复事件线和 provider/source 多 Home 仍有高风险审查积压 |
| 畸形或未来版本工具输入不能在展开 Diff 时崩溃整张会话卡片 | v02-006、009、014 | `0b83e6aa` 对 Edit/MultiEdit/Write 输入做完整形状校验 | **已验证** | 26 项 parser 回归通过；不完整 MultiEdit 会安全回退而不是渲染误导性局部 diff |
| 多开 Bridge/SDK/Codex 进程不能由旧代迟到事件覆盖新代 | v02-007、010～012 | `a4dbf3c1`、`320f1189`、`a35cc591` | **已验证** | SDK 100/100、Codex 144/144 相关回归曾通过 |
| 发送大图不能在 Mobile UI isolate 同步 Base64 编码；图片后立即发送的文字不能越序；编码失败或离线取消不能堵塞/迟到发送 | v02-006、014；全局性能门禁 | `99979115`；`ChatSessionCubit` 的可注入图片编码器和有序 input dispatch tail | **已验证** | 红测证明旧路径会同步发送两条消息、完全绕过异步编码器；现生产默认用 `compute` 编码，只有存在图片/既有 backlog 时进入顺序队列，纯文字无 backlog 仍同步发送。编码失败标记本地消息失败但继续后续消息，离线取消会 fence 尚未完成的编码；4 项窄测试与 ChatSessionCubit 152/152 全通过，定向 analyze 仅保留 2 条基线 info |
| 内联 data URL 与生成图片不能在聊天列表/气泡 `build` 中重复 Base64 解码 | v02-006、014；全局性能门禁 | `94372778`；`data_image_decode.dart`、`AsyncDataImage` 和生成图片延迟映射 | **已验证** | 红测证明旧 mapper 立即物化 bytes，气泡也绕过异步 decoder；现 64 KiB 以上在 isolate 解码，小图保留低开销同步 fast path，最多缓存 8 份压缩字节，列表映射只保留 data URL。网络图片、磁盘 cache key、缩略图 decodeWidth 和全屏无界缩放语义不变；37 项图片/预览/macOS chrome 回归与 10 文件 analyze 通过 |
| 图片草稿和待发送附件不能在 App 启动时全量 Base64 解码，也不能在每次编辑时阻塞 UI；慢的旧写入、删除和迁移不能复活过期草稿 | v02-006、014；全局性能门禁 | `7c91196e`；`DraftService` 的原始编码缓存、懒解码、异步编码和每会话 generation fence | **已验证** | 红测证明旧构造器会立即解码全部持久图片，注入的异步编码器也没有真正接管待发送消息；现只在首次读取对应会话时解码，64 KiB 以上编码移到 isolate，小附件保留同步 fast path。相同 client ID 的新编辑优先，过期编码失败不会拒绝新值，删除会隔离未完成写入，冷迁移直接复用旧 JSON 且存储 schema/key 不变；DraftService 23/23 与 2 文件 analyze 通过 |
| 新旧 Mobile/Bridge、官方项目和 schema/API/native-Dart 边界兼容 | v02-006、014；PROJECT_HANDOFF | capability negotiation、additive fields、legacy lanes、无破坏性 DB 迁移 | **持续门禁** | 每个提交均保留 fallback；最终仍需旧 Bridge + 新 App、新 Bridge + 旧 App 组合回归 |
| 合并官方最新 commits | v02-014 | `c2cc8379` 语义整合官方 `3289ce93`；`97fb5aab` 同步 `1.109.3` 并保持本地 build 单调递增；本轮 fetch 的 upstream/main=`82962136` | **已验证** | 同一 Claude/Codex 会话的通知或深链会优先揭示现有路由，会话 ID 重启后以实时身份而非旧参数匹配；Codex 深链保留 provider。52 项导航/解析/重启/活动会话回归通过，6 文件 analyze 无问题。官方 build `202` 低于已经交付的本地 build 204，因此本分支采用 `1.109.3+205`，未伪装成官方原始构建号 |
| 全部功能后做全软件性能、安全和兼容审查 | v02-006、014 | 已有阶段性 perf 修复与本台账 | **未完成** | 需在功能收束后执行全 Bridge/Mobile 测试、analyze、iOS Simulator build、热点基准、安全复审和产物清理。官方导航联合回归另外确认两个 WorkspaceShell 用例会因 `_LegacyExploreLane` 关闭时遗留 12 秒 quarantine timer 失败；它不在本次导航改动路径，但必须在后续性能/生命周期批次先红测再修 |
| Bridge 部署、IPA、真机、owner/stable 各自独立，不得混称完成 | v02 H；PROJECT_HANDOFF §11 | build 204 记录：`runs/20260728-005152_ccpocket-build204-ipa/` | **部分完成** | `576c90a8` 已构建并审计未签名 build 204，专供目录启动竞态验收；当前源码已前进到 `97fb5aab`，后续深链、安全、通知 ACK、公平调度、历史/会话管理，图片发送、iOS HTTP 错误识别、Bridge 预览限幅、Agent 统一预览、草稿性能、本地化完整性/四语言收束，以及官方 1.109.3 导航修复均不在 build 204。未部署新 Cloud/Bridge、未安装真机、未发布 owner/stable |

## 7. 当前独立复审闭环

用户要求的独立 Agent 复审发现中，P1/P2 已全部在当前分支闭环：

- 离线待挂接消息持久化与幂等：`a4007c6d`
- continuity watch 熔断后的半开恢复：`ae7b9397`
- 旧 Bridge Git 迟到/破坏性响应隔离：`935b5604`
- 多页面共享 pending binding 租约：`6894a494`
- unknown raw status 保留：`4c215776`
- 悬浮窗贴边收纳与位置记忆：`a3d87745`
- Side Chat registry 按 Bridge 隔离：`1d99e1cd`
- Explorer 旧 Bridge 单通道与迟到帧排空：`f8438e15`
- Git remote-status 路径拒绝不再伪装成功：`8374d105`
- 分页后展开状态 key 迁移：`8d04d5ed`
- 文件密码限流跨重连、并行尝试生效：`e95f1772`

P3 的缓存标题 N+1 已由 `704b5e09` 改成每 300 个身份一批。硬编码英文已经
继续按功能域拆分：`5562e535`（会话状态/审批）、`5cd90b8f`（Explore）、
`50e60902`（Git）、`f23c9187`（文件传输界面与通知）、`b431221c`（slash
command）、`932f8bec`（二维码）、`bfe4bd5a`（截图）、`72a96edc`（工具活动与
运行过程）、`b197f0d6`（主题、许可、机器管理、权限、沙箱与速度）、`77305280`
（ARB 键集一致性门禁）、`6e2b46fb`（会话历史、工具详情、拖放与悬浮临时会话
四语言）。第 4 节列出的长尾
仍然是系统性本地化工作，不能因这些高曝光面已完成就提前关闭。

## 8. 下一实施顺序

1. 继续完成剩余领域错误映射和长尾固定 UI 的四语言量化扫描；
2. 修复 `_LegacyExploreLane` 关闭后 quarantine timer 生命周期，并复跑 WorkspaceShell；
3. 按 Cloud → Bridge → 新 Mobile 的独立门禁部署并真机验收通知去重、动作与后台保活；
4. 收束文件预览 HTTP/JSON 错误、下载实现和本地 HTML 安全预览；
5. 处理 content scheduler、session manager、Bridge 进程生命周期的剩余高风险项；
6. 全量回归、性能/安全复审、iOS Simulator build、磁盘与构建产物收束；
7. 最后才列出需要用户在物理 iPhone 上完成的视觉、通知、Face ID 和后台验收。
