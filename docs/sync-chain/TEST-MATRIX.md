# 回归矩阵与证据边界

状态只用 PASS / FAIL / NOT_RUN / BLOCKED；每次运行保留命令、退出码、源码身份和原始日志。
已有旧 CI/设备收据仅作历史参考，不计作本分支验证。

| ID | 场景 | 预期 | 当前状态/入口 |
|---|---|---|---|
| R01 | 部分 turns_page 提交 | cache epoch 与通知推进；新条目可读取；complete 仍 false | FAIL 基线红灯：epoch 未推进；E002 |
| R02 | 完全相同缺口/内容重放 | 不重复自动请求 | NOT_RUN；现有 bounded summary 用例 |
| R03 | 同 canonical revision 后续内容/缺口变化 | 必要修复仍可执行 | FAIL 基线红灯：两种变化均被抑制；E002 |
| R04 | 修复运行期间发生变化 | 合并 dirty；成功后按新观察判断，不丢变化 | NOT_RUN；补回归 |
| R05 | focus/transport/reset/dispose | 旧结果不生效；无计时器与等待泄漏 | NOT_RUN；现有与补充用例 |
| R06 | 删除列表 64/2000/2001 边界 | entries/deletes 按各自预算 | NOT_RUN；protocol tests |
| R07 | 历史/最新修复并发 | 保留已提交前缀、顺序与分页游标规则 | NOT_RUN；Service/Repository tests |
| R08 | 错误 source、订阅、sequence | fence / bounded recovery / last-good | NOT_RUN；Service + wire fault tests |
| R09 | 真 Bridge → JSON → Dart → SQLite → Cubit/layout | 与 Provider fixture 的稳定 ID/顺序/内容相符 | NOT_RUN；blackbox receiver/full page |
| R10 | stdio JSON-RPC 模式 | 不旁路生产 RPC 解码/分发 | NOT_RUN；receiver RPC 模式 |
| R11 | SQLite 关闭重开 | durable 内容可恢复 | NOT_RUN；receiver tests |
| R12 | 全 Mobile analyze/tests | 无新增 error/warning/回归 | NOT_RUN |
| R13 | 真实 Provider 新事件 | 原始记录与 Bridge/cache/page 对照 | NOT_RUN |
| R14 | 模拟器 / 真机 / 生产 | 各自独立验收 | NOT_RUN |

R09/R10 的最上游是隔离 Provider fixture，使用真实 Bridge、协议、SQLite 和页面相关代码；
即使 PASS，也只证明接收闭环，不冒充 R13/R14。

结构抽取前必须覆盖对应行为变化、取消和重放；纯粹复制 implementation 的测试不作为额外证据。
