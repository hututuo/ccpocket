# Phase 2：Native 与 Product Shell（P-014–P-026）

状态：`DRAFT_FOR_ROOT_INTEGRATION / PHASE_2_PRODUCT_DESIGN / IMPLEMENTATION_NOT_AUTHORIZED`

本文只覆盖 P-014–P-026。它以 `d152b118045264abeb8a1760b94113e323e46283` 工作树中的真实源码、v4 输入锁、功能胶囊、core-touch/pressure/source map 和长期 decisions 为事实基线。源码存在和测试存在只记为 `SOURCE_PRESENT`；本轮没有启动 Bridge、占用 `8765`、构建 IPA、发布 OTA、安装设备或做真机验收。

## 1. 固定边界

- 默认保留现有用户效果和现有 Dart/Swift/service/test 模块；只有 owner 错误、不安全边界、Claude 可达性或无法验收的回调所有权才 `ADAPT/REWRITE/DELETE`。
- 通知、后台、权限、更新、商业支持、图标、翻译、native callback、动效和 cache UI 都是 Product Platform/UI 状态，不进入 Session Kernel。
- Phase 2 只消费 Phase 1 接受后的最小语义接缝，不自行重开核心：post-commit projection、exact Interaction revalidation、durable cursor/foreground repair、local composer ingress、native lifecycle fence、K-015 authoritative settings mutation/ACK、protected local-state namespace。
- 通知是 committed fact 的投影，不是 conversation fact；通知送达、点击、系统权限、APNs token、位置租约、RevenueCat entitlement、选中图标、译文和动画帧都不得成为 canonical history。
- installed source、Bridge build/deploy、Mobile build、base IPA、签名安装、真机行为、owner patch 和 stable promotion 是独立门禁。设置页不得把它们压成一个 “updated” 布尔值。
- `stable` 是默认更新通道。owner 只用于本地 owner 设备。应用内没有 stable 发布/晋级动作；stable 仍需用户当次明确授权和发布脚本的 `--confirm-stable`。
- Claude 没有 runtime、wire、DB discriminator、capability、Mobile model、route 或 UI。只保留 unexported/unregistered、构造不可达、调用必然 `NOT_IMPLEMENTED` 的 typed seam。Astraeus 上游文件名/许可中的 “Claude” 只属于第三方归属，不构成 provider seam。

## 2. 现场源码事实与处置总览

| ID | 当前事实 | 目标处置 | feature owner |
|---|---|---|---|
| P-014 | Bridge notification projector、push relay/runtime、Mobile local notification、原生 action host 已存在；默认 action/completed/failed on、progress off、foreground on；remote push 配置仍可能是 dummy | `ADAPT` | NotificationService + notification projector |
| P-015 | `UIBackgroundTask`、warm `BGAppRefresh`、可选 location notification-only 三条路径已存在 | `ADAPT` | BackgroundLifecycleService；三条路径保持分离 |
| P-016 | permission host v3 列出 9 个 permission；Dart 最低 v2，probe 2 s、request 2 min | `KEEP + ADAPT` | PermissionService + per-platform adapter |
| P-017 | Mobile Shorebird service、compat revision banner、macOS updater 已存在；owner unlock 为版本 7 连点 | `ADAPT` | UpdateService；release authority 仍在外部流程 |
| P-018 | `speech_to_text` service/hook 已把识别文本写入 controller，但缺 draft revision/lifecycle fence | `ADAPT` | SpeechInputPort + accepted ComposerIngress |
| P-019 | 默认及两枚 Supporter icon、iOS method channel/readback 已存在 | `ADAPT` | AppIconService |
| P-020 | RevenueCat offering/purchase/restore 和 Supporter 页面已存在 | `KEEP + ADAPT` | CommerceAdapter |
| P-021 | review/banner/licenses/changelog/auth help 已存在；Changelog 目前依赖网络 | `ADAPT` | ShellServices |
| P-022 | Explore/Setup/QR/Settings/Debug 等已存在，但 router、workspace、resume/new-session 仍有大量 Claude 可达路径 | `REWRITE + DELETE` | Product router；Claude 仅 internal seam |
| P-023 | en/zh/ja/ko 四份 ARB 各 1,199 keys 且 key 集相同；Apple Translation host 尚不存在 | `KEEP fixed l10n + ADAPT optional translation` | Localization + narrow NativeTranslationPort |
| P-024 | MobileHostSnapshot schema v1 有 18 个 capability，但没有统一 lifecycle epoch；fence 散落在 plugin generation/runId | `ADAPT` | NativeCapabilityHost + 独立 plugin adapters |
| P-025 | authoritative effort 调用链、固定 72×6 fire、ACK rollback、GPL 归属和测试均存在 | `KEEP + ADAPT` | K-015 settings owner + presentation-only motion |
| P-026 | cache UI 可清 catalog/source/conversation，完整副本另删；尚无统一 protected namespace registry | `ADAPT + narrow REWRITE` | LocalStateNamespaceManager + existing stores |

## 3. 只消费的 Phase 1 接缝

最终类型名由 root 与 Phase 1 草案统一；本稿只绑定以下语义，不能用相似的 feature-local 第二实现替代。

| 接缝 | 消费者 | 调用方向 | Phase 2 只需要的语义 | 明确不进入接口 |
|---|---|---|---|---|
| S-05 post-commit projection | P-014、P-025 status/insights | Kernel/Repository → feature | source/thread、committed event id/revision、typed event、occurredAt、redacted presentation metadata | APNs token、OS delivery、banner、动画、译文 |
| exact Interaction revalidation | P-014 notification action | feature → Interaction owner | authenticated connection actor、source/thread/turn/request、authority epoch、allowed action、claim/result | notification payload 自报 authority、系统 action delivery 状态 |
| durable cursor + foreground repair | P-015 | feature → Repository/read owner | source epoch、已有 cursor/coverage、deadline/cancel、bounded delta、repair result | location、battery、entitlement、后台永久 socket |
| S-09 local composer ingress | P-018 | speech feature → composer owner | draft revision、replace range、partial/final/cancel、result | audio、recognizer object、自动 send/operation |
| P-024 lifecycle/capability fence | P-014–P-019、P-023–P-024 | Dart ↔ native adapter | capability id/version、host epoch、lifecycle epoch、request id、terminal callback key | 万能 raw method map、OS object、actor/identity |
| K-015 settings mutation | P-025 | UI → settings owner → Provider | target source/thread、settings revision、model support、effort、next-turn timing、mutation id、ACK/conflict/rollback | thumb position、fire grid、FPS、palette |
| P-026 namespace protection | P-026 | cache UI → local-state owners | namespace id/classification、source partition、clear epoch、atomic result/readback | arbitrary path/glob、generic clear-all、canonical history delete |

