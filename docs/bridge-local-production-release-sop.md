# Bridge-only 本地生产发布 SOP

> **强制 SOP。** 本文适用于 CC Pocket 的本机 `com.ccpocket.bridge`
> 生产运行时发布。它定义可审计的候选、切换、回滚和验收门禁；不替代每次
> 对源码语义、用户授权和目标行为的现场判断。

`test-bridge` 只定义源码测试与类型检查；`release-bridge` 是 npm/GitHub
发布流程。二者都**不**授权或替代本文的本机 LaunchAgent/runtime 切换。

## 1. 授权与输入合同

每次 Bridge-only 发布必须收到一次明确授权，并且交接包必须含有：

- 绝对 worktree、branch、完整 40 位 HEAD、行为提交；
- 本次允许与禁止的动作、目标行为和目标 runtime 名称；
- 当前 runtime 与明确的直接回滚 runtime；
- 必要的真实线程或协议验收目标，以及手机是否在本次范围内。

发布会话首先在该绝对 worktree 验证 branch、完整 HEAD、`git status --short`
和 `git diff --check`。不从短 SHA 推断完整提交，不以旧报告代替现场，也不从旧
cwd、旧 PID 或旧 runtime 继续发布。

以下均为独立门禁，任一低层结果不得代替高层结果：源码测试、候选 runtime、
生产 runtime、Mobile OTA、IPA、Cloud、物理手机和 `stable`。本 SOP 不扩大授权；
Mobile、OTA、IPA、Cloud、Desktop、网络、会话数据和 `stable` 均须各自的当次授权。

## 2. 生产事实与秘密处理

持久发布会话的 shell 可能继承过期的 `CODEX_HOME`、source id、socket、host、
port 或 public URL，绝不能把它当作生产事实。

生产事实必须同时来自以下现场来源：

1. 当前 `~/Library/LaunchAgents/com.ccpocket.bridge.plist` 的
   `EnvironmentVariables`；
2. 当前 LaunchAgent registration 与实际 Bridge 进程；
3. loopback listener、`/health`、`/version`、`/readyz`。

候选从 plist 的完整 `EnvironmentVariables` 构造生产等价环境，只允许覆盖：

- 候选 `BRIDGE_CLI_ENTRY`；
- `BRIDGE_HOST=127.0.0.1`；
- 唯一的候选端口；
- 与候选端口匹配的 candidate public WebSocket URL。

其余值必须原样继承，尤其是 `CODEX_HOME`、
`BRIDGE_CODEX_DAEMON_SOCKET`、`BRIDGE_CODEX_SOURCE_ID`、API key、artifact/public
URL（除上述 candidate public URL）、allowed dirs、文件传输和会话配置。候选默认
继承生产 source id；不得人为覆盖它来让真实 durable thread 不再匹配。

`BRIDGE_REQUIRE_API_KEY` 与 `BRIDGE_API_KEY` 是两个独立配置事实，也必须从 plist
原样继承。不得仅凭“存在 key”推断当前认证开关，更不得在 runtime 切换时顺便开关
认证。本机开发阶段当前要求 `BRIDGE_REQUIRE_API_KEY=1`；以后改成 `0` 是单独的配置
变更和风险确认，不是普通 Bridge 升级的默认动作。

所有独立 metadata 与协议探针也必须显式注入从 plist 读取的
`CODEX_HOME`、`BRIDGE_CODEX_DAEMON_SOCKET` 和 `BRIDGE_CODEX_SOURCE_ID`，并在证据中
标注环境来源为“当前 LaunchAgent plist”。不依赖 shell 默认值。

API key、WebSocket token、deep link、完整环境、正文、路径和私密 payload 均不得写入
日志、run record 或回报。只能说明 credential 已配置、使用了脱敏/哈希，或报告安全的
布尔/计数结果。

## 3. 候选构建与隔离检查

1. 记录构建前磁盘与当前 runtime、回滚 runtime、LaunchAgent entry、PID、loopback
   listener、LAN proxy、health/version/readyz 和 daemon/Action Broker 状态。
2. 用该 HEAD 构建 TypeScript 与 native file-browser helper，运行与变更相关的 Bridge
   定向测试；完整源码测试证据可复用，但必须记录来源和适用范围。
3. 将 `dist`、生产依赖与必要 native helper 安装到新的版本化 runtime。不得覆盖当前
   runtime。生产最终最多保留当前新 runtime 与一个明确回滚 runtime；失败候选和可重建
   staging 之后必须清理。
4. 在未占用的 loopback 候选端口启动，并确认 runtime path、版本、HEAD、HTTP health
   与 daemon attachment。

生产实例持有 Action Broker writer lease 时，使用同一 source id 的并行候选可出现
`writer_lease_unavailable`，因此 candidate `/readyz` 可为 not-ready；这是预期互斥，
不是绕过。候选仍必须完成 health、daemon attachment、认证只读目录及真实 v1/v2
wire smoke。切换后再证明新生产实例持有 writer lease。

## 4. 强制真实 wire smoke

所有 smoke 必须走真实 Bridge HTTP/WebSocket wire；手写 JSONL/raw parser 的结果只能
帮助定位，不能代替正式 API 或 v2 门禁。每个探针记录候选 runtime、显式环境来源、
目标 provider/thread、观察到的协议事件集合及 complete snapshot 命中状态；不记录正文。

