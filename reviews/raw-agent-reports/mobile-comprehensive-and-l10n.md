I'll start by exploring the repository structure to understand the codebase layout.
Large review scope. Let me dispatch parallel investigations while I survey the core myself.
Only one subagent slot was available. I'll handle the rest directly. Starting with the update/release chain (B).
已完成 A–E 全部审查（menubar 部分由并行子代理完成）。以下为最终报告。

---

# CC Pocket 移动端综合代码审查报告

审查对象：`_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725`（只读，未修改任何文件）

---

## A. 本地化覆盖率扫描

### A.0 量化统计

**ARB 键统计**

| 文件 | 键数 | 相对模板(ja)缺失 | 多余 |
|---|---|---|---|
| `app_ja.arb`（模板） | 872 | — | — |
| `app_en.arb` | 872 | 0 | 0 |
| `app_ko.arb` | 872 | 0 | 0 |
| `app_zh.arb` | **949** | 0 | **77** |

**硬编码用户可见字符串**（口径：`Text(...)` / `label:` / `hintText:` / `labelText:` / `tooltip:` / `helperText:` / `semanticsLabel:` / `errorText:` 参数位的字面量；已排除 `lib/l10n/`、`*.g/.freezed/.gr.dart`、`lib/mock/`、路径与 URL）

| 指标 | 数量 |
|---|---|
| 含插值的字面量总数 | 202 |
| **纯字面量（无插值）** | **132** |
| 其中含 CJK 字符 | **0**（全部为英文） |
| ARB 之外的临时本地化表 | **17 个**（12 个顶层 `*Strings` 类 + 5 个私有 `_*Copy` 类） |
| 模板中定义但代码从未引用的死条目 | **88 / 872（10.1%）** |

**按文件分布 TOP 10（纯字面量）**

| # | 文件 | 数量 | 样例 |
|---|---|---|---|
| 1 | `lib/screens/mock_preview_screen.dart` | 16 | `'Mock Preview'` / `'Scenarios'` |
| 2 | `lib/features/git/widgets/branch_selector_sheet.dart` | 9 | `'New Branch'` / `'Create & Checkout'` |
| 3 | `lib/widgets/session_card.dart` | 7 | `'worktree'` |
| 4 | `lib/widgets/worktree_list_sheet.dart` | 7 | `'Remove Worktree'` |
| 5 | `lib/features/codex_session/codex_session_screen.dart` | 6 | `'Explore'` |
| 6 | `lib/features/git/widgets/commit_bottom_sheet.dart` | 6 | `'Commit'` / `'Commit & Push'` |
| 7 | `lib/features/settings/settings_screen.dart` | 6 | `'Bridge machine'` |
| 8 | `lib/widgets/screenshot_sheet.dart` | 6 | `'Screenshot saved'` |
| 9 | `lib/services/store_screenshot_extension.dart` | 5 | `'CC Pocket'` |
| 10 | `lib/features/explore/explore_screen.dart` | 4 | `'Explorer'` / `'No recent open files yet'` |

**按 feature 目录聚合 TOP 5**：`features/git` 35 → `features/settings` 24 → `screens/`（mock_preview）19 → `widgets/bubbles` 16 → `features/claude_session` 11

**AppLocalizations 采用率（按 feature）**

| feature | 使用 AppLocalizations 的文件 |
|---|---|
| `features/explore` | **0 / 8** |
| `features/file_transfer` | **0 / 10** |
| `features/git` | 4 / 28 |
| `features/session_insights` | 1 / 3 |

**"应保留原文" vs "应中文化" 分类**（针对 `app_zh.arb` 中 41 条无中文字符的条目）

- **应保留原文（24 条）**：`setupStep1Command='npx --yes @ccpocket/bridge@latest'`、`serverUrlHint='ws://<host-ip>:8765'`、`projectPathHint='/path/to/your/project'`、`branchHint='feature/...'`、`machineEditOpenSshPrivateKeyHint='-----BEGIN OPENSSH PRIVATE KEY-----'`、`machineEditJumpHostHint='bastion.example.com'`、`imagePasteShortcutCtrlV='Ctrl+V'`、`appTitle='CC Pocket'`、`git='Git'`、`authHelpLanguageEn='English'` 等 —— 命令、路径模板、快捷键、产品名、语言自称，符合产品原则。
- **应中文化但漏译（约 17 条）**：`machineEditPort='Port'`、`machineEditSshUsername='SSH Username'`、`machineEditSshPort='SSH Port'`、`machineEditPrivateKey='Private Key'`、`machineEditSshPrivateKeyPem='SSH Private Key (PEM)'`、`machineEditSshJumpHost='SSH Jump Host'`、`machineEditJumpHost='Jump Host'`、`machineEditJumpPort='Jump Port'`、`machineEditJumpUsername='Jump Username'`、`machineEditJumpPassword='Jump Password'`、`machineEditJumpPrivateKeyPem='Jump Private Key (PEM)'`、`effort='Effort'`、`reasoning='Reasoning'`、`webSearch='Web Search'`、`supporterTitle='Supporter'`、`goalTokensUnit='tokens'` —— 这些是**字段标签**而非技术标识符，中文用户在"编辑机器"整屏看到的是英文。

---

### 发现清单

**[A1] [P1] `apps/mobile/lib/l10n/app_zh.arb`（77 处 zh 独有键）**
- 问题：`app_zh.arb` 比模板 `app_ja.arb` **多出 77 个键**，其中 **76 个未在 `app_localizations_zh.dart` 中生成 getter**，即 76 条已完成的中文译文**永远不会显示在 UI 上**。
- 触发场景：`l10n.yaml` 的 `template-arb-file: app_ja.arb`，gen-l10n 只按模板键集生成 getter，非模板语言的多余键被静默丢弃（仅产生一条 warning）。
- 证据：失效译文包括 `addAndConnect='添加并连接'`、`addMachine='添加设备'`、`editMachine='编辑设备'`、`connectionSuccessful='连接成功！'`、`captureEntireDesktop='截取整个桌面'`、`codexToolApprovalNeeded='需要你批准 Codex 的工具操作'`、`disconnected='已断开连接'`、`statusIdle/statusRunning/statusStarting/statusApproval/statusCompacting`、`machineNameLabel`、`machineHostLabel` 等。这批键名与 A.0 中"应中文化但漏译"的机器编辑界面高度重合 —— **说明中文化工作实际做了，但因为没有同步写入模板而全部丢失**。
- 建议：把这 77 个键补进 `app_ja.arb`（模板）及 `app_en.arb`/`app_ko.arb`，重跑 `flutter gen-l10n`；同时在 CI 加一条 ARB 键集一致性校验（模板 ⊇ 各语言），使这类丢失无法再次静默发生。

**[A2] [P1] 全项目 17 处 ARB 之外的临时本地化表**
- 问题：除 ARB 外还存在**两套平行机制**，共 17 个本地化表，完全脱离 ARB 工具链（无键一致性校验、无 `avoid_hardcoded_japanese` lint 覆盖、无翻译进度可视化）。
- 证据：
  - 12 个顶层 `*Strings` 类：`features/mobile_update/l10n/mobile_update_strings.dart:6`、`features/permission_management/l10n/permission_management_strings.dart:5`、`features/subagents/l10n/subagents_strings.dart:4`、`features/side_chat/l10n/side_chat_strings.dart:5`、`features/notification_settings/l10n/notification_settings_strings.dart:3`、`features/session_insights/l10n/session_insights_strings.dart:7`、`features/codex_core_actions/codex_core_actions_strings.dart:3`、`features/settings/cache_management_strings.dart:3`、`features/conversation_mirror/conversation_mirror_strings.dart:3`、`features/auto_approval/auto_approval_strings.dart:3`、`features/file_browser/file_browser_strings.dart:3`、`features/session_archive/session_archive_strings.dart:3`
  - 5 个**私有** `_*Copy` 类（连文件都不独立）：`features/file_transfer/file_transfer_sheet.dart:520`、`features/chat_session/widgets/chat_input_with_overlays.dart:1278`、`features/session_list/session_list_screen.dart:3006`、`features/permission_management/permission_management_screen.dart:375`、`features/file_browser/file_mutation_authorization.dart:232`
