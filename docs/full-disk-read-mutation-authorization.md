# 全盘只读与文件变更二次授权

> 状态：accepted design，尚未实现。本文记录用户已确认的长期产品行为和实现边界，
> 不表示 Bridge、Mobile、基础 IPA、运行配置或真机权限已经更新。

## 1. 产品决定

CC Pocket 的 owner 自用部署允许 Bridge 在 macOS 实际授予的权限范围内浏览、
搜索、读取、预览和下载全盘文件，不要求按项目目录缩小只读范围，也不限制
Codex/Claude 根据用户任务读取文件。

手机直接发起的任何文件系统变更必须经过 Bridge 权威验证的二次授权。允许的
二次授权方式为：

1. 输入在 Mac Bridge 本地设置的文件变更密码；
2. 在已登记的 iPhone 上通过 Face ID，由 Secure Enclave 中受生物识别保护的
   私钥对本次操作挑战签名。

两种方式任选其一。Face ID 不是把 `faceIdPassed: true` 发送给 Bridge；Bridge
必须验证与本次具体操作绑定的密码证明或设备签名。

## 2. 两套文件入口，共享全盘只读权限

产品保留两套清晰独立的文件入口。它们不共用交互界面和写入语义，但必须复用
同一个 Bridge 全盘只读授权、canonical path 校验和预览/下载基础设施。

### 2.1 手动文件管理

- 用户从 Mobile 文件管理器主动浏览目录、搜索、固定常用位置、查看 metadata、
  预览或下载文件；
- owner 模式不再用项目目录或 `BRIDGE_ALLOWED_DIRS` 阻止只读访问；
- 只读操作不需要文件变更密码或 Face ID；
- 从手动文件管理器发起的任何写入仍按本文的二次授权方案执行。

### 2.2 Agent 文件引用与超链接

- Codex/Claude 的原有工具、输出格式、文件写入和 provider 权限机制保持不变；
- 当 Agent 回复引用本地绝对路径或相对 session cwd 的文件路径时，Bridge 继续
  将它识别为结构化文件引用，Mobile 继续显示为可点击超链接；
- 用户点击 Agent 文件引用后的预览、Quick Look、下载或 Mac 到手机传输属于
  只读访问，必须使用与手动文件管理相同的 owner 全盘只读权限；
- owner 模式下，Agent 引用的文件即使位于当前 project、session cwd 或旧
  `BRIDGE_ALLOWED_DIRS` 之外，也不能返回 `path_not_allowed`。Bridge 应解析
  canonical path、验证文件身份和读取能力，然后签发短期 opaque read
  capability；HTTP 端不能直接接受未经授权的任意本地路径；
- macOS TCC、Unix 权限、文件已删除或目标不是普通文件等真实失败必须返回
  独立错误，不能把它们伪装成项目目录权限错误；
- 从 Agent 预览页继续执行重命名、移动、覆盖或删除时，操作从只读引用链路
  转入手动文件变更链路，并要求密码或 Face ID。

这两套入口共享读取权限，不意味着把 Agent 机制重写成第二套文件管理器。Agent
只负责产生真实文件引用；Bridge 负责把引用安全映射为 Mobile 可预览的只读
capability；Mobile 文件管理器负责用户主动浏览和所有直接文件变更交互。

### 2.3 统一预览路由，复用现有实现

实现前的源码核对已经确认，下列能力不是待重写功能：

- Bridge 已能从 Agent 回复中提取本地绝对路径、相对 session cwd 的路径和
  Markdown 文件链接，登记 artifact 并向 Mobile 返回结构化引用；
- Agent 文件引用和手动文件管理最终都进入同一个
  `ArtifactPreviewScreen`；
- iOS 已有原生 `QLPreviewController` adapter，且 native 层已经调用
  `QLPreviewController.canPreview`；
- Flutter 预览外壳已经统一提供返回、分享、下载、传输进度、取消和错误提示。
  embedded Bridge 页面不应再复制一套 JavaScript-to-native 操作栏。

现存问题是路由方式，而不是缺少上述能力。当前 Dart 只根据 Office/RTF
扩展名决定是否调用 Quick Look；JSON、PDF、图片、音视频和普通文本仍固定进入
本地 WebView。Quick Look 返回 `unsupported` 时，当前页面也只显示重试，不会
自动切换到本地预览。

后续实现采用一个共享的 preview coordinator：

1. Agent 引用和手动文件管理都把同一份 artifact/read capability 交给统一预览页；
2. iOS 在完成认证、大小限制、可取消的临时文件准备后，先由设备当前系统版本的
   `QLPreviewController.canPreview` 判断并尝试系统预览；
3. Quick Look 明确不支持、原生 adapter 不可用或预览启动失败时，自动切换到
   本地只读预览器，不要求用户退回后重新选择；
4. 本地预览器继续承担文本/代码、JSON、XML、YAML、CSV、日志、DOCX 等兜底，
   采用有界读取；JSON 合法时可格式化展示，失败时保留原始文本，不能因为解析
   失败阻止下载或分享；
