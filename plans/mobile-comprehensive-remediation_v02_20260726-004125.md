# CC Pocket 新一轮体验、稳定性与兼容实施方案 v02

> 状态：draft / investigation active（只调查与讨论，尚未开始实施）
>
> 创建时间：2026-07-26 00:41:25 +0800
>
> 上一版方案：
> `plans/mobile-comprehensive-remediation_v01_20260725-012458.md`
>
> 本文是 build 202 之后根据真实使用反馈建立的新一轮实施方案。v01 保留为
> 上一阶段的需求、实现和验证基线，不回写为“当时没有做过”。从本轮对话开始
> 新提出、重新定义或在真机上复现的问题统一登记到 v02；v02 在用户确认前只作
> 调查和设计，不授权修改 Dart、Swift、Bridge、Cloud、协议、构建或运行服务。

## 0. 使用规则与权威边界

1. 本文是方向性实施指南，不是对根因或修复完成的声明。
2. 每个问题必须分开记录：
   - 用户可见现象和期望；
   - 已由当前源码、Git、产物或运行态确认的事实；
   - 尚未取得证据的假设；
   - 实施前必须补做的取证；
   - 兼容、性能、回滚和验收边界。
3. 真正实施时必须在当时的统一集成 HEAD 上重新追踪完整调用链。若真实代码已经
   变化，或发现更深层原因，应更新本文并修正设计，不得为了照抄方案只修表面。
4. 疑似 bug 只有在事件顺序、连接身份、connection epoch、provider identity、
   本地缓存和运行对象都核对后才能修改；调查过程中顺带发现的问题先登记，不
   直接动手。
5. 官方 upstream、本地功能、运行中 Bridge、Cloud、基础 IPA、owner OTA 和
   stable 是不同状态。任何“已经合并”“已经连接”“已经可用”都必须注明所指
   层级。
6. 新旧 Mobile、Bridge、基础 IPA 与官方 provider/app-server 继续采用 additive
   协议和能力协商；不得用只适用于当前自用环境的快捷修复破坏官方可回放性。
7. 性能审查仍是整轮实施的最终阶段，同时也是每项设计的前置约束：不能通过
   无界轮询、全量重建、重复解析或隐藏真实状态来改善表面体验。

## 1. 本轮问题登记

### v02-001：启动时连接页提前消失，进入无信息的中央大加载

#### 1. 用户可见现象

- 刚进入 App 时，用户仍在 IP/Bridge 连接阶段，连接页就自动消失。
- 随后界面只剩中央的大型加载动画。
- 有时界面表现得像“已经连接并跳到后面”，但 Bridge 实际尚未完成可用连接，
  因而只能继续等待。
- 用户不需要这个脱离上下文的中间加载页。连接尚未完成时应继续留在原连接页，
  明确告诉用户正在连接哪台 Bridge、进行到哪一步、是否可取消或重试。

#### 2. 已确认的源码事实

当前 build 202 源码的冷启动链路是：

```text
SessionListScreen.initState
        │
        ▼
读取 SharedPreferences 中保存的 bridge_url
        │
        ├─ 有保存地址：立即设置 _isAutoConnecting = true
        │                  │
        │                  ▼
        │          整个 ConnectForm 被替换为
        │          Center(CircularProgressIndicator)
        │
        ▼
BridgeService.autoConnect -> connect
        │
        ├─ connection state = connecting
        ├─ WebSocket channel.ready 后 state = connected
        │   （这里只证明 WebSocket upgrade/transport ready）
        └─ SessionListCubit 在 connected 事件后请求 session_list
                            │
                            ▼
             BridgeService 收到 SessionListMessage
             才标记当前 connection epoch 权威就绪
```

- `_isAutoConnecting` 分支无条件覆盖整个连接表单，只显示中央转圈。
- 即使不是自动连接，只要展示状态为 `connecting`，当前代码也覆盖连接表单并
  只显示同一个中央转圈。
- v01 实施的 `SessionHomeConnectionGate` 已经修复了“WebSocket 一打开就直接
  展示会话首页”的事实错误：首次连接必须收到当前目标的权威 `session_list`
  才能展示已连接首页。
- 但该门禁只决定“能不能展示会话首页”，没有决定“等待期间怎样展示”。当
  transport 已 connected、但权威 `session_list` 尚未到达时，它把展示状态降为
  `connecting`，随后仍命中全屏转圈分支。