- 建议：至少统一为「一个 feature 一个 `l10n/xxx_strings.dart`」的规范并全部覆盖 4 语言；长期应回归 ARB。若确实要保留（如 `mobile_update_strings.dart:5` 注释所述"便于整体移除 OTA 模块"），需要在 CI 加一个针对这些类的字段数一致性检查。

**[A3] [P2] `apps/mobile/lib/features/file_transfer/file_transfer_sheet.dart:520-522`（另见 `chat_input_with_overlays.dart:1278`、`session_list_screen.dart:3006`）**
- 问题：3 个 `_*Copy` 类是**二元 zh/en 开关**，日语与韩语用户拿不到本地化。
- 触发场景：日语（本项目的模板语言、主要用户群）用户打开「文件互传」整个面板显示英文。
- 证据：
  ```dart
  final bool zh;
  factory _TransferCopy.of(BuildContext context) =>
      _TransferCopy(Localizations.localeOf(context).languageCode == 'zh');
  String get title => zh ? '文件互传' : 'File Transfer';
  ```
  该文件 `grep -c "'ja'"` = 0、`"'ko'"` = 0。这是本次中文化工作引入的**回归**（原本可能是纯英文，加中文时未按 4 语言结构改造）。
- 建议：改为与其他 `*Strings` 类相同的 `switch (languageCode) { 'zh' => _zh, 'ja' => _ja, 'ko' => _ko, _ => _en }` 四语言结构。

**[A4] [P2] `apps/mobile/lib/features/explore/`（0/8 文件）与 `lib/features/file_browser/`、`lib/features/git/`（4/28 文件）**
- 问题：`explore` feature **完全没有任何本地化机制**，全部为硬编码英文；`git` feature 仅 4/28 文件接入。
- 证据：`explore_screen.dart:182` `chrome.wrapTitle(const Text('Explorer'))`、`explore_screen.dart:357` `Text('No recent open files yet')`、`explore_breadcrumbs.dart:57`；`git_screen.dart:618,622` `Text('Cancel')`/`Text('Revert')`、`branch_selector_sheet.dart:217,230,241` `'New Branch'`/`'Cancel'`/`'Create & Checkout'`、`commit_bottom_sheet.dart:90,105,177,184` `'Done'`/`'Try Again'`/`'Commit'`/`'Commit & Push'`、`diff_image_widget.dart:223` `'Tap to load preview'`。
- 说明：这里的 `'Commit'`、`'Revert'` 等虽然是 Git 概念，但作为**按钮文案**属于 UI 文案而非命令原文，应中文化为「提交」「还原」；而分支名 `feature/...`、路径、`git` 命令本身应保留。
- 建议：优先补齐 `git`（35 条，用户高频）与 `explore`（8 文件）两个 feature。

**[A5] [P2] `apps/mobile/l10n.yaml:3-4` 与全部 17 个临时表的 fallback 不一致**
- 问题：ARB 侧 `template-arb-file: app_ja.arb` + `preferred-supported-locales: ["ja"]` → 不受支持语言回落**日语**；而所有临时表统一 `_ => _en` → 回落**英语**。
- 触发场景：设备语言为 fr/de/es 等任一非 zh/ja/ko/en 语言时，同一屏内会同时出现日语（ARB 文案）与英语（17 个临时表文案）。
- 证据：`mobile_update_strings.dart:98-104` `switch (...) { 'zh' => _zh, 'ja' => _ja, 'ko' => _ko, _ => _en }`。
- 建议：统一 fallback 语义（推荐两侧都改为 `en`，并把 `l10n.yaml` 的 preferred 改为 `["en"]`），或在临时表中把 default 改为 `_ja`。

**[A6] [P2] ARB 死条目 88 个（10.1%）**
- 问题：`app_ja.arb` 中 88 个键在 `lib/` 下（排除生成产物）从未被引用，四个语言文件各携带一份译文（合计 352 条无效翻译）。
- 证据（前 25 条）：`agentReadyForPrompt`、`allClear`、`always`、`apiKeyHint`、`apiKeyOptional`、`appIconMonthlySupporterPerk`、`appIconSupporterDialogTitle`、`approveForSession`、`archiveConfirm`、`archiveConfirmMessage`、`backToSessions`、`bestStreak`、`changeExecutionModeBody`、`changeExecutionModeTitle`、`codexApprovalNeverDescription`、`codexApprovalOnFailureDescription`、`codexApprovalOnRequestDescription`、`codexApprovalUntrustedDescription`、`codexAutoReview`、`codexAutoReviewUnavailableDescription`、`codexPlanModeDescription`、`copyForAgent`、`defaultNotRecommended`、`diffLines`、`executionAcceptEditsDescription`。
- 注意：其中部分可能通过动态查表使用（如 `l10n` 反射式访问），删除前需逐条确认。
- 建议：写一个 `tool/arb_lint.dart`，同时校验「模板 ⊇ 各语言」「模板键均被引用」两条规则，接入 CI。

**[A7] [P3] `apps/mobile/analysis_options.yaml:19` — lint 只覆盖日语硬编码**
- 问题：`avoid_hardcoded_japanese: true` 是唯一启用的硬编码文案 lint；对硬编码**英文**与**中文**均无检测。
- 影响：A.0 统计出的 132 条硬编码英文字面量全部不会被静态检查发现，本次中文化的"最终扫描"缺乏自动化兜底。
- 补充：4 处 `// ignore_for_file: altive_lints_plugin/avoid_hardcoded_japanese`（`lib/mock/mock_sessions.dart:1`、`lib/mock/mock_scenarios.dart:1`、`features/settings/widgets/speech_locale_bottom_sheet.dart:1`、`features/settings/widgets/app_locale_bottom_sheet.dart:1`）经核查均为合理豁免（mock 数据、语言选择器需显示语言自称）。
- 建议：追加自定义 lint 或复用上述 `arb_lint.dart` 扫描 `Text('...')` 参数位。

**[A8] [P3] `apps/mobile/lib/screens/qr_scan_screen.dart:54`**
- 问题：`content: Text('Not a valid CC Pocket connection QR code')` 硬编码英文，且该 SnackBar 在**每一帧**检测到非法条码时都会弹出。
- 触发场景：摄像头对准任意无关二维码时，SnackBar 以相机帧率刷屏。
- 建议：接入 ARB；同时加防抖（记录上次提示时间，≥2s 才再次提示）。

**[A9] [P3] `apps/mobile/lib/features/debug/debug_screen.dart:67-69`**
- 问题：`const Text('Force support prompts')` 与 `const Text('Show the home support banner and settings spread appeal regardless of eligibility.')` 硬编码英文。
- 说明：该页面在 release 构建中可达（见 E4/B4），不属于纯开发者不可见页面。

---

## B. 更新与发布链路

