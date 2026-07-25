# CC Pocket Bridge 1.69.4-compat.1 部署记录

- 来源分支：`integration/mobile-1.109.2-comprehensive-20260725`
- 运行源码提交：`ae17d712`
- 分支当前文档提交：`e8fc9825`
- 版本：`1.69.4-compat.1`
- 新运行目录：
  `/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.4-compat.1-ae17d712`
- 上一运行目录：
  `/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.0-compat.6-4e611c6b`

## 更新边界

只替换现有 `com.ccpocket.bridge` LaunchAgent 的 `BRIDGE_CLI_ENTRY`。保留同一个
用户级 LaunchAgent、同一个 8765 监听端口和全部既有网络/路径设置；不创建第二个
Bridge，不修改会话、镜像、传输、Gallery、手机或 Shorebird 数据。

本次按用户要求先更新 Bridge，没有同时配置 API key。因此新版本会继续对要求
认证的全盘读取、私有 HTTP 和文件修改能力执行安全降级；升级本身不会自动放开
这些权限。

## 更新前验证

- Bridge 源码与 `ae17d712` 一致，后续提交只改文档。
- 生产构建成功，原生 file-browser helper 生成成功。
- 并发全量测试首次为 1670/1672；两个 session catalog 文件监听时序用例在隔离
  环境连续 3 次通过。
- 单线程全量复测：91/91 files、1672/1672 tests 通过。
- 生产依赖安装完成，`npm ls --omit=dev` 通过。
- 隔离端口 18765：`/health` 正常、`/version` 为
  `1.69.4-compat.1`、单监听进程。

## 文件校验

- `dist/cli.js` SHA-256：
  `434ff074850a5be6031d7e9e21b93da9086f560a969929cd219660b72fc8742b`
- `dist/websocket.js` SHA-256：
  `e1dcddde6e9ecca8b6ee4001ef568b40a862ba3096867994c0f3f49de34aa618`

## Live 激活结果

- 更新前 PID：`37155`。
- 更新后 PID：`88496`。
- LaunchAgent：`com.ccpocket.bridge`，状态 `0`。
- TCP 8765：只有 PID `88496` 一个监听者。
- 本机 `/health`：正常。
- 本机 `/version`：`1.69.4-compat.1`。
- Mac 自身 Tailscale IPv4 `/version`：`1.69.4-compat.1`。
- LaunchAgent 中的 `BRIDGE_CLI_ENTRY`、进程命令和 runtime 路径一致。
- runtime 的 `dist/cli.js`、`dist/websocket.js` 与复测后的构建产物逐字节一致。
- 验证时 `/health` 报告 `clients: 0`；因此只确认服务和 Tailnet 入口已就绪，
  不把尚未发生的手机重连写成成功。

激活脚本的失败 trap 未触发，旧 runtime 和更新前 plist 均保留。
