I'll start by exploring the repo structure and the l10n setup.
Note: the template ARB is `app_ja.arb`, not en. Let me check the ARB files.
Now let me write the scanner script.
Now let me write the scanner script.
Important finding — there's a parallel hand-rolled string system. Let me inspect.
Let me manually verify the top offenders.
A third pattern: binary `zh ? ... : ...`. Let me quantify all patterns.
Now the ARB analysis (tasks 2-4).
扫描完成，仓库未做任何修改（脚本与中间产物只落在 `/Users/huyiyang/AI agent/Codex/scratchpad/`）。

---

# apps/mobile 本地化（l10n）覆盖率量化审查报告

## 0. 关键结论（先看这里）

这个仓库**不是"缺本地化"，而是"有 4 套并行的本地化机制"**，其中 2 套是残缺的。产品要求的"手机固定文案中文化"在 zh 上基本达成（90.5%），但代价是 **ja/ko 出现回归**，且 ARB 单一事实源已经失效。

**扫描口径**：`apps/mobile/lib/` 下 392 个 .dart 文件（已排除 `lib/l10n/` 生成产物、`*.g.dart`、`*.freezed.dart`、`*.gr.dart`），共提取 UI 上下文字面量 + 含 CJK 字面量 **2587 条**。

---

## 1. 量化统计表

### 表 1-1：字符串字面量总体分类（任务 1 的 (a)/(b) 拆分）

| # | 类别 | 数量 | 归属 | 严重度 |
|---|---|---|---|---|
| A1a | **硬编码英文 UI 文案**，无任何 l10n 机制 | **246** | (a) 应本地化 | P1 |
| A2 | **zh/en 二元三目**，ja/ko 降级为英文 | **161**（zh 侧 139 / en 侧 22） | (a) 应本地化（ja/ko 缺失） | P1 |
| A3 | 文件内联 4 语言 `switch`/`_pick` | 68 | 已本地化，架构债 | P2 |
| B | `*_strings.dart` 手写 4 语言类（12 个文件） | 965 | 已本地化，架构债 | P2 |
| C | `mock/` 演示与商店截图数据 | 313（CJK 22 / en 291） | 非生产主路径 | P3 |
| A1b | 纯插值/格式化串（`'+$additions'`、`'${n} / ${m}'`） | 56 | (b) 保留原文 | — |
| T | 命令/路径/provider/技术标识符 | 111 | (b) 保留原文 | — |
| — | **合计** | **2587** | | |

> **(a) 应当本地化的 UI 文案 = 407 条**（A1a 246 + A2 161）
> **(b) 应保留原文 = 167 条**（A1b 56 + T 111）

T 类 111 条的构成：命令行 38、标识符 27、provider/命令名 23（`Codex` / `Claude` / `Bash` / `Grep` / `macOS` / `ccpocket`）、路径 URI 9、点分标识符 8、纯插值 5、纯符号 1。**这部分保留原文是正确的，符合产品要求，无需改动。**

### 表 1-2：按机制的本地化覆盖率

| 机制 | 字符串数 | zh 可用 | ja 可用 | ko 可用 | en 可用 |
|---|---|---|---|---|---|
| ARB / `AppLocalizations` | 1147 调用点 | ✅ | ✅ | ✅ | ✅ |
| `*_strings.dart` + 内联 switch | 1033 | ✅ | ✅ | ✅ | ✅ |
| zh/en 二元三目 | 161 | ✅ | ❌ 退英文 | ❌ 退英文 | ✅ |
| 完全硬编码英文 | 246 | ❌ | ❌ | ❌ | ✅ |
| **有效覆盖率** | **2587** | **90.5%** | **84.3%** | **84.3%** | 100% |

**ARB 渗透率仅 44.4%**（1147 / 2587）—— 超过一半的用户可见文案不走 ARB，无法被翻译流程、审校流程和 lint 覆盖。