**[B1] [P1] `apps/mobile/lib/features/mobile_update/mobile_update_models.dart:5` vs `.github/workflows/ios-patch.yml:8-15` vs `CLAUDE.md`**
- 问题：Shorebird track 名称在**代码、CI、文档三方不一致**，导致通过 GitHub Actions 发布的补丁**任何 App 构建都收不到**。
- 证据：
  - 代码：`enum MobileUpdateChannel { stable, owner }`，`mobile_update_gateway.dart:62` `UpdateTrack(channel.name)` → 只会查询 `stable` / `owner`
  - CI：`ios-patch.yml:11-15` 与 `android-patch.yml:11-15` 的 `track` 输入 `default: 'staging'`，`options: [staging, stable]` —— **没有 `owner` 选项**
  - 本地脚本：`.claude/skills/shorebird-patch/patch.sh:67` `--track=owner`（与代码一致）
  - 文档：`CLAUDE.md` "パッチはデフォルトで **staging** に配信される" + "アプリのデバッグ画面（ロゴ5連打）で Update Track を Staging に変更して検証可能"
- 触发场景：走 CI 发补丁 → 默认落到 `staging` → App 永远查不到 → 补丁静默丢失，发布者以为已投放。
- 附带：文档描述的入口也是错的 —— track 切换实际在**设置页版本条目 7 连击**（`settings_screen.dart:1769`），不是调试页 5 连击。
- 建议：三方统一为 `owner`（把 CI 的 choice 改为 `owner`/`stable`，同步 `CLAUDE.md`）；并在 `patch.sh` / workflow 中加一条断言：track 值必须存在于 `MobileUpdateChannel` 枚举中。

**[B2] [P1] `apps/mobile/lib/features/mobile_update/mobile_update_service.dart`（全文件）— 无回滚与 kill-switch**
- 问题：整个 OTA 链路**没有任何回滚路径**。补丁下载后重启即生效；若补丁导致启动崩溃，用户无法在 App 内退回基础版本，服务端也没有远端停用开关。
- 触发场景：一个 `owner` 通道补丁在特定机型上启动即崩 → 该用户永久卡死，只能删除重装（丢失本地会话数据库）。且 `shorebird.yaml:14` 已 `auto_update: false`，禁用了引擎侧的自动更新逻辑，全部依赖 App 内实现，而 App 内实现没有崩溃检测。
- 建议：① 记录"补丁 N 首次启动"标记，若启动后 X 秒内未到达首帧则下次启动自动回退（Shorebird 支持通过删除 patch 目录降级）；② 在设置页增加"回退到基础版本"按钮；③ 建立服务端撤回流程（把 `stable` track 指回旧 patch number）并写入 runbook。

**[B3] [P2] `apps/mobile/lib/features/settings/settings_screen.dart:1762-1778` + `mobile_update_service.dart:173-186`**
- 问题：所谓"开发者设置"仅靠**设置页版本条目连点 7 次**解锁，任何普通用户都能触发；解锁后写入安全存储且**没有再次锁定的入口**。
- 触发场景：普通用户误触/照攻略操作后切到 `owner` 通道，从此持续接收**未经真机验证**的补丁（`shorebird-patch/SKILL.md` 明确说明 owner 是待验证通道）。
- 证据：`_versionTapCount < 7` → `service.unlockDeveloperSettings()` → `_secureStore.write(_developerUnlockedKey, 'true')`；`MobileUpdateService` 中无对应的 lock/reset 方法。
- 建议：解锁后在 `_UpdateChannelCard` 增加"退出开发者模式"按钮（写回 `'false'` 并强制 `setChannel(stable)`）；或把解锁条件改为需要输入一个只有维护者知道的短口令。

**[B4] [P2] `apps/mobile/lib/features/session_list/session_list_screen.dart:717-729` + `2357-2360`**
- 问题：首页 AppBar 标题的 5 连击调试入口**没有 `kDebugMode` 守卫**，在 release 构建中完全可用。
- 触发场景：release 版用户连点标题 5 次进入 `DebugScreen`，可访问：① **Talker 完整应用日志查看器**（`debug_screen.dart:78-82`，`Bloc.observer = TalkerBlocObserver` 记录了全部 Bloc 状态迁移，含机器 host/port/SSH 用户名，虽不含密钥）；② Mock Preview（见 E4）；③ 强制显示付费/捐赠引导开关。
- 证据：
  ```dart
  title: GestureDetector(onTap: _onTitleTap, child: Text(l.appTitle)),
  ...
  if (_debugTapCount >= 5) { _debugTapCount = 0; context.router.push(const DebugRoute()); }
  ```
  `lib/` 全文 grep `kReleaseMode` 仅命中 `release_error_widget.dart:32` 一处，此处无任何守卫。
- 建议：`if (!kDebugMode) return;` 置于 `_onTitleTap` 首行；若需保留线上诊断能力，改为「设置 → 关于 → 长按版本号」并加二次确认，且日志页做路径/主机名脱敏。

**[B5] [P2] `apps/mobile/lib/features/mobile_update/mobile_update_service.dart:188-214`**
- 问题：从 `owner` 切回 `stable` 时，如果此刻已有 owner 通道下载完成但未应用的补丁，`setChannel` 会保留 `MobileUpdatePhase.restartRequired` 并继续提示重启 —— 用户重启后装上的仍是**已声明放弃的 owner 补丁**。
- 证据：
  ```dart
  phase: _hasDownloadedPatchWaiting ? MobileUpdatePhase.restartRequired : MobileUpdatePhase.idle,
  clearTargetPatchNumber: !_hasDownloadedPatchWaiting,
  ```
  UI 文案 `mobile_update_strings.dart:128` 也承认了这点（"切换通道只影响以后检查的更新，不会立即降级已经安装的补丁"），但用户的心智是"我要退出测试版"。
- 建议：切到更保守通道时提供"丢弃待应用补丁"选项，或至少把提示文案改成明确的"待应用的补丁来自 owner 通道"。

**[B6] [P2] `apps/mobile/lib/services/app_update_service.dart:347-358`（另见 `lib/models/machine.dart:17-34`）— 版本号解析边界**
- 问题：`_isNewer` 用 `s.split('.').map((s) => int.tryParse(s) ?? 0)`，任何非纯数字段静默变 0。
- 触发场景：`1.2.3-beta.1` → `["1","2","3-beta","1"]` → `[1,2,0,1]` → 被当作 `1.2.0`。预发布版被判定为**比正式版更旧**（本例侥幸符合预期），但 `1.3.0-rc1` vs `1.2.9` → `1.3.0-rc1` 变成 `1.3.0` 判定更新（不符合 semver 预发布规则）。另仅比较前 3 段，`+build` 号完全忽略。
- 关联：`machine.dart:29-33` 的 `_semanticVersionCore` 只特判了本 fork 的 `-compat.N` 后缀，注释明确"Other prerelease labels retain the official app's existing conservative comparison"，即已知问题但未处理。
- 建议：改用 `pub_semver` 包的 `Version.parse` / `Version.prioritize`，或至少显式拒绝解析失败的版本号（返回"未知，不提示更新"而非当作 0）。

**[B7] [P2] `apps/mobile/lib/services/app_update_service.dart:164-175, 201-213` — macOS 更新路径的展示与执行不一致**
- 问题：当 Sparkle 探测未返回更新、但 `canUseNativeUpdater()` 为 true 时，代码用 **GitHub Releases 的版本号与下载链接**构造 `AppUpdateInfo`，却把 `installMode` 标为 `nativeUpdater`；随后 `performUpdate` 走 `_gateway.performUpdate()`（Sparkle），安装的是 **Sparkle appcast 里的版本，而非 UI 上展示的那个 GitHub 版本**。
- 触发场景：Sparkle appcast 落后于 GitHub Release 时，用户看到 "v1.110.0 可用"，点更新后实际装上 v1.109.x，且无任何提示。
- 建议：两条路径的版本来源必须一致 —— 要么完全信任 Sparkle（探测无更新即不显示 banner），要么 GitHub 路径固定用 `externalDownload`。

