# CC Pocket 综合修复最终回报（20260727）

依 `docs/PROJECT_HANDOFF.md` §10 九项要求编写。协调会话:
`019f8ff9-0945-72a3-a29e-c17df6f112e5`。

## 1. 任务目标与实际完成范围

目标:执行 `reviews/ccpocket-full-code-review-and-plan_v2_20260726.md` +
`reviews/raw-agent-reports/` 确认的修复计划。实际完成四个阶段:

- **原始 13 项批** + **Phase A**(对抗回归修复 A1–A6)+ **Phase B**
  (性能 4 项)——见 remediation log 条目 1–23;
- **Phase C**:`reviews/UNFIXED_BACKLOG_20260727.md` 挖掘的 P0 积压
  16 项处置(13 项修复落地、3 项核实为 NOT-REAL/NOT-ADOPTED 并记录
  证据)——log 条目 24–39;
- **Phase D**:全量 diff 最终实效审查(workflow 5 维度 + 每发现 3
  视角对抗验证,17 agent),唯一确认项已修复——log 条目 40。

**按用户指示明确排除**:batch-0 安全行为收紧(SEC-2 权限上限、自动
批准收紧、上传门控、API key 生成——Tailscale VLAN 部署,不冒旧客户端
兼容风险);P0-17 IPA 发布(需单独授权);NX 系列(未授权,见 §7 提案);
交互/动画视觉验收(推迟给用户终检)。

## 2. 路径 / 分支 / 基线

- Worktree 绝对路径:
  `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725`
- 分支:`fix/mobile-comprehensive-v02-20260726`
- 起始基线:`20382de6`(docs: 收束综合修复交接与剩余任务)
- 规模:38 个 commit,77 文件,约 +5066/−460 行

## 3. 全部 commit(时间序,后依赖前;完整 SHA)

| # | SHA | 主题 |
|---|-----|------|
| 1 | 4ab464f42d4596101c973c698ac7654a1787e574 | fix(bridge): reject Origin-bearing WebSocket handshakes (SEC-1) |
| 2 | 07110f582205570b1459bc65be9f205c744ad866 | fix(bridge): survive unhandled rejections and floating profile writes (P0-4) |
| 3 | 6d36637a2afa2bc41b27b25ad057cc68fdb2073c | fix(bridge): guard codex stdin against EPIPE crashes (P0-5) |
| 4 | 0c4c6615d65e22e4ecd447f9713c32ccb9064061 | fix(bridge): stop a rejected pipeline step from stalling session messages (P0-6) |
| 5 | 3d41f260c061898b352868e25255c56575c4b581 | fix(bridge): isolate local-feature fan-out handlers from each other (B-18) |
| 6 | a1fdf0a6203f0f685f7ed3e23e6568c138204323 | fix(menubar): drain child output concurrently to avoid pipe deadlock (P0-10) |
| 7 | 403ad9f6a65eaf9d1fc7fb202766e21f24b1ad3f | fix(git): address hunks by content fingerprint instead of positional index |
| 8 | 1d0d3501f34168a8f0715366950f81b75d010c95 | fix(git): correlate diff_result to its get_diff request via requestId |
| 9 | 7c3fca5fc93eb974c7033e83f763a40c2873c78a | fix(history): fence legacy full-history frames against stale overwrites |
| 10 | 13f79023f775d4e67381dd195b8d0e15ee62876a | fix(codex): carry user-echo dedup state across a session replacement |
| 11 | 4efc7ac06635b284f74b44fd8ae3bcaba8cef1e3 | fix(mobile): harden the four parse-boundary failure modes (P0-7/8/9/14) |
| 12 | 3c1985e587168ceaf0042353ea18a669d084d363 | fix(bridge): route project .html/.json artifacts through the preview chain |
| 13 | 435c36139496fb9084aa60d4b5c3589bed05e464 | fix(mobile): fall back to the WebView preview on any Quick Look failure |
| 14 | 000f1965b5728e496b220120aa4476c612a81244 | fix(git): stop trimming diff text before assembling hunk patches |
| 15 | 5706df5206657894954ec023c40f808decd685c4 | fix(bridge): allow private-origin WebSocket handshakes for the web client |
| 16 | 298bc125487a16ab7275707f595591e892ee1c2f | fix(mobile): reject session_list frames that lack a sessions list |
| 17 | 0244f8edccd4fb7fea8398e0d90b521b3044ab60 | fix(bridge): keep line-anchored .html/.json refs on the source path |
| 18 | 5bb08e2f760dbc9aefa033f60cde8765515d2fee | fix(mobile): keep artifact chip dedup stable across Bridge kind changes |
| 19 | 043eb36a01b6facee6fb30cc421b554dd7a6aa17 | fix(mobile): rework legacy history gate around solicited-reply trust |
| 20 | 26db9cd9774673200cbcccc52be094fa8a2198ae | perf(mobile): bound image decode size at thumbnail render sites |
| 21 | 716d71182a20209b4935b371447339afc6423d9c | perf(mobile): cache generated-image items in the expanded tool bubble |
| 22 | bc36c23bff47ddd8cf8a46b3a4ab37438515ec18 | perf(mobile): widen the stream flush interval as the text grows |
| 23 | b44418ad472245a3241cf259ce8e85060245f9a1 | perf(mobile): stop accumulating CurvedAnimations in zoom gesture handlers |
| 24 | 1358d478ac0877f872b9abf2445123c4751d2b64 | fix(bridge): return codex session to idle when approval outlives its turn |
| 25 | 8316707efb425a914e1b41ad2550b09d8ea4b19a | fix(bridge): deny pending sdk permissions instead of stranding their resolvers |
| 26 | cb989494cfcac0ea2dcc20d7eb914503151313cf | fix(bridge): settle in-flight codex RPCs on transport error without exit |
| 27 | 7e6d94a8bf4563f3eacd1d3a94665a77b28d6bfd | fix(bridge): validate prompt-history entries fully and make v1 import atomic |
| 28 | 3226eafb67603931f80674cc58f5cdb7be52c697 | fix(ios): accept fractional-second timestamps in notification approval actions |
| 29 | 3325401db5226b715edd5e29b61246fab5484418 | fix(menubar): parse fractional-second resetsAt so usage countdown renders |
| 30 | 4528efa802a1e1be3d1b9a6bc4af4f40a703a9d4 | fix(bridge): stop fabricating on-request approval policy when it is unknown |
| 31 | 67836abab8b7bc82b0b9688844c46b0c04410f43 | fix(mobile): unpin a rejected cancel request from paused transfers |
| 32 | ad3d77ba59f27b0b403690ca23667d4bc2c6bd8a | fix(bridge): carry a pending plan approval across a codex permission restart |
| 33 | fd8f6a56f8277c1b956a8e070544e17ce1e6ebc9 | fix(mobile): stop dropping whole history frames over one malformed entry |
| 34 | a2f77b66e7a97900e6b84a3bbfec099479a4eb36 | fix(mobile): isolate nested local-feature slot decode failures |
| 35 | 82c40f4e5fa678723b6167db842afacf41985d71 | fix(mobile): tolerate additive unknown fields in side-chat payloads |
| 36 | 75722673e03b06b5d2c5500b80db9dbcddcc8b9c | fix: stop git results from crosstalking between project views |
| 37 | f7aa3c062ced06bbef09e46dcf08cbe390a0e8bd | fix(mobile): gate received-file preview behind the QuickLook eligibility policy |
| 38 | 48fe6d15ff20f0f1ecb23d48cecf48f9c75cd3f6 | fix(bridge): open side chats on parents with an unknown approval policy |

