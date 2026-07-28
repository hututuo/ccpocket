# CC Pocket 今日提交与分支单线收束结果 v02

> 状态：`accepted`（源码收束与自动验证完成）
> 完成时间：2026-07-28 22:28:04 +0800
> 工作树：
> `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-v03-20260728`
> 分支：`fix/mobile-comprehensive-source-closure-20260728`
> 收束源码 HEAD：`e4b8118c`；本报告与台账提交位于其后，不改变产品源码
> 本报告不授权合入 stable、push、部署 Bridge/Cloud、发布 OTA、构建签名
> IPA、安装物理设备、删除分支或移除旧工作树。

## 1. 最终结论

截至收束源码 HEAD `e4b8118c`，2026-07-28 当天所有仍由 Git ref 可达的
CC Pocket 提交已经收进同一条真实祖先链：

- 当日 ref 可达提交：`109`（本报告自己的文档提交不计入该源码快照）
- 不属于当前 HEAD 祖先的当日 ref 可达提交：`0`
- 官方 `upstream/main@82962136`：当前 HEAD 的真实祖先
- 稳定 Bridge 身份分支 `1645dfe3`：当前 HEAD 的真实祖先
- 共享 Codex 来源分支
  `c56fe921 → a9f855a9 → 30a33de3`：当前 HEAD 的真实祖先
- 当前工作树无未解决冲突，旧脏工作树未被覆盖、stash、reset 或清理

这次不是机械把旧分支整枝覆盖到新源码，而是先证明哪些提交已被现行实现语义吸收，
再把相应分支作为第二父提交登记进历史。这样既保留真实 Git 血缘，也不会把旧协议、
旧 Side Chat 或旧缓存模型重新带回当前实现。

## 2. 当日提交台账

### 2.1 官方更新

重新 fetch 后，官方仍是：

`829621364b730b866e0c39b27d0aab868084f2aa`
`chore: bump version to 1.109.3+202`

官方导航行为 `3289ce93` 已由本地 `c2cc8379` 在更完整的嵌入式工作区、
来源身份和会话路由语义上适配；官方版本提交已由 `97fb5aab` 保持本地 build
单调递增到 `1.109.3+205`。

为避免“功能已适配但官方 SHA 不在历史里”的歧义，已形成：

- `563bcedd` `merge: 接入官方 1.109.3 血缘`

常规 merge 实际报告 9 个冲突：

- Claude 会话屏
- Codex 会话屏
- Session Link 屏
- `main.dart`
- session stack navigation
- connection URL parser
- `pubspec.yaml`
- connection URL parser 测试
- session stack navigation 测试

对官方 `3289ce93` 和本地 `c2cc8379` 做 `range-diff` 后，确认当前版本是官方
行为的严格适配版。9 处均保留当前实现；merge 相对第一父提交没有源码树变化，
随后由全量 Mobile、Bridge、iOS build 和 RunnerTests 证明没有冲突残留。

### 2.2 稳定 Bridge 身份分支

原分支：

- `feature/bridge-stable-device-identity-20260728@1645dfe3`

现行实现：

- `fac56c47` 在当前源码上适配稳定 `bridgeInstanceId`、`codexSourceId`、
  跨 IP canonical cache 和离线 mutation v2 门禁。

语义和测试核对完成后，以不改变当前树的显式 merge 登记血缘：

- `509afe71` `merge: 登记稳定 Bridge 身份分支已适配`

### 2.3 共享 Codex 来源分支

原分支：

- `c56fe921`：共享来源基础
- `a9f855a9`：后续来源隔离
- `30a33de3`：兼容文档

现行映射：

- `c56fe921 → 8aabde45`：patch-equivalent
- `a9f855a9 → 170621dd`：按现行身份模型适配
- `30a33de3 → 0e6d2525`：现行兼容边界

语义和测试核对完成后，以不改变当前树的显式 merge 登记血缘：

- `df1d821d` `merge: 登记共享 Codex 来源分支已适配`

### 2.4 reflog 中三个已被替代的孤立对象

当日 reflog 仍能看到两个不属于当前祖先链、也不再由分支引用的旧对象：

- `059492d0`：旧的 `1.109.3+202` 版本提交。其 patch-id 与当前
  `97fb5aab` 完全相同，不能再次应用。
- `81989403`：较早的验证台账提交。它与 `fed199f7` 具有同一父提交；
  `fed199f7` 还补充了后续 Simulator 证据，是明确的增强替代版。
- `1c76f2f7`：本报告的第一次提交，随后由祖先链中的 `4bb98371` 仅移除
  Markdown 行尾空格并完整替代；没有独有源码或产品语义。

这三个对象不是遗漏分支，不应为了让所有 reflog SHA 成为祖先而制造重复提交。

## 3. 两个脏工作树的处置

### 3.1 旧 v02 工作树

路径：

`/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725`

该工作树保留 17 个 tracked 文件的 441/47 行改动和 10 个 untracked 项目记录。
逐 hunk 对照后确认：

- 未读、路由、通知、消息缓存和会话生命周期的原始 `codexSourceId` 方案，已被
  当前 `BridgeDataSourceIdentity` 模型更完整覆盖；
- 当前 `resolve_session_link` 在请求前和响应后都校验权威 Bridge/source
  identity，并用 connection epoch 隔离迟到响应；不再复制旧的冗余 wire 字段；
- 唯一确定缺口是外部 `ccpocket://session/...` URL 自身没有携带来源身份。

已提取并重新按当前模型实现：