**[B8] [P3] `apps/mobile/lib/main.dart:582-588` + `mobile_update_service.dart:124-135`**
- 问题：每次 App `resumed` 都调用 `checkInBackground()`，而 `_lastCheckedAtKey` **只在 `_gateway.check()` 成功后写入**（`mobile_update_service.dart:243-246`）。持续失败时（离线/服务端故障）没有任何退避，每次切回前台都重试一次网络请求。
- 建议：失败时也记录时间戳（用独立的 `_lastFailedAtKey` + 指数退避），或在 `_setFailure` 中写入一个较短的冷却时间。

**[B9] [P3] `apps/mobile/lib/features/mobile_update/mobile_update_screen.dart:127-137`**
- 问题：`state.failureDetail` 是 Shorebird SDK 抛出的**原始英文异常字符串**，直接渲染给用户。与"手机固定文案中文化"的产品要求冲突，且可能包含内部 URL / 文件路径。
- 建议：release 构建下只显示已本地化的 `l.failure(kind)`，原始 detail 折叠到"查看详情"或仅写入日志。

**[B10] [P3] `apps/mobile/lib/main.dart:158`**
- 问题：`await mobileUpdateService.initialize()` 位于 `main()` 的同步启动路径上，其内部串行 `await` 了安全存储读取 + 2 次 Shorebird 平台通道调用（`_refreshPatchNumbers`）。Keychain 在设备刚解锁时可能有明显延迟。
- 建议：改为 `unawaited(...)`，由 `MobileUpdateSettingsTile` / `MobileUpdateScreen` 的 `initialize()` 幂等调用（`_initialization ??=`）兜底 —— 该幂等机制已经存在，可直接利用。

**（正面）** 通道切换、下载确认、单飞（`_singleFlight`）、失败分类（`_classifyFailure` 区分 signature / versionMismatch / network）、`shouldPromptRestart` 与 `dismissRestartPrompt` 的配对、`MobileUpdateRestartPrompt` 的 listener 增删（`didUpdateWidget` + `dispose` 都正确处理）均实现完整，无内存泄漏。`shorebird.yaml:14` `auto_update: false` 与 App 内显式流程的设计是正确的。

---

## C. apps/menubar（此前完全未审）

### 架构概述

`apps/menubar` 是一个独立的 **macOS 菜单栏 App**（Swift 6.2 / SwiftUI，XcodeGen，`MACOSX_DEPLOYMENT_TARGET = 26.0`），约 3100 行 / 26 个 Swift 文件。定位是「Mac 端 Bridge 控制台 + 首次安装向导」：帮用户安装 Node / Codex CLI / Bridge，把 Bridge 注册为 launchd 服务，展示配额用量，并生成供手机扫描的连接二维码。

- **入口**：`App/MenuBarApp.swift`（`@main`，Scene 仅空 `Settings`），实际逻辑在 `App/AppDelegate.swift` —— 手动创建 `NSStatusItem` + `NSPanel`（非 popover），内嵌 `NSHostingView(PopoverContentView)`。`Info.plist` `LSUIElement = true`，纯后台。
- **模块**：`Services/`（`BridgeClient` HTTP、`BridgeProcessManager` 子进程、`DoctorRunner`、`NetworkDiscovery`、`QRCodeGenerator`）→ `ViewModels/`（4 个 `@MainActor ObservableObject`）→ `Views/`（Usage / Connect(QR) / Doctor 三 Tab + `OnboardingView`）→ `Models/`（Codable DTO）。
- **与 Bridge 的通信**：**明文 HTTP**，`BridgeClient.swift:9` 硬编码 `http://localhost:\(port)`（用的是 `localhost` 而非 `127.0.0.1`；不是 `0.0.0.0`，方向正确）。端口来自 `UserDefaults["bridgePort"]`，为 0 则回落 8765 —— 而**该 key 全仓库无任何写入点**，实际永远是 8765。**客户端不发任何 Authorization 头**；Bridge 侧 `/usage` `/doctor` 本应鉴权，但 `isDirectLoopbackRequest()` 对回环放行，属于"靠 loopback 豁免"而非真有认证。超时：普通 5s、doctor 60s。
- **第二条通道（风险集中处）**：大量通过 `Process` 拉起 `/bin/zsh -li -c "<字符串>"` 执行 npm / brew / launchctl / CLI 登录。`BridgeProcessManager` 不直接托管 Bridge 进程，而是 `launchctl load/unload ~/Library/LaunchAgents/com.ccpocket.bridge.plist`。
- **工程化现状**：`.github/workflows/` 下 13 个 workflow **无一引用 menubar** —— 无 CI、无签名配置、当前不参与发布。

### 发现清单

**[C1] [P0] `apps/menubar/CCPocketMenubar/Services/BridgeProcessManager.swift:35-39`（同 `Services/DoctorRunner.swift:49-52`）— 经典 Pipe 死锁**
- 问题：`process.waitUntilExit()` 在前、`pipe.fileHandleForReading.readDataToEndOfFile()` 在后。管道缓冲（~64KB）写满后子进程阻塞在 write，父进程卡在 waitUntilExit —— 互相等待。
- 触发场景：**必然发生**。`brew install node`、Homebrew 安装脚本、`npm install -g @anthropic-ai/claude-code` 的输出都远超 64KB。表现为「Install Node.js」按钮转圈直到 300s/600s 超时报错，而安装可能已成功一半。
- 加剧：超时仅 `process.terminate()`（SIGTERM 给 zsh），**不杀进程组**；孙进程仍持有管道写端，`readDataToEndOfFile()` 可能永久阻塞。
- 建议：改用 `readabilityHandler` 异步收集（先读后等），或输出重定向到临时文件；超时时 `setsid` 建独立进程组并 `kill(-pgid, SIGKILL)`。

**[C2] [P1] `apps/menubar/CCPocketMenubar/Services/BridgeProcessManager.swift:80-85` — shell 字符串拼接命令注入（潜伏）**
- 证据：`var cmd = "npx --yes @ccpocket/bridge@latest setup"`；`if let apiKey, !apiKey.isEmpty { cmd += " --api-key \(apiKey)" }`，参数无引号、无转义，最终交给 `zsh -li -c`。
- 触发场景：任何未来把 API Key 输入框接到 `DoctorViewModel.setupBridge(port:apiKey:)` 的改动。当前 `DoctorPageView.swift:184` 只传 nil，**暂不可达**，属于埋雷。
- 附带：命令行参数在 `ps` 中全局可见，密钥走命令行本身即泄露。
- 建议：废弃 `shell(_ command: String)` 整套 API，改为 `Process.arguments = [...]` 逐参数传递；密钥走 `process.environment`。

**[C3] [P1] `apps/menubar/CCPocketMenubar/Services/BridgeProcessManager.swift:65,70,77` — 家目录路径未加引号插入 shell**
- 证据：`plistPath = NSHomeDirectory() + "/Library/LaunchAgents/..."` 直接拼进 `launchctl load \(plistPath)`。家目录含空格时参数被拆分，Bridge 启停静默失败。

**[C4] [P1] `apps/menubar/CCPocketMenubar/Services/BridgeProcessManager.swift:110-115`（触发点 `ViewModels/DoctorViewModel.swift:181,321`）— curl | bash 静默 RCE**
- 证据：`"/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""`，无 checksum、无签名、无版本 pin，在一个**未开沙箱**的 GUI App 中由「Install Node.js」按钮触发。`HEAD` 意味着内容随时可变。
- 建议：改走已存在的 `openTerminalGuide`（`BridgeProcessManager.swift:158`）让用户自己在终端执行；或 pin 到 commit SHA 并校验 sha256。