### 表 1-3：(a) 类问题按 feature 目录分布 Top 10

| # | 目录 | A1a 硬编码英文 | A2 zh/en 二元 | 小计 |
|---|---|---|---|---|
| 1 | `widgets/` | 93 | 7 | **100** |
| 2 | `utils/` | 0 | 58 | **58** |
| 3 | `features/git/` | 55 | 0 | **55** |
| 4 | `features/file_transfer/` | 0 | 32 | **32** |
| 5 | `services/` | 29 | 0 | **29** |
| 6 | `features/chat_session/` | 10 | 20 | **30** |
| 7 | `features/claude_session/` | 4 | 17 | **21** |
| 8 | `features/session_list/` | 8 | 10 | **18** |
| 9 | `features/side_chat/` | 0 | 10 | **10** |
| 10 | `features/settings/` | 11 | 0 | **11** |

### 表 1-4：ARB 健康度

| 指标 | en | ja | ko | zh |
|---|---|---|---|---|
| 键数 | 872 | 872 | 872 | **949** |
| 相对 en 缺失 | — | **0** | **0** | **0** |
| 相对 en 多余 | — | **0** | **0** | **77** |
| `@meta` 条目数 | 45 | 54 | 39 | 45 |
| 值含 `{ph}` 但未声明 `placeholders` | 14 | 5 | 21 | 20 |
| 值仍为英文（可翻译的） | — | — | — | **约 12**（另 29 条为技术原文，正确） |
| 死条目（lib 内零引用） | **88** | — | — | — |

生成产物一致：`app_localizations.dart` 暴露 872 个 key，四个 locale 实现文件全部对齐。

---

## 2. 逐条发现

### P0 级

**[P0] [/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/apps/mobile/lib/utils/tool_categories.dart:160]**
- **问题**：`getToolDisplayName()` 用 `required bool zh` 布尔开关做双语，58 条工具名（"读取文件"/"运行命令"/"开启子 Agent"…）只有 zh/en 两版，**ja/ko 用户看到英文**。这是聊天流中曝光率最高的文案之一（每个工具调用气泡都渲染）。
- **证据**：
  ```dart
  String getToolDisplayName(String name, {required bool zh, ...})
  // :175
  'Read' => zh ? '读取文件' : 'Read file',
  ```
  三处调用点全部写死 `zh: Localizations.localeOf(context).languageCode == 'zh'`：
  `widgets/bubbles/tool_result_bubble.dart:239`、`:466`、`widgets/bubbles/assistant_bubble.dart:922`。
- **建议**：把 `bool zh` 改成 `AppLocalizations l`（或 `Locale`），58 条 key 全量入 ARB。这是投入产出比最高的一处。

