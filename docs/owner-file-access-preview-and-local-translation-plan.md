# CC Pocket owner 文件能力、统一预览、本地翻译与统一会话实施参考

> 状态：accepted product design / provisional implementation reference
> 当前只完成设计整理，尚未开始实现、集成、构建、部署、发布或真机验收。
> 本文是后续任务的主要参考，不是可直接照抄的最终技术规格。

## 0. 文档权威边界

本文合并三组已经由用户确认、但尚未交付实现的方案：

1. owner 自用部署的全盘只读、手动文件管理、Agent 文件引用、统一预览，以及
   Mobile 文件变更的密码或 Face ID 二次授权；
2. CC Pocket 固定界面的完整中文化，以及对动态英文警告/说明使用 Apple
   Translation framework 做本地翻译；
3. Codex Desktop 风格的统一会话列表、APP 前台全会话轻量增量同步、直接打开
   并继续使用，以及将完整下载状态收束为会话行内勾号。

本文有意写得完整，但编写前只核对了相关主链路，没有穷尽所有 Bridge、Mobile、
native、HTTP、文件传输、Gallery、历史兼容、发布和测试代码。因此：

- 产品目标、用户可见行为、安全原则和不做事项是已确认决定；
- 本文出现的现有类名、文件路径和行为描述只代表编写时快照；
- 拟议 capability、method channel、RPC、缓存键、状态机和实现顺序都是候选设计；
- 后续执行前必须重新确认真实仓库、worktree、branch、完整 HEAD、官方上游、
  当前运行 Bridge、基础 IPA、Shorebird release 和设备系统版本；
- 如果现场源码与本文冲突，不能机械套用本文；应先判断冲突属于代码演进、
  文档错误还是产品决定变化，再做最小语义实现；
- 不得因为本文写了“应当”就声称相应能力已经存在或已经发布。

本文编写时用于只读核对的候选快照为：

- worktree：
  `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-background-notify-candidate-20260724`
- branch：`integration/mobile-1.108.1-background-notify-candidate-20260724`
- HEAD：`99956f60ceb02a8657316d1d04d47611b8038e4f`

该快照只是设计证据，不是未来实现的指定基线。

## 1. 最终产品决定

### 1.1 owner 文件访问

- Bridge 在 macOS 实际授予的 TCC、Unix 权限和系统保护范围内，允许 owner
  浏览、搜索、读取、预览和下载全盘文件。
- 只读访问不再受 session project、session cwd 或旧
  `BRIDGE_ALLOWED_DIRS` 的产品级目录白名单限制。
- 全盘只读不代表绕过 FileVault、Keychain、其他用户权限、SIP、TCC 或文件
  自身 ACL。
- Agent 的 provider 工具、sandbox、permission mode、审批和写入行为保持原样，
  不把 Agent 改造成第二套 Mobile 文件管理器。

### 1.2 两套文件入口

产品继续保留两套入口：

1. 手动文件管理：用户主动浏览、搜索、固定位置、查看 metadata、预览、下载，
   以及发起受二次授权保护的文件变更；
2. Agent 文件引用：Agent 正常输出本地路径或 Markdown 文件链接，Bridge 使用
   已有识别机制登记为结构化 artifact，Mobile 显示可点击链接。

两套入口不合并交互界面，但共用：

- owner 全盘只读 authority；
- canonical path、symlink、文件身份和真实权限检查；
- opaque 短期 read capability；
- 统一预览、下载和分享管线。

### 1.3 预览

- iOS 上能由当前系统 Quick Look 预览的格式优先使用 Quick Look。
- 不能由 Quick Look 打开的格式自动落到本地只读预览器。
- Agent 引用与手动文件管理使用同一个预览协调器和同一个页面外壳。
- 分享、下载、返回、传输进度、取消和错误提示继续复用现有 Flutter 实现。
- 未识别的二进制文件仍可下载或分享，但不能被猜测为文本强行解码。

### 1.4 文件变更授权

Mobile 或 Bridge 文件管理 RPC 直接发起的任何 Mac 文件系统变更，必须由
Bridge 权威验证以下任一方式：

1. 在 Mac Bridge 本地设置的文件变更密码；
2. 已登记 iPhone 通过 Face ID 解锁 Secure Enclave 私钥，对本次具体操作挑战
   签名。

授权必须一次性、短时、绑定设备、连接 generation、操作和规范化路径。Bridge
不能相信 Mobile 自报 `faceIdPassed: true`。

### 1.5 中文化和动态翻译

- APP 自己固定的按钮、标题、菜单、tooltip、错误、warning 和状态首先进入
  现有 ARB/feature l10n，不调用翻译模型。
- 常见 Codex、Git、Bridge 和文件术语使用一个很小的本地术语表，保证机械翻译
  一致。
- 只有 Bridge/Agent/provider 动态返回、且被识别为用户可读自然语言的英文警告
  或说明，才调用 Apple Translation framework。
- 不引入 ML Kit、LibreTranslate、云翻译 API 或手机内自带第三方模型包。
- 不为不具备 Apple Translation framework 的旧系统实现翻译回退。旧系统必须
  继续正常运行并显示英文原文，但可以完全不显示动态翻译入口。
- 翻译失败、语言包未下载或系统不支持时，不能阻塞消息、审批、警告或会话使用。

### 1.6 统一会话与前台增量同步

- 首页最终只保留一套会话列表，不再把“运行中”“常驻”“已下载”分别做成占据
  顶部空间的独立会话区；这些都只是同一个 durable 会话的行内状态。
- 用户点击任何已知会话都应立即进入并看到手机已有的最近内容。恢复或建立
  Bridge runtime、增量对账和 interactive 切换在后台完成，不再要求用户先
  “激活”，再第二次进入或使用。
- APP 处于前台且 Bridge 已连接时，未打开的会话也接收轻量变化通知和必要增量，
  写入本地可重建缓存；未打开会话不构建聊天 Widget、不做 Markdown 重排，也不
  展开或渲染工具详情。