**[C5] [P1] `apps/menubar/CCPocketMenubar/Views/QRCodePage/QRCodePageView.swift:52-56,81` + `ViewModels/QRCodeViewModel.swift:19-20,51-56` — 连接凭据明文同屏 + 密钥存 UserDefaults**
- 三重问题：① `buildConnectionURL` 把 API Key 作为 `token=` 编入 `ccpocket://connect?url=ws://<内网IP>:<port>&token=<key>`；② 该串既渲染成二维码，**又以可选中的明文 `Text` 直接显示**（`:81`，仅中间截断，支持 `textSelection` 复制）—— 截屏、录屏、屏幕共享、肩窥全部泄露长期凭据；③ 密钥来源 `UserDefaults.standard.string(forKey:"bridgeApiKey")`，明文落在 `~/Library/Preferences/*.plist`，**未进 Keychain**。
- 更严重：由于 `bridgeApiKey` 从未被写入（见 C9），二维码今天实际是**无 token 的 `ws://` 明文地址**；结合 Bridge 默认 `BRIDGE_HOST=0.0.0.0` 且默认无 API Key，等于向同一 LAN 广播一个可直接取得 Claude/Codex CLI 执行能力的**无鉴权入口**。
- 建议：密钥迁 Keychain；明文 deep link 默认打码、token 永不明文渲染；检测到 Bridge 未配置 API Key 时给出红色告警而非照常出码。

**[C6] [P1] `apps/menubar/CCPocketMenubar/Services/BridgeProcessManager.swift:11`（同 `Services/DoctorRunner.swift:27`）— 在 continuation 内同步阻塞协作线程池**
- 问题：`shell` / `runDoctorCLI` 为 `nonisolated async`，continuation body 直接在协作线程池线程上跑 `waitUntilExit()`，最长阻塞 600s。协作线程池线程数 = CPU 核数，几个并发安装即可耗尽，拖垮整个 async 运行时。

**[C7] [P1] `apps/menubar/CCPocketMenubar/Services/BridgeProcessManager.swift:110-115,142-152` — 交互式命令在无 TTY 下执行，功能实际不可用**
- Homebrew 安装脚本需按 RETURN 且需 sudo（无 tty 时 `sudo: no tty present` 直接失败）；`claude auth login` / `codex --login` 是需 TTY 的交互式 OAuth 流程。三者都用 `Process` + `Pipe`（无伪终端）拉起，大概率直接失败或挂到 120s 超时。

**[C8] [P2] `apps/menubar/CCPocketMenubar/Services/BridgeProcessManager.swift:81,89,94` + `Services/DoctorRunner.swift:30` — `npx --yes @ccpocket/bridge@latest` 供应链风险**
- 4 处 `--yes`（跳过确认）+ `@latest`（不锁版本）下载并执行代码；`installOrUpdateBridge` 还是 `npm install -g`。npm 包被投毒时用户点一下「Update」即中招。

**[C9] [P2] `apps/menubar/CCPocketMenubar/ViewModels/QRCodeViewModel.swift:15,20` + `Services/BridgeClient.swift:12` — `bridgePort`/`bridgeApiKey` 只读不写，无设置界面**
- 全仓库 grep 这两个 key：3 处读、**0 处写**。用户执行 `bridge setup --port 9000` 或设置 `BRIDGE_API_KEY` 后，菜单栏 App 仍连 8765、仍生成无 token 二维码，Usage/Doctor 长期显示「Bridge Not Running」。
- 建议：补设置面板（密钥存 Keychain），或直接解析 `~/Library/LaunchAgents/com.ccpocket.bridge.plist` 的 `EnvironmentVariables`。

**[C10] [P2] `apps/menubar/CCPocketMenubar/CCPocketMenubar.entitlements:1-9` — 未开启 App Sandbox**
- entitlements 只有 `com.apple.security.network.client`，**无 `com.apple.security.app-sandbox`**（`project.yml:31` 已开 `ENABLE_HARDENED_RUNTIME`）。对需要 `Process` 拉起 zsh/npm/brew 的 App 是必然，但后果需明确：无法上架 MAS；被篡改的 `~/.zshrc` 会以完整用户权限运行；无文件访问范围限制。`network.client` 范围正确（未申请 `network.server`）。

**[C11] [P2] `apps/menubar/CCPocketMenubar/Services/BridgeProcessManager.swift:13-14`（同 `DoctorRunner.swift:29-30`）— 一律用 `zsh -li`**
- `-i` 会 source 用户 `~/.zshrc`，App 的每次探测（含每次打开面板触发的 `npm view`）都在执行用户任意 shell 配置；无 TTY 时易触发 job-control 警告 / `compinit` 提示甚至阻塞。建议改 `zsh -lc`。

**[C12] [P2] `apps/menubar/CCPocketMenubar/Services/BridgeProcessManager.swift:213-217`（同 `DoctorRunner.swift:71`）— 原始子进程输出直接作为用户可见错误**
- `ProcessError` 匹配不到已知模式时 `return String(trimmed.suffix(200))`，把 zsh 合并 stdout+stderr 尾部原样抛给 UI（`DoctorPageView.swift:117`、`OnboardingView.swift:173`）。`claude auth login` / `npm` 失败时输出常含家目录绝对路径、registry 认证错误、临时 token 片段。

**[C13] [P2] `apps/menubar/CCPocketMenubar/Views/PopoverContentView.swift:39-45` — `onAppear` 只触发一次，面板数据不刷新**
- `NSHostingView` 在 `AppDelegate.swift:28-30` 创建后终生存在，靠 `orderOut`/`orderFrontRegardless` 显隐（`:75,86`），不保证触发 SwiftUI disappear/appear。注释「Fetch on popover open instead of polling」的意图未实现，第二次点击图标看到的是陈旧数据。

**[C14] [P2] `apps/menubar/CCPocketMenubar/ViewModels/AppViewModel.swift:120,128-137` — 每次健康检查都 fork 登录 shell 访问 npm registry**
- `checkHealth()` 成功后无条件 `checkForBridgeUpdate` → `zsh -li -c "npm view @ccpocket/bridge version"`，即「source 整个 .zshrc + 一次网络往返」，1–3s 起步，且无去重。建议加 24h 缓存或直接 `URLSession` 请求 registry。

**[C15] [P2] `apps/menubar/CCPocketMenubar/Localizable.xcstrings` — 仅英语(源) + 日语，无中文**
- `sourceLanguage = "en"`，125 个 key，`localizations` 仅含 `ja`（覆盖 125/125）。**无 zh-Hans / zh-Hant / ko**。若该 App 面向中文用户需新增 zh-Hans 125 条。
- 注意：其中约 8 个 key（`Git`、`Keychain access`、`Screen Recording`、`Port availability` 等）是 Bridge 端 doctor 检查名，走 `Models/DoctorReport.swift:25-31` 的**运行时动态查表**，编译器不提取，新增 Bridge 检查项时必须手工同步。

**[C16] [P2] `apps/menubar/project.yml:33` — `DEVELOPMENT_TEAM: ""` + 无任何 CI**
- 13 个 workflow 全文 grep `menubar`/`CCPocketMenubar`/`xcodegen` **零命中**。`ENABLE_HARDENED_RUNTIME: YES` 加空 TEAM，只能 ad-hoc 签名，无法公证，用户下载会被 Gatekeeper 拦截。
- 建议：补 `menubar-release.yml`（xcodegen → xcodebuild archive → Developer ID → notarytool → DMG），或明确标注为实验性目录。

**[C17] [P2] `apps/menubar/CCPocketMenubar/Info.plist:4-7` — 只有 `LSUIElement`，缺关键 Bundle 键**
- 整个 plist 只有一个 key。`project.yml:13-14` 定义了 `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`，但既未设 `GENERATE_INFOPLIST_FILE=YES` 也未设 `INFOPLIST_KEY_*` → 产物很可能缺 `CFBundleShortVersionString`/`CFBundleVersion`，而公证与 `SMAppService` 均依赖版本键。