若上述接缝在 Phase 1 接受稿缺失，本稿产生的是 `MINIMAL_CORE_AMENDMENT_REQUEST`，而不是在 notification/background/cache 调用点自行补 owner。

## 4. 跨能力宿主规则

### 4.1 Platform capability 与 base IPA

`MobileHostSnapshot` 是 installed native host 的事实，不是总版本猜测。每项能力独立声明 `capabilityId → apiVersion`；缺失、低版本、timeout、malformed response、`MissingPluginException` 都 fail closed，只隐藏/降级该项能力。

- 纯 Dart 页面/策略在 native contract 不变且与实际 Shorebird base 匹配时才可能 owner OTA。
- Swift、plugin、Info.plist usage description、entitlement、asset catalog、Translation framework 或 native dependency 变化必须新 base IPA。
- source merge、IPA build、signed IPA、安装、真机 permission/callback 行为分别验收。

### 4.2 Host/lifecycle epoch 与 callback key

目标 snapshot 在 schema v2 增加两个 opaque string：

```text
hostEpoch       新 Flutter engine/native channel binding 时变化
lifecycleEpoch  foreground/background/unknown 的有效所有权代次变化时变化
```

每个有回调的 plugin 仍保留独立 typed API，但请求和回调均携带：

```text
NativeCallContext {
  capabilityId, capabilityApiVersion,
  hostEpoch, lifecycleEpoch,
  requestId
}
NativeCallbackKey = capabilityId + hostEpoch + lifecycleEpoch + requestId + terminalKind
```

规则：

1. Dart 只接受当前 snapshot 的 capability/version 和当前 epoch；
2. native 只完成匹配的 in-flight request；旧 engine、旧 lifecycle、旧 generation/runId 的 callback 只释放旧资源，不发布新 UI；
3. terminal callback 每个 key 至多消费一次；重复 callback 为 no-op 并计脱敏诊断；
4. idempotent read 可返回同 request 的缓存 terminal result，permission prompt、purchase、icon change 等非幂等动作拒绝 duplicate；
5. callback key/epoch 只用于所有权和 fence，不能成为 thread/source/data identity；
6. NotificationAction、BGTask、location lease 等还要执行各自更强的 source/authority fence。

### 4.3 通用错误与验收层

feature error 至少保留：`unsupported`、`requires_base_app_update`、`permission_required`、`permission_blocked`、`timeout`、`cancelled`、`stale_callback`、`duplicate_callback`、`platform_error`、`capacity`、`source_changed`。UI 显示人类说明，日志只写稳定 error code 和脱敏阶段。

每项分别标记：source tests、runtime adapter、native unit/XCTest、simulator UI、physical device、release artifact/entitlement。后一个 PASS 不能由前一个推断。

## 5. P-014 Notifications

### 5.1 入口、偏好与通道

设置 → Notifications 保留以下独立控制：总开关、action required、completed、failed、progress、foreground banner、lock-screen privacy、语言、可选 background notification mode。

| 通道 | 能力事实 | 系统权限 | 失败降级 |
|---|---|---|---|
| in-app/foreground | Dart UI 可用 | 无 | 当前会话默认抑制；用户关闭 foreground banner 后只保留 unread |
| local notification | installed notification plugin | 用户从设置开关或 feature action 显式请求 | 无权限时设置页显示 blocked/open Settings，聊天继续 |
| remote APNs/FCM | final signed entitlement + runtime token registration + real Firebase/APNs + relay | notification permission | dummy Firebase、重签名丢 APS、token/relay 失败时保持 in-app/local/foreground catch-up |

默认沿用现有效果：action/completed/failed enabled，progress disabled，foreground banner enabled。U-004 固定锁屏正文默认脱敏；preview 只能逐设备 opt in。隐私模式移除标题/项目、tool、问题正文、结果正文、路径和 source label，只保留 “需要操作/已完成/失败” 等固定文本。

### 5.2 投影、去重、unread 与动作

- event inventory 固定为 `approval_required`、`ask_user_question`、`session_completed`、`session_failed`、`session_progress`。未知 future event 默认不订阅，critical event 需独立版本/偏好后才开启。
- projector 只读消费已提交 typed event；progress 只能来自变更后的 tool stage，维持 45 s/session rate limit。
- 沿用当前 bounded hints：256 sessions、128 permission ids/session、2,048 Codex action request ids。eviction 最坏只允许一次后续重复，不能丢 conversation fact。
- `deliveryId` 只做 notification delivery ACK/dedupe。OS 显示失败不 ACK；Bridge 断线后不盲目循环显示。推送 relay 在没有 server-side delivery dedupe 前保持 at-most-once retry 语义。
- unread 完全由 committed assistant output/read watermark 决定。notification delivered/opened/dismissed 不创建或清除 unread；点击进入 exact thread 后，正常可见/ack 流程才推进 watermark。
- notification action payload 只是 lookup hint。打开后必须重新取得当前 source/thread/turn pending Interaction/CAB snapshot，核对 authenticated actor、authority epoch、allowed action 和 claim。已解决/过期/换 source 显示 “已处理或不再可用”，绝不重放旧 approve/reject。
- native cold-launch action queue 按 `(source, thread, request, decision)` latest-only 去重；Dart ready 后仍要执行上一条 revalidation。队列有界，超界丢最旧并只留诊断，不自动批准。

### 5.3 存储、隐私、生命周期

- NotificationPreferences、privacy/foreground choice 为 device-local settings；remote token 按 authenticated device/source 注册。原始 token 只进 secure/platform store 和 relay，不进 session cache。
- projector dedupe state 可重建且有界；通知正文不落 CC Pocket DB。OS Notification Center 的副本由系统管理。
- source/connection/host/lifecycle epoch 变化使未提交 action callback 失效。打开当前正在看的 session 时抑制重复 foreground banner。

### 5.4 验收与回退

- Bridge projector tests：五 event、45 s rate、privacy、bounded dedupe、legacy token subscription、late Interaction。
- Dart tests：偏好默认、当前会话抑制、本地 permission user gesture、malformed payload、source mismatch、duplicate action。
- XCTest：cold/warm action queue、host epoch replacement、duplicate terminal callback。
- 真机：本地通知；final re-signed IPA 的 entitlement/profile、APNs registration、真实 push。dummy Firebase 只允许标 `REMOTE_NOT_AVAILABLE`。
- 回退：关闭 notification adapters/capability 后保留 unread、chat 和 foreground catch-up；不得回退成 notification writer 或 background full sync。