5. 未识别的二进制格式显示文件名、类型、大小和“不支持直接预览”，仍保留下载
   与分享，不猜测编码、不把任意二进制交给文本解码器；
6. 分享和下载继续由 Flutter 外壳统一实现，对 Quick Look 与本地预览使用同一
   组按钮、同一传输取消/进度和安全文件名规则；不另造第二套按钮或下载协议。

[Apple 将 JSON 声明为 `public.json`](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/json)，
并明确它符合 `public.text`；
[Quick Look 支持符合 `public.text` 的文本文件](https://developer.apple.com/documentation/quicklook/qlpreviewcontroller)。
因此 JSON 应进入系统优先路线。但 Apple 也说明 Quick Look 的支持范围可能随
系统版本变化，不能把“JSON 永远可预览”或任何固定扩展名表当作最终事实，设备
上的 `canPreview` 结果才是权威分流。

系统优先不改变访问权限：Quick Look 和本地预览器都只能消费 Bridge 签发的
短期 opaque read capability，不能接受 Mobile 提交的任意 Mac 路径。临时文件
必须位于 App sandbox，关闭系统预览后删除；下载到用户可见位置与临时预览文件
仍是两个不同动作。

## 3. 权限分层

### 3.1 不需要二次授权

- 列目录、读取 metadata、搜索和读取文件内容；
- 应用内预览、Quick Look、下载到手机、从 Mac 发送到手机；
- Gallery、Artifact 和文件管理器中的只读访问；
- Agent 本地文件超链接的解析、预览和下载，即使目标位于 session project
  或旧允许目录之外；
- Codex/Claude provider 运行时根据用户任务进行的文件读取；
- Codex/Claude 自己的工具写入。Agent 工具行为继续由 provider 的 sandbox、
  permission mode、审批和现有 Bridge 自动审批规则管理，不能被本方案改造成
  每次写文件都弹 Face ID。

连接认证仍是独立的第一层门禁。无需二次授权不等于允许未认证设备访问。

### 3.2 必须二次授权

本节只约束 Mobile 或 Bridge 文件管理 RPC 直接发起的变更：

- 新建文件或目录；
- 写入、追加、编辑、覆盖或截断；
- 重命名、移动、替换；
- 从手机上传并落盘到 Mac；
- 删除、清空、永久删除或覆盖已有目标；
- 将来新增的任何会改变 Mac 文件系统状态的文件管理操作。

默认删除优先进入可恢复的废纸篓。永久删除必须显示不可恢复提示，并使用一次
新的操作授权；不能复用此前的普通写入授权。

## 4. 密码方案

- 密码只能在 Mac 上通过 Bridge 的本地管理入口设置、修改或清除。
- Bridge 不保存明文密码，只保存独立 salt、Argon2id verifier 和版本化参数。
- 凭据文件放在 `~/.ccpocket/` 下，权限必须为 `0600`，不得写入 plist、命令行、
  普通日志、完成回报或 Mobile 配置。
- Mobile 默认不持久保存文件变更密码。用户每次输入后只用于当前挑战，失败或
  超时立即清除。
- Bridge 对连续失败进行逐级延迟和有界锁定；成功、失败和锁定只记录设备、
  时间和操作类型，不记录密码或文件正文。
- 忘记密码只能在 Mac 本地重置。重置会撤销全部未消费授权、现有 Face ID 设备
  登记和在途挑战，然后重新登记手机。

初版可在 Tailscale 加密连接和 Bridge 连接认证之上提交密码并在 Bridge
执行 Argon2id 校验。若未来允许非 Tailscale 网络，再单独引入应用层 TLS 或
PAKE；不能把当前自用边界误写成公网密码协议已经完成。

## 5. Face ID 的后端可验证方案

### 5.1 设备登记

1. 用户先通过文件变更密码完成一次登记授权；
2. iPhone 在 Secure Enclave 生成不可导出的签名私钥，并使用
   `biometryCurrentSet` 保护；
3. Mobile 把公钥、稳定设备 ID、算法和 capability 发送给 Bridge；
4. Bridge 保存公钥登记，不保存 Face ID 数据、图像或私钥；
5. Mac 本地管理入口可查看和撤销已登记设备。

Face ID 集合变化、App 重装、Keychain/Secure Enclave 密钥失效或设备被撤销
后，原登记必须 fail closed，并要求使用密码重新登记。

### 5.2 操作挑战

Bridge 在执行变更前先完成 canonical path、允许的 owner 全盘策略、symlink、
目标存在性、文件身份和冲突检查，然后生成一次性挑战。挑战至少绑定：

- request ID、连接 generation 和登记设备 ID；
- 操作类型；
- canonical 源路径和目标路径；
- 相关文件身份、大小或预期不存在状态；
- 操作参数摘要的哈希；
- 随机 nonce、签发时间和过期时间。

Mobile 展示人能理解的操作摘要。Face ID 成功后，Secure Enclave 私钥签署完整
挑战；Bridge 验证签名、设备状态、连接 generation、内容摘要、时效和 nonce，
不能只相信 Mobile 自报结果。

## 6. 一次性操作授权

- 密码或 Face ID 成功只授权挑战中列明的一个操作或一个明确批次。
- 授权默认 60 秒过期、只能消费一次，并绑定当前 Bridge 实例、连接 generation、
  设备和规范化路径。
- 不提供默认的全局“已解锁五分钟，期间任意写入”状态。将来如增加便捷模式，
  必须由用户显式开启，并保持路径、操作类型和最大时长约束。
- 执行前重新检查目标身份和 symlink；检查后使用文件句柄、原子落盘、
  no-overwrite 或 compare-and-swap 语义，防止授权后路径被替换。
- 执行结果通过关联 request ID 返回。超时、断线、重连、Bridge 重启、重复帧和
  晚到签名一律不得执行变更。

## 7. 连接安全与全盘读取前置条件

owner 配置可以使用 `BRIDGE_ALLOWED_DIRS=*` 表达全盘只读意图，但在实际启用前
必须先满足：

- Bridge 连接认证已启用；
- 私有 HTTP 与 WebSocket 入口采用同一认证边界，Gallery 上传、列表、读取和
  删除不能绕过；
- 服务只监听 Tailscale 地址，或有等价且已验证的接口级防火墙限制；
- mDNS 保持关闭；
- 请求体、单文件、连接数、失败认证和持久 Gallery 存储有界；
- macOS TCC/Full Disk Access 只授予路径稳定、身份稳定的 Bridge 宿主或窄
  helper。不要把授权绑在每次升级都会变化的版本化 Node 路径上。

全盘读取只覆盖 macOS 实际允许当前宿主读取的资源，不宣称能够绕过 TCC、
FileVault、Keychain、其他用户权限或系统完整性保护。

## 8. 协议与兼容

建议使用 additive capabilities：

- `full_disk_read_v1`
- `full_disk_reference_preview_v1`
- `file_mutation_step_up_v1`
- `biometric_device_signature_v1`

兼容行为：

- 新 Bridge + 新 Mobile：手动文件管理和 Agent 文件引用均可只读全盘，直接
  文件变更要求密码或 Face ID 签名；
- 新 Bridge + 旧 Mobile：旧 Mobile 保持可用的只读能力；需要二次授权的文件
  变更入口 fail closed 并提示更新，不能回退为无授权写入；旧 Mobile
  无法消费的新引用 capability 继续使用其明确降级；
- 旧 Bridge + 新 Mobile：没有 step-up capability 时不展示或不执行直接文件
  变更；普通会话和旧文件读取继续降级。Agent 引用若仍被旧允许目录拒绝，
  Mobile 显示“需要更新 Bridge”，不能误报文件不存在；
- 旧 Bridge + 旧 Mobile：行为不变。

Secure Enclave 签名是否可由现有基础 IPA 的原生能力完成，必须在实现前现场核对。
如果需要新的 Swift、method channel、entitlement、插件或宿主 capability，
Face ID 路径属于新基础 IPA 边界，不能用 Shorebird 成功结果冒充原生能力已加入。
密码路径和 Bridge 权威授权可以先作为独立阶段实现，但不得因此削弱最终兼容
门禁。

## 9. 审计与恢复

- Bridge 记录设备、时间、操作类型、规范化路径摘要、授权方式、结果和 request
  ID；不记录密码、Face ID 数据、文件正文、签名私钥或完整敏感响应。
- 用户可以在 Mac 本地撤销单台设备、全部设备或清除文件变更密码。
- 撤销、密码重置、Bridge 重启和连接 generation 变化会使未消费挑战与授权
  全部失效。
- 文件变更日志只是审计证据，不是 canonical 文件状态；实际执行结果仍需重新
  stat/读取确认。

## 10. 实现顺序与验收

1. 收紧连接和全部私有 HTTP 入口，修复 Gallery 绕过与无界上传；
2. 建立手动文件管理与 Agent 引用共用的 owner 全盘只读 authority，将本地
   路径安全映射为短期只读 capability；
3. 在现有 `ArtifactPreviewScreen` 和 Quick Look adapter 上实现系统优先、
   本地自动降级的统一 preview coordinator，并复用现有分享/下载；
4. 实现 Bridge 本地密码设置、Argon2id verifier、挑战和一次性操作授权；
5. 将所有 Mobile 直接文件变更 RPC 接入统一授权器；
6. 实现 iOS Secure Enclave + Face ID 设备登记和签名；
7. 再启用 owner 全盘只读配置和稳定 TCC 宿主；
8. 最后做旧/新 App 与 Bridge 兼容、project 外 Agent 引用、断线重放、
   symlink/TOCTOU、失败锁定、删除恢复和物理 iPhone Face ID 验收。

在步骤 1 至 7 完成并验证前，不把当前运行 Bridge 改成全盘开放，也不把本设计
描述为已经部署。