**[P0] [.../apps/mobile/lib/l10n/app_zh.arb:358, :744, :828, :841 等 77 处]**
- **问题**：`app_zh.arb` 比模板多 **77 个 key**，这些 key **完全不会被 `flutter gen-l10n` 生成**（`app_localizations.dart` 中查无此条），是纯死重量，且会误导后续维护者以为文案已中文化。
- **证据**：`"statusRunning": "运行中"`（L744）、`"sandboxModeTitle": "沙箱模式"`（L358）、`"addMachine": "添加设备"`（L828）。验证：`grep "String get statusRunning" lib/l10n/app_localizations.dart` → 0 命中。
- **完整 77 键清单**：`addAndConnect, addMachine, captureEntireDesktop, codexIsAsking, codexSessionDone, codexToolApprovalNeeded, connectionSuccessful, disconnected, displayFirst, displayLast, displaySummary, editMachine, environmentSection, filterAllAiTools, filterAllProjects, filterNamed, fullScreen, machineBasicInfo, machineHostLabel, machineNameHint, machineNameLabel, machineNoSavedDescription, machineRefreshStatus, machineSectionTitle, messageHistoryCount, messageProviderPlaceholder, messagesAppearAfterProcessing, newShort, noMessagesYet, noWindowsFound, permissionAcceptEditsMode, permissionBypassMode, permissionChipAcceptEdits, permissionChipBypass, permissionDefaultMode, permissionModeTitle, permissionPlanMode, portLabel, questionNeedsYourAnswer, runningSessions, sandboxChipOff, sandboxModeTitle, sandboxOffLabel, sandboxOnLabel, sandboxSafeMode, sandboxStandard, screenshotFailed, screenshotSaved, searchSessionsHint, sessionStarted, sshConfiguration, sshCredentialsRequired, sshEnableRemoteStartup, sshPortLabel, sshPrivateKeyHint, sshPrivateKeyLabel, sshRemoteStartupSubtitle, sshUsernameLabel, startWithProvider, statusAnswerQuestion, statusApproval, statusApproveTool, statusApproveToolCall, statusCleaningContext, statusCompacting, statusIdle, statusNeedsYou, statusReady, statusReviewPlan, statusRunning, statusStarting, statusWorking, systemSubtypeLabel, testConnection, testingConnection, toolApprovalNeeded, worktreeTooltip`
- **建议**：其中 `sandboxModeTitle` / `permissionModeTitle` / `status*` 等明显对应 `widgets/session_visual_status.dart`、`features/chat_session/widgets/session_mode_bar.dart` 里的硬编码英文（见下条）——说明**有人写了中文翻译但没把 key 加进 en/ja/ko，导致整批翻译白做**。应把这 77 个 key 补进 en/ja/ko，然后把对应 UI 改成走 ARB。

### P1 级

**[P1] [.../apps/mobile/lib/widgets/slash_command_sheet.dart:83-160]**
- **问题**：43 条斜杠命令描述全部硬编码英文，四语言用户都看到英文。
- **证据**：
  ```dart
  const knownCommands = <String, ({String description, IconData icon})>{
    'compact': (description: 'Compact conversation', icon: Icons.compress),
    'plan': (description: 'Switch to Plan mode', ...),
  ```
- **建议**：命令名 `compact`/`plan` 保留原文（正确），但 `description` 应改为 ARB key。因为是 `const` map，需重构为运行时构建（`Map<String, IconData>` + `l10n.slashCmd<X>Desc`）。

**[P1] [.../apps/mobile/lib/features/git/git_screen.dart:272, :466-493, :548-575, :618-622, :735, :989-1025]**
- **问题**：整个 Git 屏幕 25 条 UI 文案硬编码英文，是本次审查中未本地化最集中的业务界面。
- **证据**：`label: 'View File'`、`subtitle: 'Open the full current file'`、`label: 'Stage'` / `'Unstage'` / `'Revert'` / `'Request Change'`、`Text('Cancel')`、`tooltip: 'Close'` / `'Files'`、`label: 'Revert All'` / `'Stage All'` / `'Commit'`。
- **注意**：同文件 `:511`、`:593` 已在用 `gitDiscardFileUnstagedChangesMessage` 等 ARB key —— 说明是**部分迁移后停滞**。
- **建议**：整屏补齐 ARB。`Stage`/`Unstage`/`Commit` 属于 Git 术语，可考虑保留原文，但需产品显式决策并统一（目前是无决策的遗漏）。

**[P1] [.../apps/mobile/lib/services/bridge_service.dart:772, :778, :820, :826, :832, :838, :919, :1166, :1178, :1391, :1874, :1893, :1915, :1994, :2340, :2495, :2533, :5088]**
- **问题**：18 条用户可见错误提示硬编码英文，且大量重复。
- **证据**：`message: 'Bridge disconnected while preparing the file.'`（重复 6 次）、`'Bridge changed while preparing the file.'`（3 次）、`'Bridge is not connected.'`、`'Bridge connection was closed.'`。
- **建议**：service 层拿不到 `BuildContext`，应改为抛出带错误码的领域异常，由 UI 层映射到 ARB key。这是架构问题，不能靠简单替换解决。