**[C18] [P2] `apps/menubar/CCPocketMenubar/Services/BridgeProcessManager.swift:146` vs `ViewModels/DoctorViewModel.swift:358` — 同一动作两套不一致命令**
- 程序化执行 `"claude auth login"`，复制给用户的是 `"claude login"`（后者才是实际子命令）。`codex --login`（`:148`/`:360`）同样需核实。

**[C19] [P3] 其他**
- `Services/NetworkDiscovery.swift:7-57`：`getifaddrs` 只过滤 `127.*`，Docker bridge（172.17.x）、link-local、其他 VPN 的 utun 都会列出；`ip.hasPrefix("100.")` 判 Tailscale 不严谨（应为 100.64.0.0/10）。信息仅本机展示，风险低。
- `ViewModels/QRCodeViewModel.swift:28`：`addresses.first(where: { $0.label == "LAN" })` **用已本地化字符串做逻辑判断**（`label` 来自 `NetworkDiscovery.swift:45,47` 的 `String(localized: "LAN")`）。一旦某语言译作「局域网」，自动选址静默失效并回落到可能是 Docker 网卡的 `addresses.first`。
- `Services/BridgeClient.swift:34-36`：每次 `doctor()` 新建 `URLSession` 且从不 `invalidateAndCancel()`，每次刷新泄漏一个 session。
- 未取消的裸 `Task { }`：`AppViewModel.swift:93,112,129`、`DoctorViewModel.swift:101,383`、`UsageViewModel.swift:17`。其中 `DoctorViewModel.performAction`（`:379`）**无并发守卫**，连点两次「Install Codex」会并发跑两个 `npm install -g`。
- Swift 侧硬编码未本地化字符串共 **9 处 / 4 文件**：`Views/UsagePage/UsagePageView.swift:108,115`（`"5-hour"`/`"7-day"`，经 String 变量走 `Text` verbatim 重载，不参与本地化且不在 xcstrings 中）、`Models/UsageInfo.swift:16,18,24,26`（`"—"`/`"now"`/`"\(hours)h \(minutes)m"`）、`Services/DoctorRunner.swift:71`、`Services/BridgeProcessManager.swift:216`、`Views/PopoverContentView.swift:145`。
- xcstrings 中约 15 条僵尸 key（`Welcome to CC Pocket`、`Get Started`、`You're All Set!` 等改版残留）。
- 死代码：`BridgeProcessManager.isServiceRegistered()`、`DoctorViewModel.uninstallBridge()`、`allSetupCommands(for:)`、`openSetupTerminal(for:)`、`copySetupCommands()` 全部零调用点。
- `CCPocketMenubar.xcodeproj/project.pbxproj` 与 XcodeGen 的 `project.yml` 并存且都被提交，会漂移。

**（正面）** 无硬编码密钥（全量 grep 仅 `https://openai.com/codex` 与 Homebrew 安装脚本 URL）；`Info.plist` 无 `NSAllowsArbitraryLoads`（ATS 默认生效）；**全项目 0 个 `Timer`**（无轮询）；`AppDelegate.swift:80` 的全局事件监听闭包正确使用 `[weak self]`，**未发现 retain cycle**；无 force try、无数组越界风险。

---

## D. 构建与依赖

**[D1] [P1] `apps/mobile/pubspec.yaml:92-97` + `apps/mobile/pubspec.lock:946-954`**
- 问题：`dependency_overrides` 把 `irondash_engine_context` 指向**第三方 GitHub fork** `https://github.com/Sabbar-Engineering/irondash`，且 `ref: HEAD`（跟随该 fork 默认分支）。
- 触发场景：任何一次 `flutter pub upgrade` 或 lock 刷新，都会静默拉取该第三方仓库的最新代码进入构建产物。`irondash` 是 `super_clipboard` / `super_drag_and_drop` 的底层，直接处理**剪贴板与拖放数据**。
- 证据：`pubspec.lock` 中 `resolved-ref: "3c8667f62ab0643361f4d9b393ab2b6229d28801"`，说明当前构建被 lock 固定；但 `pubspec.yaml` 中的 `ref` 未固定，锁文件是唯一防线。
- 建议：把 `ref:` 显式改为该 commit SHA（`ref: 3c8667f62ab0643361f4d9b393ab2b6229d28801`）；跟踪 `irondash/irondash#77` 合并进度并尽快移除 override；若长期需要，考虑改为在本组织下 vendored 一份并自行审计。

**[D2] [P2] `.github/workflows/test.yml:74`**
- 问题：CI 门禁 `dart analyze .` **未加 `--fatal-infos`**。Dart 默认 error/warning 致命、**info 不致命**，而 `flutter_lints` 绝大多数规则产出的是 info 级 —— 即**所有 lint 违规都不会让 CI 失败**。
- 影响：`analysis_options.yaml` 中配置的 `avoid_hardcoded_japanese` 等规则在 CI 中形同虚设，本地 hook 是唯一防线。
- 建议：改为 `dart analyze --fatal-infos .`（先跑一次评估存量违规数量，必要时分阶段收紧）。

**[D3] [P2] `.github/workflows/test.yml:1-6` — 缺 `permissions:` 块**
- 问题：唯一由 `pull_request` 触发的 workflow **没有顶层 `permissions:`**，使用仓库默认 GITHUB_TOKEN 权限（可能是 write-all）。其余 8 个 release workflow 都正确设置了 `permissions:`。
- 建议：加 `permissions: contents: read`。

**[D4] [P2] `apps/mobile/pubspec.yaml:46` — `flutter_markdown` 已停止维护**
- `flutter_markdown` 已被 Flutter 团队标记 discontinued，不再接收修复（含安全修复）。本项目在 `lib/theme/markdown_style.dart` 上有大量定制（682 行），迁移成本不低，但需要纳入计划。
- 建议：评估迁移到 `flutter_markdown_plus` 或 `markdown_widget`；短期至少在 `decisions.md` 记录该风险并锁定版本。

**[D5] [P2] `apps/mobile/pubspec.yaml:41` — `marionette_flutter` 位于 production dependencies**
- 问题：UI 自动化框架被列为运行时依赖而非 `dev_dependencies`，其代码会被链接进 release 产物。虽然 `main.dart:111` 用 `kDebugMode` 守卫了 `MarionetteBinding.ensureInitialized()`，但包本身仍在包体内。
- 建议：确认 `marionette_flutter` 是否支持放入 `dev_dependencies`（若 `MarionetteBinding` 只在 debug 使用则应可行）；若不可行，至少在发布前用 `--split-debug-info` + 产物符号检查确认无自动化入口被暴露。

**[D6] [P2] `apps/mobile/analysis_options.yaml`（全文件）— 静态检查强度不足**
- 未启用 `analyzer: language: strict-casts / strict-raw-types / strict-inference` → **允许隐式 dynamic 转换**（直接导致 E3 的 `dynamicArgs.sessionId` 问题无法被发现）。
- 未启用 `avoid_dynamic_calls`、`unawaited_futures`（项目大量手写 `unawaited(...)`，无 lint 兜底）、`prefer_final_locals`、`always_declare_return_types`。
- 无 `analyzer: errors:` 段（正面：**没有把任何告警降级为 ignore**）；无 `exclude` 段（正面：**没有排除任何真实代码**）。
- 建议：优先启用 `strict-casts: true` 与 `avoid_dynamic_calls`，与 D2 的 `--fatal-infos` 配套推进。

