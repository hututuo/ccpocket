# CC Pocket 本地发布快速通道

> 本文补充而不削弱 `docs/bridge-local-production-release-sop.md`。目标是避免每次
> 发布从零开始重跑所有层，同时保留源码、生产、OTA、IPA 和设备之间的独立门禁。

## 1. 先按生产差异分流

发布任务在执行测试或构建前，必须先取得：

- 精确源码 HEAD 和 clean 状态；
- 当前 Bridge runtime 对应的源码 HEAD；
- 当前 Mobile/IPA 或 Shorebird base 对应的源码与原生基线；
- Bridge、Mobile Dart、Mobile native/resource、Cloud 和纯测试/文档各自的 tree diff。

根据真实差异只进入必要通道：

| 差异 | 必须执行 | 必须跳过 |
|---|---|---|
| 纯文档/测试 | 受影响测试、analyze/diff-check | 新 runtime、Bridge 切换、OTA、IPA |
| Mobile Dart-only | Mobile 门禁；匹配 base 时 owner OTA，否则 IPA | Bridge 全量、候选、切换 |
| Mobile native/resource/plugin | Mobile 门禁和新 IPA | OTA；无 Bridge 差异时跳过 Bridge |
| Bridge-only | Bridge 门禁、候选、切换 | Mobile 全量、OTA、IPA |
| Bridge + Mobile | 两条通道分别执行 | 不得用一条通道的成功代替另一条 |
| Cloud-only | Cloud 门禁和当次明确授权的部署 | Bridge/Mobile 发布 |

运行时版本号不同不等于产品代码不同。若 `packages/bridge` 及其真实构建输入相对当前
runtime 的源码 HEAD 没有差异，禁止为了让 runtime 名称包含最新总仓库 HEAD 而重建或
重启 Bridge。Mobile 同理：只有交付物输入树发生变化才需要新 OTA/IPA。

## 2. 全量验证由发布任务负责，但每层只跑一次

- 固定发布任务负责发布级全量测试；协调任务不重复跑同一套全量测试。
- 第一次进入某个受影响产品层时，发布任务运行该层的完整门禁一次。
- 若失败，发布任务立即向协调任务回报失败测试、原始错误、完成阶段和生产状态，然后
  停在该阶段；不得自行改业务源码。
- 协调任务修复后，发布任务先重跑失败项和受影响范围。只有产品源码、依赖、生成器或
  测试基础设施发生了会影响广泛结果的变化，才重跑该层全量。
- 纯测试 helper、lint 或文档修复不会使已经通过且产品 tree hash 未变的另一产品层证据
  失效。不得因此从 Bridge preflight 或整个发布流程重新开始。

每份可复用证据必须绑定：完整 HEAD、相关产品 tree hash、依赖锁文件 hash、工具链版本、
命令、结果和时间。任一绑定输入变化，才使该证据失效。

## 3. 阶段化续跑

固定阶段如下：

1. `classify`：diff 分类、生产/云端/设备只读快照；
2. `source-gates`：仅受影响层的测试、analyze、build；
3. `artifact`：OTA 或 IPA，及必要的 Bridge candidate；
4. `activate`：仅真正发生 Bridge 代码变化时切换生产；
5. `audit`：产物、运行时和回滚核验；
6. `offer`：满足设备门禁时发送，否则只报告路径。

每阶段完成后记录输入 fingerprint 和结果。后续出现 warning、测试失败、签名/lineage
阻断或用户补充修复时，只从第一个失效阶段续跑。禁止无条件回到第 1 阶段重新阅读全部
项目资料、重跑无关全量测试或重启未变化的服务。

### 3.1 可执行快速通道

仓库提供 `scripts/local-release-fast.sh`，把最容易重复且确定性的步骤固化为四个命令：

```bash
# 只分类，不构建、不发布
npm run local-release:plan -- --base <已部署基线>

# 运行一次最小真实链路门禁；相同 fingerprint 自动复用
npm run local-release:gate -- --base <已部署基线>

# 仅在 Bridge tree 变化且 lock 未变化时，APFS clone 依赖并覆盖新 dist
npm run local-release:bridge-runtime -- --base <已部署基线>

# 复用 Flutter/Pods/DerivedData，一次构建并审计无签名 AltStore IPA
npm run local-release:ipa -- --base <已部署基线> --build-number <新 build>
```