**[P1] [.../apps/mobile/lib/features/file_transfer/file_transfer_sheet.dart:519-570（`_TransferCopy` 类）]**
- **问题**：31 条文件互传界面文案用 `final bool zh` 做双语，ja/ko 退英文。
- **证据**：
  ```dart
  class _TransferCopy {
    final bool zh;
    factory _TransferCopy.of(BuildContext context) =>
        _TransferCopy(Localizations.localeOf(context).languageCode == 'zh');
    String get title => zh ? '文件互传' : 'File Transfer';
  ```
- **建议**：改用同仓库已有的 4 语言模式（参考 `features/side_chat/l10n/side_chat_strings.dart`），或直接入 ARB。

**[P1] 其余 zh/en 二元退化文件（共 13 个文件 / 161 条）**

| 绝对路径 | 条数 |
|---|---|
| `.../lib/utils/tool_categories.dart` | 58 |
| `.../lib/features/file_transfer/file_transfer_sheet.dart` | 31 |
| `.../lib/features/claude_session/widgets/rewind_message_list_sheet.dart` | 14 |
| `.../lib/features/chat_session/widgets/chat_process_disclosure.dart:29-37,148-166,237-324` | 10 |
| `.../lib/features/session_list/session_list_screen.dart:3015-3032` | 10 |
| `.../lib/features/side_chat/widgets/auxiliary_floating_dock.dart:493` | 10 |
| `.../lib/features/chat_session/widgets/chat_input_with_overlays.dart:1289-1305` | 7 |
| `.../lib/features/codex_session/codex_session_screen.dart:1585` | 7 |
| `.../lib/widgets/bubbles/assistant_bubble.dart:922` | 5 |
| `.../lib/features/chat_session/widgets/chat_message_list.dart` | 3 |
| `.../lib/features/claude_session/claude_session_screen.dart:1285` | 3 |
| `.../lib/widgets/bubbles/tool_result_bubble.dart:585` | 2 |
| `.../lib/features/file_transfer/received_file_inbox_banner.dart:36` | 1 |

- **典型证据**（`auxiliary_floating_dock.dart:493`）：
  ```dart
  String _label(BuildContext context, String zh, String en) =>
      Localizations.localeOf(context).languageCode == 'zh' ? zh : en;
  ```
- **典型证据**（`claude_session_screen.dart:1285` 与 `codex_session_screen.dart:1585` 完全重复）：
  ```dart
  Localizations.localeOf(context).languageCode == 'zh' ? '一键全部折叠' : 'Collapse all'
  ```
- **建议**：这 13 个文件是"中文化改造"留下的直接伤疤——为了赶 zh 交付跳过了 ja/ko。应统一收敛，禁止新增 `== 'zh' ?` 模式（可加 lint / CI grep 门禁）。

**[P1] [.../apps/mobile/lib/widgets/session_visual_status.dart:47, :57, :63, :70, :76]**
- **问题**：会话状态标签 `'Needs You'` / `'Working'` / `'Ready'` 硬编码英文，但 `app_zh.arb` 里已存在 `statusNeedsYou` / `statusWorking` / `statusReady` 中文翻译（属于上面的 77 个孤儿 key）。翻译已写好却没接上。
- **建议**：把 3 个 key 补进 en/ja/ko 后，直接替换。属于低成本高收益。

**[P1] [.../apps/mobile/lib/providers/machine_manager_cubit.dart:245, :276, :287, :336, :413, :483]**
- **问题**：6 条 SnackBar 成功提示硬编码英文（`successMessage: 'Machine added successfully'` 等）。
- **建议**：同 bridge_service，Cubit 层应返回语义化结果码而非成品文案。

**[P1] 其余 A1a 硬编码英文集中文件**

