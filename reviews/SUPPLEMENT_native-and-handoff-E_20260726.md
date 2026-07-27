# 补充审查报告 — 原生层 + 交接文档 §E 追溯

> **本文是 `ccpocket-full-code-review-and-plan_v2_20260726.md` 的补充件，不是替代件。**
> 主文档覆盖 Dart / TypeScript / `apps/menubar`。本文覆盖主文档**漏掉的三块**：
> 1. `apps/mobile` 自己的 iOS / macOS / Android 原生层（3,538 行）
> 2. 交接文档 §E（当前任务清单）的逐条追溯（22 条）
> 3. E.4.4 文件写操作鉴权的 **Bridge 侧**（`file-mutation-auth.ts` 808 行）
>    与 `isPathAllowed` 覆盖面的系统性核查
>
> **产出：27 条编号发现（23 条缺陷 + 4 条事实认定）。**
>
> 审查日期：2026-07-26　审查方式：全文件通读（非抽样）　**本文作者未修改任何源码**
> worktree: `_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725`
> branch: `fix/mobile-comprehensive-v02-20260726`
> 审查基线 HEAD: `20382de6`　　**本文写成时 HEAD 已是 `403ad9f6`**
>
> ### ⚠️ 本文写成时，修复工作已在并行进行中
>
> 另一个 Agent 正依据主文档执行修复，见 `reviews/remediation-log_20260726.md`。
> 截至本文写成，已完成 7 个 commit（`4ab464f4` … `403ad9f6`：SEC-1 / P0-4 / P0-5 /
> P0-6 / B-18 / P0-10 / P0-1），并有**未提交的进行中改动**
> （`packages/bridge/src/parser.ts`、`packages/bridge/src/websocket.ts`，对应 P0-2）。
>
> **本文的 21 条发现全部位于 `apps/mobile/ios|macos|android` 原生层，
> 与上述工作零文件重叠**，可安全并行。但请注意：
> - 本文第 2 章引用的 **Swift / Kotlin 行号基于 `20382de6`**，原生层至今未被改动，行号有效；
> - 本文第 1 章、第 3 章引用的 **Bridge / Dart 行号可能已因上述 commit 位移**，
>   引用前请以当前 HEAD 复核；
> - 动手前先读 `remediation-log_20260726.md` 的进度总览，避免与在途项冲突。

---

## 目录