## 6. P-015 Background lifecycle

### 6.1 三条必须分开的路径

| 路径 | 当前/目标用途 | 允许数据 | 明确不承诺 |
|---|---|---|---|
| finite continuation | active turn 从前台转后台后的有限 `UIBackgroundTask` | 已有 watch/cursor 的 bounded delta 和 completion tracking | 永久 socket、冷启动、首次全量历史 |
| warm BGAppRefresh | iOS opportunistic refresh；现有 Flutter runtime 可用才执行 | 最多 2 个已有 conversation cursor、cached-delta-only | cold/headless Flutter、按时运行、force-quit 后恢复 |
| optional notification-only location lease | active work 的轻量通知连接 | background notification/activity/ACK | stream/history/Mirror/file/tool body；坐标读取/存储/上传 |

notifications-only 与 background catch-up 不能共用一个 “background enabled” 布尔值。notification-only engaged 时，BGAppRefresh 必须直接退出，不能重新引入 conversation synchronization。

### 6.2 时间、容量和停止条件

保留当前已实现预算作为初始合同：connection 4 s、session list 5 s、history response 4 s、continuation tracking 22 s/500 ms poll；foreground repository budget 12 s，background warm budget 8 s；BGAppRefresh native budget 25 s、最早 15 min，由 iOS 可延迟/取消。background 不允许 unbounded full-history fallback；foreground 才可执行兼容 repair。

location notification lease 只有以下全部成立才 pre-arm：用户显式开启、active work、notification permission、Always Location、host capability、Bridge `background_notification_delivery_v1`、transport ready、非 Low Power、thermal 非 serious/critical。停止条件：task count=0、user disable、resume/leave lifecycle、permission/location error、Low Power、thermal pressure、Bridge disconnect 2 min、source/host epoch change、plugin expiration。

坐标 delegate 必须保持空实现；不得读、log、persist 或发 coordinates。系统 background indicator 必须可见。coarse accuracy/distance filter 只属于 native execution primitive，不进 core 或诊断正文。

### 6.3 状态、错误和 foreground repair

feature state：`foreground_interactive`、`preparing`、`finite_continuation`、`refresh_waiting/running`、`notifications_only`、`paused(reason)`、`foreground_repairing`、`unsupported`。`inactive` 只是准备态；只有真实 `paused/hidden/detached` 标记 background。`inactive → resumed` 不触发伪 catch-up。

resume 顺序固定：increment lifecycle epoch → cancel/end old continuation/location → request Bridge `interactive` and receive ACK → restore watches/subscription → session list/status → durable cursor delta repair → clear catch-up pending。任一步取消时保留 `foregroundCatchupPending` 给下一次 definite resume。

generation/runId/deadline 共同 fence。late BG expiration、旧 continuation end、旧 delivery-mode ACK 或旧 history frame不能关闭/覆盖新 lease。deadline 到达必须取消底层 request/subscription，而不是只停止 UI await。

### 6.4 Platform 与验收

- finite/BGRefresh 需要 `backgroundContinuation`、`backgroundRefreshWarmRuntime`、BG task identifier 和 `fetch`；location path 额外需要 permissionHost v3、usage strings、`UIBackgroundModes/location`；remote notification 仍独立依赖 APS/FCM。
- Swift/Xcode/Info.plist/entitlement 变化要求新 base IPA；Dart policy tuning 才可能 owner OTA。
- simulator 可验 lifecycle/generation/UI；background timing、energy、force-quit、indicator、Low Power/thermal、re-signed entitlement 必须物理 iPhone。
- 回退顺序：先关 optional location notification-only；保留 finite continuation/BGRefresh；再可关 background module，foreground canonical repair 仍必须工作。

## 7. P-016 Permission management

### 7.1 Inventory 与 request mode

设置 → Permissions 只做 passive snapshot；只有用户点击具体 permission 的 “Allow/Open Settings/Choose” 才 request。

| stable id | status/query | request mode | 说明 |
|---|---|---|---|
| notifications | direct query | direct/openSettings | 不在 app launch 初始化时 prompt |
| camera | AV query | direct/openSettings | QR/相机 feature action |
| photoLibrary | Photos query | direct/openSettings | limited 是可用状态 |
| microphone | AV query | direct/openSettings | voice mic tap |
| speechRecognition | Speech query | direct/openSettings | voice mic tap，和 microphone 分开 |
| locationAlways | CoreLocation query | direct upgrade/openSettings | 仅 P-015 optional mode；需要 native API v3 |
| localNetwork | 无可靠持久 grant query | featureTriggered | 由实际 LAN/discovery 行为触发 |
| files | system-managed | systemPicker | 由 picker 触发 |
| biometrics | system-managed | featureTriggered | 由 exact protected operation 触发 |

Dart host v2 继续使用旧 base 的已有 permission；只有 `locationAlways` consumer 要求 v3。unknown id、unknown status、低 API、旧 OS、missing/malformed/timeout 都是 `requires_app_update` 或 `unavailable`，不能猜 authorized。

### 7.2 状态、容量、fence

状态枚举沿用 notDetermined/authorized/whenInUse/always/denied/restricted/limited/provisional/ephemeral/systemManaged/unavailable/unknown。probe timeout 2 s，request 上限 2 min；同一 permission 同时只允许一个 prompt request。第二次点击 join 当前 UI busy 状态，不再发 prompt。

permission snapshot 不持久化为事实；每次进入页面、resume、open Settings 返回后 readback。request 带 NativeCallContext，旧 lifecycle/duplicate callback 不更新新页面。权限被系统撤销后下一次 readback 立即降级对应 feature，不清其他设置。

### 7.3 验收与回退

测试 unknown/future status、direct/openSettings/systemManaged、v2/v3 matrix、timeout/duplicate/late callback。真机分别验证 notification、camera、photo limited、mic+speech、location upgrade、Settings 返回。回退 permission UI/plugin 不影响 core；具体 feature 继续自行 fail closed。

## 8. P-017 Updates and release state

### 8.1 两种检查不能混同

