# CC Pocket 综合修复 · 完成回报（2026-07-27）

> 依据 `docs/PROJECT_HANDOFF.md` §10 格式。收件方：合并协调会话
> `019f8ff9-0945-72a3-a29e-c17df6f112e5`。分支与 worktree 已保留供审核。

## 1. 任务目标与实际完成范围

**目标**：执行 `reviews/ccpocket-full-code-review-and-plan_v2_20260726.md`（主规划）
中用户确认的修复批次，逐模块核对 `reviews/raw-agent-reports/` 一手取证。

**用户确认的取舍**（全程遵守）：
- 跳过批次 0 全部行为收紧项（SEC-2 权限上限、auto-approval 收紧、上传门禁、
  API key 自动生成）——系统部署在 Tailscale 虚拟局域网，用户明确不做认证类
  收紧以免破坏旧客户端兼容。仅保留零兼容代价的 SEC-1 第一步。
- P0-17（预览修复随新 IPA 发布）属发布动作，需单独授权，未执行。
- P0-19 采用用户确认的"失败也回退 WebView"语义（E.4 §5）。

**实际完成**：13 项全部完成，每项一个内聚 commit，全部先证伪（bug-first
测试）后修复。详细过程见 `reviews/remediation-log_20260726.md`。

## 2. 位置与基线

- **Worktree 绝对路径**：
  `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725`
- **分支**：`fix/mobile-comprehensive-v02-20260726`
- **起始基线**：`20382de6e30b6796a8decd0480c208dac98aba30`

## 3. 全部 commit（自基线起，从早到晚；顺序即建议合并顺序）

| # | SHA | 条目 | 层 |
|---|---|---|---|
| 1 | `4ab464f42d4596101c973c698ac7654a1787e574` | SEC-1 拒绝带 Origin 的 WS 握手 | Bridge |
| 2 | `07110f582205570b1459bc65be9f205c744ad866` | P0-4 unhandledRejection 兜底 | Bridge |
| 3 | `6d36637a2afa2bc41b27b25ad057cc68fdb2073c` | P0-5 codex stdin EPIPE 防护 | Bridge |
| 4 | `0c4c6615d65e22e4ecd447f9713c32ccb9064061` | P0-6 消息流水线防毒化 | Bridge |
| 5 | `3d41f260c061898b352868e25255c56575c4b581` | B-18 fan-out 逐 handler 隔离 | Bridge |
| 6 | `a1fdf0a6203f0f685f7ed3e23e6568c138204323` | P0-10 menubar 管道死锁 | menubar |
| 7 | `403ad9f6a65eaf9d1fc7fb202766e21f24b1ad3f` | P0-1 Git hunk 内容指纹定位 | Bridge+Mobile |
| 8 | `1d0d3501f34168a8f0715366950f81b75d010c95` | P0-2 diff_result requestId 匹配 | Bridge+Mobile |
| 9 | `7c3fca5fc93eb974c7033e83f763a40c2873c78a` | P0-3 legacy history 代际栅栏 | Mobile |
| 10 | `13f79023f775d4e67381dd195b8d0e15ee62876a` | 候选B commitReplacement 去重字段 | Bridge |
| 11 | `4efc7ac06635b284f74b44fd8ae3bcaba8cef1e3` | 解析层四项 P0-7/8/9/14 | Mobile |
| 12 | `3c1985e587168ceaf0042353ea18a669d084d363` | P0-18 .json/.html 走预览路由 | Bridge |
| 13 | `435c36139496fb9084aa60d4b5c3589bed05e464` | P0-19 Quick Look 失败回退 WebView | Mobile |

**依赖**：#7→#8（同文件相邻逻辑）、#11 依赖 #9（bridge_service.dart 叠加）、
#13 依赖 #12（同一预览链语义）。其余相互独立可单独回滚。

## 4. git status 与非本人改动

`git status --short` 输出仅：`?? reviews/`（审查报告 + 修复日志 + 本报告，
协调文档按惯例不入库）。**无任何不属于本轮的源码改动。**
另一 Agent 的补充审查（NX 系列）只产出文档，未触碰源码，已核实零重叠。

## 5. 关键文件与行为

- `packages/bridge/src/websocket.ts`：Origin 握手门禁；get_diff requestId 回显。
- `packages/bridge/src/process-guards.ts`（新增）：进程级兜底。
- `packages/bridge/src/codex-transport.ts`：stdin EPIPE 防护。
- `packages/bridge/src/session.ts`：流水线防毒化；换血携带三个去重字段。
- `packages/bridge/src/local-features/controller.ts`：fan-out 隔离。
- `apps/menubar/.../ProcessRunner.swift`（新增）：并发排水，两处调用点复用。
- `packages/bridge/src/git-operations.ts` + `apps/mobile/lib/utils/diff_parser.dart`：
  hunk 内容指纹双端契约（金样 sha1 双端各钉一份）。
- `apps/mobile/lib/services/bridge_service.dart`：legacy history 代际栅栏；
  session_list 丢弃计数日志。
- `apps/mobile/lib/models/messages.dart`：guardian fail-closed、whereType 急切
  解析、session_list 逐条容错、conversation_content 惰性解码。