依赖关系:整体线性,单分支;强耦合对——#30 与 #38(38 修复 30 引入的
side-chat 判别回归,必须同入);#7/#8/#14(git hunk 链);#20–23(perf
批相互独立)。每个 commit 均为独立可回滚单元。

## 4. `git status --short` 与非本任务改动

```
?? reviews/
```

工作区仅剩未跟踪的 `reviews/`(审查计划、raw 报告、积压清单、
remediation log、本报告)。**待协调决定**:是否纳入版本控制(建议随
分支提交,合并时保留审计链;若不合并可留 worktree)。除此之外无任何
不属于本任务的改动。

## 5. 关键文件与行为(按域)

- **Bridge 稳定性**:codex-process(审批晚于 turn 完成回 idle、传输
  error 结算在途 RPC、plan 审批跨权限重启携带)、sdk-process(清审批
  必 resolve deny)、websocket(approvalPolicy 未知不捏造/不持久化)、
  process-guards(unhandled rejection 兜底)、prompt-history-store
  (全字段校验 + 导入原子性)。
- **协议**:13 种 git 结果帧回显 projectPath(parser.ts 类型同步);
  side-chat 未知附加字段容忍(判别器仍严格);local-features/side-chat
  父进程 duck-check 兼容未知 approvalPolicy。
- **App 解析层**:messages.dart(history 系帧逐条降级、分页游标容错、
  展示字段防崩)、protocol_host(嵌套槽解码失败降级 ErrorMessage,
  顶层严格契约不变)。
- **App git 视图**:git_view_cubit/commit_cubit/branch_cubit 增
  `_isForeignProject` 过滤(17 个 handler)。
- **file_transfer**:暂停槽 cancel 失败解钉;收件箱预览过 QuickLook
  资格门(HTML/超 64MB 降级分享)。