1. Mobile ↔ Bridge compatibility：比较单调 `clientBridgeCompatibilityRevision`，当前源码两端为 1。相等无 banner，Bridge 较低提示更新 Bridge，Bridge 较高提示更新 App；missing 为 legacy/unknown。不得访问 npm registry 或比较公开包最新版。
2. installed Mobile delivery：Shorebird manual/automatic/silent 和 `stable/owner` track。它不决定 Bridge compatibility revision。
3. macOS Desktop update：Sparkle/native updater 优先，GitHub DMG 为 fallback，是单独 surface，不参与 iOS owner/stable。

### 8.2 Mobile 状态机与授权

`idle → checking → upToDate | updateAvailable → downloading → restartRequired`，任一步可到 `unavailable/failed(kind)`。failure kind 保留 network/signature/versionMismatch/download/install/unknown；retry 只重做最近失败的 check 或 download。

- manual check 永远绕过 6 h throttle，但只检查；显示 update 后需要第二次用户动作 download。
- automatic/silent 可按 6 h throttle check/download；automatic 提示 restart，silent 不提示。应用不能替用户 restart/kill。
- stable 默认。版本号 7 连点才把 owner 入口解锁；unlock/channel 存 iOS secure storage。切 channel 只影响未来 check，不声称已安装 patch 降级。
- SDK 在下载前无法得知 remote patch number，UI 先显示 checked track；下载后再显示 next patch。
- 应用内绝不 publish、promote、rollback stable、build IPA、替换 Bridge 或安装 App。

### 8.3 独立完成门禁

```text
source implemented
→ commit integrated
→ Bridge built
→ Bridge deployed/protocol accepted
→ Mobile tests/analyze
→ simulator install/launch
→ base IPA built + native diff inspected
→ signed/re-signed artifact entitlement verified
→ physical iPhone install/launch/behavior
→ owner patch exists + device reopen confirms
→ explicit user approval + exact patch stable promotion
```

UI 可以显示已确认层和 `NOT_RUN/BLOCKED/FAIL`，不得推断下一层。native/plugin/entitlement/asset/Flutter engine/Xcode/native dependency 变化必须 base IPA；Dart-only 仍需 exact release lineage。

### 8.4 回退

关闭 update UI/service 不改变 installed patch。失败保留 current working app；downloaded next patch 可等待 restart。owner 验证失败不得用 stable 掩盖，也不得自动 rollback。release rollback 仍是单独外部授权。

## 9. P-018 Voice composer ingress

### 9.1 入口和状态

composer microphone button（可在 Settings 隐藏）进入 `probing → idle → listening(partial/final) → stopping → idle`；不可用、permission blocked、locale unavailable、recognizer error 分别展示。desktop/web 沿用 unsupported；移动平台还需 `speech` host capability。

第一次 mic tap 是 microphone + speech permission 的明确 user gesture。页面 build/initialize 只查状态，不弹 prompt。用户选择 `speechLocaleId`，空值跟随系统；不支持 locale 时回系统默认并告知。

### 9.2 Draft merge

开始识别时捕获 `{draftRevision, selectionStart, selectionEnd, requestId}`。每个 partial 通过 Phase 1 ComposerIngress 替换同一个 recognizer-owned range；下一 partial 替换上一 partial，不重复 append。final 将该 range 提交为普通 draft text，仍不发送。

若用户在识别期间编辑/移动 selection，draft revision 不匹配，当前 speech patch 必须停止或重新 capture，绝不能覆盖用户新文本。cancel 恢复开始识别前的 range；stop 保留最后 partial/final，具体按钮文案清楚区分。send 永远是另一显式动作，speech partial/final 不创建 operation/timeline item。

### 9.3 容量、隐私、lifecycle

识别文本遵守 composer 的同一字符上限；partial 回调按 UI frame 合并，内存只保留 base range + latest partial。CC Pocket 不持久化音频或 recognizer object；Apple/OS speech service 的处理现实在 permission copy 中说明。background、route dispose、host/lifecycle epoch change、incoming call/error 都 cancel listener；late result 由 request/draft revision fence 丢弃。

### 9.4 验收与回退

测试 selection replacement、连续 partial、final、user edit conflict、cancel/stop、locale、permission denied、background/late callback、never auto-send。真机验证 mic/speech dual prompt、系统 locale 与无网络/不可用现实。回退 voice adapter 后 composer、keyboard、draft persistence 和 send 均不变。

## 10. P-019 Alternate app icon

保留三项 inventory：default、Supporter Light Outline、Supporter Pro Copper Emerald。Settings → Appearance → App icon 是入口。默认 icon 对所有用户可用；两枚 alternate icon 可以是 Supporter 致谢外观，但 entitlement 失效、RevenueCat offline 或 icon failure 绝不能限制任何核心功能。

状态：`probing → ready(current) → applying(target) → readback(current)`，另有 `unsupported/failed(error,current)`。platform current icon 是事实；SharedPreferences selection 只是 intent。set 失败、callback timeout、unsupported、Supporter 状态变化后必须 native readback 并把 UI 恢复真实 current，不能停在 optimistic target。

iOS 使用 `supportsAlternateIcons/alternateIconName/setAlternateIconName`。Android 当前没有已核实同等 host，继续 feature-level unsupported，不能因 Dart 把 Android 列为 supported platform 就展示成功。新增/替换 icon assets 是 native/asset base IPA 变化；仅选择已有 icon 才是 runtime local action。

同一 lifecycle 一次只允许一个 apply；requestId/epoch fence 丢弃旧 completion。选中值可持久化，但不保存 native handle。回退 alternate icon module 时先 readback/可选恢复 default；不删除 assets 不影响 core。

## 11. P-020 Supporter / RevenueCat

### 11.1 用户效果与状态

Settings → Supporter 保留 current offering、subscription/one-time packages、purchase、restore、support history 和感谢 UI。状态：`unavailable/loading/ready/inactive/active/purchasing(package)/restoring/cancelled/error`。取消购买不是 failure；同一时间只允许一个 purchase/restore。

RevenueCat `supporter` entitlement 是 store-scoped commerce fact。公开 SDK key来自 build environment；debug test key 只在 debug。CC Pocket 不自建跨平台 account，不把 receipt/customer id 写入 session DB，不在日志打印完整 customer/receipt。package cache 只保存 SDK object 的当前 offering 生命周期。

### 11.2 不门控核心

Supporter 只能影响感谢 banner、Supporter page、alternate icon 等非核心外观。连接、会话、history、发送、审批、Goal/Plan、文件、Git、notification、cache cleanup 和设置安全能力永远可用。commerce unavailable/offline/error 时 core acceptance 必须与 active Supporter 相同。