普通候选至少验证：认证、只读目录、v1、v2、目标目录/状态行为，以及错误不会泄露秘密。
当 `BRIDGE_REQUIRE_API_KEY=1` 时还必须证明：`/health` 声明
`bridgeAuthentication.required=true`，缺失和错误连接密钥均在 WebSocket upgrade
阶段返回 401，正确密钥可以连接。记录中只保存状态码和布尔结果，不保存密钥、完整 URL
或 deep link。当配置为 `0` 时必须证明 health 声明 `required=false`、无密钥可以连接，
并明确报告 owner 全盘读取等依赖认证的高权限表面已经 fail closed。

涉及 focused Codex settings 时，以下六项全部为强制项：

1. exact rollout path 可由 staging 正式 resolver 解析；
2. staging 的正式 `getCodexSessionIndexMetadata(..., { authoritativeCodexSettings: true })`
   返回目标；
3. 认证 WebSocket `conversation_sync_v2` 真实订阅完成；
4. 返回项的 provider 与 durable thread identity 完全匹配；
5. 收到 `codexSettingsSnapshotComplete=true`；
6. 目标字段实际存在：至少 model、model reasoning effort、approval、sandbox、
   collaboration（以及本次行为要求的其他字段）。

若 raw rollout 有字段，但正式 metadata API 或 v2 没有产出，必须停止：输出最小的
`raw → metadata API → v2` 差异证据，交给开发会话修复。不得以 raw 解析成功、构建成功
或 candidate 启动成功强行部署。

## 5. 温和生产切换与回滚

只有全部强制 smoke 成功，才能切生产。

1. 在外部控制 shell 中备份当前 plist 与 runtime，并记录可执行回滚入口；Bridge
   不能管理、停止、重建或迁移共享 app-server。
2. 生成 candidate plist，对比并断言唯一改动是 `BRIDGE_CLI_ENTRY`。必须保留
   `CODEX_HOME`、daemon socket/source id、`BRIDGE_REQUIRE_API_KEY`、API key、
   public/artifact URL、allowed dirs、文件传输和会话配置。
3. 使用项目已验证的温和 LaunchAgent registration 流程切换。若这会终止共享
   app-server 或正在运行的 Codex 会话，停止而非强行发布。
4. 任何切换、监听、health、daemon、Action Broker 或协议验收失败，立即恢复旧
   `BRIDGE_CLI_ENTRY`、重启旧 runtime 并重新验证旧服务。

保留现有 LAN proxy `192.168.124.67:8765`；它与 Bridge loopback listener 分开归因。
不得主动修改 Mullvad、Tailscale、Tailnet、Desktop 环境或用户会话数据。

## 6. 生产验收

切换成功必须全部证明：

- 唯一 `127.0.0.1:8765` Bridge listener 与 PID；LAN proxy 单独列出，不能误报第二个
  Bridge；
- LaunchAgent entry、进程 argv/runtime path 与已记录的 runtime hash 一致；
- `/health`、`/version`、`/readyz`；
- `/health.bridgeAuthentication` 与生产 plist 的认证开关一致；认证开启时，缺失/错误
  key 快速 401、正确 key 正常握手；
- shared daemon identity/socket；
- Action Broker ready、control-ready、non-degraded 且 writer lease held；
- 认证目录、v1/v2 与本次目标行为的真实 smoke；
- 仅限本次启动窗口的日志无新增错误（历史警告须明确隔离，不能混入结论）。

手机不在线或未参与授权时，只能报告服务端验收，绝不能声称手机链路、安装、视觉或
真实行为已验收。

## 7. 失败、收束与回报

候选失败：停止候选，确认候选端口无 listener，生产 entry/PID/health/readyz 未变。
切换失败：恢复旧 entry，复验旧 PID、唯一 loopback listener、health 与 readyz。
无论成功或失败，都清理临时脚本、staging 与失败产物；最终只保留新 runtime 和一个
回滚 runtime。不得让大量 `/private/tmp` 探针长期滞留。

最终回报必须明确属于以下之一：**未切换**、**切换后已回滚**、**切换成功**。并列出：

- worktree、branch、完整 HEAD、行为提交；
- runtime/版本/hash、PID、loopback listener、LAN proxy；
- health/version/readyz、shared daemon、Action Broker；
- 目标 smoke、日志结论、手机验收是否实际发生；
- 回滚 runtime/入口，以及保留和清理范围；
- 明确列出本次未授权而未执行的边界。

“构建成功”从不等于“生产可用”。

## 8. 2026-08-02 归纳的教训

- 第一次候选人为覆盖 `BRIDGE_CODEX_SOURCE_ID`，使真实 thread 不匹配。以后候选默认
  继承生产 source id。
- 第二次独立 metadata 探针没有可靠地固定到生产环境，出现另一会话能读到九字段而
  发布会话正式 API 返回空的矛盾。以后所有探针必须以 plist 为环境权威来源并显式证明。
- 即使 raw `turn_context` 有 settings，metadata/v2 不产出时仍必须停止，不能跳过
  complete snapshot 门禁。

具体源码行为仍需逐次探索；本 SOP 不允许删除用户授权边界、source/production 分层或
真实验收门禁。