| 绝对路径 | 条数 | 样例 |
|---|---|---|
| `.../lib/widgets/session_card.dart:209,1595,1767,1827,1899,2166,2202,2227,2904` | 11 | `'Type your answer...'`、`'Review your answers'`、`'Submit'`、`'(no description)'` |
| `.../lib/features/git/widgets/branch_selector_sheet.dart:75,95,111,180,217,222,230,241,261` | 9 | `'Branches'`、`'Search branches...'`、`'In use by another worktree'`、`'Create & Checkout'` |
| `.../lib/widgets/worktree_list_sheet.dart:90,92,98,106,148,165,221,285` | 8 | `'Remove Worktree'`、`'No worktrees found'`、`'main repo'` |
| `.../lib/widgets/new_session_sheet.dart:2515,2567,2576,2817,3288,3293` | 7 | `'Environment'`、`'Permissions'`、`'Fast — 1.5× speed, more usage'` |
| `.../lib/features/git/widgets/commit_bottom_sheet.dart:64,90,105,140,177,184` | 6 | `'Auto-generate message'`、`'Commit & Push'` |
| `.../lib/widgets/screenshot_sheet.dart:72,138,151,173,177,195` | 6 | `'Screenshot saved'`、`'Capture entire desktop'`、`'No windows found'`（zh 翻译已在 77 孤儿 key 中） |
| `.../lib/models/messages.dart:2714,2739,2758` | 5 | `title: 'Additional Permissions'`、`'Command Approval'`、`'File Change Approval'` |
| `.../lib/screens/qr_scan_screen.dart:55,67,73,101` | 4 | `'Not a valid CC Pocket connection QR code'`、`'Scan QR Code'` |
| `.../lib/features/settings/widgets/theme_bottom_sheet.dart:68,83,88,93` | 4 | `'Theme'`、`'System'`、`'Light'`、`'Dark'` |
| `.../lib/features/explore/explore_screen.dart:182,200,346,357` | 4 | `'Explorer'`、`'No recent open files yet'`（`explorer` 恰是 ARB 死键，见下） |
| `.../lib/features/git/widgets/diff_image_widget.dart:223,261,272,347` | 4 | `'Tap to load preview'`、`'Before'`、`'After'` |
| `.../lib/features/chat_session/widgets/session_mode_bar.dart:495,769,958` | 4 | `'Permissions'`、`'Sandbox'`、`'Permission'`（zh 翻译在 77 孤儿 key 中） |
| `.../lib/features/settings/licenses_screen.dart:61,70,140` | 3 | `'Open Source Licenses'`、`'Search packages...'` |
| `.../lib/features/git/widgets/git_file_list_sheet.dart:94,115` | 3 | `'Files'` |
| `.../lib/features/chat_session/widgets/codex_settings_sheet.dart:141,184` | 3 | `label: 'Speed'` |
| `.../lib/widgets/bubbles/plan_card.dart:96` | 1 | `'Implementation Plan'` |
| `.../lib/features/session_list/workspace_shell_screen.dart:1008,1009` | 2 | `label: 'Resize right pane'`（无障碍标签） |

### P2 级

**[P2] [.../apps/mobile/l10n.yaml:3]**
- **问题**：`template-arb-file: app_ja.arb`，模板是日文而非英文。这解释了为什么 `app_zh.arb` 的 77 个新增 key 被静默丢弃——它们不在 ja 模板中，gen-l10n 直接忽略。任何"先写中文再补其他语言"的流程在此配置下都会静默失效。
- **证据**：
  ```yaml
  arb-dir: lib/l10n
  template-arb-file: app_ja.arb
  preferred-supported-locales: ["ja"]
  ```
- **建议**：要么切换模板到 `app_en.arb`（需同步 `@meta` 声明），要么在 CI 加 key 集合一致性校验，让"多余 key"直接 fail build 而非静默丢弃。