离线可以显示 SDK 的 last-known verified entitlement/summary，但 offering/purchase 显示 unavailable/retry；不得凭本地 bool 自授 entitlement。恢复购买必须用户动作。entitlement change 只触发 perk readback，不中断页面或重启 runtime。

### 11.3 验收与回退

测试 no key/unsupported platform、empty offering、purchase success/cancel/error、restore、listener update、offline last-known、core feature matrix invariant。Store sandbox 真机验购买/恢复；模拟器 mock 只算 UI。回退 commerce adapter 时隐藏购买入口/显示 unavailable，核心及 default icon 不变。

## 12. P-021 Product shell services

### 12.1 Route/content inventory

| surface | 当前效果 | 目标 |
|---|---|---|
| in-app review | 3 天、3 次成功连接、3 个 session、2 个 usage day；negative 24 h；prompt 90 d 且同版本一次 | `KEEP`；计数仅 local product analytics，不写 timeline |
| Support banner | dismissed、Supporter、无 offering、有 update 时抑制 | `KEEP`；离线/commerce unavailable 不骚扰 |
| Licenses | package licenses、MIT、GPL/third-party notice | `KEEP`；完全离线且可搜索/辅助功能可读 |
| Changelog | 当前从 GitHub raw 拉取并按版本过滤 | `ADAPT`：基础 App 内置最近 release snapshot；网络可条件更新并 last-good，离线仍可打开 |
| Auth Help | en/ja/zh/ko bundled Markdown | `KEEP`；删除 Claude provider 专属可达内容后改为 Codex/Bridge auth help |

Changelog remote fetch 设 bounded timeout、大小/content-type、ETag/last-good；失败显示 bundled snapshot，不空白。Markdown link 只通过显式点击外开；不执行 HTML/script。Licenses/Changelog/Auth Help 均支持 Dynamic Type、VoiceOver、返回手势和无网。

review/support counters、dismissal、last-good changelog 是 device-local product settings/cache；它们不是 conversation authority。回退任一 shell surface 不要求 Session Kernel/schema rollback。

## 13. P-022 Product routes and zero reachable Claude

### 13.1 保留 route

保留：Home/Workspace、Codex session、typed session link、Explore、Gallery、Git、Settings、Licenses、Changelog、Auth Help、Supporter、QR Scan、Setup Guide、Debug。Mock Preview 只在 debug/test build 注册，release router 不含 route/deep link。

每条 route 有 typed args、guard 和 unknown/deep-link failure page。route/path 不是 data identity；打开 session 必须携带已验证 Codex source + durable thread id，不能从 URL/title 猜。

### 13.2 必须删除的 Claude reachability

当前源码仍有 `ClaudeSessionRoute('/session/:sessionId')`、workspace fallback、session resume coordinator、provider filter/default、new-session Claude tab/settings、mock wrappers 和 Bridge Claude runtime handlers。目标处置：

- `DELETE` router import/registration/generated route 和所有 navigation construction；旧 `/session/:id` 返回 unsupported/not-found，不能映射到 Claude，也不能猜成 Codex。
- `DELETE` workspace/home/session-list 的 Claude screen fallback 和 `provider ?? claude` 默认；缺 provider 是 invalid/unknown source，不创建 runtime。
- `DELETE` new-session Claude tab/model/effort/permission fields、Claude billing/auto-rename surface、release Mock 中的 Claude provider scenario。
- `DELETE` production Bridge Claude process factory、start/resume/list routing、wire discriminator、capability advertisement 和 DB fields；不保留 hidden feature flag。
- 保留历史只读文档/许可证中必要文字，但不能通过 route/runtime 构造。

唯一 seam 形态沿用原设计：unexported/unregistered `UnfinishedConversationProvider` brand，`designStatus='NOT_IMPLEMENTED'`，private constructor，唯一 callable path 返回 `UNSUPPORTED_PROVIDER`。它不进入 root screen feature switch、wire、DDL、Mobile enum 或 capability snapshot。

验收：release route inventory golden、deep-link fuzz、grep/lint provider discriminator allowlist、Bridge factory test、Mobile no Claude route/widget/runtime test。第三方 Astraeus attribution/file name 单独 allowlist。回退 shell route 重排也必须维持 Claude unreachable，不能以“兼容旧链接”为由恢复 runtime。

## 14. P-023 Fixed localization and optional Apple on-device translation

### 14.1 固定文案

en/zh/ja/ko ARB 当前各 1,199 keys 且 key 集一致，这是 source fact，不代表所有生产 widget 无 hard-coded English。所有按钮、标题、菜单、tooltip、状态、错误和 warning 固定 copy 进入 ARB/feature l10n；Codex、Git、Bridge、JSON、Quick Look 等按 reviewed glossary 保留。

CI 扫 production widget raw strings，排除 log/protocol/error code/mock/test/code sample/brand。危险词 Revert/Delete/Overwrite/Reset/Discard 需要语义 widget test，不只做 key parity。codegen 输出与功能 commit 分离，避免无关 formatter churn。

### 14.2 动态翻译 allowlist

只接受完整稳定的自然语言 warning/explanation：provider warning、Bridge human explanation、结构化 error 的 human detail、用户显式点 Translate 的说明。以下 classifier 任一命中即拒绝：command/code/patch/diff、path/URL/SHA/branch/worktree、JSON/XML/YAML/log/payload、error code/tool/model/MCP/plugin id、credential/token/challenge/signature/疑似 secret、streaming partial。

译文是 display attachment：保留原文，标 “On-device machine translation”，危险操作默认原文可见；绝不写回 canonical history、notification action、approval meaning 或 diagnostics source。auto translation 只处理已安装语言对；可能触发语言包下载/同意的 `prepareTranslation` 只能来自用户显式动作。

translation cache key 为 `(sha256(sourceText), sourceLanguage, targetLanguage, policyVersion)`，memory-only LRU 128 entries/512 KiB；关闭功能、locale/policy change 或 memory pressure 清除。不得保存 Apple model、原文 secret 或 translated canonical copy。

### 14.3 Platform fact 与 lifecycle

本机 Xcode 26.1.1/iPhoneOS 26.1 SDK 已确认 Translation framework 存在，`LanguageAvailability`/`TranslationSession` 基础 API为 iOS 18+；项目 deployment target 仍为 iOS 15。目标新增独立 `systemTranslation:1` capability 和 narrow plugin，使用 `@available(iOS 18, *)`。iOS 15–17/旧 base 显示原文且基础功能不降级；无 ML Kit/cloud fallback。