- **原生**:iOS 通知动作与 menubar 用量倒计时的 ISO8601 小数秒解析;
  menubar 子进程管道并发排空。
- **性能**:缩略图解码尺寸约束、生成图缓存、流式 flush 间隔自适应、
  缩放手势动画不累积。

完整逐项证据链见 `reviews/remediation-log_20260726.md`(40 条)。

## 6. 测试 / 构建与原始信号

- **Bridge**(HEAD=48fe6d15):`npx vitest run` → **1737/1737 全绿**
  (94 文件)。注:收尾另一次整跑中 session-catalog-monitor 出现 1 次
  vi.waitFor 超时,隔离复跑 3/3 通过,该文件未被任何本次 commit 触碰
  ——确认环境负载抖动。`npx tsc --noEmit` 干净。
- **Flutter**:`flutter test` 全量 → **2356 通过**,仅 2 个已记录
  基线项:`file_transfer_sheet_test` "auto-resume off…"(修复前即存在
  的确定性红)与 `file_transfer_service_test` watermark(负载抖动,
  隔离复跑通过)。`dart analyze`:0 error/0 warning;931 个 info 均为
  既有基线,本次改动文件零新增。`dart format`:干净。
- **纪律**:每项修复先内联核实(含推翻子代理结论的勘误)→ 红测(红因
  与缺陷链一致才算数)→ 修复 → 绿 → 独立 commit;所有子代理/workflow
  产出均经本人逐 diff 复核后才提交。
- **未执行**:iOS simulator build/install/launch 终验(交互验收推迟
  给用户);真机;Web 构建。

## 7. 剩余风险 / 冲突与建议合并顺序

- **合并顺序**:单分支线性,整体 rebase/merge 即可;不建议摘樱桃
  (#30/#38 必须成对,git hunk 链 #7/#8/#14 有内部依赖)。
- **剩余风险**:①`5706df52` 私网 Origin 放行以 IP 字面量/localhost 为
  界,Tailscale MagicDNS 域名形式的 web 客户端未覆盖(Phase D 对抗
  审查 1/3 维持,未确认为实际使用场景,记录待产品确认);②基线抖动
  两处(见 §6)建议后续加固;③`reviews/` 目录去留待定(§4)。
- **NX-P1 批提案(未授权,待批)**:NX-1+NX-2(Secure Enclave 重复
  密钥 + 生物识别误判删公钥缓存,必须成对修)、NX-3(deviceId 写
  Keychain 失败静默身份漂移)、NX-5(Picker 呈现失败后 pickerResult
  永久 busy)、NX-20(Android 图标零别名窗口,两行顺序调换)。
- **新增 NX 候选**(本阶段处置记录):chat_session_state 权限字段
  unknown 态(10+ 文件重构)、getToolDisplayName ja/ko 工具名翻译、
  file_transfer 多槽暂停重构(C13,需产品拍板)、77 个 zh 孤儿键清理。

## 8. 兼容性说明

- **新 App + 旧 Bridge**:git 结果无 projectPath 戳 → cubit 全收
  (行为同旧版);history/side-chat 容错只放宽不收紧;所有新增客户端
  行为无新消息类型,无 unsupported_message 风险。
- **旧 App + 新 Bridge**:git 结果新增 projectPath 键——App 解析按键
  取值、忽略未知键,无影响;approvalPolicy 未知时省略——App 水合逻辑
  按存在才合并,无 undefined 崩溃路径;plan 审批重启后以**相同
  toolUseId** 重发 permission_request,在屏审批卡可继续解析。
- **协议**:无破坏性变更;能力协商仍按类型名;判别器(type/event
  枚举/XOR)全部保持严格。
- **历史/存储**:prompt-history 校验收紧仅拒绝此前会导致后续崩溃的
  畸形条目;导入失败现在保旧数据(原来清空)。存储 schema 无变更。
- **native–Dart 边界**:iOS/菜单栏仅本地解析加固,通道契约无变更。
- **上游基线**:未触碰 upstream 同步面(fork 专属文件为主);与官方
  更新的兼容边界不受影响。

## 9. 完成状态分层(§11 口径)

| 层 | 状态 |
|----|------|
| 源码实现 + 测试 + 提交 | ✅ 完成(38 commit,全部验证过) |
| 兼容说明 | ✅ 本报告 §8 |
| 合并入共享分支 / push | ❌ 未做(未授权;分支与 worktree 保留供审核) |
| Bridge 部署 / 服务替换 | ❌ 未做(未授权) |
| OTA / IPA / 安装 | ❌ 未做(P0-17 明确排除,需单独授权) |
| 真机 / 交互动画验收 | ❌ 未做(按约定由用户终检;模拟器无残留多构建) |
| stable 晋级 | ❌ 不适用 |