**[D7] [P3] `apps/mobile/pubspec.yaml:35` — `intl: any`**
- 无版本约束，仅靠 `pubspec.lock` 与 `flutter_localizations` 的传递约束固定。建议改为显式 `^0.20.x`（与 lock 中解析值一致）。

**[D8] [P3] `apps/mobile/lib/theme/app_theme.dart:295-340` — `google_fonts` 运行时联网取字体**
- 问题：使用 `GoogleFonts.ibmPlexSansTextTheme()` / `GoogleFonts.spaceGrotesk(...)`，但 `pubspec.yaml:175-184` 的 `fonts:` **只打包了 3 个等宽代码字体**，IBM Plex Sans / Space Grotesk 未随包分发；且全项目未设置 `GoogleFonts.config.allowRuntimeFetching = false`（grep 零命中）。
- 影响：App 首次启动会向 `fonts.gstatic.com` 发起 HTTP 请求下载字体 —— 属于需要在隐私政策中披露的第三方网络请求；离线首启时排版回退到系统字体。
- 建议：把两个字体本地打包（体积可控，可只取需要的字重），并设 `allowRuntimeFetching = false`；或在 `PRIVACY_POLICY.md` 中补充说明。

**[D9] [P3] `.github/workflows/`（全部）— 无格式门禁**
- `grep -rn "dart format" .github/workflows/` 零命中。格式一致性仅靠本地 `pre-stop-check` hook 保障，外部贡献者的 PR 不受约束。
- 建议：在 `test.yml` 加 `dart format --set-exit-if-changed .`。

**（正面，无需修改）**
- **所有第三方 action 均已 pin 到完整 commit SHA**（`actions/checkout@3d3c42e5...`、`subosito/flutter-action@1a449444...`、`shorebirdtech/setup-shorebird@4dd9d7dc...` 等），供应链实践优秀。
- 无 `pull_request_target`、无 `continue-on-error: true`、无 `|| true`、无 secret 回显。
- `npm audit`：根工作区与 `functions/` **均为 0 个已知漏洞**。
- `firestore.rules`：写得很紧 —— `bridges/{bridgeId}/tokens/{tokenId}` 要求 `request.auth.uid == bridgeId`，其余 `match /{document=**} { allow read, write: if false; }` 全拒。
- `patches/` 目录仅含一份部署记录 Markdown（`bridge-runtime-deploy_v13_20260726-010033.md`），**无代码补丁**，不涉及安全行为改动。
- 340 处 `// ignore: cast_nullable_to_non_nullable` 与 25 处 `implicit_dynamic_type` 经核查**全部位于生成文件**（`.freezed.dart`/`.g.dart`），手写代码中零命中，非滥用。
- `shorebird.yaml`：`app_id` 硬编码但官方明确说明其非机密；`auto_update: false` 与 App 内显式流程配套，配置正确。

---

## E. router / screens / theme / mock

**[E1] [P1] `apps/mobile/lib/features/session_list/session_list_screen.dart:484-490` + `main.dart:895-907` + `android/app/src/main/AndroidManifest.xml:30` / `ios/Runner/Info.plist:37-40`**
- 问题：深链接 `ccpocket://connect?url=...&token=...` 被解析后**直接连接，无任何用户确认**；连接成功后还会把攻击者的 host/port/token **持久化写入本机 Machines 列表**。
- 触发场景：用户点击网页/聊天消息中的恶意 `ccpocket://connect` 深链（携带
  攻击者 Bridge 地址与伪凭据）→ App 静默把会话入口指向攻击者服务器 →
  用户后续输入的所有 prompt 发往攻击者；攻击者可返回任意伪造的“工具审批
  请求”（展示任意文件路径与 diff）进行钓鱼。
- 证据：
  ```dart
  void _onDeepLink() {
    final params = widget.deepLinkNotifier?.value;
    if (params == null) return;
    widget.deepLinkNotifier?.value = null;
    _connectWithParams(params.serverUrl, params.token);   // 无确认
  }
  ```
  `_connectWithParams` 中唯一的分支是 `if (health == null && mounted)` 才弹 `_showSetupGuide` —— **健康检查成功时直接连接并 `machineManagerCubit.recordConnection(host:..., apiKey: trimmedApiKey ...)` 落库**。QR 扫码路径（`qr_scan_screen.dart:44-47`）同理。
- 缓解因素：iOS/Android 在从浏览器跳转自定义 scheme 时通常有一次系统级"是否打开 CC Pocket"提示，但那不是对**连接目标**的确认。
- 建议：所有来自 deep link / QR 的连接请求，在连接前弹出确认对话框，明确展示目标 `host:port`、是否携带 token、以及"此操作会把该服务器加入你的设备列表"；对非 `wss://` 的外网地址额外警告。

**[E2] [P2] `apps/mobile/lib/router/app_router.gr.dart:119-246`（`ClaudeSessionRouteArgs`）与 `:250-403`（`CodexSessionRouteArgs`）— 生成产物陈旧**
- 问题：已确认的 `durableProviderSessionId` 缺参问题**恰好影响 2 个路由**，且是 `.gr.dart` 未重新生成导致。
- 证据：我对全部 19 个 `@RoutePage` 屏幕的构造函数参数与生成的 `*RouteArgs` 做了逐字段比对，结果：
  | 屏幕 | 生成产物 | 状态 |
  |---|---|---|
  | `ClaudeSessionScreen`（`claude_session_screen.dart:87`） | `ClaudeSessionRouteArgs` | **缺 `durableProviderSessionId`** |
  | `CodexSessionScreen`（`codex_session_screen.dart:96`） | `CodexSessionRouteArgs` | **缺 `durableProviderSessionId`** |
  | `AdaptiveHomeScreen` / `ExploreScreen` / `GalleryScreen` / `GitScreen` / `SessionLinkScreen` / `SettingsScreen` / `SetupGuideScreen` / `WorkspaceClaudeSessionScreen` / `WorkspaceCodexSessionScreen` | 对应 Args | 全部一致 ✓ |
  | 其余 8 个无参屏幕 | `PageRouteInfo<void>` | 一致 ✓ |
  `grep durableProviderSessionId lib/router/app_router.gr.dart` → **0 命中**。
- 影响：通过 `ClaudeSessionRoute(...)` / `CodexSessionRoute(...)` 导航时（`session_link_screen.dart:111,122`、`session_list_screen.dart:1743,1755`）该参数恒为 `null`，`claude_session_screen.dart:208,230,242,252,477,491` 与 `codex_session_screen.dart:240,262,274,284,521,535` 中的 durable-id 分支全部走 null 路径。
- 建议：跑 `dart run build_runner build --delete-conflicting-outputs` 重新生成；并在 CI 加一步「重新生成后 `git diff --exit-code`」，防止 `.gr.dart` 再次陈旧。

**[E3] [P2] `apps/mobile/lib/router/session_route_observer.dart:68-81` 与 `:50-63`**
- 问题（类型安全）：`_extractSessionId` 用 **dynamic 调用** `dynamicArgs.sessionId` 并以裸 `catch (_)` 吞掉 `NoSuchMethodError`：
  ```dart
  try {
    final dynamic dynamicArgs = arguments;
    return dynamicArgs.sessionId?.toString();
  } catch (_) { return null; }
  ```
  任何 Args 类字段改名都会**静默降级为"无活动会话"**而不是编译错误。`avoid_dynamic_calls` 与 `strict-casts` 都未启用（见 D6），静态检查无法发现。