每个 request 带 host/lifecycle epoch，source text hash 与 target language；latest-only UI owner 丢弃旧语言/旧 cell callback。翻译 timeout/cancel/model unavailable/user拒绝下载均回原文。新增 Swift/framework/capability 是新 base IPA；之后纯 Dart copy/policy 才可能 OTA。

验收：ARB parity + production raw-string audit、classifier negative corpus、cache bound、locale churn、iOS 15 fallback、iOS 18+ 真机 language installed/download denied/offline、原文 accessibility。模拟器结果不冒充 device language model acceptance。

## 15. P-024 Native capability host

### 15.1 Snapshot 与 plugin inventory

保留 schema v1 的严格 parse bounds（最多 64 capabilities，id 1–64 ASCII alnum，version 1–1000，probe 2 s），schema v2 additive 增加 host/lifecycle epoch。当前 iOS capability 事实包括 permissionHost 3、fileTransfer 2、quickLook/share/notifications/speech/webView/secureStorage/database/clipboard/dragDrop/photoLibrary/biometrics/fileMutationBiometricAuth/backgroundContinuation/backgroundRefreshWarmRuntime/backgroundLocationKeepAlive 1、notificationApprovalActions 2。未来 translation 独立加 `systemTranslation:1`。

snapshot 只说明 compiled host 能力；permission granted、APS provisioning、Firebase real config、RevenueCat offering、Bridge capability 和当前 OS resource state 必须各自 readback，不能由 snapshot 推断。

### 15.2 不建万能 gateway

MobileHostService 只 probe/cache inventory 和 epoch。Permission、file transfer、Quick Look、file mutation auth、background、notification action、app icon、translation 各自保留 typed adapter、timeout、capacity 和 error enum；禁止 `invoke(capability, Map)`、raw callback bus 或 native object passthrough。

AppDelegate/engine rebind 创建新 host epoch并注入各 plugin context。每个 plugin 负责自己的 in-flight table/duplicate policy，统一只复用 NativeCallContext/value parser。host snapshot force refresh 只在 engine rebind/base update/explicit diagnostics，普通 UI 不反复 probe。

### 15.3 验收与回退

- Dart parser/property tests：malformed/oversized/unknown capability、old schema、新 optional fields。
- XCTest conformance：snapshot version 与实际 registered plugin method set 对应；旧/重复/late callback；engine replacement；每个 stateful op 资源释放。
- base IPA 检查 compiled plugin、Info.plist/entitlement/assets、真实 OS minimum；Shorebird old Dart 对新增 dormant plugin 兼容。
- 每个 adapter 可独立关闭/revert；保留 snapshot/epoch fence。不能通过删除 fence 回退到 raw method channel。

## 16. P-025 Authoritative effort and presentation effects

### 16.1 Effort 是 settings mutation，不是动画值

必验六档为 `low/medium/high/xhigh/max/ultra`。`none/minimal` 只在 model catalog 明确广告时保留为兼容选择；future unknown effort 可显示 raw read-only，不得误标成 High。可选档位来自 authoritative `session_list/model/list` catalog，不由 slider invent。

选择请求携带 source/thread、settings revision、model、effort、target=`next_turn`、mutation id/epoch；保持 speed/service tier/sandbox/permission/collaboration 等非目标字段。当前 turn 不声称被改。外部 Desktop owner 活跃且无可写 authority 时 fail closed `settings_owned_elsewhere`。

UI 可以显示 `pending effort`，但 provider/Bridge authoritative ACK 才替换 committed setting。ACK 必须匹配 mutation/source epoch；late ACK 只能更新下一次 rollback base，不能覆盖更晚 pending mutation。rejected、unsupported tier、conflict、disconnect-before-admission 回到最后 authoritative projection；`OUTCOME_UNKNOWN` 先 read-only reconcile，不盲重发。

入口保留 current session settings sheet、session mode bar/new Codex session。所有入口消费同一 model support/setting adapter，不能各自维护 effort default。

### 16.2 72×6 fire 精确合同

- 进入 x-high/Max/Ultra 播放一次 deterministic arrival burst；只有 Max/Ultra persistent fire。
- 一张 immutable full-track 72 columns × 6 rows UV grid。drag 只改 simulation front 与 `slider + 2%` mask，不 translate/stretch/compress/regenerate grid。
- Max 用同一模拟，偏红 crimson/magenta palette，motion rate 0.35；Ultra 紫白 palette，0.70。Max ↔ Ultra 不清 framebuffer、不跳 accumulated phase。
- LTR logical column increasing 左→右；RTL 只 mirror paint coordinate。移动到较低 effort 的 cross-frame shift 在 LTR 为负。
- active track 在 LTR 结束于 thumb center 前 8 logical pt，RTL 后 8 pt；fire clip 同一 active rect，thumb 最后绘制。
- primary pointer-down 同一 rendered frame commit/snap；keyboard selection 120 ms glide；drag release 150 ms settle。到达 burst/colour/fire 独立。
- TickerMode/Reduce Motion 停 fire/burst 且不积累 hidden time；重新启用从 last visible feedback 继续。
- immutable UV/hash/envelope 预缓存；RGB blur 一次遍历；warm 已选 tier 只评估 reference frame 228 的最后 72 feedback frames；stale catch-up 最多 2 frames。
- glow/fringe/core 三层共享 indexed mesh，每帧一个 `drawVertices`，录制后立即 `Vertices.dispose()`。

### 16.3 其他状态视觉逐项归属

| effect | fact input | motion | reduced-motion/performance rule |
|---|---|---|---|
| Home status dot | SessionVisualStatus working/needsYou/error/idle/unknown | working/needsYou pulse | TickerMode + disableAnimations；error/idle/unknown static |
| unread glow | committed unread watermark | static glow | 不能由 notification delivery 驱动 |
| Plan orbit/glow | provider-backed Plan state | orbit highlight | reduced motion 显示 static plan badge，不丢状态 |
| session toolbar status dot/timer | committed process status | pulse + 1 s elapsed label | timer 为显示，不写 activity fact；统一接入 disableAnimations |
| context/quota rings | read-only SessionInsights projection | static circular meters | missing unknown 不画 0；75% orange、90% error；last-good cache 32 entries/64 KiB/1 day |

Painter/animation 不得推断 working、effort、quota 或 write session state。quota cache 只是 stale-while-refresh presentation。

### 16.4 许可、性能、验收与回退

