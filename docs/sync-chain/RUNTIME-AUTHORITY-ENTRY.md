# Detached 控制权限的 runtime 归属入口

## 起点与需要证明的行为

产品仍为 C1c/C1d 完整门禁 `da3d3f6`；测试写法后续为 `2f95d6d0`。
视觉终态分支已经核对远端 runtime ID，原 mutation lease 不在其验收范围（R48）。
相关产品原则见 `decisions.md` 的 2026-08-02 runtime attachment changes：
session_list handle 与 V2 authority 是两个事实，只有形成当前精确目标后才允许设置、停止、steer 或发送。

静态路径显示：status 签名带 runtimeSessionId，但接纳 authority 时只标成本地当前 binding generation。
A→B→C 期间 B 未被 Cubit 观察时，单个 rejected authority 槽只记 A；
迟到的同源 B writable status 可能把 authority B 与当前 runtime C 拼成可写 target。
这是需要公开行为验证的疑点，当前还不是 red 证据。

## 唯一 owning path 与范围

| 接点 | 当前事实 / 校验 | 本批需要保护 |
|---|---|---|
| updateDetachedProviderStatus | provider/thread/source/time/duplicate/rejected generation；authority 标成本地 binding generation | 已明确属于另一 runtime 的状态不能授予当前控制权限；只读呈现与控制准入分开 |
| _runtimeSessionIdForMutation / _hasCurrentDetachedAuthorityLease | V2 capability 要 exact lease；writable/steerable 分类 | 已知远端身份不匹配时拒绝；匹配的现有权威、turn/host规则仍成立 |
| sendMessage / retryMessage | 捕获 runtime lease；异步图片/排队/dispatch 前后核对 generation/source/authority | stale status 不创建有效 lease；新 owner 正常发送；异步中变更仍拒绝 |
| approve/approveAlways/reject/answer/interrupt/stop | 调用时共用 runtime mutation gate；Desktop stop另走detach规则 | 实际 Bridge send/stop/interrupt 不得发出，而不是只验证按钮状态 |
| Codex settings | runtime target 带 source/thread/runtime/authority/operation；durable settings能力另走thread target | stale runtime权限不创建混合target；durable target不借用runtime lease |
| legacy无V2 / 旧V2无新增字段 / Desktop appServer | 各有已存在兼容或authority路径；appServer状态剥离runtime ID | 不因新增可选字段删除合法旧路径；缺失字段的证明能力须明确，不能伪造ID |

本批先保护有明确 runtime 身份的已知矛盾；身份本身仍不是 authority。
没有新增字段的旧 V2 状态无法仅凭该字段完成远端归属证明，保留原规则及其证据边界。
不在这批移植新协议、造第二个权限owner或重写Bridge控制RPC。

## 执行顺序

1. 用原 MockBridgeService 与 public Cubit 输入补 A→B→C、旧B未观察的 writable/steerable 状态。
   capability 分别为 SyncV2-only、SyncV2+RuntimeOverlay，避免把overlay能力误当mutation门禁。
2. 断言发送/审批/回答/停止/interrupt/settings 的实际输出；保留合法 C、旧V2缺字段、legacy与Desktop正向保护。
   旧B status时间较新且same-source，不能用时间或不同source提前排除疑点。
3. 若产品行为 FAIL，保存red checkpoint，才在原权限接纳接点窄修。
   现有B缓存视觉反向测试、队列十三项、原异步lease取消契约必须继续通过。
4. 记录各reset/source/suspend/null/close的旧事实退休；不新增重复身份缓存。
5. 固定产品/测试输入，相关public/JSON/SQL与七黑盒、完整Mobile/analyze/format及独立复核。
   Bridge未变化时按精确tree继承已完成门禁，不伪装重跑。

queue-only旧/未来authority策略仍是R47，历史R29与095cab00失败归因仍未解决。
源码门禁、真实Provider、设备、生产部署与发布继续各自报告。