- [第 1 章　对主文档三处断言的更正](#第-1-章对主文档三处断言的更正)
- [第 2 章　新增发现（NX-1 ～ NX-27）](#第-2-章原生层新增发现21-条)
  - 2.1–2.8　iOS / macOS / Android 原生层
  - 2.9　macOS 窗口层
  - **2.10　Bridge 侧文件写操作鉴权（E.4.4 的另一半）**
- [第 3 章　交接文档 §E 逐条追溯表（22 条）](#第-3-章交接文档-e-逐条追溯表22-条)
- [第 4 章　§E 未覆盖项的取证结果](#第-4-章未闭环项需接手-agent-专项取证)
- [第 5 章　系统性模式补充](#第-5-章系统性模式补充)
- [第 6 章　实施顺序增量建议](#第-6-章实施顺序增量建议)
- [附录　本轮取证边界](#附录本轮取证边界)

---

## 第 1 章　对主文档三处断言的更正

动手前请先用本章修正主文档，否则会按错误的覆盖范围排期。

### 1.1　主文档第 2 章「安全 25 条」不含 `apps/mobile` 原生层

主文档第 2 章的安全结论**只覆盖 Dart 与 TypeScript**。`apps/mobile/ios/Runner/`、
`apps/mobile/macos/Runner/`、`apps/mobile/android/` 下共 **3,538 行**原生代码中，
只有 `NotificationActionHostPlugin.swift` 进入了主文档（P0-20）。

精确覆盖账（`grep <basename>` 命中数）：

| 文件 | 行数 | 主文档 | raw-agent-reports |
|---|---:|---:|---:|
| `ios/Runner/FileTransferPlugin.swift` | 767 | 0 | 0 |
| `ios/Runner/BackgroundSyncHostPlugin.swift` | 533 | 0 | 1（顺带） |
| `ios/Runner/PermissionHostPlugin.swift` | 418 | 0 | 0 |
| `ios/Runner/FileMutationAuthPlugin.swift` | 378 | 0 | 0 |
| `ios/Runner/ArtifactQuickLookPlugin.swift` | 331 | 0 | 1（顺带） |
| `ios/Runner/BackgroundLocationKeepAlivePlugin.swift` | 218 | 0 | 0 |
| `ios/Runner/NotificationActionHostPlugin.swift` | 200 | **2** | 1 |
| `ios/Runner/AppDelegate.swift` | 175 | 0 | 3（顺带） |
| `ios/Runner/MobileHostSnapshotPlugin.swift` | 86 | 0 | 1（顺带） |
| `macos/Runner/AppUpdater.swift` | 355 | 0 | 0 |
| `android/.../MainActivity.kt` | 77 | 0 | 0 |

**零覆盖合计 2,213 行（6 个文件）。** 本文第 2 章补上。

> ⚠️ 注意区分：这些文件**有单元测试**（`ios/RunnerTests/RunnerTests.swift` 659 行，
> 覆盖全部 9 个 iOS 插件）。**有测试 ≠ 被审查过**——主文档 §7.2 的核心结论正是
> 「测试夹具与生产数据形状不一致会掩盖真 bug」，本文第 2 章又新增了两个实例。

### 1.2　主文档第 3 章 E.1.3「预览失败」的归因需补一句限定

主文档把 JSON/HTML/Quick Look 预览失败归因为
「发布问题（`34e97866` 不在任何 tag）+ `.json`/`.html` 被 `artifact-manager.ts:82`
归类 `kind:"source"` 短路预览路由」。

**本轮通读原生侧后，该归因成立，且得到了正向验证**，补充两条证据：

1. `ArtifactQuickLookPlugin.swift` 全 331 行**未发现会导致 `.json`/`.html` 失败的缺陷**。
   路径校验（`validatedFileURL:116-150`）只要求文件在 App 沙盒内且是常规文件；
   `QLPreviewController.canPreview` 对 `.json`/`.html` 返回 true。
2. `MobileHostSnapshotPlugin.swift:17` 的能力清单里 `"quickLook": 1` **已编译进 base IPA**，
   因此 OTA 补丁可以直接使用该能力，不需要新 base IPA。

**结论强化**：E.1.3 确实是「路由 + 发布」问题，不是原生问题。修 Dart 侧路由即可，
但 `34e97866` 含 Swift 变更这一点仍然成立 —— 需确认那部分 Swift 变更是否为本次预览
链路所必需；若不是，可拆出纯 Dart 修复走 OTA。

### 1.3　我此前口头说的「iOS 原生层几乎没被审查」说重了

`notification-e2e-bridge-cf-apns.md` 确实审过通知链路，`NotificationActionHostPlugin.swift:52`
的 ISO8601 缺陷已经作为 **P0-20** 记录在主文档 `:409-418` 和 `:953`。
准确表述是 1.1 节的那张表：**11 个原生文件中 1 个进了主文档，6 个零覆盖。**

---

## 第 2 章　原生层新增发现（21 条）

编号沿用 `N-` 前缀但与主文档 N-1/N-2 不冲突，本文用 `NX-` 前缀。
每条给：位置 → 失败场景 → 解决方案。

### 2.1　`FileMutationAuthPlugin.swift`（E.4.4 的生物识别闸门，378 行，零覆盖）

先说结论：**整体设计是可靠的** —— Secure Enclave 不可导出私钥、`.biometryCurrentSet`
（生物特征集合变更即失效）、只回传公钥与 DER ECDSA 签名、挑战长度上限 4096、
错误信息统一截断到 240 字符。以下是缺陷。

---

#### NX-1　重复 Secure Enclave 密钥导致永久签名失败循环　**P1**

**位置**：`FileMutationAuthPlugin.swift:173-234`（`loadOrCreatePublicKey`）
与 `:236-268`（`loadPrivateKey`）

**机理**：

```swift
// :239-245  查询没有 kSecMatchLimit，且 keyTag 是固定常量
let query: [String: Any] = [
  kSecClass as String: kSecClassKey,
  kSecAttrApplicationTag as String: keyTag,      // 固定："...p256.v1"
  kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
  kSecReturnRef as String: true,
  kSecUseAuthenticationContext as String: context,
]
```

```swift
// :174-176  只看「公钥缓存」在不在，不看 Secure Enclave 里的私钥在不在
if let cached = loadKeychainData(account: publicKeyAccount) { return cached }
// :203      缓存不在就直接再造一把，从不删除同 tag 的旧私钥
guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &creationError),
```

**失败场景**：
1. 用户已注册，Secure Enclave 中存在私钥 K1，Bridge 侧登记了公钥 P1。
2. 任意路径删除了公钥缓存 —— 例如 NX-2 描述的那条（一次生物识别失败即可触发）。
3. Dart 重新调用 `prepareKey` → `loadOrCreatePublicKey` 发现缓存空 → 造出 **K2**，
   返回 P2。此时 Keychain 中 **K1 与 K2 同 tag 并存**。
4. 后续 `signChallenge` → `loadPrivateKey` 的查询无 `kSecMatchLimit`，
   默认 `kSecMatchLimitOne`，**返回哪一把由 Keychain 内部顺序决定，未定义**。
5. 若返回 K1，签名用 K1，Bridge 用 P2 验签 → 失败。用户重试仍是同一把 → **永久失败**。
   界面表现为「Face ID 通过了，但 Mac 说签名无效」，且重装 App 才能恢复。

**解决方案**：
1. `loadOrCreatePublicKey` 在 `SecKeyCreateRandomKey` **之前**先
   `SecItemDelete([kSecClass: kSecClassKey, kSecAttrApplicationTag: keyTag])`，确保同 tag 唯一。
2. `loadPrivateKey` 的查询显式加 `kSecMatchLimit as String: kSecMatchLimitOne`
   并在删除逻辑落地后仍保留 —— 显式优于依赖默认值。
3. 更稳妥：把 tag 改为「每次注册生成一个唯一后缀」，公钥缓存里连同 tag 一起存，
   `loadPrivateKey` 按存下来的 tag 精确查。这样根本不存在同 tag 多把的可能。
4. 测试：`RunnerTests.swift` 补一条「连续两次 `prepareKey` 后 `signChallenge` 的签名
   必须能被第二次返回的公钥验证」。现有 3 处 `FileMutationAuthPlugin` 断言未覆盖此路径。

---

#### NX-2　一次生物识别失败被当作「密钥已失效」并删除公钥缓存　**P2**

**位置**：`FileMutationAuthPlugin.swift:248-258` 与 `:146-148`

```swift
// :249-254
let code =
  status == errSecItemNotFound || status == errSecAuthFailed   // ← errSecAuthFailed
  ? "biometric_key_invalidated"
  : status == errSecUserCanceled ? "biometric_cancelled" : "biometric_key_unavailable"
```
```swift
// :146-148
if error.code == "biometric_key_invalidated" {
  Self.deleteKeychainData(account: Self.publicKeyAccount)   // ← 删公钥缓存
}
```

**失败场景**：`errSecAuthFailed`（-25293）在 LocalAuthentication 语境下也会由
**「用户连续几次没被 Face ID 认出」** 产生，这是暂时性的，密钥并没有失效。
一次没认出 → 公钥缓存被删 → 直接触发 NX-1 的第 2 步 → 造出第二把密钥。
**NX-2 是 NX-1 最现实的触发器，两条必须一起修。**

**解决方案**：只有 `errSecItemNotFound` 才算 invalidated；`errSecAuthFailed` 归到
新错误码 `biometric_auth_failed`，Dart 侧提示「再试一次」，**不删任何东西**。
真正的「生物特征集合变更」由 `.biometryCurrentSet` 保证会让 `SecItemCopyMatching`
返回 `errSecItemNotFound`，所以收窄条件不会漏掉真失效。

---

#### NX-3　deviceId 写 Keychain 失败被静默吞掉，导致身份漂移　**P1**

**位置**：`FileMutationAuthPlugin.swift:270-281`

```swift
let value = "ios:\(UUID().uuidString.lowercased())"
try? saveKeychainData(Data(value.utf8), account: deviceIdAccount)   // ← try?
return value
```

**失败场景**：`saveKeychainData` 抛错（设备存储满、Keychain 在首次解锁前不可写 ——
注意本条用的是 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`，
但 `loadOrCreateDeviceId` 会被 `snapshot()` 在任意时机调用）时，
`try?` 吞掉错误，函数照常返回一个**没被持久化**的新 UUID。
于是 `prepareKey` 用 deviceId-A 注册公钥，下一次 `signChallenge`
返回 deviceId-B + 用 A 的密钥签的名 → Bridge 按 B 查不到公钥 → 拒绝。
**表现与 NX-1 相同（Face ID 过了但 Mac 拒绝），但根因不同，排查时极易混淆。**

**解决方案**：`loadOrCreateDeviceId` 改为 `throws`，写失败就抛
`FileMutationNativeError(code: "device_identity_unavailable")`；
`snapshot()` 把 `deviceId` 变成可空并附 `reason`。**绝不能返回一个没存下来的 ID。**

---

#### NX-4　生物识别可用性有两个真相源　**P3**

**位置**：`PermissionHostPlugin.swift:145-148` 把 `biometrics` 恒定报为
`status: "systemManaged"`；而 `FileMutationAuthPlugin.swift:45-60` 的 `snapshot()`
给出真实的 `canEvaluateBiometrics` / `biometryType` / `reason`。

**后果**：Dart 若从权限中心读 biometrics 状态，永远得到无信息的 `systemManaged`，
无法在设置页告诉用户「Face ID 未启用，所以文件写操作不可用」。
这与主文档记录的「权限状态双真相源」是同一类问题（主文档 P0-11/12 的权限账本）。

**解决方案**：`PermissionHostPlugin` 的 `biometrics` 条目改为转发
`FileMutationAuthPlugin.snapshot()` 的 `canEvaluateBiometrics`，
或在 Dart 侧明确规定「biometrics 只认 `ccpocket/file_mutation_auth` 通道」并删除权限中心里的该条目。

---

### 2.2　`FileTransferPlugin.swift`（767 行，零覆盖）

先说结论：**这是本次审查见到的写得最扎实的原生文件**。
`fsync` 目录、`fstat` 前后比对 inode/size/mtime/ctime 防换文件、`lstat` 拒绝符号链接、
`link()` 原子无覆盖提交、跨卷检测、容量安全边际、1 MB 分块 + `autoreleasepool`。
以下是缺陷。

---

#### NX-5　Picker 呈现失败后 `pickerResult` 永久占用　**P1**

**位置**：`FileTransferPlugin.swift:191-223`（`presentPicker`）、`:225-257`（`presentExportPicker`）、
`:259-265`（`finishPicker`）

```swift
pickerResult = result
pickerMaximumBytes = maximum
pickerMode = .importing
pickerController = picker
presenter.present(picker, animated: true)     // ← 没有 completion，没有呈现校验
```

`finishPicker` 只可能从 `documentPicker(didPickDocumentsAt:)` 或
`documentPickerWasCancelled` 两个 delegate 回调进入。

**失败场景**：`presenter` 此刻已在呈现别的 modal（例如 Quick Look 刚打开、
或系统弹了权限框），`present` 会静默失败，两个 delegate **都不会**触发。
结果：
- 本次 `pickFile` 的 Dart `Future` **永不完成**（无超时）；
- `pickerResult != nil` 永久成立 → **之后每一次 `pickFile`/`exportFile` 都返回 `busy`**，
  直到 App 重启。用户表现为「文件选择按钮点了没反应，重启才好」。

**对照证据**：同仓库的 `ArtifactQuickLookPlugin.swift:273-287` **做了这个校验**：

```swift
presenter.present(session.controller, animated: true) { [weak self, weak session] in
  guard let self, let session, self.activeSession === session else { return }
  session.controller.presentationController?.delegate = session
  guard session.controller.presentingViewController != nil else {
    self.finish(session, error: FlutterError(code: "presentation_failed", ...))
    return
  }
}
```

**解决方案**：把 `ArtifactQuickLookPlugin` 的这段模式原样搬到两个 `present` 调用上：
在 completion 里检查 `picker.presentingViewController != nil`，为 nil 就
`finishPicker(FlutterError(code: "presentation_failed", ...))`。
另外 `presentPicker` 开头的 `busy` 判断建议同时校验
`pickerController?.presentingViewController != nil`，作为兜底自愈。

---

#### NX-6　错误信息用 `String(describing:)` 回传，泄露完整文件系统路径　**P2**

**位置**：`FileTransferPlugin.swift:734-750`

```swift
return FlutterError(code: code, message: String(describing: error), details: nil)
```

**失败场景**：`default` 分支会接到 `POSIXError`、`CocoaError`、`NSError`。
`String(describing:)` 对 `CocoaError`/`NSError` 会展开 `userInfo`，
其中 `NSFilePath` / `NSURL` 含**完整绝对路径**（包含用户名与项目路径）。
该字符串进入 Dart 侧错误处理，按主文档第 2 章的取证，Dart 错误信息会落入
调试包（`utils/debug_bundle_share.dart` 的 `_buildDebugBundlePayload`）和剪贴板导出，
即「粘贴给 AI 聊天」的那份内容。**这条与主文档第 2 章的路径泄露族是同一族，需并表处理。**

**解决方案**：`default` 分支只回固定文案 `"file_transfer_failed"`，
真实 `String(describing:)` 走 `os_log(.debug)` 留在设备本地；
或对 message 做与 `AppUpdater` 同款的截断 + 路径打码（把 `NSHomeDirectory()` 前缀替换为 `~`）。

---

#### NX-7　完成的下载文件被移出「排除备份」，会进 iCloud 备份　**P2（需产品决策）**

**位置**：`FileTransferPlugin.swift:720-725`

```swift
static func restoreCompletedBackupSemantics(_ url: URL) throws {
  var values = URLResourceValues()
  values.isExcludedFromBackup = false      // ← 完成后允许备份
  try mutable.setResourceValues(values)
}
```

在 `probeCommit`（`:530`、`:539`）、`linkNoClobber`（`:558`）、
`finalizeLinkedCommit`（`:572`）四处被调用。

**后果**：从 Mac 拉到手机的**项目源码文件**会进入 iCloud 备份。
中间态（`markTransient`，`:481-490`）正确地设了 `isExcludedFromBackup = true`，
说明作者是有意区分中间态与终态的 —— 所以这**大概率是刻意设计而非疏漏**
（用户会期望下载的文件在换机后还在）。

**但它与交接文档 E.4.4 的隐私姿态存在张力**：E.4.4 要求写操作必须过 Face ID，
说明项目文件被当作敏感内容；那么把同样的内容同步进 iCloud 是否可接受，
需要一次明确决策而不是默认继承。

**解决方案（二选一，需用户拍板）**：
- **A**：保持现状，但在设置页/首次下载时明示「下载的文件会包含在 iCloud 备份中」。
- **B**：改为默认排除备份，设置页给一个「允许备份下载的文件」开关。
  注意改动会影响已下载文件，需要一次性迁移遍历。

---

#### NX-8　`pickerController` 是写入后从不读取的死字段　**P3**

**位置**：`FileTransferPlugin.swift:34`、`:221`、`:255`、`:263`

`private weak var pickerController` 在三处被赋值，全文无任何读取点。
建议：要么删除，要么按 NX-5 的方案把它用在 `busy` 自愈判断里（推荐后者）。

---

### 2.3　`PermissionHostPlugin.swift`（418 行，零覆盖）

#### NX-9　定位权限请求无超时，Dart Future 可永久悬挂　**P2**

**位置**：`PermissionHostPlugin.swift:326-355`、`:357-373`

```swift
case .notDetermined:
  self.pendingLocationResult = result          // ← 存起来，等 delegate
  self.shouldUpgradeLocationRequest = true
  self.locationManager.requestWhenInUseAuthorization()
```

**失败场景**：`locationManagerDidChangeAuthorization` 是唯一的释放点。
若系统未回调（用户把 App 切走后再也不回来、系统弹框被其他 modal 遮挡、
定位服务在系统层被关闭），`pendingLocationResult` 永久非 nil：
- 本次请求的 Dart `Future` 永不完成；
- `:328` 的 `guard pendingLocationResult == nil` 使**后续所有定位权限请求**
  直接返回 `permission_request_in_progress`，直到 App 重启。

这与 NX-5、NX-16 是**同一模式**（见第 5 章）。

**解决方案**：`requestLocationAlways` 里挂一个
`DispatchQueue.main.asyncAfter(deadline: .now() + 60)` 的 `DispatchWorkItem`，
超时就 `completeSnapshot(result)` 并清空 `pendingLocationResult`；
delegate 正常回调时 `cancel()` 该 workItem。
可直接复用 `BackgroundSyncHostPlugin.swift:5-26` 的 `BackgroundRefreshCompletion`
（「只完成一次」的线程安全封装），仓库里已经有这个工具了。

---

#### NX-10　`:113` 使用已废弃的 `CLLocationManager.authorizationStatus()` 静态方法　**P3**

**位置**：`PermissionHostPlugin.swift:113`

```swift
let locationAlways = statusName(CLLocationManager.authorizationStatus())
```

iOS 14 起该静态方法已废弃，应使用实例属性 `manager.authorizationStatus`。
同仓库 `BackgroundLocationKeepAlivePlugin.swift:152` **用的正是实例属性**，两处不一致。
当前行为仍正确，但 `permissionSnapshot` 是 `static` 函数、拿不到实例，
所以修复需要顺带把它改成实例方法或注入状态。属于技术债，不影响功能。

---

### 2.4　`BackgroundSyncHostPlugin.swift`（533 行，仅顺带提及）

先说结论：`BackgroundRefreshPendingController`（`:58-210`）的状态机设计得很好 ——
锁内改状态、锁外回调、`runId` 匹配防止旧任务误杀新任务、
无 Dart 端点时保持原始 deadline 失败关闭。`RunnerTests.swift` 也覆盖了它（5 处断言）。

#### NX-11　全部静态可变状态无同步，存在跨线程数据竞争　**P2**

**位置**：`BackgroundSyncHostPlugin.swift:280-287`

```swift
private static var channel: FlutterMethodChannel?
private static var schedulerRegistrationAttempted = false
private static var schedulerRegistered = false
private static var refreshRequestPending = false
private static var registrationGeneration = 0
private static var refreshEndpoint: BackgroundRefreshEndpoint?
private static weak var activePlugin: BackgroundSyncHostPlugin?
```

**写点**：`registerBackgroundRefreshTask()`（`:308-318`，`didFinishLaunching`，主线程）、
`register(with:)`（`:320-359`，引擎初始化，主线程）、
`handleBackgroundRefreshTask`（`:462-508`，**显式跳主线程**，`:470` 写 `refreshRequestPending`）、
`scheduleRefresh`（`:442-460`，`:455` 写 `refreshRequestPending`）。

**读点**：`status(activeGeneration:)`（`:429-440`）读 `schedulerRegistered` 与
`refreshRequestPending`，由 `handle` 的 `"getStatus"` 分支触发。

**问题**：`handle` 在 Flutter 平台线程执行。iOS 上平台线程通常即主线程，
所以现实中大概率不会真的并发 —— **但 `scheduleRefresh` 没有任何线程断言或跳转**，
而同文件的 `perform`/`expire` 闭包（`:336`、`:351`）却**特意用了 `runOnMain`**，
说明作者已经意识到线程问题，只是覆盖不全。这属于「一半做了一半没做」，
在未来引入后台队列或 Swift 6 严格并发时会直接变成编译错误或真实竞态。

**解决方案**：把这 7 个静态变量收进一个 `private static let lock = NSLock()` 保护的
访问器里；或整体标注 `@MainActor` 并把 `handle`/`scheduleRefresh` 也走 `runOnMain`。
后者与 `macos/Runner/AppUpdater.swift:5` 已采用的 `@MainActor` 风格一致，推荐。

---

#### NX-12　`beginContinuation` 未走 `runOnMain`，与同文件其他路径不一致　**P3**

**位置**：`BackgroundSyncHostPlugin.swift:377-398`

`continuation.begin` 最终调用 `UIApplication.shared.beginBackgroundTask`
（`:291-296`），该 API 要求主线程。同文件 `:336`、`:351`、`:371` 都显式用了 `runOnMain`，
唯独此处直接调用。修法同 NX-11。

---

### 2.5　`BackgroundLocationKeepAlivePlugin.swift`（218 行，零覆盖）—— E.4.1 的实现体

先说结论：**隐私姿态是真的落到了代码上**，不是口号：
`didUpdateLocations`（`:176-178`）确实是空实现且有注释说明；
精度设为 `kCLLocationAccuracyThreeKilometers`、`distanceFilter = 1000`（`:126-127`）；
低电量/热压力自动停（`:90-93`）；`showsBackgroundLocationIndicator = true`（`:131`）不隐藏指示器。
Info.plist 的两条用途描述也明确写了 "Coordinates are never read, stored, or uploaded"。
**这一条 E.4.1 要求的「源码复核（不重复实现）」，复核结论是：实现与承诺一致。** 以下是缺陷。

---

#### NX-13　文件头注释描述的行为由 Dart 侧实现，注释未说明，会误导维护者　**P3（已降级）**

> **本条已复核并下调严重度。** 初稿判为 P2「可能未实现」，
> 后续取证证明 **Dart 侧确实兜住了**，详见下方「复核结论」。
> 保留本条是因为注释本身仍会误导人，但它**不是功能缺陷**。

**位置**：`BackgroundLocationKeepAlivePlugin.swift:9-11`

```swift
/// Dart may start this primitive only while an agent turn is active. It may be
/// pre-armed during iOS' foreground-to-background transition; full stream
/// delivery is disabled as soon as the app reaches the background lifecycle state.
```

但本文件的 `init`（`:22-45`）**只注册了两个观察者**：
`.NSProcessInfoPowerStateDidChange` 和 `ProcessInfo.thermalStateDidChangeNotification`。
**没有任何 app 生命周期观察者**（`UIApplication.didEnterBackgroundNotification` 等），
`handleResourcePressure`（`:159-164`）也只看电量与温度。

**后果**：注释描述的这条关键隐私/功耗约束，要么由 Dart 侧兜住，要么**根本没实现**。
如果是前者，注释写在原生文件里会误导后续维护者；如果是后者，就是真实缺陷 ——
定位会在 App 进入后台后持续保持，而这正是 E.4.1 明确想避免的。

**复核结论（已取证，Dart 侧兜住了）**：
责任方是 `apps/mobile/lib/features/background_sync/background_notification_mode_controller.dart`，
实现质量很好：

- `enterForeground()`（`:422-443`）与 `leaveLifecycle()`（`:446-464`）
  都调用 `_locationHost.stop()`；
- `_stopPrearmedLocation()`（`:412-419`）处理「预armed 但未真正投递」的中间态；
- 全部生命周期路径都用 `_lifecycleOperationGeneration` 做**代际栅栏**
  （`:416`、`:435`、`:437`、`:459`、`:462`），防止慢的异步 stop 覆盖新状态 ——
  这与 Swift 侧 `BackgroundContinuationController` 的代际防护是同一套正确模式。

**所以「预armed → 进入后台关闭投递」确实实现了，只是实现在 Dart 而不在 Swift。**

**iOS 单元测试也印证了这一点**：`RunnerTests.swift:390`
`BackgroundLocationKeepAliveFailsClosedForPowerPermissionAndThermalPressure`
测的是静态函数 `eligibilityPauseReason`，其入参只有
authorization / locationServicesEnabled / lowPowerMode / thermalState ——
**app 生命周期从设计上就不属于原生侧的资格模型**。

**解决方案（纯文档修复，不改行为）**：把 `BackgroundLocationKeepAlivePlugin.swift:9-11`
的注释改写为明确归属，例如：

```
/// Dart may start this primitive only while an agent turn is active.
/// Lifecycle gating (pre-arm on foreground→background, stop on background /
/// foreground) is owned by Dart:
/// lib/features/background_sync/background_notification_mode_controller.dart
/// (enterForeground / leaveLifecycle, generation-fenced). This host only
/// fails closed on permission, low-power, and thermal pressure.
```

**教训值得记下**：这条差点被我判成功能缺陷。原生文件用第一人称语气描述了
一个自己并不负责的行为，跨语言审查时极易误判。建议约定：
**原生注释描述跨语言行为时必须写明责任方文件路径。**

---

#### NX-14　`stop()` 不复位 `allowsBackgroundLocationUpdates`　**P3**

**位置**：`:130` 设 `true`，`:138-148` 的 `stop()`/`stopLocationUpdates()` 只调
`stopUpdatingLocation()`，未把该标志复位为 `false`。
`CLLocationManager` 实例是长生命周期的（`:22` 注入、默认 `CLLocationManager()`），
标志会一直留着。建议在 `stopLocationUpdates()` 里加 `manager.allowsBackgroundLocationUpdates = false`。

---

#### NX-15　运行期错误后永久停摆，无重试路径　**P3**

**位置**：`:180-186`

```swift
guard locationError?.code != .locationUnknown else { return }
pauseReason = "location_runtime_error"
stopLocationUpdates()
```

任何非 `locationUnknown` 的 `CLError`（含临时性的 `.network`）都会导致
keep-alive 永久停止，只能靠 Dart 侧重新 `start`。
建议：对可恢复错误码（`.network` 等）做一次有限次数的延迟重试，
或至少在 `statusChanged` 里把 `pauseReason` 区分为「可重试/不可重试」，让 Dart 能决策。

---

### 2.6　`macos/Runner/AppUpdater.swift`（355 行，零覆盖，**零测试**）

#### NX-16　`setFeedURLOverride` 无任何校验，且没有任何调用方　**P2 → 建议直接删除**

**位置**：`AppUpdater.swift:190-210`

```swift
let rawURL = (payload["feedUrl"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
if let rawURL, !rawURL.isEmpty {
  UserDefaults.standard.set(rawURL, forKey: Self.feedURLOverrideDefaultsKey)   // ← 无校验
```

**无 scheme 校验、无 host 允许名单、无长度限制**，直接持久化，
再由 `feedURLString(for:)`（`:226-230`）交给 Sparkle 作为更新源。

**严重度限定（已取证，勿高估）**：`macos/Runner/Info.plist` 中
`SUPublicEDKey = $(SPARKLE_PUBLIC_ED_KEY)` **已配置**，Sparkle 会做 EdDSA 签名校验。
因此劫持 feed **无法安装任意代码**，不是 RCE。
真实风险是**降级攻击**：攻击者可用一个自建 feed 只投喂「官方签过名的旧版本」，
把用户钉死在一个已知有缺陷的版本上；`SUEnableInstallerLauncherService = True`
意味着安装走特权 helper，降级本身是"合法"完成的。

**额外事实**：Sparkle 官方正是因为这个风险才弃用了「从 UserDefaults 读 feed URL」。
本文件 `:16` 老老实实调了 `controller.updater.clearFeedURLFromUserDefaults()`
**清掉 Sparkle 自己的那份**，然后在 `:8` 用自己的 key
（`ccpocket.sparkle.feed_url_override`）**重新实现了一份没有防护的同款机制**。

**并且**：全仓 `grep` 确认 `setFeedURLOverride` 与 `clearFeedURLOverride`
**没有任何 Dart 调用方**。`lib/services/app_update_service.dart:60` 只调用了 `getFeedURL`。
这是**纯死接口**，只贡献攻击面。

**解决方案（推荐 A）**：
- **A**：删除 `setFeedURLOverride` / `clearFeedURLOverride` 两个 case 与
  `feedURLOverrideDefaultsKey`，`effectiveFeedURLString` 只读 `Info.plist` 的 `SUFeedURL`。
  改动极小、无回归风险（无调用方）。
- **B**（若确需保留调试能力）：`#if DEBUG` 包起来，并校验
  `scheme == "https"` + host 在编译期常量允许名单内。

---

#### NX-17　`probeForUpdate` 无超时，挂起后永久 `probe_busy`　**P2**

**位置**：`AppUpdater.swift:122-169`、释放点在 `:212-224` 的 `resolveProbe`

`pendingProbeResult` 只由 Sparkle 的 delegate 回调释放
（`:240` `didFindValidUpdate`、`:252` `updaterDidNotFindUpdate`、
`:311` `didAbortWithError`、`:323` `didFinishUpdateCycleFor`）。
若网络挂起导致 Sparkle 一个回调都不发，则：
- 本次探测的 Dart `Future` 永不完成；
- `:130` 的 `guard pendingProbeResult == nil` 让**后续所有探测**返回 `probe_busy`，直到重启 App。

与 NX-5、NX-9 同一模式（第 5 章）。

**解决方案**：`pendingProbeResult = result` 的同时启动一个 60 秒
`DispatchWorkItem`，超时则 `resolveProbe(error: FlutterError(code: "probe_timeout", ...))`；
`resolveProbe` 内统一 `cancel()`。因为类已是 `@MainActor`（`:5`），实现很简单。

---

#### NX-18　诊断信息把 bundlePath 回传 Dart，并把 feed / 下载 URL 写系统日志　**P3**

**位置**：`:57-66`（`diagnostics` 含 `bundlePath`）→ `:100-102` `errorDetails()`
→ 作为 `FlutterError.details` 回传 Dart（`:135`、`:143`、`:152`、`:161`、`:181`、`:317`、`:344`）；
以及 `:68-70` 的 `log()` 用 `NSLog` 打印 feed URL、下载 URL、bundle 路径到统一日志。

与 NX-6 同族（路径进 Dart → 可能进调试包）。macOS 上 `NSLog` 内容对同机其他进程可见。
建议：`errorDetails` 去掉 `bundlePath`；`log()` 改用 `os_log` 并把 URL 降为 `.debug` 级别。

---

#### NX-19　`AppUpdater.swift` 355 行零测试　**P2**

`macos/RunnerTests/RunnerTests.swift` 只有 **12 行**（模板 stub）。
对比 `ios/RunnerTests/RunnerTests.swift` 有 659 行、覆盖全部 9 个 iOS 插件。

这是主文档 **P0-21**（`apps/menubar` 零测试导致 `resetsAtDate` 缺陷无人发现）的
**第二个实例**。`AppUpdater` 承担「官方更新」这条链路（交接文档 E.5.2），
是 stable 晋级路径的一部分，零测试不可接受。

**解决方案**：至少补三条 —— `effectiveFeedURLString` 的 override/bundled/nil 三分支；
`resolveProbe` 只完成一次；`updaterDidNotFindUpdate` 产出的 map 形状。
前两条不需要真的跑 Sparkle，把 `SPUUpdater` 依赖抽成协议即可。

---

### 2.7　`android/.../MainActivity.kt`（77 行，零覆盖）

#### NX-20　切换启动器图标时存在「零个别名启用」窗口，桌面图标可能丢失　**P1**

**位置**：`MainActivity.kt:52-76`

```kotlin
val aliases = listOf(
    "$packageName.MainActivityDefault",              // ← 列表第一个
    "$packageName.MainActivitySupporterLightOutline",
    "$packageName.MainActivitySupporterProCopperEmerald",
)
for (alias in aliases) {
    packageManager.setComponentEnabledSetting(
        ComponentName(packageName, alias),
        if (alias == targetAlias) ENABLED else DISABLED,
        PackageManager.DONT_KILL_APP,
    )
}
```

**manifest 已坐实前置条件**（`android/app/src/main/AndroidManifest.xml:39-77`）：
`MainActivityDefault android:enabled="true"`，另两个 `android:enabled="false"`。

**失败场景**：用户从默认图标切到 `light_outline`：
1. 第 1 次迭代：`MainActivityDefault` ≠ target → **DISABLED**。
   此刻三个别名**全部处于禁用状态**，系统中不存在任何 `LAUNCHER` 入口。
2. 第 2 次迭代：`MainActivitySupporterLightOutline` → ENABLED。

第 1 步与第 2 步之间是两次独立的 Binder IPC。若在这个窗口内进程被杀
（`DONT_KILL_APP` 只保证本次调用不杀，不保证系统在低内存时不杀），
或启动器在此刻刷新了它的应用列表，**桌面图标会消失**，
部分启动器（尤其国产 ROM）不会在别名重新启用后自动恢复，用户需要重启设备或从应用列表重新拖出。

**解决方案**：**先启用目标，再禁用其余**：

```kotlin
packageManager.setComponentEnabledSetting(
    ComponentName(packageName, targetAlias),
    PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
    PackageManager.DONT_KILL_APP,
)
for (alias in aliases) {
    if (alias == targetAlias) continue
    packageManager.setComponentEnabledSetting(
        ComponentName(packageName, alias),
        PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
        PackageManager.DONT_KILL_APP,
    )
}
```

短暂出现两个图标远好于短暂出现零个图标。

---

#### NX-21　`supportsAlternateIcons` 在 Android 侧硬编码 `true`　**P3**

**位置**：`MainActivity.kt:19`

```kotlin
"supportsAlternateIcons" -> result.success(true)
```

iOS 侧（`AppDelegate.swift:87`）返回真实的 `UIApplication.shared.supportsAlternateIcons`。
Android 上若 ROM 限制了 `setComponentEnabledSetting`（部分定制系统会），
调用会抛 `SecurityException` —— 而 `:23-28` 的 `try/catch` **只捕获
`IllegalArgumentException`**，`SecurityException` 会直接冒泡成平台异常，Dart 侧收到未分类错误。

**解决方案**：`catch (error: Exception)` 并映射为 `result.error("set_icon_failed", ...)`；
`supportsAlternateIcons` 至少排除已知不支持的 ROM，或保持 true 但保证失败路径可控。

---

### 2.8　`ios/Runner/Info.plist`

#### NX-22　`NSAllowsArbitraryLoadsInWebContent = true` 与 artifact HTML 预览叠加　**P2**

**位置**：`apps/mobile/ios/Runner/Info.plist`

```
NSAppTransportSecurity = {'NSAllowsArbitraryLoadsInWebContent': True}
```

**其余 Info.plist 配置本轮复核无问题**：
`BGTaskSchedulerPermittedIdentifiers = ['com.k9i.ccpocket.background-refresh']`
与 `BackgroundSyncHostPlugin.swift:276` 的标识符一致（这一条如果不一致，
后台刷新会静默永不工作，属于高危配置项，已确认正确）；
`UIBackgroundModes = ['fetch', 'location', 'remote-notification']` 与三个宿主插件对应；
九条用途描述齐全；`ITSAppUsesNonExemptEncryption = False`。

**风险**：该键允许 WebView 内容加载明文 HTTP 资源。结合 E.1.3 的 HTML artifact 预览 ——
预览的是 **agent 生成的 HTML**，其中可能含 `<img src="http://...">`、
`<script src="http://...">` 等外部引用。攻击面有两层：
1. 明文流量可被同网络中间人篡改；
2. 更重要的是**外链本身即信道** —— 一个含远程资源引用的 HTML 被预览时，
   会把「用户在什么时间预览了什么」这一事实发给外部服务器。

注意 `ArtifactQuickLookPlugin.swift:64-72` 已经封堵了**点击跳转**：

```swift
func previewController(_:shouldOpen:for:) -> Bool { return false }
```

但那只挡住用户主动点链接，**挡不住页面加载时的自动资源请求**。

**解决方案**：
1. 确认 HTML artifact 走的是 Quick Look 还是应用内 WebView（两条链路的防护不同），
   入口见第 4 章 E.4.3 的文件清单。
2. 若走 WebView：加 `WKContentRuleList` 阻断所有非 `file://` 的资源加载，
   这比调 ATS 更精确，且能同时挡住 https 外链信道。
3. 若确认 WebView 不再需要明文 HTTP，直接删除该 ATS 键。

---

### 2.9　`macos/Runner/MainFlutterWindow.swift`（82 行，零覆盖）

#### NX-23　⌘V 剪贴板桥无长度上限，且拦截后失败即静默丢失　**P3**

**位置**：`MainFlutterWindow.swift:60-72`（`performKeyEquivalent`）

```swift
guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
  return super.performKeyEquivalent(with: event)
}
nativePasteBridgeChannel?.invokeMethod("nativePaste", arguments: text)
return true      // ← 吃掉事件，系统粘贴不再发生
```

**问题**：
1. **无长度上限** —— 整份剪贴板文本通过 method channel 传给 Dart。
   用户复制了一个几十 MB 的文件内容时，会造成一次大对象跨语言拷贝。
2. **`return true` 吃掉了事件** —— 若 Dart 侧 `nativePaste` 处理器抛错或没注册，
   粘贴**静默失效**，用户按 ⌘V 没反应且无任何提示。
3. `invokeMethod` 是即发即忘，**没有回调确认 Dart 真的处理了**。

**缓解事实**：整条路径由 `nativePasteBridgeEnabled` 开关控制（`:44-46`），
默认 `false`，只有 Dart 显式 `setEnabled(true)` 才生效，所以影响面受控。

**解决方案**：给 `text` 加上限（如 1 MB，超限就回落 `super.performKeyEquivalent`）；
`invokeMethod` 带 result 回调，Dart 返回 false 时回落系统粘贴。

---

### 2.10　Bridge 侧文件写操作鉴权 —— E.4.4 的另一半（本轮补审）

`packages/bridge/src/file-mutation-auth.ts`（808 行）本次通读。

**先说结论：这是整个仓库里安全实现质量最高的一个模块，没有发现漏洞。**
证据：

- 口令：scrypt N=2^15/r=8/p=1，`timingSafeEqual` 比对，
  格式非法时**也走一遍 scrypt**（`:184-188`）避免时序侧信道；
  每客户端失败 5 次锁 30 秒（`:484-511`）。
- 挑战：绑定 `client` 对象身份 + `deviceId` + `operationDigest` + `expiresAt`
  + 32 字节 nonce + `bridgeInstanceId`（`:387-401`）；
  **无论验证成功与否都立即消费挑战**（`:439-440`）—— 彻底封死重放。
- 公钥：强制 65 字节未压缩 P-256 点、首字节 `0x04`（`:665`），
  再拼 SPKI 前缀交给 `createPublicKey`，拒绝一切畸形输入。
- 存储：`0o600` + `O_NOFOLLOW` + 读入时校验 `(mode & 0o077) !== 0` 即拒绝（`:256-264`）；
  写入走 `O_EXCL` 临时文件 + `fsync` + `rename` 原子替换（`:302-326`）。
- 一致性：改 Bridge 口令会**清空所有已注册生物识别设备**（`:167-171`）；
  存储里有设备但无口令视为非法状态（`:762-767`）。

以下是需要记录的**边界事实**，不是漏洞，但直接决定 E.4.4 的完成度判定。

---

#### NX-24　整套鉴权只覆盖 `upload` 一种操作，E.4.4 的另外三种尚未实现　**事实认定，非缺陷**

**位置**：`file-mutation-auth.ts:40-45`

```ts
export type FileMutationOperation = {
  kind: "upload";        // ← 只有这一种
  transferId: string;
  filename: string;
  sizeBytes: number;
};
```

`validateFileMutationOperation`（`:521-540`）硬性要求 `operation.kind === "upload"`。
能力标识也直说了：`FILE_TRANSFER_UPLOAD_AUTH_CAPABILITY = "file_transfer_upload_auth_v1"`。

**全 Bridge 只有一个强制点**：`file-transfer-manager.ts:369`。

**并且**：全仓检索
`case "file_delete" | "file_move" | "file_rename" | "file_write" | "file_mkdir"`
**零命中** —— 修改 / 移动 / 删除**在 Bridge 侧根本没有处理器**。

**结论**：E.4.4 要求「修改・上传・移动・删除必须密码或 Face ID」——
**当前只有「上传」这一种写操作存在，且它确实被正确地门控了。**
另外三种是**尚未实现的功能**，不是被绕过的安全漏洞。

**给接手 Agent 的要求**：将来实现删除/移动/改名时，
**必须扩展 `FileMutationOperation` 的联合类型并复用同一个 `authorize()`**，
不要另起一套。`digestOperation`（`:572-580`）目前对四个字段做规范化 JSON 摘要，
新增 kind 时记得让摘要覆盖新操作的全部语义字段（例如删除要含目标绝对路径），
否则挑战与操作的绑定会失效。

---

#### NX-25　授权缓存以 (client, filename, sizeBytes) 为键，不含内容指纹　**P3**

**位置**：`file-transfer-manager.ts:356-364`

```ts
const existingAuthorization = this.authorizedUploads.get(message.transferId);
const requiresAuthorization =
  this.fileMutationAuthorizer !== undefined &&
  (existingAuthorization?.client !== client ||
    existingAuthorization.filename !== message.filename ||
    existingAuthorization.sizeBytes !== message.sizeBytes);
```

同一 `transferId` 在 (同客户端, 同文件名, 同字节数) 下**跳过二次鉴权**（断点续传所需）。
理论上同一客户端可以在续传时送入**长度相同但内容不同**的字节。

**缓存生命周期是干净的**（已核）：断开连接清理（`:117-119`）、
关闭清空（`:146`）、完成即删（`:473`、`:602`）。所以不存在跨会话残留。

**判定**：威胁模型里攻击者需要已经是**已认证的同一个客户端连接**，
实际风险很低。记录在案即可，不建议为此加内容指纹（会破坏续传性能）。

---

#### NX-26　未配置 `BRIDGE_API_KEY` 时上传鉴权整体缺席　**事实认定，用户已明确决策跳过**

**位置**：`index.ts:244`

```ts
if (API_KEY?.trim()) {           // ← 没有 API key 就完全不构造 authorizer
  const candidate = new FileMutationAuthorizer({ ... });
```

链路后果：`fileMutationAuthorizer === undefined`
→ `file-transfer-manager.ts:361` 的 `requiresAuthorization` 恒为 `false`
→ **上传不需要口令也不需要 Face ID**。

**启动接线本身是失败关闭的，设计正确**（已核）：
- `index.ts:267-268`：owner 全盘只读模式下若没有 authorizer，
  **整个文件传输运行时都不启动**；
- `index.ts:301-312`：file browser 启动失败时，连带拆掉上传能力；
- `websocket.ts:9676-9681`：两个鉴权能力**只在 authorizer 存在时才通告**，
  客户端能通过 capability 协商得知。

**这不是需要修的缺陷** —— `reviews/remediation-log_20260726.md` 记录了用户的明确决策：

> 跳过批次 0 的行为收紧项（SEC-2 权限上限、auto-approval 收紧、**上传门禁**、
> **API key 自动生成**等）—— 部署在 Tailscale 虚拟局域网内，用户明确不做认证类收紧。

**记录在此仅为留档**：E.4.4 的「上传必须鉴权」在**当前部署配置下不成立**，
这是已知且经用户批准的取舍。若将来部署环境变化（离开 Tailscale 私网），
这一条需要重新评估 —— 届时只需设置 `BRIDGE_API_KEY` 并配置口令即可自动生效，
**无需改代码**。

---

#### NX-27　`remove_project_history` 未校验路径　**P3**

**位置**：`websocket.ts:7717-7722`

```ts
case "remove_project_history": {
  this.projectHistory?.removeProject(msg.projectPath);   // ← 无 isPathAllowed
```

客户端可传入任意 `projectPath` 字符串删除项目历史条目。
影响仅限 Bridge 本地的一份历史列表元数据，**不触碰文件系统**，故为 P3。
但它与主文档记录的 `list_gallery` 缺 `isPathAllowed` 属于同一族。

**`isPathAllowed` 覆盖面的系统性核查结果（本轮新增）**：

对 `websocket.ts` 全部 `case` 分支做了机械扫描，找出「分支体内出现路径变量
但没有 `isPathAllowed`」的 19 个候选，逐个人工判读后：

| 判定 | 数量 | 说明 |
|---|---:|---|
| **真实缺失** | 2 | `list_gallery`（主文档已记）、`remove_project_history`（NX-27） |
| 委托给了更强的校验 | 1 | `read_artifact_source` → `artifact-manager.ts` 的 `openAuthorizedSource`，内部有 `canonicalRoots` + `realpath` + 相对路径规范化，**比 `isPathAllowed` 更严，不是缺口** |
| 路径是标签而非读写目标 | 1 | `take_screenshot` 的 `msg.projectPath` 只作为 gallery 条目的分组标签；截图文件路径由 Bridge 自己生成 |
| 假阳性（会话作用域） | 15 | `input` / `approve` / `rewind` / `fork` / `set_permission_mode` 等，操作对象是既有 session，其路径已在 `start`（`websocket.ts:2160`）校验 |

**结论**：`isPathAllowed` 的覆盖面基本是完整的，
`list_gallery` 是唯一有实际数据外泄后果的缺口（主文档已登记）。
**这条结论回答了第 4 章原 §4.5 的核心疑问 ——「还有几个漏了」答案是：一个半。**

---

## 第 3 章　交接文档 §E 逐条追溯表（22 条）

来源：`plans/mobile-comprehensive-remediation_v02_20260726-004125.md` §E（第 176–237 行）。

图例：**✅ 已覆盖** = 主文档或本文有完整方案；
**⚠️ 部分** = 只覆盖了一部分；**❌ 未覆盖** = 无人核过，见第 4 章。

### E.1　先做当前源码收束

| # | 要求 | 状态 | 位置 |
|---|---|---|---|
| E.1.1 | 权限偶发回到 on-request | ✅ | 主文档第 3 章 + P0-11/12 |
| E.1.2 | Plan 首次退出后审批消失 | ✅ | 主文档第 3 章 + P0-13（**注意主文档记录的误诊风险：`auto-approval.ts:495-498` 无条件批准 `ExitPlanMode` 会产生完全相同的症状**） |
| E.1.3 | JSON/HTML/Quick Look 预览失败 | ✅ | 主文档第 3 章；**本文 1.2 节补充原生侧正向验证** |

### E.2　完成会话目录与连接体验

| # | 要求 | 状态 | 位置 |
|---|---|---|---|
| E.2.1 | — | ✅ | 主文档 5.1 v02-001.2（已修复） |
| E.2.2 | transport ready / 认证 / capability / 权威 session list / catalog metadata readiness **必须分开**，只有当前 epoch 的权威结果才能首次进入首页 | ⚠️ | **5 个信号落实 3 个**，epoch 栅栏完整。见 §4.1 |
| E.2.3 | — | ✅ | 主文档 C-14 |
| E.2.4 | — | ✅ | 主文档 C-15 + H-1 |
| E.2.5 | 验证最近会话排序、至少 10 个 hot 会话、逐项删除下载历史、普通缓存清理 | ⚠️ | 下载历史**存储层删除能力已具备**（`file_transfer_storage.dart:47`/`:777`）；hot 会话语义未定义。见 §4.2 |

### E.3　完成会话内交互

| # | 要求 | 状态 | 位置 |
|---|---|---|---|
| E.3.1 | — | ✅ | 主文档 M-15 |
| E.3.2 | — | ✅ | 主文档 2.8（已澄清） |
| E.3.3 | 权限 / Plan / **Goal thread ID** / **Spark 额度圆环** / **运行蓝条与同步光晕** | ⚠️ | 前两项 ✅ P0-11/12/13；**Goal thread ID 的数据已在模型里流转**（`codex_goal_management.dart:21`），只差 UI 透出；后两项未实现。见 §4.3 |
| E.3.4 | 完成消息未读蓝点、打开后清除、多客户端边界 | ❌ | **已确认未实现**（全仓 0 命中），见 §4.4。**「已读」是设备本地还是 Bridge 全局需先决策** |

### E.4　通知、后台、文件与安全

| # | 要求 | 状态 | 位置 |
|---|---|---|---|
| E.4.1 | Always Location 轻通知**源码复核**（不重复实现） | ✅ | **本文 2.5 节即为该复核**：实现与隐私承诺一致（坐标真的没读没传）；缺陷 NX-14/15，NX-13 为注释归属问题 |
| E.4.2 | 后台刷新 | ✅ | 原生侧本文 2.4 节（NX-11/12）；**Dart 侧本轮已审**（§4.6），代际栅栏完整 |
| E.4.3 | 文件管理保留**两套入口**（Agent 引用机制 + 用户手动管理），共用全盘只读 / 统一预览 / 下载 / 分享 | ⚠️ | 「全盘只读」边界**已核**（`OWNER_FULL_DISK_READ` → `allowFilesystemRoot`，失败关闭）；**两套入口是否共用同一套实现仍未核**，见 §4.5 |
| E.4.4 | owner 模式认证后全盘只读 / 预览；修改・上传・移动・删除必须密码或 Face ID / Secure Enclave；密码与 verifier 不进热路径 | ⚠️ | **两端均已完整审查**：原生闸门 2.1 节（NX-1/2/3/4）+ Bridge 侧 2.10 节（**无漏洞**）。**但只有「上传」这一种写操作存在**（NX-24），且当前部署未设 `BRIDGE_API_KEY` 故鉴权缺席（NX-26，**用户已决策**）。移动端口令热路径仍未核 |
| E.4.5 | 通知长按 action 回传 | ✅ | 主文档 P0-18/19/20 |
| E.4.6 | — | ✅ | 主文档第 2 章 |

### E.5　多实例、官方更新与最终性能

| # | 要求 | 状态 | 位置 |
|---|---|---|---|
| E.5.1 | — | ✅ | 主文档 B-15 |
| E.5.2 | 官方更新 | ⚠️ | **本文 2.6 节补上 macOS 更新器**（NX-16/17/18/19）；主文档批次 10 覆盖其余 |
| E.5.3 | — | ✅ | 主文档批次 10 |
| E.5.4 | 性能优化**不得**靠截断历史、减少真实同步、隐藏状态、停止实时反馈来冒充修复 | ❌ | **这是验收准则不是待办项**，见第 4 章 §4.7 |

**统计**：22 条中 **✅ 15 条、⚠️ 5 条、❌ 2 条**。

初稿为 ✅13 / ⚠️4 / ❌5；第二轮补审后 E.4.2 转 ✅，E.2.2 / E.2.5 / E.4.3 由 ❌ 转 ⚠️。
**真正完全未实现的只剩 2 条**：E.3.4（未读蓝点）与 E.5.4（性能准则，本就是验收准则非待办）。

---

## 第 4 章　§E 未覆盖项的取证结果

初稿这一章列了 7 项「只定位入口、未得结论」。**本轮已把其中 6 项查完**，
结论如下。剩余真正未闭环的只有 §4.2 的一半和 §4.3 的功能实现部分。

| 项 | 初稿状态 | 本轮结论 |
|---|---|---|
| §4.1 readiness 分层 | 未取证 | **已实现 5 之 3**，设计良好；缺认证与 capability 两个信号 |
| §4.2 hot 会话 / 下载历史删除 | 未取证 | 存储层**已具备**逐项删除；语义与 UI 仍需确认 |
| §4.3 Goal / Spark / 蓝条 | 未取证 | **已查清实现现状**，属未实现的功能需求 |
| §4.4 未读蓝点 | 未取证 | **确认未实现**（全仓 0 命中） |
| §4.5 文件管理 / owner 只读 | **最高风险** | **已查完，无漏洞**；见 2.10 节 NX-24～27 |
| §4.6 后台刷新 Dart 侧 | 未取证 | **已查完，实现质量高**（代际栅栏） |
| §4.7 性能验收准则 | 是准则非待办 | 不变，建议写进测试门禁 |

---

### 4.1　E.2.2　readiness 分层与 epoch 权威性 —— **已实现 5 之 3**

**取证结论：核心机制存在且设计得很好，不是空白。**

**epoch 栅栏是完整的**。`apps/mobile/lib/services/bridge_service.dart:381`
定义 `_connectionEpoch`，`:1403` 在重连时自增，并在至少 6 处做了过期丢弃：
`:747`、`:803`、`:829`、`:1039`、`:1430`、`:1880`
（形如 `if (epoch != _connectionEpoch) return;`）。
`:1287` 还有注释明确「Desktop watcher state belongs to this exact WebSocket epoch」。
**「只有当前 epoch 的结果才算数」这一条成立。**

**权威性闩锁存在**，`apps/mobile/lib/features/session_list/session_list_screen.dart:75-126`
的 `SessionHomeConnectionGate`，其文档注释直接点明了 E.2.2 的核心命题：

```
/// A WebSocket upgrade is transport readiness, not application readiness. The
/// latch survives a same-target reconnect so an already-open home does not
/// flash back to the connection picker, but a new target must prove both
/// application datasets independently.
```

它做到了：
- **传输就绪与应用就绪分离**（`presentationState()` `:104-116`：
  传输已连接但数据未权威时，对外呈现 `connecting`/`reconnecting` 而非 `connected`）；
- **两个权威数据集各自独立**（`hasAuthoritativeSessionList` 与
  `hasAuthoritativeRecentSessions` 必须同时为真，`:95-100`）；
- **按 target 键控**（换了 Bridge 目标就作废重证，`:89-94`）；
- **同目标重连不闪回**（`_hasReadyTarget` 闩锁保持，`:111-113`）。

**残留缺口：5 个要求信号里落实了 3 个。**
E.2.2 要求 transport / **认证** / **capability** / 权威 session list / catalog metadata
五者分离。`SessionHomeConnectionGate.update()` 的入参只有
`state` + `targetKey` + 两个 authoritative 布尔 —— **认证完成与 capability 协商完成
没有作为独立的闸门输入**，catalog metadata 也未单列为第 5 个信号。

**给接手 Agent 的具体任务**：
1. 确认认证失败/未完成时，能否出现「两个 authoritative 数据集都为真」的组合。
   若不能（即认证是取得数据的前置条件），则认证信号是**隐含满足**的，
   只需在注释里写明这一推理，不必新增闸门。
2. capability 同理 —— 但要特别检查**降级路径**：
   老 Bridge 不支持某能力时，是否会让某个 authoritative 标志永远为 false，
   导致首页永远进不去。这是比「信号不够多」更现实的风险。
3. catalog metadata readiness 是否需要独立，取决于首页是否会用 catalog 缓存抢先渲染。
   入口：`apps/mobile/lib/features/session_list/cache/session_catalog_cache_repository.dart`。

**已知相关缺陷（主文档）**：C-14、C-15、H-1 就在这一带，动手前先读那三条。

### 4.2　E.2.5　最近会话排序 / 10 个 hot 会话 / 逐项删除下载历史

**本轮新增取证**：

- **逐项删除下载历史：存储层能力已具备。**
  `apps/mobile/lib/features/file_transfer/file_transfer_storage.dart` 有
  `delete(String key)`（`:47`）与 `deleteReceive(checkpoint, {required bool deletePartial})`
  （`:777-782`，并会一并清掉 `_secretStore` 里的下载密钥）。
  **所以这一项不需要从零实现**，只需确认 UI 是否已接上、以及删除后
  磁盘上的已下载文件是否同步清理（注意与 NX-7 的 iCloud 备份语义联动：
  文件若已进备份，本地删除不等于备份中删除）。
- **`hotSession` 关键字全仓 0 命中** —— 「hot 会话」在代码中没有对应概念。

**取证入口**：
- 排序与 hot 会话：`apps/mobile/lib/features/session_list/`
- 下载历史 UI：`features/file_transfer/` 下的界面层
- 普通缓存清理：`features/settings/`

**仍需先决策的问题**：「至少 10 个 hot 会话」是容量上限、预热数量，还是 UI 展示条数？
交接文档原文未定义，**建议先向用户确认语义再实现**，否则做出来大概率不是想要的。

### 4.3　E.3.3 后三项　Goal thread ID / Spark 额度圆环 / 运行蓝条与同步光晕

**已确认的实现现状**：
- **Goal 功能已实现**：
  `apps/mobile/lib/features/codex_session/widgets/codex_goal_card.dart`、
  `codex_goal_management.dart`、`apps/mobile/lib/services/codex_goal_request_router.dart`，
  l10n 齐全（`goalTitle` / `goalStart` / `goalManage` / `goalNoActiveTitle` 等，
  `app_localizations_*.dart:2639+`）。**但 thread ID 是否透出到 UI，未核。**
- **Spark 目前只是模型名**：`apps/mobile/lib/models/messages.dart:246` 的
  `'gpt-5.3-codex-spark'`。全仓**没有额度圆环组件**。
  `codex_goal_card.dart` 命中了 rateLimit 类关键字，是最可能的落点。
- **运行蓝条 / 同步光晕**：`syncGlow`/`runningBar`/`blueBar` 全仓 0 命中，**大概率未实现**。
- **Goal thread ID 的数据是有的，但只用于比较，未见透出 UI**：
  `features/codex_session/widgets/codex_goal_management.dart:21` 有
  `left.threadId == right.threadId`（用于相等性判断）。
  **所以 threadId 已在模型里流转，E.3.3 要的只是把它显示出来**，
  不需要新增协议字段 —— 这大幅降低了这一项的实现成本。

**注意**：这三项是**产品功能需求**，不是 bug。9 路审查 agent 的指令是「找 bug」，
所以从设计上就不会覆盖它们。需要按功能实现走，不要当缺陷修。

### 4.4　E.3.4　未读蓝点 / 打开后清除 / 多客户端边界

**已确认**：`unseen` / `unread` / `未读` 全仓 **0 命中**。**该功能未实现。**

**多客户端边界是这一项的难点**：同一会话在 iPhone 与 iPad 同时打开时，
「已读」状态是设备本地的还是 Bridge 全局的？交接文档未定义。
**建议先决策再实现**：
- 本地：实现简单，但换设备会重新出现蓝点；
- Bridge 全局：需要新增协议消息（记得遵守 additive + capability 协商原则，
  见项目 `CLAUDE.md`「Bridge 非対応メッセージの Graceful Degradation」，
  新增类型需在 `chat_message_handler.dart` 的 `_unsupportedActions` 加一行）。

### 4.5　E.4.3 + E.4.4　文件管理两套入口 / owner 模式全盘只读边界 —— **已查完，无漏洞**

初稿把这一项标为「最高风险、完全没核」。**本轮已完整取证，结论是好消息。**
详细发现见 **2.10 节（NX-24 ～ NX-27）**，此处只列对应关系：

| 初稿的问题 | 本轮答案 |
|---|---|
| Bridge 是否**强制**要求签名？还是「有就验，没有就放行」？ | **强制**。`file-transfer-manager.ts:369` 无条件调 `authorize()`，`authorize()` 首行即 `if (!proof) throw step_up_required`（`file-mutation-auth.ts:414-419`）。**但整个 authorizer 只在设置了 `BRIDGE_API_KEY` 时才构造** —— 见 NX-26，用户已明确决策跳过 |
| `isPathAllowed` 是否覆盖全部入口？还有几个漏了？ | **答案是一个半**。机械扫描 19 个候选 + 人工判读：真实缺失 2 处（`list_gallery` 主文档已记、`remove_project_history` = NX-27），其余是委托给更严校验、或纯标签、或会话作用域假阳性。详见 NX-27 下的表 |
| 「全盘只读」边界如何强制？ | `index.ts:55` 的 `OWNER_FULL_DISK_READ` → `file-browser-manager.ts:200` 的 `allowFilesystemRoot`，在 `:210`（根集合）与 `:739`（拒绝文件系统根）两处强制。**且 `index.ts:267-268` 是失败关闭的**：owner 全盘只读模式下若鉴权器起不来，整个文件传输运行时不启动 |
| 修改/移动/删除是否被绕过？ | **不存在绕过 —— 这三种操作在 Bridge 侧根本没有处理器**（NX-24）。E.4.4 是「部分未实现」，不是「有洞」 |

**仍未核的一项**：**「密码/verifier 不进热路径」**。
Bridge 侧可以确认：`file-mutation-auth.ts:282-294` 的注释明确写了
「Authorization is a cold path, so re-read this small private file here without
adding work to browsing, transfer bytes, or chat sync」，且 verifier 只存在于
`FileMutationAuthStore` 内部，不外泄。
**但移动端侧是否把口令留在了内存或热路径上，我没有核。**
取证入口：`apps/mobile/lib/services/` 下 `FlutterSecureStorage` 的使用点，
以及文件写操作 UI 到 `mutationAuthorization` 载荷的构造链路。

**同样未核的一项**：**E.4.3 的「两套入口是否共用同一套实现」**。
入口：`apps/mobile/lib/features/file_browser/`、`features/file_transfer/`、
`features/explore/`。**必读已有报告**：`raw-agent-reports/file-transfer-state-machine.md`、
`file-upload-subsystem.md`、`file-browser-transfer-models.md`、`explore-feature.md`、
`artifact-preview-route-chain.md`。
关注点不变：各写一份意味着安全补丁要打两遍，且必然漏一遍。

### 4.6　E.4.2　后台刷新的 Dart 协调器 —— **已查完，实现质量高**

`apps/mobile/lib/features/background_sync/background_notification_mode_controller.dart`
本轮已审（作为 NX-13 的取证）。结论：

- 生命周期路径完整：`enterForeground()`（`:422-443`）、
  `leaveLifecycle()`（`:446-464`）、`_stopPrearmedLocation()`（`:412-419`）
  都正确地停掉 keep-alive；
- **全部异步路径都有代际栅栏** `_lifecycleOperationGeneration`
  （`:416`、`:435`、`:437`、`:459`、`:462`），慢的 `stop()` 回来时不会覆盖新状态。
  这与 Swift 侧 `BackgroundContinuationController` 的 `activeGeneration`
  防护是同一套模式 —— **两侧纪律一致，是本仓库难得的正面案例。**

**仍建议接手 Agent 补看一项**：`performRefresh` 的 25 秒预算
（`BackgroundSyncHostPlugin.swift:278` `refreshExecutionBudget = 25`）
在 Dart 侧是否被真正遵守，以及超时后是否会留下半完成的写操作。
原生侧已经保证「到点必定 `setTaskCompleted`」（`:481-500` 的
`DispatchWorkItem` + `expirationHandler` 双保险），
所以风险不在「任务不结束」，而在「Dart 的写操作被拦腰截断」。

### 4.7　E.5.4　性能验收准则

**这不是待办项，是验收准则**：性能优化不得靠截断历史、减少真实同步、
隐藏状态或停止实时反馈来冒充修复。

**建议做法**：把它写进主文档第 7 章「测试门禁」，作为批次 10（性能）的**准入条件**：
任何声称改善性能的提交，必须同时证明
①历史条数未减少 ②同步频率未降低 ③状态展示未被隐藏 ④实时反馈未被关闭。

---

## 第 5 章　系统性模式补充

主文档第 7.2 节确立了「测试夹具与生产数据形状不一致」这一模式。本轮新增两个模式。

### 5.1　模式：等待外部回调却不设超时 —— **已知 4 处，跨 3 种语言**

| # | 位置 | 等待对象 | 卡死后果 |
|---|---|---|---|
| 1 | `session_link_cubit.dart:83-116` `_resume()`（主文档） | Bridge `session_created` 消息 | Future 悬挂 |
| 2 | `FileTransferPlugin.swift:191-223`（NX-5） | `UIDocumentPicker` delegate | Future 悬挂 **+ 后续永久 busy** |
| 3 | `PermissionHostPlugin.swift:326-355`（NX-9） | `CLLocationManager` 授权 delegate | Future 悬挂 **+ 后续永久 in_progress** |
| 4 | `AppUpdater.swift:122-169`（NX-17） | Sparkle updater delegate | Future 悬挂 **+ 后续永久 probe_busy** |

**共同形态**：`pendingXxx = result` → 只在成功回调里清空 → 无超时 → 且 `pendingXxx != nil`
被复用为「忙」判据，于是**一次卡死污染所有后续调用**，只能重启 App 恢复。

**同仓库已有正确范例**（照抄即可，不要新发明）：
- `bridge_service.dart:3196-3200` `resolveSessionLink` 有
  `Duration timeout = const Duration(seconds: 10)`；
- `BackgroundSyncHostPlugin.swift:5-26` 的 `BackgroundRefreshCompletion`
  是线程安全的「只完成一次」封装；
- `BackgroundSyncHostPlugin.swift:481-500` 演示了
  `DispatchWorkItem` + `asyncAfter` + 成功时 `cancel()` 的完整超时模式。

**建议纪律**：任何把 `FlutterResult` / `Completer` 存进实例字段的代码，
**必须**在同一个函数里配一个超时；且「忙」判据不得与「有未完成请求」直接等同。
建议加进 `/self-review` 技能的检查清单。

### 5.2　模式：零测试的原生子系统 —— **已知 2 处**

| 子系统 | 行数 | 测试 | 后果 |
|---|---:|---|---|
| `apps/menubar`（主文档 P0-21） | — | **0** | `UsageInfo.swift:11` 的 `resetsAtDate` 恒为 nil，额度倒计时永远显示「—」，无人发现 |
| `macos/Runner/AppUpdater.swift`（NX-19） | 355 | **12 行 stub** | 官方更新链路（E.5.2）无任何回归保护 |

对比：`ios/RunnerTests/RunnerTests.swift` 有 659 行，覆盖全部 9 个 iOS 插件 ——
**同一个仓库里，iOS 侧的纪律没有传导到 macOS 侧。**

**建议纪律**：把「原生目标必须有非 stub 的测试目标」加进 CI 门禁，
按行数比（测试行 / 源码行）设一个下限告警，而不是靠人记得。

### 5.3　对主文档 §7.2 的印证

主文档 §7.2 记录的 ISO8601 夹具问题在本轮再次被印证：
`NotificationActionHostPlugin.swift:52` 用裸 `ISO8601DateFormatter()`（不含
`.withFractionalSeconds`），而生产侧 `websocket.ts` 五处 `new Date().toISOString()`
**必然带三位小数秒**，测试夹具 `RunnerTests.swift:322` 却用了
`"2026-07-25T01:02:03Z"`（无小数秒）—— 测试通过，真机 100% 失效。

**本轮已把这个问题彻底封闭（穷举，非抽样）**：

```
全部 Swift 源码中的裸 ISO8601DateFormatter() 构造 —— 共 2 处，无第三处：
  ios/Runner/NotificationActionHostPlugin.swift:52          → 主文档 P0-20
  apps/menubar/CCPocketMenubar/Models/UsageInfo.swift:11    → 主文档 P0-21

RunnerTests.swift 中全部日期字面量 —— 共 2 处，都无小数秒：
  :322  let occurredAt = "2026-07-25T01:02:03Z"
  :364  "occurredAt": "2026-07-25T01:02:03Z"
```

**结论：该模式在原生侧只有已知的 2 个实例，两个都已在主文档登记，没有第三个。**
修复时建议顺手把两处收口到一个共享工具（例如
`ISO8601DateFormatter.ccpocketInternetDateTime`，`formatOptions` 含
`.withFractionalSeconds`），并**同时把 `RunnerTests.swift:322`/`:364`
的夹具改成带小数秒的形式** —— 否则测试仍然测不到真实格式。

---

### 5.4　iOS 原生测试覆盖矩阵（本轮新增）

`ios/RunnerTests/RunnerTests.swift` 共 **27 个用例 / 659 行**，覆盖 9 个插件。
把它与本文的发现对照，可以精确看出「测试测了什么、漏了什么」：

| 插件 | 用例数 | 测到的 | **没测到的（本文发现所在）** |
|---|---:|---|---|
| ArtifactQuickLook | 3 | 路径校验、相对/缺失路径、符号链接逃逸 | 呈现生命周期 |
| FileTransfer | 6 | 文件名净化、流式拷贝、超大/符号链接拒绝、硬链接提交与崩溃恢复、容量、支持信息 | **NX-5 呈现失败**、**NX-6 错误信息内容** |
| PermissionHost | 4 | 支持信息、requestMode 失败关闭、各权限状态映射 | **NX-9 pending 无超时** |
| MobileHostSnapshot | 2 | 能力清单、低于最低 iOS 失败关闭 | — |
| NotificationApprovalAction | 2 | 本地+远程载荷解析、错误类别拒绝 | **P0-20 的小数秒（夹具本身有问题）** |
| **FileMutationAuth** | **1** | 仅 `isValidChallengePayload` 边界 | **NX-1 / NX-2 / NX-3 密钥与身份全生命周期** |
| BackgroundLocationKeepAlive | 1 | 电量/权限/热压力失败关闭 | NX-14 / NX-15 |
| BackgroundSync（含两个控制器） | 8 | 代际幂等、只完成一次、启动竞态接管、重复拒绝与过期、过期只通知匹配运行、端点替换、**标识符与 Info.plist 一致** | **NX-11 静态状态竞争** |

**两点观察**：

1. **`RunnerTests.swift:647` `BackgroundRefreshIdentifierMatchesInfoPlist` 是个好设计** ——
   它把「配置与代码不一致会导致功能静默全失效」这类高危项变成了自动化断言。
   本文 NX-22 复核 Info.plist 时之所以能快速确认标识符正确，正是因为这条测试的存在。
   **建议把这个思路推广**：凡是「配置错了不会报错、只会静默失效」的地方都加一条同款测试。
2. **`FileMutationAuthPlugin` 是覆盖最薄的一个（1 条）**，而它恰恰是 E.4.4 的安全闸门，
   本文最严重的三条发现（NX-1/2/3）全在它的未测路径上。**这不是巧合。**

---

### 5.5　值得记录的正面模式：代际栅栏

本轮意外收获 —— 仓库里有一套**跨语言一致**的正确并发纪律，建议明确写进规范并推广：

| 位置 | 机制 |
|---|---|
| `BackgroundSyncHostPlugin.swift:220-262` | `BackgroundContinuationController.activeGeneration`，`end(generation:)` 只关闭匹配代际 |
| `BackgroundSyncHostPlugin.swift:174-189` | `expire(runId:)` 只终止 runId 匹配的任务，旧任务的迟到过期杀不掉新任务 |
| `background_notification_mode_controller.dart:412-464` | `_lifecycleOperationGeneration`，慢的 `stop()` 回来时不覆盖新状态 |
| `bridge_service.dart:381 / 1403 / 1430 / 1880` | `_connectionEpoch`，旧连接的响应一律丢弃 |
| `session_list_screen.dart:89-94` | `_readyTargetKey`，换目标即作废权威性闩锁 |

**这套纪律恰好是主文档多条 P0 的解药**（旧响应污染新状态、迟到回调杀掉新会话）。
凡是新写「异步回来后写状态」的代码，都应照此加代际/epoch 判断。
本文 NX-11 的问题正是「同一个文件里一半做了、一半没做」。

---

## 第 6 章　实施顺序增量建议

本文共 27 条编号（NX-1 ～ NX-27），其中 **23 条是缺陷**，
**4 条是事实认定**（NX-24 / NX-25 / NX-26 属边界记录，NX-13 复核后降级）。
建议如下并入主文档第 6 章的批次划分。

### 优先做（本文 P1，4 条）—— 建议并入主文档「批次 1（P0 收束）」之后立即执行

| # | 条目 | 理由 |
|---|---|---|
| NX-1 + NX-2 | Secure Enclave 重复密钥 + 误判失效 | **必须成对修**。NX-2 是 NX-1 的触发器；单修任一条都留有永久失败循环。命中 E.4.4 核心链路 |
| NX-3 | deviceId 静默漂移 | 与 NX-1 症状相同、根因不同，不一起修会让排查陷入混乱 |
| NX-5 | Picker 呈现失败永久 busy | 用户可感知的功能性死锁，且修复方案已在同仓库 `ArtifactQuickLookPlugin` 中现成 |
| NX-20 | Android 图标零别名窗口 | 后果是桌面图标丢失、部分 ROM 不可恢复；改动仅调换两行顺序，性价比最高 |

### 其次（本文 P2，10 条）

- **并入主文档第 2 章（安全）**：NX-6（路径泄露，与主文档路径泄露族并表）、
  NX-16（Sparkle feed 降级面，**建议直接删除死接口**）、NX-18、NX-22（ATS + HTML 预览）
- **并入第 5.1 节的超时批次，一次性处理**：NX-9、NX-17（连同主文档已记录的
  `session_link_cubit.dart:83-116`，三处一起改，共用同一套超时模式）
- **并入批次 10（性能与并发）**：NX-11
- **单独处理**：NX-19（补 macOS 测试目标）
- **需用户决策后再动**：NX-7（下载文件是否进 iCloud 备份）

**顺带一起做的两件事**（成本极低、收益明确）：
- 修 P0-20 / P0-21 时，把两处裸 `ISO8601DateFormatter()` 收口到一个共享工具，
  **并同时改掉 `RunnerTests.swift:322`/`:364` 的无小数秒夹具**（见 5.3）；
- 修 NX-1/2/3 时，**补 `FileMutationAuthPlugin` 的生命周期测试** ——
  它现在只有 1 条测试，而本文最严重的三条发现全在它的未测路径上（见 5.4）。

### 最后（本文 P3，9 条）

NX-4、NX-8、NX-10、NX-12、NX-13（文档修复）、NX-14、NX-15、NX-21、NX-23、NX-25、NX-27
—— 技术债、一致性与注释修正，建议在触碰对应文件时顺手清理，不单独排期。

### 不进批次的 4 条事实认定

| # | 性质 | 处理方式 |
|---|---|---|
| NX-24 | 修改/移动/删除在 Bridge 侧尚未实现 | **将来实现时必须复用同一个 `authorize()` 并扩展 `FileMutationOperation`**，写进开发约定 |
| NX-26 | 无 `BRIDGE_API_KEY` 时上传鉴权缺席 | **用户已明确决策跳过**，仅留档。部署环境若离开 Tailscale 私网需重新评估 |
| NX-25 | 授权缓存不含内容指纹 | 风险极低，记录在案，不建议改 |
| NX-13 | 注释归属不清 | 纯文档修复，见 2.5 节 |

### 第 4 章的 7 项：现在只剩 3 项需要动作

初稿说「7 项都要先取证」，**本轮查完 6 项后，实际剩下的动作是**：

| 项 | 现状 | 动作 |
|---|---|---|
| §4.1 认证/capability 两个信号 | 机制已有，5 之 3 | **取证**：重点是老 Bridge 降级路径会不会让首页永远进不去 |
| §4.2 hot 会话语义 | 未定义 | **先问用户**，不要凭猜实现 |
| §4.3 Goal thread ID | threadId 已在模型里流转 | **纯 UI 透出**，成本低 |
| §4.3 Spark 额度圆环 / 蓝条光晕 | 未实现 | 功能实现，按需求走 |
| §4.4 未读蓝点 | 未实现 | **先决策**「已读」是设备本地还是 Bridge 全局 |
| §4.5 剩余两小项 | — | 移动端口令热路径；两套入口是否共用实现 |
| §4.7 性能准则 | — | 写进主文档第 7 章测试门禁 |

**§4.5 已从「最高风险未闭环」降级** —— 本轮取证证明 Bridge 侧鉴权模块
是全仓质量最高的实现之一，且不存在绕过。风险重心应转移到
**NX-1/2/3（原生密钥生命周期）**，因为那才是这条链路上真正会坏的地方。

---

## 附录　本轮取证边界

### 本文覆盖了什么

**全文件通读（非抽样）**，共 11 个文件 3,538 行：

```
apps/mobile/ios/Runner/FileTransferPlugin.swift                767  ✅ 通读
apps/mobile/ios/Runner/BackgroundSyncHostPlugin.swift          533  ✅ 通读
apps/mobile/ios/Runner/PermissionHostPlugin.swift              418  ✅ 通读
apps/mobile/ios/Runner/FileMutationAuthPlugin.swift            378  ✅ 通读
apps/mobile/ios/Runner/ArtifactQuickLookPlugin.swift           331  ✅ 通读
apps/mobile/ios/Runner/BackgroundLocationKeepAlivePlugin.swift 218  ✅ 通读
apps/mobile/ios/Runner/NotificationActionHostPlugin.swift      200  ✅ 通读（确认主文档 P0-20 无误）
apps/mobile/ios/Runner/AppDelegate.swift                       175  ✅ 通读
apps/mobile/ios/Runner/MobileHostSnapshotPlugin.swift           86  ✅ 通读
apps/mobile/macos/Runner/AppUpdater.swift                      355  ✅ 通读
apps/mobile/android/.../MainActivity.kt                         77  ✅ 通读
apps/mobile/ios/Runner/Info.plist                                —  ✅ 12 个关键键
apps/mobile/macos/Runner/Info.plist                              —  ✅ Sparkle 6 键
apps/mobile/android/app/src/main/AndroidManifest.xml             —  ✅ activity-alias 段
```

### 第二轮补审覆盖了什么（初稿列为「未覆盖」，现已补上）

```
packages/bridge/src/file-mutation-auth.ts                   808  ✅ 通读（E.4.4 Bridge 侧）
packages/bridge/src/index.ts:236-315                         80  ✅ 鉴权器启动接线
packages/bridge/src/file-transfer-manager.ts:350-395          46  ✅ 唯一强制点
packages/bridge/src/websocket.ts                              —  ✅ 全部 case 分支的 isPathAllowed 机械扫描 + 19 个候选人工判读
apps/mobile/macos/Runner/MainFlutterWindow.swift             82  ✅ 通读
apps/mobile/macos/Runner/AppDelegate.swift                   13  ✅ 通读
apps/mobile/ios/RunnerTests/RunnerTests.swift               659  ✅ 27 个用例逐条对照 + 日期字面量穷举
apps/mobile/lib/features/background_sync/
  background_notification_mode_controller.dart               —  ✅ 生命周期与代际栅栏路径
apps/mobile/lib/features/session_list/session_list_screen.dart —  ✅ SessionHomeConnectionGate 全类
apps/mobile/lib/services/bridge_service.dart                  —  ✅ _connectionEpoch 全部栅栏点
apps/mobile/lib/features/file_transfer/file_transfer_storage.dart — ✅ 删除接口
```

### 本文仍然没覆盖什么（重要）

1. **移动端「口令/verifier 是否进热路径」未核**（E.4.4 的最后一小项）。
   入口：`apps/mobile/lib/services/` 下 `FlutterSecureStorage` 使用点，
   以及写操作 UI → `mutationAuthorization` 载荷的构造链路。
2. **E.4.3「两套入口是否共用同一套实现」未核。**
   入口：`features/file_browser/`、`features/file_transfer/`、`features/explore/`。
   **必读** `raw-agent-reports/` 里对应的四份报告。
3. **`app_update_service.dart` 未读** —— NX-16/17 的 Dart 对侧。
   （已确认它只调 `getFeedURL`，不调 `setFeedURLOverride`，但整体逻辑未审。）
4. **§4.1 的认证/capability 降级路径未核** —— 老 Bridge 缺能力时
   authoritative 标志会不会永远为 false，导致首页进不去。
5. **`functions/`（Cloud Functions）本文未涉及**，
   见 `raw-agent-reports/notification-e2e-bridge-cf-apns.md`。
6. **Android 侧除 `MainActivity.kt` 外未涉及**，且 Android 无原生测试。
7. **`RunnerTests.swift` 的断言强度未逐条评估** ——
   本文只做了「测了哪些路径 / 漏了哪些路径」的矩阵（5.4）与日期字面量穷举（5.3），
   没有评估每条断言本身是否足够严格。

### 取证命令（可复现）

```bash
# 原生文件清单与行数
find apps/mobile/ios apps/mobile/macos apps/mobile/android \
  -name '*.swift' -o -name '*.kt' | grep -v Pods

# 覆盖账：某文件是否被此前的报告提到
grep -c "<basename>" reviews/ccpocket-full-code-review-and-plan_v2_20260726.md
grep -rl "<basename>" reviews/raw-agent-reports/

# Info.plist 关键键
python3 -c "import plistlib;d=plistlib.load(open('apps/mobile/ios/Runner/Info.plist','rb'));print(d.get('BGTaskSchedulerPermittedIdentifiers'))"

# 未实现功能确认（0 命中 = 未实现）
grep -rlniE "unseen|unread|未读" apps/mobile/lib --include='*.dart'
grep -rlniE "syncGlow|runningBar|blueBar" apps/mobile/lib --include='*.dart'
```

### 与其他文档的关系

| 文档 | 关系 |
|---|---|
| `ccpocket-full-code-review-and-plan_v2_20260726.md` | **主文档**。本文的第 1 章更正它的 3 处断言，第 2 章补它的原生层空白，第 3 章补它的 §E 追溯 |
| `raw-agent-reports/`（27 份 856 KB） | **一手证据**。改任何模块前必须先翻对应那份；与主文档冲突时以 raw report 为准 |
| `remediation-log_20260726.md` | **在途修复日志**（另一 Agent 正在写）。动手前**必读进度总览**，避免与在途项冲突。本文 21 条与其零文件重叠 |
| `README.md` | 索引。**注意：其中的报告清单未包含本文与 `remediation-log`，也未反映本文第 1.1 节的覆盖账** |
| `../plans/mobile-comprehensive-remediation_v02_20260726-004125.md` | 交接文档，本文第 3 章追溯的对象 |
| `../docs/PROJECT_HANDOFF.md` | 项目 `CLAUDE.md` 要求动手前必读 |

### 授权边界提醒（摘自交接文档与项目 CLAUDE.md）

未经用户明确授权，**不得**：合入共享或稳定分支、push、restart/replace 当前 Bridge、
部署 Cloud、发布 owner OTA、晋级 stable、构建并安装真机 IPA、rebase 或改写他人历史、
删除旧分支/worktree/构建证据/会话数据。

在当前 worktree 中发现用户或其他 Agent 的未提交修改时，**必须先停下识别**，
不得用 reset / checkout / clean 覆盖。

**源码实现、Bridge 部署、OTA 发布、IPA 签名安装、真机验收、stable 晋级
是彼此独立的授权与完成状态。**