- “所有会话自动同步”不等于首次把所有历史全部下载到手机。所有会话保留可直接
  打开的最近窗口和后续增量；用户主动完整下载的会话才保存全部可恢复历史。
- 完整下载按钮的状态收束为：未下载显示下载符号、下载中显示进度、已下载显示
  勾号。完整下载会话仍留在原列表顺序中，不因下载或自动同步被移到顶部。
- iOS 真正挂起、系统回收或用户强退后不承诺永久 WebSocket；回到前台后必须按
  durable provider thread ID 和 revision/sequence 增量追平。

## 2. 已确认存在的能力与不得重复实现的部分

截至上述只读快照，已经确认：

- `packages/bridge/src/artifact-candidates.ts` 已负责从 Agent 内容识别本地文件
  candidate；
- `packages/bridge/src/artifact-manager.ts` 已负责 artifact 登记、解析和短期访问；
- `apps/mobile/lib/features/chat_session/widgets/chat_message_list.dart` 已能从
  Agent 文件引用进入预览；
- `apps/mobile/lib/features/file_browser/file_browser_screen.dart` 已能从手动
  文件管理进入预览；
- 两条 Mobile 路径最终都使用
  `apps/mobile/lib/features/artifact_preview/artifact_preview_screen.dart`；
- Flutter 预览页已经包含分享、下载、进度、取消和返回交互；
- `ArtifactQuickLookPlugin.swift` 已调用
  `QLPreviewController.canPreview`，并限制临时预览路径位于 App sandbox；
- Bridge 本地预览器已有文本、JSON、XML、YAML、CSV、日志、PDF、图片、音视频、
  DOCX 和 unsupported fallback 的部分实现；
- Mobile 已有 `app_en.arb`、`app_zh.arb`、`app_ja.arb`、`app_ko.arb` 和若干
  feature-specific strings，但仍存在直接写死的英文 UI 文案。
- Recent session 点击当前仍调用 `resumeSession()`，等 Bridge 创建运行实例后
  才导航到聊天，因此“激活”仍是用户可感知的前置步骤；
- `DesktopSessionListContinuityTracker` 只跟踪已经出现在 Bridge active
  session list 中的 Codex 会话，不覆盖所有未激活历史会话；
- Conversation Mirror 已能让未打开的 Codex 会话在连接时增量同步，但产品与
  Bridge 当前都把 resident watch 限制在最多 8 个；
- Home 当前存在独立 `ConversationMirrorResidentSection`，并从普通 recent
  list 中排除 resident 会话；
- 会话行内已经存在 Mirror 状态按钮：未下载、已保存未常驻、常驻和同步中已有
  不同状态，不应再造第二套下载状态系统。

后续不得重复创建：

- 第二套 Agent 路径解析器；
- 第二套 artifact URL/下载协议；
- 手动文件管理专用的另一套预览页面；
- Quick Look 专用的另一套分享/下载系统；
- embedded WebView 到 native 的宽泛 JavaScript action bridge；
- 与现有 ARB 并行的全新 UI 国际化框架。

上述结论仍需在实际实现基线上重新验证，尤其要检查官方更新是否已经替换或扩展
这些接缝。

## 3. 总体架构

```text
Agent 文件引用 ─┐
                ├─ Bridge read authority ─ opaque read capability ─ Preview coordinator
手动文件管理 ───┘                                          │
                                                           ├─ Quick Look
                                                           ├─ 本地预览器
                                                           ├─ 分享
                                                           └─ 下载

Mobile 文件变更请求
        │
        ├─ canonical path / identity / conflict preflight
        ├─ Bridge 一次性 challenge
        ├─ 密码证明 或 Secure Enclave 签名
        └─ Bridge 复核后原子执行

固定 UI 英文 ─ ARB + 本地术语表
动态自然语言英文 ─ Apple Translation（可用时）─ 译文 + 可查看原文

Bridge 会话索引/变化监视
        │
        ├─ compact revision/status event
        ├─ changed-session bounded delta
        └─ Mobile Mirror/SQLite（不渲染未打开会话）
                         │
                         ├─ 统一会话列表行内状态
                         └─ 打开后立即读本地窗口并后台恢复 interactive runtime
```

Bridge 是 Mac 文件读取和变更授权的权威端。Mobile 不直接提交任意本地路径给
HTTP，也不直接决定某个写操作已经获准。Apple Translation 只处理 Mobile 已经
收到的可翻译显示文本，不改变 Bridge 消息、canonical history 或 provider 原文。

## 4. owner 全盘只读设计

### 4.1 统一 read authority

后续应先找到现有 allowed-roots、artifact candidate、file browser、Gallery、
transfer 和 HTTP content/download 各自的授权入口，判断能否收束为一个明确的
read authority。

owner 模式的 authority 负责：

- 解析绝对路径和相对 session cwd 路径；
- canonicalize，并拒绝 NUL、路径遍历、非法编码和不完整 URI；
- 明确处理 symlink，避免检查路径与实际打开对象不一致；
- 验证目标是允许读取的普通文件或明确支持的目录；
- 验证真实 stat、权限、大小和必要的文件身份；
- 签发不暴露 Mac 绝对路径的短期 opaque capability；
- 对 preview/content/download/range 请求重复校验 capability、时效和文件身份；
- 将真实 TCC/Unix/file-not-found/not-regular-file 错误与
  `path_not_allowed` 区分。

owner 全盘模式不意味着 HTTP 接口接受 `?path=/任意路径`。路径只在 Bridge
内部解析，Mobile 和浏览器只消费不可推导的 capability。

### 4.2 Agent 引用

- 继续使用现有 artifact candidate 提取；
- 相对路径以生成该消息的真实 session cwd/project 语义解析，不能使用 Mobile
  当前页面猜测的 cwd；
- owner 模式下，project 外有效文件不能再因旧 allowed-root 规则被拒绝；
- 同一消息重复引用可复用登记，但 capability 仍需短时、可撤销和有界；
- 文件已变化时应返回明确的 changed/conflict 信号，不能静默预览另一个对象；
- Agent 自己写文件继续走 provider 原机制，不要求 Mobile Face ID。