**[P2] 12 个 `*_strings.dart` 平行本地化体系（965 条字符串）**
- **文件清单**（全部含 zh/ja/ko 完整翻译，机制本身正确）：
  ```
  .../lib/features/notification_settings/l10n/notification_settings_strings.dart   169
  .../lib/features/permission_management/l10n/permission_management_strings.dart   116
  .../lib/features/mobile_update/l10n/mobile_update_strings.dart                   112
  .../lib/features/codex_core_actions/codex_core_actions_strings.dart               84
  .../lib/features/conversation_mirror/conversation_mirror_strings.dart             84
  .../lib/features/file_browser/file_browser_strings.dart                           78
  .../lib/features/side_chat/l10n/side_chat_strings.dart                            68
  .../lib/features/auto_approval/auto_approval_strings.dart                         63
  .../lib/features/settings/cache_management_strings.dart                           54
  .../lib/features/session_insights/l10n/session_insights_strings.dart              46
  .../lib/features/subagents/l10n/subagents_strings.dart                            46
  .../lib/features/session_archive/session_archive_strings.dart                     45
  ```
- **问题**：这些文案**永远不会出现在 ARB 翻译流程里**，无法被外部译者、翻译记忆库、术语一致性检查覆盖。4 个 `conversation_mirror` / `file_browser` / `notification_settings` / `session_archive` / `cache_management` 甚至没有独立的 `_en` 字段，靠 `languageCode` bool getter 拼装。
- **建议**：不必立即重构（功能正确），但应作为技术债登记，新功能强制走 ARB，并加 CI 规则禁止新增 `*_strings.dart`。

**[P2] [.../apps/mobile/lib/l10n/app_en.arb — 88 个死条目]**
- **问题**：872 个 key 中 88 个在 `lib/` 下零引用（已用严格 + 宽松双重匹配交叉验证，并额外在 `test/` 下复核）。翻译成本 88×4 = 352 条无效翻译。
- **完整清单（88 条，全部列出）**：
  `agentReadyForPrompt, allClear, always, apiKeyHint, apiKeyOptional, appIconMonthlySupporterPerk, appIconSupporterDialogTitle, approveForSession, archiveConfirm, archiveConfirmMessage, backToSessions, bestStreak, changeExecutionModeBody, changeExecutionModeTitle, codexApprovalNeverDescription, codexApprovalOnFailureDescription, codexApprovalOnRequestDescription, codexApprovalUntrustedDescription, codexAutoReview, codexAutoReviewUnavailableDescription, codexPlanModeDescription, copyForAgent, defaultNotRecommended, diffLines, executionAcceptEditsDescription, executionDefaultDescription, executionFullAccessDescription, explorer, fcmBridgeNotInitialized, fcmDisabled, fcmDisabledPending, fcmEnabledPending, indentSizeSubtitle, itemsProcessed, lineCopied, lineCountSummary, machineEditDismissKeyboardTooltip, modelOptional, noActiveSessions, noMatchingPrompts, orConnectManually, pushNotifications, pushNotificationsSubtitle, pushNotificationsUnavailable, reasoning, reasoningEffortHighDesc, reasoningEffortLowDesc, reasoningEffortMaxDesc, reasoningEffortMediumDesc, reasoningEffortMinimalDesc, reasoningEffortModelSpecificDesc, reasoningEffortNoneDesc, reasoningEffortUltraDesc, reasoningEffortXhighDesc, resetQueue, searchHint, serverRequiresApiKey, serverUrlHint, sheetSubtitleSandboxCodex, showAll, startSessionToBegin, stopSessionConfirm, supportBannerAction, supporterImpactDevicesBody, supporterImpactDevicesTitle, supporterLearnMoreBody, supporterLearnMoreTitle, supporterRestoreNoticeBody, supporterRestoreNoticeTitle, supporterSummarySinceChip, supporterSummaryStreakChip, supporterSummaryStreakLabel, swipeApprove, swipeDismiss, swipeReject, swipeSend, swipeSkip, terminalAppSubtitle, tooltipPermissionMode, updateDownloaded, updateTrack, updateTrackDescription, updateTrackStable, updateTrackStaging, usageConnectToView, viewChanges, waitingForApprovalRequests, waitingForTasks`
