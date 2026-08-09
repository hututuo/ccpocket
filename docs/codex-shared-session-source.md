# Codex 顺序多实例共享会话来源

## 状态

本文件记录 CC Pocket 对“两个 Codex/Cockpit 前端顺序使用同一份权威会话存储”
的第一阶段支持。源码能力已经加入，但没有修改当前运行中的 Bridge 配置，也没有
部署 Bridge、发布 OTA、构建 IPA 或迁移本地数据。

本阶段采用严格的**顺序单写者**模型：同一时刻只能有一个 Cockpit/Codex
app-server 使用该来源。并发多运行时的 turn owner、审批路由和冲突 UI 不在本阶段
范围内。

## 身份分层

以下身份不能混为一谈：

- `CODEX_HOME`：一个运行实例的物理配置根，包含该实例的认证、配置、数据库和
  sessions 入口。
- `BRIDGE_CODEX_SOURCE_ID`：一份权威会话与生命周期存储的稳定公开身份。
- `bridgeInstanceId`：一台 Bridge 安装的稳定身份，仍用于机器级缓存和 Mirror
  隔离。
- provider thread ID：一条会话的持久身份；运行时 session ID、标题、项目路径和
  时间都不能替代它。

未配置 `BRIDGE_CODEX_SOURCE_ID` 时，Bridge 继续按 `CODEX_HOME` 路径计算原有的
`codex-home-<24 hex>`，行为与旧版本完全一致。不会根据 sessions 符号链接或
`realpath` 自动判断两个 Home 同源，因为仅共享 JSONL 不能证明认证、app-server
索引和生命周期元数据也属于同一权威来源。

## 显式来源 ID

允许的值只有两种：

- 新来源：`codex-source-` 加 32 位小写十六进制随机数（128 bit）。
- 无迁移接管：精确使用一个现有 `codex-home-` 加 24 位小写十六进制身份。

ID 是公开的 opaque 标识，不是密码或认证凭证。空串、空白、大写、人类名称、
路径和其他格式都会使 Bridge 启动或 setup 失败，不会静默回退。

Cockpit 应按“Codex 账号/profile + 同一权威会话存储”生成并持久化新 ID；切换
账号或权威存储时必须轮换。若希望继续使用既有的 archive、目录缓存和已下载
Mirror，应把准备作为 canonical 的那个旧 `codex-home-*` 精确设为共享 ID。这样
只接管该分区；另一个 Home 原有分区仍保留隔离，不做宽泛合并。

配置入口为：

```text
ccpocket-bridge setup --codex-source-id codex-source-<32 lowercase hex>
```

macOS launchd 和 Linux systemd setup 都会持久化此值；systemd 同时持久化
`CODEX_HOME`，避免逻辑来源和实际读取目录分离。直接启动 Bridge 时也可以设置
同名环境变量。

## Cockpit 必须保证的外部合同

CC Pocket 只接受来源声明，不负责证明两个 Cockpit 实例真的共享同一权威存储。
启用前 Cockpit 必须：

1. 确认两边属于同一 Codex 账号/profile 和同一 session authority。
2. 让当前 app-server 数据库、thread/list 索引和 rollout 文件对该来源完整一致。
   Bridge 目前不会在 app-server 成功但只返回空或部分目录时擅自把 JSONL 扫描
   结果合并进去。
3. 按 source ID 实施单写者锁，并校验 PID、进程启动时间或 boot session。旧进程
   仍存活或状态不明时应拒绝启动。
4. 实例切换前正常结束旧 app-server；不能只依赖“用户不会同时点两个窗口”。

## Mobile 与 Bridge 行为

- `codexSourceId` 的现有 wire 字段继续使用，没有新增破坏性协议字段。
- 同一 `bridgeInstanceId + codexSourceId` 的目录缓存、最近消息热窗口、
  source-bound archive 和 Mirror 继续落在同一来源分区。
- 打开“已归档会话”时，新 Bridge 会用官方 `thread/list(archived:true)` 对当前
  `codexSourceId` 做有界对账。完整扫描可移除该来源的陈旧本地投影；达到安全上限
  或旧 app-server 不支持时只合并已确认结果并保留旧投影，不跨来源删数据。
- 来源切换会结束旧的内容订阅并建立新订阅；旧订阅的迟到帧仍受 connection
  generation、subscription ID 和 Bridge instance 检查拒绝。
- source-aware 新客户端发起的 resume、fork、rename、archive、unarchive、
  delete 和 Mirror 继续接受 source mismatch 检查；共享来源 ID 不会削弱这些
  检查。旧 Mobile 不发送 source，legacy 无 source archive 也保留既有
  best-effort 兼容，它们不构成 source 认证。破坏性操作仍受 provider、
  project-path、archived identity 等现有校验约束。
- 新随机 ID 会创建新分区。旧数据不会批量删除或迁移；只有当前官方归档目录
  明确返回同一个 durable thread ID 时，才会把该条 legacy archive 绑定到当前
  source，未命中的 legacy 条目保持原样。
- 不同 `bridgeInstanceId` 仍不会仅凭相同 source ID 自动合并机器级缓存。

## 兼容矩阵

- 未配置来源 ID：新 Bridge 与旧行为相同。
- 新 Bridge + 旧 Mobile：仍发送现有 `codexSourceId` 字段；旧客户端按既有能力
  协商工作。
- 新 Mobile + 旧 Bridge：缺少来源身份时继续走 legacy 分区，不伪造共享来源。
- 两个 Home + 同一显式来源 ID：在同一 Bridge 安装且 Cockpit 外部合同成立时，
  顺序切换可复用同一目录、热窗口和 Mirror 来源。
- 两个 Home + 不同来源 ID：source-aware 新客户端和 source-bound 数据中的目录、
  热窗口、archive、Mirror 与生命周期操作严格隔离；旧 Mobile/legacy archive
  仍遵循上一条兼容边界。

没有数据库 schema 迁移，没有更改 canonical history 格式，也没有把 source ID
当作认证。未来若需要同时运行两个实例，必须另行设计运行时 owner/lease、审批
路由和冲突诊断，不能扩大本阶段语义。