- `packages/bridge/src/artifact-manager.ts`：.html/.htm/.json 判 preview。
- `apps/mobile/lib/features/artifact_preview/artifact_preview_screen.dart`：
  Quick Look 任意失败回退 WebView。

## 6. 测试、构建与原始信号

- **Bridge**：全套 vitest 最近一次 **1719/1719 全绿**（94 文件）；
  `tsc --noEmit` 通过；`npm run bridge:build` 通过（含 native helper）。
  过程中 session-catalog-monitor 在并发负载下偶发计时抖动，单独复跑均过，
  已在日志归档。
- **Mobile**：全套 `flutter test` 最近一次 **2323 通过 / 1 失败**——唯一
  失败 `file_transfer_sheet_test.dart: auto-resume off exposes and runs the
  queued-start action` 为**起始基线即红**（stash 全部改动后在干净 HEAD 复现，
  证据见日志 #10 附注），与本轮无关。`dart analyze` 触及文件零告警
  （仓库既有 931 条 info 级提示未增减）。iOS simulator build：✅ 通过
  （`flutter build ios --simulator --debug`，318.6s，产物单路径原地覆盖，
  未新建模拟器设备）。
- **menubar**：swift test 5/5（含 2MB 输出不死锁回归）；xcodebuild Debug 通过。
- **每项修复均有 bug-first 证据**：修复前红、修复后绿的原始输出摘录见
  `reviews/remediation-log_20260726.md` 各分项。
- **对抗性复审**（13 commit 全量，5 维度审查 + 逐 finding 反驳制核实）：
  18 agent（5 维度审查 + 13 验证）产出 13 项主张，10 项确认 / 3 项驳回
  （全文见 `reviews/ADVERSARIAL_REVIEW_RESULT_20260727.md`）。确认项中
  6 项为本轮修复自引入的回归，已全部按"先红后修"补齐（A1–A6，commit
  `000f1965` / `5706df52` / `043eb36a` / `298bc125` / `0244f8ed` /
  `5bb08e2f`，分项记录见 remediation-log #14–#19）；其余 4 项确认属
  基线既有问题，并入未修清单（`reviews/UNFIXED_BACKLOG_20260727.md`）。
  A 系列完成后复验：Bridge vitest 1724/1724 全绿；Flutter 2327 通过 +
  1 已归档基线红（file_transfer_sheet）+ 1 负载抖动（单独复跑即绿）。

## 7. 剩余风险与建议

- 两个基线失败（file_transfer_sheet 确定性红 + file_transfer_service 抖动）
  不在本轮清单，建议独立立项。
- P0-17：预览链修复要到达真机**必须发新 IPA**（含 Swift 改动，OTA 补不了），
  需用户授权后走 `/release-app`。
- 原始报告中留档未修的项：A-2~A-8 解析层扩展、A5/A6/A8~A12、B1~B6、
  C 系传输状态机、D 系性能——均在 `reviews/raw-agent-reports/` 与主文档，
  待下一批次排期。
- **NX 系列（另一 Agent 补充审查，本轮未执行，待用户确认后立项）**：
  建议下一批次优先做 P1 四条——NX-1+NX-2（Secure Enclave 重复密钥 +
  误判失效，必须成对修）、NX-3（deviceId 静默漂移）、NX-5（Picker 失败
  永久 busy）、NX-20（Android 图标零别名窗口）；修 NX-1/2/3 时按建议补
  `FileMutationAuthPlugin` 生命周期测试。详见
  `reviews/SUPPLEMENT_native-and-handoff-E_20260726.md` 第 6 章。

## 8. 兼容性

- **协议全部加法**：get_diff/diff_result 的 `requestId`、hunk ref 的
  `fingerprint` 均为可选键；旧 Bridge 解析器已核实容忍多余键、走旧索引
  路径；新 App 对不回显 requestId 的旧 Bridge 接受无标记响应。
  `droppedSessionCount` 为客户端解析产物，不上行。
- **guardian status**：缺省（旧 Bridge 省略）→ approved 与旧行为一致；
  未知字面量 → denied（fail-closed）。已取证首版实现确实省略该字段。
- **artifact kind**："preview"/"source" 为既有二值枚举，新老 App 均完整
  处理两值；.html/.json 翻为 preview 后按既有规则不带 projectRelativePath，
  与 pdf/png 等一致。
- **历史/存储**：代际栅栏纯客户端内存状态，重连即清，不触存储 schema；
  Mirror/快照路径未动。
- **native-Dart 边界**：未改任何 MethodChannel 契约；menubar 为独立
  macOS App 内部实现替换，行为等价。
- **上游基线**：全部改动在本地兼容 fork 分支上，未合共享分支。

## 9. 完成状态边界（按 §10 第 9 条明确区分）

| 维度 | 状态 |
|---|---|
| 源码实现 | ✅ 完成（13 commit） |
| Bridge 部署 | ❌ 未做（未替换运行服务） |
| OTA 发布 | ❌ 未做 |
| IPA 签名安装 | ❌ 未做（P0-17 需单独授权） |
| 真机验收 | ❌ 未做（预览链真机取证清单见原始报告 A.1） |
| stable 晋级 | ❌ 未做 |
| push / 合并共享分支 | ❌ 未做（分支与 worktree 保留待审） |