- 问题（功能 bug）：观察者只识别 `ClaudeSessionRoute.name` / `CodexSessionRoute.name`。而在工作区（平板/桌面）布局下，会话是作为**内嵌 Widget** 渲染的（`workspace_shell_screen.dart:1187,1205` 直接构造 `WorkspaceClaudeSessionScreen`，`WorkspaceClaudeSessionRoute` 虽被生成但**未注册进 `AppRouter.routes`**），活动会话由 `workspace_shell_screen.dart:740` 的 `selectSession` 单独登记。两套机制写同一个全局单例：
  - 用户在工作区打开会话 → `setActiveSession(A)`
  - 推入 `SettingsRoute` → 观察者 `didPush` 发现 args 无 `sessionId` → `clearActiveSession()`
  - 返回 → 观察者 `didPop` → `_syncActiveSession(AdaptiveHomeRoute)` → 仍无 `sessionId` → **再次 `clearActiveSession()`**
  - `selectSession` 不会被重新调用（`_selectedSession` 未变）→ **活动会话永久丢失**
- 影响：用户正在看的会话会继续收到推送通知（`NotificationService` 的"当前会话不打扰"逻辑失效）。
- 建议：① `_extractSessionId` 改为对已知 Args 类型做显式 `is` 分支；② 观察者在遇到 `AdaptiveHomeRoute` 时不要清除，改为把权威来源交给 `WorkspaceShellScreen`（例如 `didPop` 回到 Home 时回调 shell 重新登记 `_selectedSession`）。

**[E4] [P2] `apps/mobile/lib/router/app_router.dart:46` + `lib/screens/mock_preview_screen.dart` + `lib/mock/`**
- 问题：mock 数据与 mock 预览界面**会被编译进 release 产物且在 release 中可达**。
- 证据：
  - `AutoRoute(page: MockPreviewRoute.page, path: '/mock-preview')` 无条件注册；`app_router.dart:19` 无条件 `import '../screens/mock_preview_screen.dart'` → Dart tree-shaker 无法移除。
  - 可达路径：首页标题 5 连击（B4）→ `DebugScreen` → `debug_screen.dart:89` `context.router.push(MockPreviewRoute())`。
  - 体积：`lib/mock/` 5,881 行（`mock_scenarios.dart` 3,514 + `store_screenshot_data.dart` 910 + `mock_sessions.dart` 811 + `mock_image_data.dart` 646）+ `mock_preview_screen.dart` 1,582 + `mock_bridge_service.dart` 885 + `store_screenshot_extension.dart` 1,603 + `replay_bridge_service.dart` 290 ≈ **12,000 行**。
  - 对比：`store_screenshot_extension.dart:64`、`mock_preview_extension.dart:9`、`performance_probe_extension.dart:12` 都有 `if (!kDebugMode) return;` —— 但那只守卫了 **Marionette 扩展的注册**，不影响代码被链接进产物，也不影响 UI 入口可达。
- 建议：把 `MockPreviewRoute` 的注册包在 `if (kDebugMode)` 内（auto_route 的 `routes` getter 支持条件构造），并把 `lib/mock/` 与 mock 相关 service 移出主 import 图（例如放到单独的 dev-only entrypoint `lib/main_dev.dart`）。

**[E5] [P3] `apps/mobile/lib/mock/mock_scenarios.dart:181,202,203,204,221`**
- 问题：mock 数据中硬编码了**开发者真实机器的绝对路径**：`/Users/k9i-mini/Workspace/ccpocket/...`（5 处）。结合 E4，这些字符串随 release 产物一起分发，暴露维护者的 macOS 用户名与工作目录布局。
- 对照：`lib/mock/mock_sessions.dart` 全部使用 `/Users/demo/Workspace/...`（正确做法）。
- 建议：统一替换为 `/Users/demo/...`。

**[E6] [P3] `apps/mobile/lib/features/mobile_update/mobile_update_settings_tile.dart:39-41`**
- 问题：`MobileUpdateScreen` 用 `Navigator.of(context).push(MaterialPageRoute(...))` 打开，绕过 auto_route。该屏幕因此无路由名（`SessionRouteObserver` 会把它当作无 sessionId 的路由触发 `clearActiveSession`，加剧 E3）、不可深链、不出现在路由栈的可观测性中。
- 建议：加 `@RoutePage()` 并注册进 `AppRouter.routes`，与其他屏幕保持一致。

**[E7] [P3] `apps/mobile/lib/screens/mock_preview_screen.dart:65`（模式共 102 处）**
- 问题：`Theme.of(context).extension<AppColors>()!` 强制解包，全项目 **102 处**。
- 现状：`app_theme.dart:109` 在 `_buildTheme` 中通过 `extensions: [appColors]` 注册，light/dark 两条路径（`:515` `AppColors.light()` / `:560` `AppColors.dark()`）都覆盖，因此当前安全。
- 风险：任何用局部 `Theme(data: ThemeData(...))` 包裹的子树（例如第三方组件、预览、测试）都会让这 102 处同时抛 null check 异常。
- 建议：提供 `AppColors.of(context)` 扩展方法，内部 `?? AppColors.light()` 兜底。

**（正面）**
- **CJK 字体回退已正确实现**：`app_theme.dart:16-27` 定义 `['PingFang SC', 'Noto Sans CJK SC']`，`:388-391` 在 `languageCode == 'zh'` 时 `textTheme.apply(fontFamilyFallback:)`；`main.dart:976-978` 的 `themeLocale = appLocale ?? platformDispatcher.locale` 确保「跟随系统」的中文用户同样生效。（可考虑扩展到 `ja`/`ko`，因 IBM Plex Sans 同样无假名/谚文字形。）
- `connection_url_parser.dart:86-96` 的 `_isValidWebSocketUrl` 对 scheme 与端口范围做了正确校验；IPv6 带方括号的形式也有单独处理。
- `markdown_style.dart:19` 的 `_HighlightSpanCache(maxEntries: 80)` 有容量上限，`:65-67` 在高亮器初始化后主动 `clear()`，无无界缓存泄漏。
- `theme/` 目录整体质量良好，颜色全部走 `ColorScheme` / `AppColors` 扩展，未发现散落的硬编码颜色。

---

## 优先处理建议（跨 A–E，按投入产出排序）

1. **[E1]** deep link / QR 自动连接加确认对话框 —— 唯一一个"可被外部主动触发、后果最严重"的移动端问题。
2. **[C1]** menubar 的 Pipe 死锁 —— 唯一一个"必然复现、功能直接不可用"的缺陷。
3. **[B1]** 统一 Shorebird track 为 `owner`（代码/CI/文档三方）—— 否则走 CI 发的补丁 100% 丢失。
4. **[A1]** 把 77 个 zh 独有键补进模板并重跑 gen-l10n —— 一次操作即可恢复 76 条已完成但失效的中文翻译，是本次中文化收益最高的单点修复。
5. **[B4] + [E4]** 给 5 连击调试入口加 `kDebugMode` 守卫，并把 `MockPreviewRoute` 条件注册 —— 一并解决 release 可达的日志查看器、mock 界面与 [E5] 的开发者路径泄露。
6. **[C2]/[C3]/[C4]/[C7]** menubar 把 `shell(String)` 整体替换为参数数组 API，交互式命令改走 `openTerminalGuide` —— 一次重构消灭命令注入、路径未引号、`curl|bash` RCE、无 TTY 必失败四个问题。
7. **[D2] + [D6] + [E2]** CI 加 `--fatal-infos` + `strict-casts` + `.gr.dart` 重新生成校验 —— 建立能自动拦截 E2/E3 这类问题的门禁。
8. **[D1]** 把 `irondash` fork 的 `ref: HEAD` 固定到 commit SHA。
9. **[B2]** 设计 OTA 回滚 / kill-switch 机制（可与 [B3] 的开发者模式再锁定一并做）。
10. **[A3] + [A4]** 修 3 个 zh/en 二元 `_*Copy` 类的日韩回归，补齐 `git`（35 条）与 `explore`（8 文件）两个 feature 的本地化。