### 4.3 手动文件管理

- 浏览、搜索、metadata、固定位置、预览和下载均为只读；
- 大目录必须分页、可取消并设结果上限；
- 搜索必须有范围、超时、并发和结果上限，不能因为“全盘”就无界扫描；
- 默认不跟随未知 symlink 逃逸；如允许跟随，必须以 canonical target 重新授权；
- 系统目录、隐藏文件和包目录是否显示应由用户设置决定，但不改变真实权限；
- 只读失败必须给出能区分 TCC、文件不存在、权限不足和 Bridge 版本过旧的提示。

## 5. 统一预览设计

### 5.1 当前已知问题

编写时快照中，Dart 仍以 Office/RTF 扩展名白名单决定是否调用 Quick Look。
JSON、普通文本、PDF、图片和音视频固定进入 WebView。本地 native 虽然已经调用
`QLPreviewController.canPreview`，但只有被 Dart 白名单选中的文件才有机会到达
该判断；Quick Look 返回 unsupported 时也不会自动进入本地预览器。

### 5.2 目标状态机

候选状态：

```text
idle
  -> preparing
  -> quickLookPresented
  -> localPreview
  -> unsupportedMetadata
  -> failed
```

具体 enum 和对象边界必须以实际 Flutter 结构决定，不能为了匹配本文强行重构。

目标流程：

1. 统一预览页接收 Bridge 已解析的 artifact/read capability，不接收任意 Mac
   绝对路径；
2. 验证 capability 时效、大小和连接 identity；
3. 在 iOS 上以可取消、有进度的方式准备 Quick Look 所需 sandbox 临时文件；
4. 由当前设备的 `QLPreviewController.canPreview` 做最终判断；
5. 支持时展示 Quick Look；
6. 明确 unsupported、native adapter 不可用或启动失败时，无需返回上一页，直接
   切换到本地预览；
7. 本地预览也失败时显示 metadata、真实错误、分享和下载；
8. Quick Look 关闭后删除临时文件；用户明确下载的永久副本不能被一起删除。

Apple 将 JSON 声明为符合 `public.text` 的 `public.json`，因此 JSON 应进入
系统优先路线；但 Apple 明确说明 Quick Look 支持类型可能随系统版本变化，实际
仍以设备 `canPreview` 为准：

