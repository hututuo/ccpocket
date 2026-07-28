# Bridge 1.69.4-compat.3 与 Mobile build 205 交付

Status: active.

## 目的

为当前综合修复源码生成包含新原生宿主能力的 `1.109.3+205` AltStore 输入 IPA，
并把 Mac 后台 Bridge 从 `1.69.4-compat.2` 更新到
`1.69.4-compat.3`。

## 全局修改

- 新增版本化 runtime：
  `/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.4-compat.3-8c1d9907`
- 更新：
  `/Users/huyiyang/Library/LaunchAgents/com.ccpocket.bridge.plist`
- 因 Tailscale TCP Serve 已把 Tailnet 8765 转发到本机
  `127.0.0.1:8765`，Bridge 监听由 `0.0.0.0` 收窄为 loopback，避免重启后的
  端口冲突。
- 保留 compat.2 runtime 作为回滚点。
- 没有修改会话、镜像、传输、Gallery 或手机数据。

## 交付物与验证

- IPA：
  `/Users/huyiyang/Documents/Downloads/CC-Pocket-1.109.3-build205-comprehensive-8c1d9907-AltStore.ipa`
- SHA-256：
  `94db9907128f21338165aee1cf15626e588813528d4bbf583e18e5cbc6b50ceb`
- Bridge 本机 health 正常，版本为 `1.69.4-compat.3`，只有一个 loopback
  8765 监听者。
- 详细构建、测试、Cloud 边界和清理记录见
  `../runs/20260728-230109_ccpocket-build205-ipa/DEPLOYMENT.md`。
- 回滚见
  `../backups/20260728-232718_bridge-1.69.4-compat.3-8c1d9907-deploy/README.md`。

## 未完成的发布门禁

- IPA 尚未由 AltStore 重签或安装到物理 iPhone。
- 手机经 Tailnet 重连和原生能力尚未真机验收。
- 当前 Firebase 账号没有可部署项目，Cloud Function 未更新；App 仍使用 dummy
  Firebase 配置。
- 未发布 Shorebird release/patch，未改变 owner/stable channel，未 push 或合并
  稳定分支。
