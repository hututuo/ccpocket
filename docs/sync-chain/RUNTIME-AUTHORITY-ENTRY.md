# Detached 控制权限的 runtime 归属入口

## 起点与需要证明的行为

调查起点为 C1c/C1d 完整门禁 `da3d3f6`，测试写法后续为 `2f95d6d0`。
当时视觉终态分支已经核对远端 runtime ID，原 mutation lease 尚不在其验收范围（R48）。
本入口现已完成 C1e 的选定权限契约；当前完整输入为 `16196f05`，测试 import 后续为 `8178295d`。
相关产品原则见 `decisions.md` 的 2026-08-02 runtime attachment changes：
session_list handle 与 V2 authority 是两个事实，只有形成当前精确目标后才允许设置、停止、steer 或发送。

静态路径显示：status 签名带 runtimeSessionId，但接纳 authority 时只标成本地当前 binding generation。
A→B→C 期间 B 未被 Cubit 观察时，单个 rejected authority 槽只记 A；
迟到的同源 B writable status 可能把 authority B 与当前 runtime C 拼成可写 target。
E061/E062 已由两种 capability 下的公开输入证明：16 项行为 FAIL / 8 项保护 PASS，
input/approval 实际目标为 C，stop/interrupt 实际调用 C，settings 混合 C runtime 与 B authority。
已有合法C的settings owner会被B替换，合法C image dispatch lease也会被B取消。
red时产品未改，失败日志及red checkpoint保留。E063在原接点窄修，26项新契约与相关313项PASS；
最终完整门禁见E064/E065：产品/测试16196f05全量3396 PASS / 4 SKIPPED及固定SHA review通过，
8178295d仅删除unused test import，26项与完整analyze/format复查通过；不能写成控制全链验收。

## 唯一 owning path 与范围

| 接点 | 当前事实 / 校验 | 本批需要保护 |
|---|---|---|
| updateDetachedProviderStatus | 原source adoption/provider/thread之后，known本地binding与known远端ID矛盾则早退；其后保留time/duplicate/rejected规则 | 不推进矛盾status的时间/authority/turn，也不撤掉合法C；无binding时仍可只读显示，mutation因缺handle被原getter拒绝 |
| _runtimeSessionIdForMutation / _hasCurrentDetachedAuthorityLease | V2 capability 要 exact lease；writable/steerable 分类 | 已知远端身份不匹配时拒绝；匹配的现有权威、turn/host规则仍成立 |
| sendMessage / retryMessage | 捕获 runtime lease；异步图片/排队/dispatch 前后核对 generation/source/authority | stale status 不创建有效 lease；新 owner 正常发送；异步中变更仍拒绝 |
| approve/approveAlways/reject/answer/interrupt/stop | 调用时共用 runtime mutation gate；Desktop stop另走detach规则 | 实际 Bridge send/stop/interrupt 不得发出，而不是只验证按钮状态 |
| Codex settings | runtime target 带 source/thread/runtime/authority/operation；durable settings能力另走thread target | stale runtime权限不创建混合target；durable target不借用runtime lease |
| legacy无V2 / 旧V2无新增字段 / Desktop appServer | 各有已存在兼容或authority路径；appServer状态剥离runtime ID | 不因新增可选字段删除合法旧路径；缺失字段的证明能力须明确，不能伪造ID |

本批先保护有明确 runtime 身份的已知矛盾；身份本身仍不是 authority。
C1f另核对实际SessionManager可复用同public runtime ID替换CodexProcess并轮换authority。
因此C1e的known-ID矛盾guard不能作为全部replacement证明；新R50仅验证状态尚未被页面观察时的合法等待。
C1g仅在Bridge补实际同ID replacement与catalog capacity/public ACK组合（R52 / E077）；known-ID guard仍不证明Mobile新旧authority策略。
C1h实际Mobile已收到A/尚未观察B的两窗口在4e6d3d4a闭合（R54），本地commit顺序公开反向保护另列R55。
只有当前合法bridgeRuntime receipt取得新退休证明；cached-only/跨订阅、overlay自身await后替换及无ID远端归属仍R47/R49，见QUEUE-AUTHORITY-ENTRY。
没有新增字段的旧 V2 状态无法仅凭该字段完成远端归属证明，保留原规则及其证据边界。
不在这批移植新协议、造第二个权限owner或重写Bridge控制RPC。
已知不同runtime的status在签名/时间接受前拒绝，避免其驱动合法当前owner的退休。
未绑定页仍可读取status，binding到达后必须经原重新接纳形成控制lease；这两项cold-start red已窄修green。
原replacement terminal用例只修正正反状态的runtime ID到实际replacement，保留旧authority反向保护与全部断言。

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

## 接手与回退

精确门禁/继承关系见ACCEPTANCE.json。原12行guard仅持局部比较值，没有另一份authority/runtime缓存。
回退产品16196f05时保留26项测试，先审阅E061–E065的red/正反向输入及unbound窄修。
原terminal replacement用例明确的runtime ID保留，旧authority反向仍独立；不删断言或变更期限。
若要收紧无字段旧组合，先证明其合法用途与新的协议/运行事实，再独立行为批；本修复未授权退役兼容路径。