`claude_range_slider_fire.dart` 保留 GPL-2.0-only header、Astraeuszhao/UI revision `528cf0a6899d1a0c71bbb91e7dc7eaca75fdeafa`、THIRD_PARTY_NOTICES；combined fork GPL-2.0-only，原 MIT notice 保留在 `LICENSES/MIT.txt`。license metadata 与 behavior/performance commit 分离。

验收分四层：settings unit/Bridge ACK-conflict-reconcile；motion deterministic/drag/RTL/clip/reduced/Ticker tests；profile physical owner iPhone 10 s Max/Ultra（60 Hz frame budget 16.67 ms，记录 p50/p95 raster、dropped frames、allocation/thermal，不以 simulator 结论替代）；用户最终视觉验 Max/Ultra palette/underlap/arrival。若 profile 不达标，只能优化缓存/batching，不改 grid/equations/palette。

回退 fire renderer/UI 独立恢复 non-animated discrete slider；保留六档 selectable values 和 K-015 authoritative settings contract。license notice 只在对应 derived code 完全删除后才能移除。

## 17. P-026 Cache management

### 17.1 Namespace registry

Settings → Storage & Cache 不再调用 `clearAll/path glob`。每个 owner 注册 typed descriptor：

```text
LocalStateNamespaceDescriptor {
  namespaceId, owner, sourcePartition?,
  classification: rebuildable | protected | userOwnedCopy,
  userClearable, automaticGcAllowed,
  measuredBytes, itemCount, ownerLimit,
  clearProtocolVersion
}
```

| namespace | class | current bound/fact | clear policy |
|---|---|---|---|
| session catalog/hot windows/status/index/detail staging | rebuildable | 10,000 sessions/source；2,000 hot entries；8 MiB stage | all/source/thread atomic clear，保留 partition aliases 和 read watermarks |
| session insights quota | rebuildable | 32 entries、64 KiB、1 day | 可自动/手动 clear |
| Git/media/artifact/preview thumbnails/temp | rebuildable | 各 owner 现有限额/OS temp | owner clear；不删用户保存文件 |
| translation display cache | rebuildable | memory 128/512 KiB | locale/policy/memory pressure clear |
| drafts/images/pending submission | protected | `draft_v1_*`/image/submission keys | cache UI 永不删除；只在 composer explicit discard |
| offline/outbox/queued operations/Interaction claims | protected | Phase 1 queue limits | 只能 owner 的 cancel/reconcile 流程处理 |
| credentials/trust/pairing/SSH/API keys/update owner unlock | protected | secure/platform stores | cache UI 不展示 secret，不清除 |
| settings/preferences/read watermarks | protected | SharedPreferences + cache DB watermark | 专门 settings/reset flow；cache clear 保留 |
| transfer checkpoint/secret/partial/staged upload | protected | 7 day、512 sidecars、64 KiB/checkpoint；queue 8/30 GiB | transfer cancel/expiry/recovery owner 处理；cache clear 不碰 |
| received downloads/user files | userOwnedCopy | file system/inbox | 文件 UI 明确删除，不叫 cache clear |
| downloaded full conversation copy | userOwnedCopy | 100,000 entries/64 MiB/conversation；512 MiB local-copy DB bound | 单 copy/全部 copies 独立确认；普通 cache clear 永不删除 |

v4 不恢复 Mirror writer。当前 `ConversationMirror` storage 只能作为 target full-copy store 的源码复用候选；必须移除 live/canonical writer 语义，Provider durable history 仍权威。旧数据默认不导入；若保留同文件读取会产生 runtime compatibility，则按 input lock 不做 importer。

### 17.2 原子 clear、并发与低空间

clear 请求为 `{namespaceId, sourcePartition?, expectedClearEpoch, requestId}`。owner serializes writers，先 cancel/await该 namespace staging writes，在一个 SQLite transaction 或 owner-defined atomic swap 中删除，commit 后 increment clear epoch，readback count/bytes，再发布 UI result。旧 epoch writer/callback 不得把 cleared rows 写回。

当前屏幕可继续保留 visible in-memory last-good list，同时标 `cache cleared; refresh required`；连接后用新 source epoch canonical reconcile。不得为了清 cache 断开 authenticated socket、清整个 DB、删 draft 或把 last-good 变空白。

容量继续采用各 owner hard bounds和 content-plane reservation，不另造万能 cache size。自动 GC 只选择 `rebuildable && automaticGcAllowed` 的 LRU/expired rows，并为当前已声明的最大 operation reservation 保留实际 filesystem headroom；无法满足时返回 typed `insufficient_storage` 和 cleanup UI，不越级删除 protected/userOwnedCopy。

### 17.3 验收与回退

- registry completeness test：任何 on-disk/SharedPreferences/secure namespace 必须唯一分类；unknown 默认 protected。
- fault injection：clear 中 crash/rollback、concurrent writer、late callback、source switch、restart/readback、low space。
- survival matrix：draft、pending submission、offline queue、credentials、settings、read watermark、transfer checkpoint/partial 均 byte-for-byte/semantic survive。
- full-copy delete 单独 confirm，删除失败保留 metadata/retry；普通 clear 后 full copies仍可打开。
- 回退 cache UI/action 时保留 Phase 1 protected namespace contract；绝不恢复 destructive broad clear。

## 18. 兼容矩阵

| 组合 | 行为 |
|---|---|
| new Dart + old native host | 每项 missing capability fail closed；固定 l10n、core chat 可用；translation/epoch-dependent action 隐藏 |
| old Dart + new native host | 新 plugin dormant；旧 method 保持兼容；native 不主动 prompt |
| new Mobile + old Bridge | notification-only/action/cursor capability 缺失时降级 local/in-app/foreground repair；不发 unknown wire |
| old Mobile + new Bridge | Bridge 只按 advertised capability 发旧流；不把 progress/notification action 自动开启 |
| iOS 15–17 | 无 Apple Translation；显示原文；其他 host capabilities独立 |
| remote push unavailable | local/in-app/unread/foreground catch-up 正常；不得宣称 remote PASS |
| commerce unavailable | Supporter purchase/perk unavailable；全部 core feature不变 |
| cache registry unavailable | 隐藏 broad clear；提供 per-owner safe actions；protected state不动 |

## 19. 必做事实实验与 device gates