- **值得注意的交叉信号**：
  - `explorer`（"Explorer"）是死键，而 `features/explore/explore_screen.dart:182` 却硬编码了 `Text('Explorer')` —— **key 存在但没人用，UI 反而写死英文**。同类还有 `searchHint`、`viewChanges`、`noActiveSessions`。
  - `reasoningEffort*Desc` 共 9 条 + `codexApproval*Description` 共 4 条 + `execution*Description` 共 3 条，成组死亡，疑似整个设置面板被重写过但旧 key 未清理。
  - `swipeApprove/Dismiss/Reject/Send/Skip` 5 条成组死亡，疑似滑动手势提示 UI 被移除。
- **建议**：优先复活 `explorer` / `searchHint` / `viewChanges` / `noActiveSessions` 这类"key 有翻译、UI 写死英文"的（直接消掉 P1 问题），其余删除。

**[P2] `@meta` 占位符声明缺失（en 14 / ja 5 / ko 21 / zh 20）**
- **问题**：值里有 `{placeholder}` 但对应 `@key.placeholders` 未声明。因为模板是 ja，最终以 ja 的声明为准，非模板语言的缺失不影响编译，但破坏了 ARB 的自描述性，且一旦切换模板会立刻炸。
- **en 缺失清单（14）**：`galleryWithCount{count}, sshPasswordPrompt{machineName}, deleteMachineConfirm{displayName}, minutesAgo{minutes}, hoursAgo{hours}, daysAgo{days}, worktreeExisting{count}, diffLines{count}, diffSummaryAddedRemoved{added,removed}, lineCountSummary{count}, submitWithCount{count}, allWithCount{count}, itemsProcessed{count}, bestStreak{count}`
- **ja 缺失清单（5）**：`removeProjectConfirm{name}, toolSuggestionTitle{toolName}, toolSuggestionInstall{toolName}, toolSuggestionConnect{appName}, rewindConfirmBody{mode}` — **这 5 条在模板语言里缺失，风险最高**。
- **ko 缺失（21）/ zh 缺失（20）**：在 ja 的基础上再叠加 en 的那批。
- **占位符集合不一致**：跨语言实际使用的 `{ph}` 集合，**0 处真实不一致**（初筛命中的 `supporterSummaryDurationMonths` 是 ICU plural 语法 `{count, plural, =1{1개월} ...}` 导致的误报，已排除）。

### P3 级

**[P3] [.../apps/mobile/lib/l10n/app_zh.arb — zh 仍为英文的值]**
- **总量**：41 条值不含汉字。其中 **29 条为正确保留原文**（命令 `npx --yes @ccpocket/bridge@latest`、路径 `/path/to/your/project`、`-----BEGIN OPENSSH PRIVATE KEY-----`、品牌 `CC Pocket` / `Codex` / `Claude` / `Git` / `iPhone`、快捷键 `Ctrl+V` / `Cmd+V`、域名、`English` / `한국어` 语言自称）——**完全符合产品要求，不应改动**。
- **12 条疑似漏译**（含 key 与行号）：

