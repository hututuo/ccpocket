# CC Pocket 85% 会话目录卡点修复与部署记录

时间：2026-07-30

源码：`integration/mobile-session-sync-v2-20260730@00ee7c18`

功能修复提交：`99ebf0ff`

## 根因

真实 Bridge 首次目录同步的第 2 帧包含一个约 28,230 UTF-8 bytes 的
`firstPrompt`。Mobile v2 协议把目录摘要限制为 4,096 个字符；因此：

1. Mobile 提交并 ACK `sync_begin`；
2. 第 2 帧 `catalog_changes` 在 JSON 模型解码阶段失败；
3. 后续帧形成 sequence gap；
4. Mobile 主动取消并重新订阅；
5. 首页 readiness 永远停在 85%，同时产生多条“无法读取响应”错误。

Bridge 的 320 项目录读取、状态计算和 v2 序列生成本身均正常。数据库迁移和
WebSocket 连接不是本次根因。

## 修复

- Bridge 在目录状态哈希和分帧之前统一规范化展示字段：
  - `name` 最多 512 字符；
  - `summary`、`firstPrompt` 和展示用 `projectPath` 最多 4,096 字符；
  - 截断不拆分 UTF-16 surrogate pair；
  - 非法超长 lineage 可选 ID 省略，不使整个目录失效。
- Mobile 对旧 Bridge 发来的超长 `name`、`summary`、`firstPrompt` 做同样的
  安全展示截断，不再丢弃整批同步。
- 这只约束目录摘要。Provider 权威历史、完整会话正文和 Mac 端原文件没有截断
  或改写。

## 自动验证

- Bridge 定向：12/12。
- Bridge 全量：96 files / 1,858 tests。
- Mobile 协议、同步服务和 SQLite 目录缓存：34/34。
- Mobile 定向 analyze：0 issue。
- `git diff --check`：通过。

真实 320 项目录的隔离 runtime 和最终 live runtime 均完成 v2 同步。live 结果：

- 目录分页：6 帧；
- 最大帧：65,139 bytes，小于 64 KiB wire 上限；
- 最大 `firstPrompt`：4,096 字符；
- priority checkpoint：sequence 52；
- sync complete：sequence 136。

## Bridge runtime

- 当前：
  `/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.4-compat.5-00ee7c18`
- 回滚：
  `/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.4-compat.4-065cddc0`
- 版本：`1.69.4-compat.5`
- 部署时 PID：`29341`，后续应以 live 状态为准。
- 唯一 listener：`127.0.0.1:8765`。
- `dist/cli.js` SHA-256：
  `e12c180058a8a6979df899daa8c09cd70c24046bd03d61509991d35893c07a17`
- `dist/websocket.js` SHA-256：
  `b42f465f95afb5370b85e6afc52959f36de1d23fc2de4d08126fad48207cd80c`
- 实际修复模块 SHA-256：
  `66088271c6f08d5b106ee8ba070f882d8694f9426f03a13231603415eb8a4329`
- production dependency tree：完整。

首次 launchd 切换因紧邻 `bootout` 的 `bootstrap` 返回 I/O error；回滚门禁成功
恢复 compat.4 和健康监听。第二次在确认卸载后切换成功。没有出现双 listener。

验证完成后删除了已被两代取代的
`1.69.4-compat.3-8c1d9907` runtime（约 256 MiB）。现在只保留 compat.5
当前版和 compat.4 直接回滚版。定向 Mobile 验证生成的 `build/`、`.dart_tool`
和 iOS ephemeral 也已删除；当前工作树只保留源码、Node 依赖和最新 Bridge
`dist`。

## Mobile / OTA 边界

用户当前安装的 build 206 可直接从 Bridge 端修复受益，不需要清缓存或重装。

Shorebird 只读查询确认云端当前最高 iOS base release 是
`1.109.3+205`，没有 `1.110.1+206` base release。build 206 是 dry-run
AltStore 输入包，不能为它发布定向 OTA patch。因此 Mobile 侧的兼容容错已进入
源码，但要到下一次真实 base IPA/release 才能进入设备；本次没有伪称已发布 OTA，
也没有修改 `owner` 或 `stable`。