- `b20d2d01` `移动端：为会话深链绑定 Bridge 来源身份`

外部链接现在可携带 `providerSessionId`、`bridgeInstanceId`、
`codexSourceId` 和 legacy `bridgeRouteIdentity`。只有稳定
`bridgeInstanceId` 存在时才信任 `codexSourceId`；现代 durable identity
优先于 legacy route，字段长度有界，旧无来源链接继续兼容。39 项 parser 测试通过。

旧 v02 工作树保持原样，没有清除或提交其中的用户/其他 Agent 改动。

### 3.2 旧 `feature/mobile-session-tools` 工作树

路径：

`/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-compat`

它包含旧的 modal bottom sheet、自造持久 Side Chat panel/protocol 和早期
ephemeral fork 逻辑。当前线已经有：

- `c5d29d39`：官方 ephemeral `thread/fork` 和现有会话 UI
- `6041395b`：真正非模态 in-tree floating dock
- `a3d87745`：拖动、贴边、折叠和位置记忆
- `1d99e1cd`：按 Bridge 隔离 runtime registry

当前实现不硬编码口述 TTL，不恢复旧持久 Side Chat，也不会用旧 modal UI 覆盖
非模态小窗。旧实现没有可继续提取的有效源码；只保留旧客户端/旧 Bridge 的兼容
handler。该脏工作树同样保持原样。

## 4. 本轮新增的确定性修复

### 4.1 外部深链来源身份

- 提交：`b20d2d01`
- 目的：防止共享 session 存储、多个 Bridge 路线或切换 Codex Home 时，
  外部链接把同 ID 会话解析到错误来源。
- 兼容：加法字段；旧链接照常工作，缺少稳定 Bridge 身份时 fail closed，
  不把未经证明的 source 当成权威。

### 4.2 Git worktree hooks 安装

- 提交：`e4b8118c` `工具链：兼容 Git worktree 安装 hooks`
- 原因：linked worktree 的 `.git` 是文件，原脚本错误拼接
  `$REPO_ROOT/.git/hooks`，导致 `npm ci` prepare 失败。
- 修复：使用 `git rev-parse --path-format=absolute --git-path hooks`
  查询有效 hooks 目录，并在安装前创建目录。
- 验证：`bash -n`、普通依赖安装，以及独立临时主仓库 + linked worktree
  的真实 hook 安装均通过。

## 5. 自动验证

### 5.1 Bridge

- TypeScript build：通过
- native file-browser helper：通过
- 全量：95 个 test files、`1836/1836` 通过
- 来源身份、Deep Link、session link、通知/未读和 Side Chat 联合专项：
  18 个 Mobile test files、`189/189` 通过

### 5.2 Mobile

- 全量 Flutter：`2576` 通过
- 环境 smoke：4 项因未配置外部 SSH 环境按预期跳过
- 结果：`All tests passed!`
- `flutter analyze --no-pub`：0 error、0 warning、52 个仓库既有 info；
  analyzer 因 info 返回非零，不把它伪装成零提示

### 5.3 iOS

- Simulator Debug：Xcode 21.4 秒，成功生成
  `build/ios/iphonesimulator/Runner.app`
- RunnerTests：iPhone 17 Pro Max / iOS 26.1 / arm64，
  `27/27` 通过，0 failed、0 skipped
- 结果包：
  `apps/mobile/build/ios/RunnerTests-20260728-222113.xcresult`

RunnerTests 最终从 `Runner.xcworkspace`、最小白名单环境和 `-quiet` 执行。
第一次直接从 project 启动会绕过 Pods，并让前置脚本输出继承环境；该失败
DerivedData 已立即删除，后续未保存或复述任何凭据值。因为敏感环境曾进入当前
Agent 工具回传，相关凭据仍应按安全事件轮换。

### 5.4 Git 与上游

- `git diff --check`：通过
- commit hooks 的 forbidden-file、secret 和 large-file 检查：通过
- 重新 fetch 后 `upstream/main` 仍为 `82962136`
- 收束源码 HEAD `e4b8118c` 时的 109 个 ref 可达提交全部为其祖先；
  本报告提交后会因新增文档提交而自然增加计数
- 当前不存在 merge conflict 或冲突标记

## 6. 产物与磁盘收束

- 构建前 Data 卷约 33 GiB 可用。
- 两份失败的 RunnerTests DerivedData（287 MB、1.6 GB）已删除。
- 成功测试的 3.2 GB DerivedData 已在提取 1.2 MB `.xcresult` 后删除。
- 当前只保留最新 Simulator `Runner.app`、最新 RunnerTests 结果包、当前
  worktree 的 Flutter/Pods 依赖和两份仍活跃工作树所需的 Node 依赖。
- 未删除任何源码、脏工作树、用户数据、分支或唯一证据。

## 7. 仍未完成且需要另行授权的门槛

源码单线收束已经完成，但以下事项仍是独立动作：

1. 将本分支合入共享或 stable 分支；
2. push 任意远端；
3. 部署 Cloud Function 或替换运行中 Bridge；
4. 构建并签名高于 build 204 的新 IPA；
5. 安装物理 iPhone；
6. 发布 owner/stable OTA；
7. 删除或移除旧分支、脏工作树和 review worktree；
8. 真机验证通知、定位保活、Face ID、长按审批、弱网目录、性能和视觉。

后续若进入发布阶段，必须继续区分：

`源码验证 ≠ Bridge 部署 ≠ IPA 构建 ≠ 真机安装 ≠ owner OTA ≠ stable`
