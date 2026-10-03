# 终态清理的 runtime 身份

## 为什么先补这个边界

C1c 原候选在同一 socket 输出未改变时，用 source/local generation 的 authority lease 退休 transient。
89084bcb 全量 3350 PASS / 4 SKIPPED，但这些状态尚未携带 runtimeSessionId。
连续 A→B→C 重绑时，B 的状态可能尚未投影到 Cubit；单槽 rejected authority 只记住 A。
之后同源 B 缓存被重新读取，原接点会把它标成 C 的 local generation。
当 C 原本没有待验证 visual、新输出和 socket idle 已到达，新分支会错误清理 C 正文。
不能用一个本地代际号证明远端 authority 属于当前 runtime。

公开回归分别将 B 缓存放在 C socket idle 前/后，两者在旧候选均行为 FAIL；
另一个回归限定旧 Bridge 缺字段不能取得新增清理资格。详见 PROCESS E052。
这不是历史 R29 或 095cab00 原 full FAIL 的因果解释。

## 唯一新增事实及所有权

- Bridge runtime snapshot 已有 bridgeSessionId；生产者以它发出可选 status.runtimeSessionId。
- 字段是实际 attachment 身份，不能从 providerSessionId、authority 字符串或本地 generation 推算。
- Provider/appServer 观察与 authority 失效转换不得继承旧 Bridge attachment 身份。
- Dart 协议负责可选、非空、最大 256 字符验证及 JSON round trip。
- SQLite 继续通过 status.toJson/fromJson 保存，不另设缓存或写入者。
- Cubit 新终态清理同时要求 status.runtimeSessionId 等于当前 bound runtime。
  原 source/time/provider/authority/ticket/revision 条件仍然成立；终态 confidence 必须 authoritative。
  runtime producer 在 control 不可用时保留旧 activity 并降级 confidence，不能凭保留的 idle 清流（E056）。

## 兼容与范围

字段可选，V2 event/capability 与现有 RPC 不改版；旧客户端忽略新增字段。
新客户端能读取没有字段的旧 Bridge 状态、保持原 completion 与 pending-turn validation。
缺少身份时不授予本批新增的终态清理资格，不伪造匹配身份。
C1c没有重写旧mutation lease接纳；随后C1e以独立公开契约窄修已知runtime身份的同源缓存归属，
见RUNTIME-AUTHORITY-ENTRY / E065。不能把这两批限定契约当控制权限全链验收，无ID旧组合仍R49。

## 执行与测试门禁

1. 先保存两种 B 缓存顺序、旧 Bridge 反向保护和 wire 身份 round trip 的 red checkpoint。
2. Bridge producer 发出真实身份；剥离不再由该 runtime 拥有的旧身份，运行 Bridge 相关整文件回归。
3. 新清理分支核对具体身份及权威置信度；二十一项 terminal 契约、Dart protocol、真实 SQLite/status 接收回归通过。
4. build 新 Bridge，再运行原三文件七个黑盒；原 receiver、fold、期限与恢复断言不改。
5. 固定 SHA 后完整 Mobile/Bridge、typecheck/analyze/format 与独立复核。
6. 再进入 runtime quarantine 的容量、取消、未来 turn 契约；行为修复与结构迁移分别提交。

回退必须保留 red 输入。若撤销身份字段，也必须同时撤销依赖它的新清理分支；
不能只移除生产字段后保留需要新字段的验收声明。
尚未执行的项记 NOT_RUN，不以旧 Bridge 门禁替代字段变化后的运行。

## 当前验收

完整产品/测试输入 `da3d3f6` 的 Mobile 3370 PASS / 4 SKIPPED、Bridge 2546 PASS / 1 SKIPPED，
新 Bridge build、noEmit、原七黑盒及固定 SHA 独立复核通过（E059）。
后续 `2f95d6d0` 只改测试 null-aware entry；40 项相关用例、格式、1017 既有诊断逐项复查通过（E060）。
产品及黑盒tree未变。C1e限定的控制身份门禁随后通过E065；真实Provider/设备及无ID远端归属仍未验收。
