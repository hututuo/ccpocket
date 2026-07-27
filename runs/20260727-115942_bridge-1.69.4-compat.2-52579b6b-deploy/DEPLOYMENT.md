# CC Pocket Bridge 1.69.4-compat.2 部署记录

- 来源分支：`fix/mobile-comprehensive-v02-20260726`
- 运行源码提交：`52579b6bff306a991ffdf95a880d773bcc62cf89`
- 版本：`1.69.4-compat.2`
- 新运行目录：
  `/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.4-compat.2-52579b6b`
- 更新前运行目录：
  `/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.4-compat.1-ae17d712`

## 更新边界

只替换现有 `com.ccpocket.bridge` LaunchAgent 的 `BRIDGE_CLI_ENTRY`。保留同一个
用户级 LaunchAgent、同一个 8765 监听端口和全部既有网络、路径、鉴权及文件传输
设置；不创建第二个 Bridge，不修改会话、镜像、传输、Gallery、手机或
Shorebird 数据。

## 更新前验证

- Bridge 全量测试：94/94 files、1745/1745 tests 通过。
- 生产构建与原生 file-browser helper 构建通过。
- 生产依赖使用 `npm ci --omit=dev --ignore-scripts` 安装，再单独构建 helper；
  `npm ls --omit=dev` 通过。
- 隔离端口 18765：`/health` 正常、`/version` 为
  `1.69.4-compat.2`、单一监听进程。
- Flutter 全量测试：2363 通过、4 个环境 smoke skip、0 失败。
- Flutter analyze：0 error、0 warning；55 个仓库既有 info。
- iOS Simulator Debug 构建通过。
- RunnerTests：27/27 通过。

## 文件校验

- `dist/cli.js` SHA-256：
  `434ff074850a5be6031d7e9e21b93da9086f560a969929cd219660b72fc8742b`
- `dist/websocket.js` SHA-256：
  `a71c0174b3953996ed88497cc4088ec47a16087da4c3a3b69983e7e7b6e39073`

## Live 激活结果

- 更新前 PID：`88496`。
- 更新后 PID：`95873`。
- LaunchAgent：`com.ccpocket.bridge`，配置 lint 通过。
- TCP 8765：只有 PID `95873` 一个监听者。
- 本机 `/health`：`status=ok`。
- 本机 `/version`：`1.69.4-compat.2`。
- LaunchAgent 中的 `BRIDGE_CLI_ENTRY`、进程命令和新 runtime 路径一致。
- runtime 的 `dist/cli.js`、`dist/websocket.js` 与本工作树构建产物一致。
- 验证时 `/health` 报告 `clients: 0`、`sessions: 0`；因此只确认服务端已
  就绪，不把尚未发生的手机客户端重连写成成功。
- Mac 自身 Tailscale IPv4 的版本探针在 3 秒连接门限内超时；本次没有修改
  Tailscale、公开 URL 或网络配置，也不把 Tailnet 可达性写成已验收。

激活脚本的失败 trap 未触发，更新前 runtime 和 plist 均保留为直接回滚点。