- 因此当前现象不是 v01 门禁完全失效，而是 v01 只完成了数据正确性门禁，
  遗留了连接阶段的 UI 状态设计：不再错误进入首页，却仍然错误地移走连接页。
- `BridgeService` 在 `channel.ready` 时发布 `connected`；当前枚举只有
  disconnected / connecting / connected / reconnecting，不能表达认证、能力
  握手、会话列表请求、会话列表已确认和兼容降级。
- `autoConnect()` 只表示“已发起连接”，返回 `true` 并不表示 Bridge 已可用。
- `_isAutoConnecting` 目前只在以下情况结束：
  1. 收到当前连接的权威 `session_list`；
  2. connection state 变为 disconnected；
  3. 根本没有可尝试的保存地址。
- 若 WebSocket 保持打开但没有返回可解析的 `session_list`，当前展示层没有
  权威就绪超时、阶段说明或恢复入口，中央转圈可能长期存在。
- `SessionHomeConnectionGate` 是 `SessionListScreen` State 内的内存对象，冷
  启动会重新创建，不会跨 App 进程借用上次 readiness。相同目标在同一页面生命
  周期内短暂重连时会保留已经建立的首页；切换规范化 URL 或 machine identity
  会清除 readiness。
- 空的 `sessions: []` 只要来自当前连接的合法 `SessionListMessage`，仍应算作
  权威完成；“会话为空”和“从未收到 session_list”不能混为一谈。

#### 3. Git 与运行态证据

- 中央转圈和 `_isAutoConnecting` 行为来自项目导入时已有的官方历史
  `2717842e`，不是 build 202 新增页面。
- v01 的连接门禁来自 `066172b3`，其测试覆盖了：
  - transport ready 不得进入会话首页；
  - 当前 Bridge 发出权威列表后才进入；
  - 同目标重连保留现有首页；
  - 切换目标必须重新取得权威列表；
  - 首次失败重连不得进入首页。
- 现有测试没有覆盖用户本次指出的展示要求：
  - 自动连接时连接表单必须仍可见；
  - transport connecting 时不得变成无信息全屏 spinner；
  - socket 已开但 session list 未到时的阶段、超时、取消和重试；
  - 冷启动旧 Bridge、错误 token、半开连接和不返回 session_list。
- 2026-07-26 只读核对时，官方 `upstream/main` 仍为
  `aa215a3b98a8035cba0e6bdd8005803f76041d66`，与 v01 登记一致。正式实施前仍需
  再次拉取并语义合并当时最新官方提交。
- 当前 Mac 实际运行的是
  `1.69.0-compat.6-4e611c6b` Bridge，而不是 build 202 源码对应的新候选；
  health 正常且当时有一个客户端连接。这个版本差异必须纳入真机复现，不能把
  “socket 上有客户端”当作新旧协议数据路径已经兼容。

#### 4. 尚未确认的部分

以下目前只是可能放大卡顿时间的分支，不作为已确认根因：

- 真机保存的 URL、token 或 machine identity 是否与当前运行 Bridge 完全一致；
- 当前那次中央加载是否停在 WebSocket、认证、`session_list` 解析，还是 recent
  catalog 的后续加载；
- 旧 Bridge 是否已返回了 build 202 能解析的 `session_list`，以及返回耗时；
- App 前后台切换、Tailscale/LAN 地址变化或 SSH tunnel 是否生成了第二次连接
  epoch；
- 物理设备日志中是否存在握手成功后立即断线、旧 token、协议错误或消息解析
  错误。

实施前应对一次真实复现采集有界诊断时间线，只记录阶段、目标的脱敏 identity、
connection epoch、消息类型和耗时，不记录 token、消息正文或文件内容。

#### 5. 目标交互

首次启动或冷启动自动连接时：

- 保留原有 IP/机器连接页，不导航到会话首页，也不替换成孤立的全屏 spinner。
- 保存地址可以自动尝试，但在对应机器卡片或连接面板内显示阶段：
  “正在建立连接”→“正在验证 Bridge”→“正在同步会话列表”。