- [UTType JSON](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/json)
- [QLPreviewController](https://developer.apple.com/documentation/quicklook/qlpreviewcontroller)

### 5.3 本地预览器

本地预览器是 Quick Look 的兜底，不是第二套导航和传输产品。

初始兜底范围：

- 文本和代码：有界前缀读取、编码识别、行号或基础可读布局；
- JSON：合法时格式化，失败时展示原始文本；
- XML/YAML/CSV/TSV/日志：有界文本展示，不执行内容；
- DOCX：复用现有本地 renderer，禁止上传外部预览服务；
- 已有 PDF、图片、音频和视频 renderer 保留作系统失败兜底；
- 未知二进制：只显示 metadata、unsupported 提示、分享和下载。

安全要求：

- HTML、SVG、Markdown 和代码预览不得获得任意网络、文件或 native bridge 权限；
- JavaScript 只为明确需要的本地 renderer 开启；
- 文本必须转义，不能把文件内容拼成可执行 HTML；
- 大文件必须有预览上限、截断提示和下载完整文件入口；
- 压缩包、数据库、二进制 plist 等未来格式使用显式 adapter，不靠 MIME 猜测
  直接执行或解码。

### 5.4 分享与下载

- Flutter 外壳继续拥有分享、下载、进度、取消和安全文件名；
- 手动文件管理若已有可续传下载，预览页继续委托它，而不是改回一次性下载；
- Agent artifact 下载沿用现有认证和时效；
- 分享使用临时副本，系统 share sheet 返回后清理；
- “预览临时文件”“分享临时文件”“用户下载副本”必须是三个可区分的生命周期；
- Quick Look 自带操作不能成为唯一下载入口，避免系统版本差异破坏产品行为。

## 6. Mobile 文件变更二次授权

### 6.1 受保护操作

只约束 Mobile/Bridge 文件管理直接发起的变更：

- 新建文件或目录；
- 写入、追加、编辑、覆盖、截断；
- 重命名、移动、替换；
- 手机上传并落盘到 Mac；
- 删除、清空和永久删除；
- 将来新增的任何 Mac 文件系统变更。

预览、下载、分享、读取 metadata 和 Agent provider 自己的工具行为不进入这一
二次授权器。

### 6.2 密码

- 只允许在 Mac Bridge 本地管理入口设置、修改、清除或重置；
- Bridge 不保存明文，只保存独立 salt、Argon2id verifier 和版本化参数；
- 文件应位于稳定的 `~/.ccpocket/` 私有配置位置并使用 `0600`，实际路径须在
  实现前核对现有配置体系；
- 密码不写入 plist、命令行、普通日志、Mobile settings 或完成回报；
- Mobile 默认不持久保存密码；
- 失败需要速率限制、逐级延迟和有界锁定；
- 重置密码撤销未消费 challenge、操作授权和 Face ID 设备登记。

### 6.3 Face ID 与 Secure Enclave

Face ID 只能解锁设备私钥，不能由客户端发送一个布尔值证明。

候选登记流程：

1. 用户先用文件变更密码完成一次登记授权；
2. iPhone Secure Enclave 生成不可导出签名私钥；
3. 私钥受 `biometryCurrentSet` 等适当策略保护；
4. Mobile 向 Bridge 登记公钥、设备 ID、算法和 capability；
5. Bridge 可在 Mac 本地管理入口撤销单设备或全部设备。

生物识别集合变化、App 重装、Keychain/Secure Enclave 密钥失效和设备撤销必须
fail closed，并要求密码重新登记。

### 6.4 一次性 challenge

Bridge 在 challenge 前完成 preflight，challenge 至少绑定：

- request ID；
- Bridge 实例和连接 generation；
- 登记设备 ID；
- 操作类型；
- canonical 源路径和目标路径；
- 文件身份、大小或预期不存在状态；
- 操作参数摘要；
- 随机 nonce、签发时间和过期时间。

密码验证或 Secure Enclave 签名成功只授权 challenge 中的一个操作或一个明确
批次。默认可使用约 60 秒、一次消费作为初始候选，但实现前应结合现有请求时序
和真机交互重新确认。

执行前再次 stat/校验 symlink 和目标身份，使用文件句柄、no-overwrite、原子
落盘或 compare-and-swap。超时、断线、重连、Bridge 重启、重复帧、晚到签名和
内容摘要不匹配都不得执行。

删除默认优先进入可恢复废纸篓。永久删除必须显示不可恢复提示并取得新的独立
授权。

## 7. 固定 UI 中文化

### 7.1 适用范围

所有由 CC Pocket 自己控制的固定可见字符串，包括：

- 页面标题、按钮、菜单、tooltip、空状态；
- Warning/Error/Retry 等固定标签；
- Git 操作、文件操作、权限和 session 状态；
- SnackBar、Dialog、通知标题和设置说明；
- accessibility label 和系统设置跳转说明。

这些内容必须迁移到现有 ARB 或已有 feature-specific strings。不要把固定 UI
送入 Apple Translation，也不要在运行时根据英文字符串做全局替换。

### 7.2 术语表

维护一个小而明确的产品术语表，候选包括：

- Warning：警告
- Error：错误
- Retry：重试
- Stage / Unstage：暂存 / 取消暂存
- Revert：还原或放弃更改，按操作风险选择准确措辞
- Worktree：工作树
- Sandbox：沙箱
- Bridge：保留 Bridge，必要时说明“连接服务”
- Agent / Subagent：Agent / 子 Agent，避免在同一页面混用多个译法
- Approval：审批
- Permission：权限

术语表只是翻译一致性来源，不应成为捕获任意动态英文的正则替换器。危险操作
文案必须人工确认语义，尤其是 Revert、Delete、Overwrite、Reset、Discard。

### 7.3 扫描方式

实施时应：

- 扫描 Flutter widget 中直接写死的可见英文；
- 区分生产 UI、mock、测试 fixture、协议枚举、日志、代码样例和品牌名；
- 检查 feature-specific l10n 是否已经有中文，避免重复迁入 ARB；
- 保留 Codex、Claude、Git、JSON、Quick Look 等必要品牌或技术名；
- 运行 l10n codegen，并避免把大范围无关 generated/formatter 漂移混入提交；
- 为关键危险操作补中文语义测试，而不只是 snapshot 文本存在测试。

## 8. Apple 本地动态翻译

### 8.1 使用范围

只翻译完整、稳定、用户可读的自然语言片段，例如：

- provider 返回的英文 warning 说明；
- Bridge 生成但尚无结构化中文的兼容提示；
- 某些动态错误的人类说明部分；
- 用户主动点击“翻译”或设置允许自动翻译的说明文本。

禁止翻译：

- shell 命令、代码、patch、diff；
- 文件路径、URL、commit SHA、branch、worktree；
- JSON、XML、YAML、日志原文和协议 payload；
- error code、工具名、模型名、MCP/plugin/app 标识；
- 密码、challenge、签名、token 和潜在秘密；
- 尚在高速流式变化的半句文本。

### 8.2 系统边界

采用 Apple Translation framework：

- [Translation framework](https://developer.apple.com/documentation/translation/)
- [Translating text within your app](https://developer.apple.com/documentation/translation/translating-text-within-your-app)
- [WWDC24 Meet the Translation API](https://developer.apple.com/videos/play/wwdc2024/10117/)

框架使用系统共享的 on-device translation models。语言包由系统管理；缺少模型
时系统可能请求用户同意下载。CC Pocket 不把模型打进 App，也不保存 Apple
模型副本。

Translation API 需要在实际可用系统上 capability-gate。当前产品决定是不为旧
系统增加 ML Kit 或云 API fallback：

- 系统支持且语言对可用：提供本地翻译；
- 系统支持但语言包未安装：由系统正常提示下载，用户拒绝则显示原文；
- 系统不支持：隐藏翻译入口或显示原文，不报功能故障；
- 不提高旧系统用户的会话、文件和其他基础功能门槛。

具体最低系统版本和编译可用性必须用实际 Xcode/SDK 核对。候选实现应使用
`@available` 和 native host capability，不能只用 Mobile 版本号猜测。

### 8.3 UI 行为

- 译文不得覆盖或写回 canonical message/history；
- 默认保留原文，可采用“译文优先＋展开原文”或“原文＋翻译”；
- 显示“本地机器翻译”标识，不能冒充 Agent 原始中文；
- 危险操作和审批文本必须始终能查看英文原文；
- 自动翻译只在完整事件到达后触发，可合并短片段或 debounce；
- 翻译加载不能阻塞 warning 卡片、审批按钮或会话滚动；
- 用户可以关闭自动翻译，关闭后清除不必要的内存缓存但不改原文；
- 同一文本重复出现时可按内容 hash、目标语言和翻译策略做有界缓存。

### 8.4 native 与 OTA

新增 Translation framework host、Swift、method channel 或 native capability
属于基础 IPA 变化。首次加入必须构建新基础 IPA；不能把 Shorebird patch 成功
解释成 native translation 已加入。

基础 IPA 已包含并声明稳定 native host 后，纯 Dart 的显示策略、术语、缓存和
开关调整是否可 OTA，必须再与当前 Shorebird release 的真实 native-Dart 契约
核对。

## 9. 统一会话列表与全会话轻量增量同步

### 9.1 当前问题与边界

当前实现把同一个 durable 会话拆成三种用户可见形态：

1. active/running session：Bridge 已经持有运行实例，Home continuity watcher
   能跟踪 Desktop 变化；
2. resident conversation：手机拥有完整副本并维持 Mirror watch，但最多 8 个，
   还会进入独立的首页顶部区域；
3. recent session：只有历史 metadata，点击时先恢复 runtime，再进入会话。

这三者是运行状态和缓存状态，不应该继续表现为三种不同的“会话实体”。直接提高
现有 resident watch 上限也不是目标方案：当前 Mirror watch 会为每个会话持有
状态并轮询 marker、在变化或定时到期时做完整 reconciliation；把这种模型机械
扩展到全部历史会话会增加 Bridge 进程、文件读取、内存快照和手机写入压力。

### 9.2 单一 durable 会话身份

统一列表和同步必须以稳定 provider identity 为主键：

```text
bridgeInstanceId + provider + providerSessionId
```

runtime session ID、标题、第一条 prompt、project 名和列表位置都不能替代
`providerSessionId`。同一个 durable 会话可以同时具有：

- 当前 Bridge runtime ID；
- provider thread/rollout revision；
- Mobile 最近窗口缓存；
- 可选的完整下载副本；
- running、needs-you、ready、unseen、syncing 等瞬时状态。

这些都是一个实体的属性。Bridge 重连、runtime 重建、Desktop 接手和 Mobile
重新打开不能生成第二张会话卡。

### 9.3 统一首页

目标首页行为：

- 删除独立 `ConversationMirrorResidentSection`；
- resident/完整下载会话不再从 recent list 过滤掉；
- 运行状态、审批状态、未读、Desktop 活动、同步和完整下载均显示为行内 badge；
- 排序继续使用用户选择的项目、时间和主动 pin 规则，下载状态不能改变排序；
- 完整下载状态按钮：
  - 无完整副本：下载符号；
  - 下载或对账中：小型进度；
  - 完整副本存在：勾号；
- “立即同步、停止完整自动同步、删除手机副本”继续留在长按/更多菜单；
- 如未来增加“只看已下载”，它是筛选器，不是首页顶部分类。

所有状态控件应复用现有 `ConversationMirrorBadge`、Mirror metadata 和 action
handler，不创建并行的保存状态或第二套数据库。

### 9.4 直接打开与延迟 runtime 恢复

点击会话后的目标顺序：

1. 立即导航到同一聊天页面；
2. 优先读取 Mobile 已有的最近窗口或完整副本并首屏显示；
3. 同时向 Bridge 查询当前 runtime，存在则直接绑定；
4. 不存在则在后台恢复 provider 会话，并把 durable ID 与新 runtime ID 绑定；
5. 从本地已知 revision/sequence 做增量 reconciliation；
6. interactive ready 后正常发送输入。

如果用户在 runtime 尚未 ready 时马上发送，输入可以进入明确标记、可取消且有界
的本地 pending queue；ready 后只发送一次。断线、恢复失败、会话已归档或 provider
身份不匹配必须显示真实状态，不能把“直接打开”实现成静默丢消息。

打开页面不应先请求完整历史。最近窗口用于即时首屏，更旧历史按现有分页机制向上
加载；有完整手机副本时直接从本地分页。

### 9.5 Bridge 统一变化流

APP 前台的“所有会话同步”应采用一个 Bridge 级索引/变化流，而不是为每个会话
复制一个完整 Mirror poller。候选职责：

- Bridge 维护已知 provider threads 的有界 revision/status 索引；
- provider rollout、历史 marker 或 active runtime 发生变化时，推送 compact
  change event；
- event 至少关联 provider、providerSessionId、project identity、revision 或
  sequence、状态和变化类型；
- Mobile 只对真正变化、且本地缺少增量的会话发起 bounded delta 请求；
- Bridge 对同一会话的短时间 burst 合并，对不同会话实行公平队列和并发上限；
- 断线重连先交换客户端已有 revision 摘要，再补缺口，不全量重发所有历史；
- revision 不连续、摘要冲突或协议不支持时，退回该单会话的 canonical
  reconciliation，不扩大成全库重建。

协议名称必须在实施时检索现有 local-feature slot 和官方上游后决定。本文中的
`conversation_index_stream_v1`、`conversation_delta_sync_v2` 仅表达候选边界，
不是已经批准的最终 wire 名称。

### 9.6 Mobile 未打开会话的数据路径

未打开会话只允许：

- 验证 generation、provider identity、revision 和顺序；
- 合并/标准化必要增量；
- 事务性写入 Conversation Mirror/SQLite；
- 更新列表需要的少量 metadata、最后活动时间、状态和未读标记；
- 在缓存/磁盘预算达到上限时按明确策略压缩或淘汰可重建的最近窗口。

未打开会话禁止：

- 构建 `ChatSessionCubit` 或完整消息 Widget 树；
- Markdown/代码高亮全文重排；
- 工具结果展开、图片解码或 Artifact 预览；
- 每个 delta 重建整个 Home；
- 为所有会话长期保留完整内存 snapshot。

Home 只订阅列表级摘要，并用稳定 key/selector 更新真正变化的行。

### 9.7 最近窗口与完整下载

两个概念必须分离：

- **最近窗口自动同步**：所有已知会话都可以拥有一个有界、可直接首屏显示的最近
  窗口，并持续接收后续增量；
- **完整下载**：用户显式选择后保存全部可恢复文本和工具历史，支持完整离线浏览。

勾号只表示完整下载副本存在。没有勾号的会话仍能直接打开和继续使用，只是向上
翻阅很久以前的内容时可能需要 Bridge 在线分页。停止“完整自动同步”只停止完整
副本的 resident 策略，不应停止该会话的列表状态和最近窗口轻量同步。

### 9.8 性能与功耗约束

- 当前打开会话保持现有低延迟流式反馈，不能为了后台同步降低用户正在看的实时性；
- 未打开会话可以用更长合并窗口，具体数值必须通过真机和长会话基准确定；
- Bridge provider reads、Mobile reconciliation、SQLite transaction 和网络字节
  都要分别设并发、单次、每分钟和全局预算；
- 同一会话的多个变化 single-flight；新 revision 可覆盖尚未开始的旧对账，但
  不能跳过已经确认需要的 sequence；
- 优先处理正在运行、needs-you、用户刚打开和列表可见的会话；
- 很久未变化的归档会话只保留索引，不维持周期性完整读取；
- 启动先显示本地列表，再分批校验远端 revision；不能因全会话扫描阻塞首帧；
- 需要基准覆盖数百/数千会话、长历史、工具密集、burst、断线重连和低内存。

### 9.9 iOS 生命周期

本方案的可靠范围首先是“APP 在前台，但用户没有打开具体会话”。此时保持一个
Bridge 连接和统一变化流是合理的。

进入 iOS 后台后：

- 现有有限 `UIBackgroundTask` 只能短时间续跑；
- `BGAppRefresh` 是系统机会性调度；
- notification-only 模式不能顺带恢复全历史/Mirror；
- 进程被系统回收或用户强退后不继续同步；
- 下次前台恢复按 durable ID 和 revision/sequence 增量追平。

不得用定位、音频或其他后台模式伪装永久全会话 WebSocket。本节不改变已经确认的
通知与后台功耗边界。

### 9.10 Provider 与兼容边界

- 当前 Desktop continuity 和 Conversation Mirror 的完整实现主要是 Codex 专用；
  “所有会话”若包含 Claude，必须通过 provider adapter 提供同一上层语义，不能
  把 Codex rollout 假设套到 Claude；
- 新 Mobile + 旧 Bridge：保留当前 recent resume、运行中 continuity 和最多
  8 个 resident 会话；统一变化流缺失时隐藏或降级，不破坏会话；
- 旧 Mobile + 新 Bridge：没有 capability opt-in 时行为不变，不发送未知事件；
- 新两端：使用统一索引/变化流和按需 delta；
- Mirror/SQLite 始终是可重建缓存，canonical provider history 仍是权威；
- 新表、字段或索引只能 additive migration，旧数据库损坏或缺字段时安全重建；
- 官方上游若新增类似 thread subscription，应优先语义复用，不保留两套竞争协议。

## 10. 候选 capability 与协议

以下名称只用于表达边界，实施时必须先检索现有命名和版本，避免重复：

- `full_disk_read_v1`
- `full_disk_reference_preview_v1`
- `file_mutation_step_up_v1`
- `biometric_device_signature_v1`
- `system_translation_v1`
- `conversation_index_stream_v1`（候选名）
- `conversation_delta_sync_v2`（候选名）

原则：

- 新字段 additive、optional、可忽略；
- 旧客户端不认识时保持旧行为或隐藏新入口；
- 需要二次授权的写操作在 capability 缺失时 fail closed；
- Translation 是 Mobile/native 本地显示能力，不要求改变 Bridge canonical
  message schema；
- 如果 Bridge 需要标注“可翻译自然语言”，应使用窄、可选的展示 metadata，
  不能把服务端翻译结果写成 provider 原文；
- capability 表达真实能力，不用总版本号代替。
- 会话变化协议只传 compact metadata 和按需增量，不能把全部会话完整 snapshot
  塞入一次广播。

## 11. 兼容矩阵

### 11.1 文件能力

- 新 Bridge + 新 Mobile：owner 全盘只读、统一预览、直接文件变更二次授权；
- 新 Bridge + 旧 Mobile：保留旧只读行为；新写操作不回退为未授权执行；
- 旧 Bridge + 新 Mobile：没有全盘/step-up capability 时隐藏或禁用对应入口；
  普通会话和旧文件读取继续工作；
- 旧 Bridge + 旧 Mobile：行为不变。

### 11.2 native 能力

- 新基础 IPA + 新 Dart：使用 Quick Look、Secure Enclave/Face ID 和系统翻译的
  已声明能力；
- 新 Dart + 旧基础 IPA：native capability 缺失时 fail closed 或回退原文/
  本地预览，不能调用不存在的 channel；
- 新基础 IPA + 旧 Dart：新增 native plugin 无调用时保持 dormant；
- Shorebird 回滚 Dart 时仍必须保证 native host 对旧调用兼容。

### 11.3 动态翻译

- 支持 Apple Translation 的系统：按用户设置翻译自然语言；
- 不支持的旧系统：APP 正常运行，固定 UI 仍通过 ARB 中文化，动态内容显示原文；
- 用户拒绝语言包：显示原文；
- 翻译异常：显示原文并可重试，不影响主流程；
- 不使用 Bridge 云翻译作为隐式 fallback。

### 11.4 统一会话

- 新 Mobile + 新 Bridge：统一列表、直接打开、前台全会话轻量变化流和按需增量；
- 新 Mobile + 旧 Bridge：沿用当前 resume/continuity/resident 行为，不假装全量
  自动同步已经存在；
- 旧 Mobile + 新 Bridge：没有新 capability 时 Bridge 不发送新事件；
- 旧 Mobile + 旧 Bridge：行为不变；
- iOS 后台、强退和进程回收继续按第 9.9 节边界处理。

## 12. 安全、隐私和性能

### 12.1 文件安全

- 全盘只读必须建立在已认证连接和受限网络暴露上；
- WebSocket 与所有私有 HTTP、Gallery、artifact、preview/content/download
  使用一致认证边界；
- mDNS、监听地址、防火墙、Tailscale 和运行宿主必须现场复核；
- 请求体、目录页、搜索、文件大小、并发、Range、失败认证和 Gallery 存储有界；
- Full Disk Access 只授予路径和身份稳定的窄宿主/helper；
- 审计日志不记录密码、文件正文、Face ID 数据、私钥或完整敏感响应。

### 12.2 翻译隐私

- 动态翻译只使用 Apple on-device 模型；
- 不把 warning、路径、代码或日志发送给第三方 API；
- 翻译缓存不成为新的 canonical history；
- 缓存应有条数/字节上限，可在设置或 App 清理时删除；
- 进入翻译前做结构化内容分类，不能仅用“包含英文字母”判断；
- 密码、token、签名、challenge 和文件正文默认永不进入翻译。

### 12.3 性能

- 静态 UI 不做运行时翻译；
- 动态翻译不对每个流式 delta 调用；
- 同语言对使用 batch/session 能力，避免并发创建大量 translator；
- 翻译结果缓存有界，列表离屏后不保留不必要 widget/任务；
- Quick Look 临时下载必须可取消、有进度并遵守预览大小限制；
- 大目录、大文件、全文搜索和本地 renderer 不得因为全盘权限变成无界工作。
- 未打开会话只做有界增量落库和列表摘要更新，不解析渲染完整聊天内容；
- 全会话同步使用统一变化流，不能机械放开每会话 Mirror poller 或 resident 上限；
- 当前打开会话的实时流式反馈优先级最高。

## 13. 实施前强制调查

后续任务开始后，先输出一份“本文假设核对表”，至少确认：

1. 实际集成基线是否已经包含 artifact path extraction、统一预览和下载/分享；
2. `path_not_allowed` 的全部产生位置及 caller；
3. file browser、artifact、Gallery、transfer 和 HTTP 是否存在多套 authority；
4. 当前 Bridge 认证、监听地址、Tailscale、mDNS 和私有 HTTP 边界；
5. 当前文件传输、预览、下载的真实大小上限和 Range/续传能力；
6. Quick Look 当前 Dart routing、native `canPreview`、失败码和临时文件生命周期；
7. APP 可见英文的完整清单，区分生产 UI 与 mock/test/log；
8. ARB 与 feature-specific strings 的所有权和 codegen 流程；
9. 当前 Xcode、iOS deployment target、Swift 版本和 Translation framework
   编译边界；
10. 当前基础 IPA 已包含哪些 native capability；
11. Face ID/Secure Enclave 是否已有可复用 host；
12. 官方上游是否新增同类文件、预览、翻译或授权能力；
13. 与正在进行的其他 worktree/commit 的路径交集和语义冲突。
14. recent session 点击、`resumeSession()`、`session_created` 和导航的完整时序；
15. Desktop continuity watch、Mirror watch、active session 和 provider runtime
    各自的身份、资源与所有权边界；
16. Home resident section、recent 去重/过滤、Mirror badge 和下载 action 的实际
    复用接缝；
17. Bridge 能否低成本监听 dormant provider thread 的 revision，是否已有官方
    app-server subscription 或只能有界监视 rollout/marker；
18. Mobile Mirror/SQLite 最近窗口、完整副本、分页、schema migration 和磁盘
    淘汰策略；
19. Codex 与 Claude 能否提供一致 delta 语义，不能做到时如何明确分阶段；
20. 数百/数千会话、长历史、burst、重连和低内存下的基线数据。

调查完成前，不按本文直接创建 protocol、数据库 schema、native channel 或大规模
UI 重构。

## 14. 候选实施阶段

阶段顺序可以因现场代码调整，但每个阶段必须保持独立、可审查：

### Phase 0：源码与运行边界审计

- 完成第 13 节调查；
- 形成现状图、冲突表和最终实施拆分；
- 不改运行 Bridge，不发布。

### Phase 1：统一会话与轻量变化流

- 先统一 durable identity、最近窗口和完整副本语义；
- 增加 capability-gated Bridge 索引/变化流及按需 delta；
- Mobile 未打开会话只落库和更新列表摘要；
- 改成单一列表、直接打开和下载勾号；
- 对旧 Bridge 保留当前路径，不发布。

### Phase 2：固定 UI 中文化

- 扫描生产 UI 硬编码英文；
- 完善 ARB/feature l10n 和术语；
- 补关键 UI/危险操作测试；
- 纯 Dart 边界成立时可作为独立提交，但此阶段不自动发布。

### Phase 3：owner read authority

- 收束只读授权；
- 修复 project 外 Agent 引用；
- 接通手动文件管理；
- 覆盖 canonical path、symlink、TCC、文件变化和 capability 时效。

### Phase 4：统一预览

- 在现有预览页上实现 Quick Look system-first；
- native unsupported 自动回退本地 renderer；
- 复用分享、下载、进度和取消；
- 补 JSON、未知二进制和大文件测试。

### Phase 5：Bridge 密码与一次性授权

- Mac 本地设置；
- Argon2id verifier；
- challenge、锁定、审计和原子执行；
- 先接一个窄写操作验证端到端，再统一覆盖所有变更 RPC。

### Phase 6：Secure Enclave + Face ID

- 设备登记、签名和撤销；
- 与密码路径共享 Bridge authorization verifier；
- 物理 iPhone 验收。

### Phase 7：Apple Translation native host

- `@available` 与 capability；
- LanguageAvailability、下载同意、翻译 session；
- Flutter 显示、原文保留、有界缓存；
- 旧系统原文兼容。

### Phase 8：候选集成与发布门禁

- 语义合并官方更新和并行分支；
- Bridge、Flutter、XCTest、模拟器、IPA 和物理真机分别验收；
- 只有用户明确授权后才部署 Bridge、发布 owner OTA、生成/安装 IPA 或晋级 stable。

## 15. 建议提交拆分

实际提交以最终调查为准，候选拆分：

1. `feat(bridge): 增加统一会话变化索引与按需增量`
2. `feat(mobile): 未打开会话增量落库与最近窗口`
3. `feat(mobile): 统一会话列表并隐藏激活步骤`
4. `ui(mobile): 以勾号表示完整会话副本`
5. `l10n(mobile): 补齐固定界面中文化`
6. `feat(bridge): 增加 owner 全盘只读 authority`
7. `fix(artifact): 允许 owner 预览 project 外 Agent 引用`
8. `feat(mobile): 统一 Quick Look 与本地预览路由`
9. `feat(bridge): 增加文件变更密码与一次性授权`
10. `feat(mobile): 接入文件变更 step-up 交互`
11. `feat(ios): 增加 Secure Enclave 文件授权签名`
12. `feat(ios): 增加 Apple 本地翻译宿主`
13. `feat(mobile): 展示动态本地译文并保留原文`
14. `docs: 更新 owner 文件、会话与翻译兼容矩阵`

不要为了匹配这份清单拆出无意义 adapter；也不要把全盘授权、Quick Look、Face ID、
翻译、生成文件和发布配置混进一个巨型 commit。

## 16. 验收清单

### 16.1 统一会话与同步

- 首页只有一套会话列表，resident/完整下载会话不再形成顶部重复卡片；
- 未运行会话点击后立即显示本地最近窗口，不要求用户先激活再第二次进入；
- runtime 恢复期间首条输入只发送一次，可取消，失败时有真实提示；
- APP 前台且未打开会话时，Desktop/Bridge 新增内容能增量写入本地；
- 未打开会话没有 Markdown、工具详情和完整 Widget 渲染；
- 无完整副本显示下载符号，下载中显示进度，完整副本显示勾号；
- 无勾号会话仍可直接打开；向上加载旧历史按需在线分页；
- 断线重连只补 revision/sequence 缺口，不全量重建所有会话；
- 数百/数千会话、长历史和 burst 基准满足现场确定的 CPU、内存、网络和首帧门槛；
- 旧 Bridge、旧 Mobile、Codex/Claude 分阶段能力和 iOS 生命周期降级符合矩阵。

### 16.2 固定中文化

- 中文 locale 下生产 UI 不再出现未批准的写死英文；
- 品牌、技术标识和代码没有被错误翻译；
- 危险操作中文与实际行为一致；
- 英文、日文、韩文现有 locale 不被破坏；
- l10n codegen、analyze 和相关 widget tests 通过。

### 16.3 动态翻译

- 支持系统上能翻译完整英文 warning；
- 译文明确标记，本地原文可见；
- 命令、代码、路径、JSON、error code 不翻译；
- 流式 delta 不重复触发翻译；
- 拒绝下载语言包、无网络下载条件、unsupported language 和旧系统均显示原文；
- 不使用模拟器结果冒充真机 Translation framework 已通过。

### 16.4 全盘只读

- 手动文件管理可读取普通 project 外文件；
- Agent 引用 project 外文件可预览，不再误报 `path_not_allowed`；
- TCC 拒绝、文件不存在、权限不足和非普通文件错误准确；
- symlink、路径遍历、编码分隔符、NUL 和文件替换攻击被拒绝；
- HTTP 不接受任意本地路径；
- 旧 Bridge/Mobile 降级明确。

### 16.5 预览、分享和下载

- JSON、PDF、图片、音视频、Office 和文本在 Quick Look 可用时系统优先；
- native unsupported 自动落入本地 renderer；
- 本地 JSON 格式化失败仍能显示原文；
- unknown binary 显示 metadata 并可分享/下载；
- Quick Look 关闭后临时文件清理；
- 分享临时文件和用户下载副本生命周期正确；
- 左滑返回、取消、断线和链接过期行为正常。

### 16.6 文件变更授权

- 未授权写入必定失败；
- 正确密码与正确 Face ID 签名可分别完成同一类操作；
- 错误密码、重放、过期、晚到签名、断线重连和设备撤销失败；
- challenge 绑定源/目标路径和文件身份；
- symlink/TOCTOU 复核有效；
- 默认删除可恢复，永久删除需要独立授权；
- 日志不泄露密码、私钥或文件正文。

## 17. 回滚与恢复

- 统一会话变化流 capability 可关闭并回退当前 recent resume、active continuity
  和最多 8 个 resident watch；
- 列表 UI 回滚不能删除手机完整副本、最近窗口或 canonical history；
- runtime 恢复失败时保留本地只读会话页和重试入口，不清空已有缓存；
- 固定中文化可按独立 Mobile commit 回滚，不改变协议和历史；
- 动态翻译显示层回滚后必须保留原文，不能造成消息丢失；
- Translation native host 在旧 Dart 下 dormant；
- owner read authority 可通过 owner capability/config 关闭，恢复受限目录模式；
- step-up 写操作 capability 关闭时所有新写入口 fail closed；
- 撤销 Face ID 设备或重置密码使未消费授权失效；
- 预览 system-first 回滚时保留现有本地预览、分享和下载；
- 回滚不能删除 canonical history、用户文件、下载副本或其他 Agent 的提交。

## 18. 明确不做

- 不把 resident watch 上限简单改成无限；
- 不为每个历史会话常驻一个 provider runtime、完整内存 snapshot 或高频 poller；
- 不把“所有会话自动同步”解释为首次自动下载所有完整历史；
- 不用定位、音频或其他 iOS 后台模式伪装永久全会话 WebSocket；
- 不把 Agent provider 工具改成每次写入都要求 Face ID；
- 不让 Mobile 自报 Face ID 成功；
- 不把 Mac 绝对路径直接暴露给任意 HTTP 调用者；
- 不新增第二套 Agent path extraction、预览页、分享或下载系统；
- 不向外部文档预览服务上传文件；
- 不用云 API 或 ML Kit 给旧 iOS 补动态翻译；
- 不运行时翻译固定 UI；
- 不翻译命令、代码、路径、payload 和秘密；
- 不因为 Translation framework 提高所有旧系统基础功能门槛；
- 不在本文完成后立即开始实现、部署、发布或构建 IPA。

## 19. 当前完成状态

本文完成只代表：

- 三组产品方案已经合并成一个可检索的实施参考；
- 已知现状、候选架构、兼容、安全、阶段和验收边界已经登记；
- 后续执行者有明确的“先调查、再实现”门禁。

本文不代表：

- 全盘读取已经启用；
- `path_not_allowed` 已经修复；
- Quick Look 路由已经统一；
- 密码或 Face ID 文件授权已经实现；
- 固定英文已经翻译；
- Apple Translation 已经接入；
- 统一会话列表、直接打开或全会话轻量同步已经实现；
- resident 顶部区已经移除或下载图标已经改为勾号；
- Bridge、Mobile、基础 IPA、owner OTA 或 stable 已发生任何变化。