| ID | 实验 | 当前状态 | 阻断的结论 |
|---|---|---|---|
| EX-P014-01 | final re-signed owner IPA 的 APS entitlement/profile、APNs registration、真实 Firebase push | `NOT_RUN`；source 有 development entitlement，build script可生成 dummy Firebase | remote lock-screen delivery |
| EX-P015-01 | physical iPhone finite/BGRefresh/location notification-only：force-quit、reclaim、Low Power、thermal、2 min disconnect、indicator | `NOT_RUN` | optional background device acceptance |
| EX-P016-01 | iOS 15/18/26 permission snapshot/prompt/Settings return matrix | `NOT_RUN` | permission native acceptance |
| EX-P017-01 | exact Shorebird base/app id/RSA lineage、owner check/download/restart；stable unchanged | `NOT_RUN` | owner OTA acceptance；不授权发布 |
| EX-P018-01 | mic+speech locale/offline/on-device privacy behavior on owner iPhone | `NOT_RUN` | voice device acceptance |
| EX-P019-01 | alternate icon asset presence、set/readback/failure after re-sign | `NOT_RUN` | icon native acceptance |
| EX-P020-01 | RevenueCat Store sandbox offering/purchase/cancel/restore/offline entitlement | `NOT_RUN` | commerce device acceptance |
| EX-P021-01 | bundled licenses/Auth Help/changelog、offline last-good、malformed remote Markdown、Dynamic Type/VoiceOver | `NOT_RUN` | product shell offline/accessibility acceptance |
| EX-P022-01 | release binary route/deep-link/Bridge factory inventory has zero reachable Claude | `NOT_RUN` | Codex-only shell acceptance |
| EX-P023-01 | Apple Translation language installed/download denied/offline on iOS 18+ device | `SDK_SOURCE_CONFIRMED / DEVICE_NOT_RUN` | optional translation device acceptance |
| EX-P024-01 | engine replacement + late/duplicate callback fault harness across all stateful plugins | `NOT_RUN` | host epoch conformance |
| EX-P025-01 | 10 s Max/Ultra physical profile + user visual acceptance | `SOURCE_TESTS_PRESENT / RUNTIME_NOT_RERUN` | fire performance/visual acceptance |
| EX-P026-01 | namespace inventory + crash/concurrent clear + protected survival/restart | `NOT_RUN` | cache management acceptance |

## 20. 建议实施与回退顺序

1. 先集成 accepted Phase 1 seams 与 product-level type adapters；没有接口则提交最小 amendment request。
2. native host epoch/conformance先行，但每个 plugin commit 独立；新 base IPA 只在用户授权的 release task 处理。
3. notification/background/permission 分三组实现，notification-only location 独立可关闭。
4. update、voice、icon、Supporter、shell、localization 分离提交；Claude unreachable 是独立 deletion/rewrite commit。
5. effort settings adapter与 fire renderer/license commits分离；cache registry 与 UI clear commits分离。
6. 每个 feature rollback 只撤自己的 adapter/UI，保留 accepted core interface、last-good data、protected namespace 和 Codex-only seam。

本文完成只表示 Phase 2 产品设计草案可供 root 集成；不表示源码实现、runtime、base IPA、owner OTA、安装、真机或 stable 已完成。

## Appendix A. 现场源码与测试 evidence anchors

以下是 `d152b118045264abeb8a1760b94113e323e46283` 的代表性锚点，不是目标 owner 的替代定义；没有列出的同域文件也不能因而删除。

| ID | Dart / TypeScript / native source | existing test evidence |
|---|---|---|
| P-014 | `packages/bridge/src/background-notification-projector.ts`、`push-runtime.ts`、`push-relay.ts`、`background-delivery-protocol.ts`；`apps/mobile/lib/services/notification_service.dart`、`notification_action_host.dart`；`ios/Runner/NotificationActionHostPlugin.swift` | projector/push tests；`notification_service_policy_test.dart`、`notification_action_host_test.dart`、`notification_approval_coordinator_test.dart` |
| P-015 | `features/background_sync/background_sync_coordinator.dart`、`background_notification_mode_controller.dart`；`ios/Runner/BackgroundSyncHostPlugin.swift`、`BackgroundLocationKeepAlivePlugin.swift` | 四份 `test/features/background_sync/*_test.dart` |
| P-016 | `features/permission_management/permission_host_service.dart`、`permission_management_screen.dart`；`ios/Runner/PermissionHostPlugin.swift` | permission host/screen tests、`permission_change_bridge_service_test.dart` |
| P-017 | `features/mobile_update/mobile_update_service.dart`、`mobile_update_gateway.dart`、`mobile_update_models.dart`；`services/app_update_service.dart`；`shorebird.yaml`；`macos/Runner/AppUpdater.swift` | mobile update service/screen tests、`app_update_service_test.dart` |
| P-018 | `services/voice_input_service.dart`、`hooks/use_voice_input.dart`、`settings/widgets/speech_locale_bottom_sheet.dart` | `hooks/use_voice_input_test.dart` |
| P-019 | `services/app_icon_service.dart`、`models/app_icon.dart`、`settings/widgets/app_icon_bottom_sheet.dart`；`ios/Runner/AppDelegate.swift` 与三组 appiconset | app icon settings/bottom-sheet tests |
| P-020 | `services/revenuecat_service.dart`、`features/settings/supporter_screen.dart`、`widgets/supporter_badge.dart` | RevenueCat、Supporter screen/badge tests |
| P-021 | `services/in_app_review_service.dart`、`features/settings/changelog_screen.dart`、`auth_help_screen.dart` 与 bundled help/licenses assets | in-app review、auth-help docs tests；网络 changelog 缺独立离线验收 |
| P-022 | `router/app_router.dart`、`app_router.gr.dart`、`features/claude_session/claude_session_screen.dart` 和现有 Bridge Claude handlers | 当前没有可替代 release inventory gate 的单一测试，故保留 EX-P022-01 |
| P-023 | `l10n/app_{en,zh,ja,ko}.arb` 与 generated localizations；当前无 Translation host | ARB consistency、high-exposure、Korean localization tests |
| P-024 | `features/mobile_host/mobile_host_service.dart`；`ios/Runner/MobileHostSnapshotPlugin.swift` 和各 typed plugin | `features/mobile_host/mobile_host_service_test.dart`；native epoch fault harness 尚缺 |
| P-025 | `widgets/third_party/astraeus/claude_range_slider_fire.dart`、`widgets/session_visual_status.dart`、`features/session_insights/state/session_insights_quota_cache.dart` | `codex_effort_motion_test.dart`、quota cache test；physical profile 尚未运行 |
| P-026 | `features/settings/cache_management_screen.dart`、`features/session_list/cache/session_catalog_cache_{repository,database}.dart`、file-transfer storage/checkpoints | cache-management/catalog repository/file-transfer tests；protected survival fault matrix 尚缺 |
