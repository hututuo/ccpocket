# 手机会话诊断快照

## 目的

当手机出现“列表正确但会话页错误、消息缺失或重复、折叠/排序跳动、同步状态反复”时，
不要再只根据截图或电脑端模拟推断。用户可在对应 Claude/Codex 会话右上角菜单选择
“上报会话诊断”，把该手机当时真实持有和实际投影的状态送回 Mac。

这项功能只用于用户显式触发的开发诊断。它不是后台遥测，不会定时采集，也不新增第二
套上传协议。

## 权威链路

```text
手机当前会话页
  ├─ ChatSessionCubit 当前状态
  ├─ ChatMessageList 已计算的真实布局、稳定键、折叠和可见角色
  ├─ 当前 SQLite 热窗口、gap、cursor、revision、状态和 read watermark
  ├─ conversation_sync_v2 有界事件环
  └─ 首页当前真实排序、分组、可见行和目标索引
        ↓ 用户点击“上报会话诊断”
递归凭据清理 + 有界 JSON
        ↓
既有 file_transfer_v2 暂存、续传、ACK、重连与 step-up 授权
        ↓
Bridge 再次校验凭据、身份、大小和 SHA-256
        ↓
~/.ccpocket/diagnostics/reports/<reportId>.json
```

报告记录的是 UI 已经计算并持有的投影，不在诊断层重新实现一次排序、分组或折叠算法。
首页和会话页只登记惰性只读捕获闭包；正常渲染不会序列化报告。
手机同时保留最近 10 秒、仅内存且不含正文的 post-frame 变化环；用户点击后继续观察至少
3 秒。报告保存完整起点/终点、内容感知 revision 和最多 96 条轻量变化样本，因此
`4→0→4`、消息消失后恢复、历史/最新切换及流式状态变化不会再仅因两端相同而被误报为
稳定。比 200 ms 更短且从未绘制成 frame 的变化仍可能不被采样，报告会明确列出观察时长、
采样间隔和覆盖范围，不把它描述成屏幕录像。

## 身份与一致性

- 报告固定绑定 `bridgeInstanceId + codexSourceId + provider + providerSessionId`；Claude
  和 Codex 报告都必须有精确 `codexSourceId`，采集前后不允许跨源。
- SQLite 异步读取前后重新核验数据源身份。期间切换 Bridge/source 会中止上报。
- 同时记录缓存 commit epoch、完整 presentation 起点/终点和点击前后 temporal trace。
  只有两次真实展示捕获都可用、内容感知 revision 与 cache epoch 均未变化，并且变化环
  未观察到中间态时才写 `capture.stable=true`；loading、未挂载或采集期间发生
  streaming/status/paging 变化都会保守标记为不稳定，但仍保留现场。
- 报告使用独立 `reportId`。同一个传输因断线或丢失回执重试时复用原有
  `transferId/resumeToken`，Bridge 通过持久 receipt 幂等返回同一归档，不重复覆盖。

## 安全边界

- 手机上在写入暂存文件之前递归清理 token、API key、password、authorization、cookie、
  私钥、签名密钥、Bearer/JWT/常见厂商密钥、`KEY=value` 形式，以及带 user-info、query
  或 fragment 的 HTTP/WebSocket URL。
- Bridge 在归档前再次递归拒绝凭据字段和高置信秘密字符串；任何一层不确定都
  fail closed。PEM/OPENSSH/PGP 私钥块也按高置信凭据处理。
- 默认情况下，报告上传必须来自 API key 或已配对设备连接；open-auth 客户端既看不到
  能力，也不能发起诊断上传。
- 本地开发排障可显式设置 `BRIDGE_ALLOW_UNAUTHENTICATED_DIAGNOSTICS=1`。该开关只在
  `BRIDGE_AUTH_MODE=open` 时放行用户显式触发的会话诊断上传，并免除该诊断上传的
  密码/Face ID step-up；它不改变普通文件上传、文件浏览或修改接口原有的认证和授权
  策略。正式部署不得设置该开关。
- API key/已配对连接仍沿用文件修改的 Face ID/Bridge 密码 step-up，不在报告或
  checkpoint 中保存口令；显式 open 开发诊断开关是唯一例外。
- 新 Mobile 通过 `file_transfer_diagnostic_report_no_step_up_v1` 识别这一窄例外；只认识
  旧诊断能力的 Mobile 仍会要求密码/Face ID，不会因为 Bridge 开关而静默降低授权。
- 手机 JSON 最大 16 MiB；Bridge 加入运行态后的归档 envelope 最大 32 MiB。结构、正文、
  SQLite 和事件环还分别有更小的条数/字符预算。
- Bridge 同时最多保留 4 份、合计 64 MiB 的诊断暂存；归档与 receipt 复核采用有界串行，
  防止多份大 JSON 同时解析放大内存。

## Mac 端保存与清理

- 默认目录：`~/.ccpocket/diagnostics/reports/`。
- 目录权限 `0700`，报告权限 `0600`；拒绝符号链接、路径替换和同名覆盖。
- 保留策略同时受 7 天、32 份、512 MiB 三个上限约束；常规清理只识别安全的
  `<reportId>.json` 普通文件。
- Bridge 只串行解析/归档一份报告。确定性校验失败会按原 inode 立即删除 Downloads
  原始上传和状态；过期、无 receipt 的失败上传也按同一身份清理。
- receipt 重放前必须重新核验归档文件、路径和四元身份；归档已丢失时不得返回假成功。
- 启动清理还会删除超过一小时的自有 `<reportId>.json.tmp-*` 崩溃残留，不触碰其他文件。
- Bridge 日志会输出 reportId、大小、耗时和最终路径，不输出报告正文或凭据。

## 排查流程

1. 在错误仍显示于手机时，打开该会话右上角菜单并点“上报会话诊断”。
2. 如要求 Face ID/Bridge 密码，完成一次操作级授权。
3. 记录手机返回的 reportId 和 Mac 路径。
4. 排查者先比较 `actualHomeProjection`、`sessionProjection.presentationAtStart/AtEnd`、
   `capture.temporalPresentation`、SQLite window、sync event ring 和 capture revision，再
   对照 Bridge envelope 中同一会话的运行态。
5. 若报告标记 `capture.stable=false`，先判断是否正好捕获到竞态；必要时保持错误页面不动
   再上报一次，而不是先刷新或退出会话。

手机侧一次状态采集最长等待 20 秒；超时会明确失败，不会把半份现场当作成功报告。

## 验收与发布边界

自动测试覆盖凭据拒绝、来源身份、大小上限、旧能力前置失败、终态清理、断线续传、
持久回执、Bridge 重启重放、同名竞争和保留清理。源码与测试通过不等于真机完成；仍需
在物理 iPhone 上确认菜单可见、Face ID/密码授权、错误现场不被刷新、上传成功提示以及
Mac 文件可读。本文件不授权构建 IPA、发布 OTA、重启生产 Bridge 或晋级 stable。