- 用户始终能看到当前目标，并可取消自动连接、修改地址、选择另一台机器或重试。
- 只有当前 connection epoch 收到可解析的权威 `session_list` 后，才切换会话 UI。
- 权威空列表是成功状态，展示正常空会话首页；超时或协议不兼容不是空列表。
- 失败后留在连接页，以可操作错误说明代替永久转圈。

已经成功进入首页后的同目标短暂重连：

- 若本地仍有属于该目标的权威缓存，可保留首页，显示非阻塞重连状态，不闪回
  连接页。
- 若目标 identity 或 connection epoch 已切换，不得显示上一台 Bridge 的内容为
  当前权威数据。
- 是否继续展示旧缓存必须与“当前连接未就绪”视觉区分，不能显示成已连接。

#### 6. 拟采用的状态边界

实施时优先建立一个可测试的 presentation model，而不是继续用一个布尔值和四态
transport 枚举拼 UI。概念阶段至少包括：

```text
idle/selecting
autoConnectPreparing
transportConnecting
transportReady
awaitingAuthoritativeSessionList
ready
reconnectingWithCachedHome
failed/cancelled/incompatible
```

- transport 状态仍由 `BridgeService` 负责。
- application readiness 继续由当前目标、connection epoch 和权威
  `session_list` 决定。
- UI presentation 负责把上述事实映射到连接页、缓存首页或已连接首页。
- 不把“有保存地址”“autoConnect 返回 true”“WebSocket open”“有旧缓存”中的
  任一项单独当作 ready。
- 超时只结束等待并给出重试入口，不得伪造成功或清除可恢复的本地缓存。

具体是否新增公共连接阶段模型、沿用现有 gate，或将状态收束到 connection
coordinator，必须在实施时结合 Mobile/Bridge 最新源码和调用者影响面决定。

#### 7. 兼容与性能约束

- 旧 Bridge 若支持既有 `session_list`，继续走相同权威门禁，不要求新能力。
- 若未来增加显式 hello/ready ack，只能作为 additive capability；旧 Bridge
  仍必须通过既有消息完成。
- 不为等待状态增加高频轮询。优先复用连接事件和一次有界的 session-list 请求；
  重试需要退避、generation fencing 和取消。
- 连接页阶段变化只重建局部状态区域，不驱动会话列表、Markdown 或历史数据重建。
- 同一连接 epoch 的重复 `connected` 或重复 `session_list` 必须幂等。
- 不记录或展示 API key/token；诊断日志使用脱敏目标 identity。

#### 8. 实施前测试矩阵

至少补齐以下确定性测试后才能修改：

1. 冷启动、有保存地址、连接进行中：连接表单仍存在，阶段提示可见。
2. WebSocket ready、尚无 session list：仍在连接页，不展示会话首页。
3. 当前 epoch 收到空 session list：进入正常空首页。
4. 当前 epoch 收到非空 session list：进入会话首页。
5. 错误 token、连接拒绝、连接关闭、半开 socket、权威等待超时。
6. 自动连接期间取消、改选另一台机器；旧连接的迟到消息不得打开首页。
7. 同目标已就绪后的短暂重连：保留缓存首页并明确重连。
8. 冷启动不得继承上一进程 readiness。
9. 新 Mobile + 当前运行旧 Bridge；新 Mobile + 新 Bridge；无保存地址首次连接。
10. iPhone 前后台切换、LAN/Tailscale 地址和 SSH jump 连接路径。

#### 9. 验收标准

- 用户没有主动离开连接页前，App 不再用无上下文中央转圈替换整个页面。
- 会话首页只在当前目标的应用层权威数据就绪后首次出现。
- 任意失败路径都能回到可操作的连接界面，不会永久等待。
- 空会话与未收到会话列表有明确不同结果。
- 新旧 Bridge 兼容测试、Flutter 定向测试、iOS Simulator 构建和物理 iPhone
  真机复现通过后，才可标记完成。

## 2. 后续讨论登记方式

从本轮对话开始，每个新增问题按 `v02-002`、`v02-003`……追加到本文。若用户
修改产品定义，以最新确认语义为准，同时保留旧定义为何被替代的记录。待所有
问题讨论与调查完成后，再统一整理依赖关系、实施批次、提交边界、完整性能审查、
官方更新合并、Bridge/Cloud/IPA 发布顺序和最终验收矩阵，并由用户确认后开始
修改。