| 行号 | key | zh 当前值 | ja | ko | 判断 |
|---|---|---|---|---|---|
| L104 | `machineEditPort` | `Port` | Port | Port | 四语言一致英文，可能是有意的技术术语；建议→`端口` |
| L113 | `machineEditSshUsername` | `SSH Username` | 同 | 同 | 建议→`SSH 用户名` |
| L115 | `machineEditSshPort` | `SSH Port` | 同 | 同 | 建议→`SSH 端口` |
| L118 | `machineEditPrivateKey` | `Private Key` | 同 | 同 | 建议→`私钥` |
| L124 | `machineEditSshJumpHost` | `SSH Jump Host` | 同 | 同 | 建议→`SSH 跳板机` |
| L125 | `machineEditJumpHost` | `Jump Host` | 同 | 同 | 建议→`跳板机` |
| L127 | `machineEditJumpPort` | `Jump Port` | 同 | 同 | 建议→`跳板端口` |
| L128 | `machineEditJumpUsername` | `Jump Username` | 同 | 同 | 建议→`跳板用户名` |
| L132 | `machineEditJumpPassword` | `Jump Password` | 同 | 同 | 建议→`跳板密码` |
| L344 | `effort` | `Effort` | Effort | Effort | 建议→`推理强度` |
| L399 | `reasoning` | `Reasoning` | Reasoning | **`추론`** | **ko 已译，zh/ja 未译 → 明确的不一致** |
| L400 | `webSearch` | `Web Search` | Web Search | **`웹 검색`** | **ko 已译 → 明确的不一致** |
| L1076 | `supporterTitle` | `Supporter` | Supporter | Supporter | 建议→`支持者` |
| L1248 | `goalTokensUnit` | `tokens` | tokens | tokens | 计量单位，保留可接受 |

- **零日文残留**：`app_zh.arb` 中**没有任何**平假名/片假名（0 条）。
- **一条韩文**：L1045 `authHelpLanguageKo = '한국어'` —— 语言自称，**正确**。
- **结论**：**zh 翻译质量很高**，唯一系统性问题是 `machineEdit*` 一组（9 条）连接配置字段全部保留英文，且 `reasoning` / `webSearch` 与 ko 不一致。

**[P3] [.../apps/mobile/lib/mock/mock_scenarios.dart / store_screenshot_data.dart / .../lib/screens/mock_preview_screen.dart]**
- **问题**：313 条硬编码字符串（英文 291 / 中文 22）。`mock_preview_screen.dart` 通过 `lib/router/app_router.dart:19` 注册进路由，**会进 release 包**，但仅用于商店截图生成，非用户主路径。
- **建议**：不作为 l10n 缺口计入。若要减小包体可考虑用 `--dart-define` 剥离。

---

## 3. 修复优先级建议

1. **立刻**：修复 `l10n.yaml` 的静默丢 key 问题（或加 CI key 集合校验）—— 否则 77 个孤儿 key 的悲剧会重演。
2. **P0**：`tool_categories.dart` 58 条工具名入 ARB（曝光率最高，且直接修复 ja/ko 回归）。
3. **P0**：把 77 个 zh 孤儿 key 补进 en/ja/ko，并接上 `session_visual_status.dart`、`session_mode_bar.dart`、`screenshot_sheet.dart` 的硬编码英文 —— **翻译已经写好了，只差接线，性价比极高**。
4. **P1**：加 CI 门禁禁止新增 `== 'zh' ?` 与 `*_strings.dart`，冻结增量。
5. **P1**：`git_screen.dart`（25 条）+ `slash_command_sheet.dart`（43 条）两个大块补齐。
6. **P2**：清理 88 个死 key（先挑出 `explorer` 等 4 个"有 key 无用"的复活）。
7. **P3**：补 `machineEdit*` 9 条 + `reasoning` / `webSearch` / `effort` / `supporterTitle` 的中文。

---

**脚本位置**（可复现，均在 scratchpad，未污染仓库）：
- `/Users/huyiyang/AI agent/Codex/scratchpad/l10n_scan.py` — Dart 词法级字符串提取 + UI 上下文判定
- `/Users/huyiyang/AI agent/Codex/scratchpad/classify.py` — 本地化机制普查
- `/Users/huyiyang/AI agent/Codex/scratchpad/final.py` / `final2.py` 逻辑 — 五分类归并
- `/Users/huyiyang/AI agent/Codex/scratchpad/arb_check.py` — 死键 / 键一致性 / 占位符
- `/Users/huyiyang/AI agent/Codex/scratchpad/zh_quality.py` — zh 漏译抽查