总 release fingerprint 绑定完整 HEAD；Bridge、Mobile 与真实闭环另有彼此独立的
fingerprint，分别绑定自己的产品 tree、lock 和工具链。相同层输入的成功门禁不会重复执行；
任一真实输入变化时只让相应阶段失效。缓存路径默认为
`~/Library/Caches/CCPocketLocalRelease`，可用 `CCPOCKET_FAST_RELEASE_CACHE` 覆盖。
Bridge build 证据同时保存按 Bridge fingerprint 校验的 `dist` 压缩包；新 worktree
复用证据时直接还原该产物，不会把另一棵工作树里的旧 `dist` 当成当前构建。
IPA 只在隔离 staging 中剥离 Xcode 复制进来的预构建 Framework 签名，并复验所有
Mach-O、`_CodeSignature` 与 provisioning；不会修改原始 archive 或源码。

该脚本故意不执行 LaunchAgent 切换、owner/stable 发布或设备安装。Bridge 候选完成真实
wire smoke 后，仍由固定发布任务按生产 SOP 做唯一一次可回滚切换；IPA 审计后再使用既有
手机发送工具 offer。这样把确定性构建压缩为一条命令，同时不把生产授权藏进脚本。

### 3.2 快速试用不再重复的步骤

- 开发任务已经给出精确 HEAD、产品 tree 和全量证据时，发布任务不再重跑同一套全量；
- 不执行 `flutter clean`、不删除 Pods/DerivedData、依赖缓存或 Bridge `node_modules`；
- Dart-only AltStore 试用包不先跑一遍 Shorebird dry-run；只有实际 owner OTA 才进入
  Shorebird lineage/signing 门禁；
- 不为 IPA 再做一个内容相同的 simulator build；定向 Widget/链路测试与 iPhoneOS archive
  是两个必要层；
- package/pub lock 未变化时不重新安装依赖；Bridge runtime 复用当前 runtime 的 APFS
  clone，随后只覆盖本次 `dist`；
- 文档、测试 helper 或另一产品层变化，不使已经绑定 fingerprint 的构建证据失效；
- 生产 Bridge tree 未变时不重建 runtime，Mobile delivery tree 未变时不生成 IPA/OTA。

## 4. 可安全并行与必须串行的工作

可并行的只读工作：

- tree diff 分类；
- 生产 Bridge health/version/listener 快照；
- Shorebird lineage 和 channel 快照；
- 磁盘、现有 IPA/runtime 和手机 preflight；
- Bridge 测试与 Mobile 测试（构建目录相互独立时）。

必须串行：

- 使用同一 Flutter/Xcode build 目录的 test/archive/package；
- Bridge candidate 与生产切换；
- LaunchAgent 修改、回滚和最终监听者验收；
- 同一 IPA 的打包、解压审计和最终移动。

## 5. 不在正式发布时实验部署脚本

- 使用项目最近一次已验证的候选探针和 LaunchAgent registration 流程；不得临时重写
  wire ACK、进程 argv 或 health/version 判定后直接用于生产。
- 当前本机 `com.ccpocket.bridge` 已验证可用的 registration 路径是既有
  `launchctl unload → load` 流程。除非先在隔离环境证明，否则不要在生产发布中改试
  `bootout → bootstrap`，也不要把 shell wrapper 当作实际 Node runtime argv。
- `/health` 与 `/version` 分别读取；不能要求 `/health` 含有不存在的 version 字段。
- v2 探针必须对每个带 sequence 的事件及时 ACK；不得把探针不完整误判为产品超时。

## 6. 时间目标与超时回报

在缓存已存在、机器负载正常时：

- classify/preflight：目标 1 分钟内；
- owner OTA：目标总计 5–8 分钟；
- Mobile-only IPA：目标总计 10–15 分钟；
- Bridge-only：目标总计 5–8 分钟；
- Bridge + Mobile IPA：目标总计 15–20 分钟。

这些是观测目标，不是绕过门禁的硬超时。某阶段超过历史正常耗时两倍时，发布任务必须
主动回报当前阶段、已耗时、正在等待的具体进程和是否仍有输出，而不是静默等待半小时。

## 7. 固定回报合同

发布任务遇到任何 source/test/build/candidate/wire/OTA/IPA/device/cleanup 阻断时，必须
直接回报协调任务：

- 精确失败阶段和原始错误；
- 已完成且仍可复用的阶段及 fingerprint；
- 源码、生产 Bridge、云端 channel、IPA 和手机分别是否变化；
- 回滚是否完成；
- 需要协调任务修复或决定的唯一下一步。

协调任务给出新 HEAD 或决定后，发布任务从第一个失效阶段继续，不重新执行仍有效阶段。
