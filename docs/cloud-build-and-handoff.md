# CC Pocket 云端构建与跨会话接手

## 公开源码入口

源码仓库是 `https://github.com/hututuo/ccpocket`。`.project-context.json` 只记录
项目身份和私有资料入口，不包含本机路径、密钥、token、登录态、真实会话库或内部
排障正文。

## 私有开发资料

内部进度、架构、决策、交接和验证证据位于私有仓库
`https://github.com/hututuo/project-dev-context` 的
`projects/hututuo--ccpocket/`。没有该仓库权限时只能读取公开源码入口，不能声称
已经完整接手。

## CI 边界

`.github/workflows/cloud-checks-candidate.yml` 是非发布流水线：

- `checks` 运行 Bridge、Mobile 和 Functions 的现有测试/静态检查；
- `candidate` 在检查成功后构建 Bridge 产物和无签名 arm64 iOS IPA，并上传为运行号
  绑定的 artifact；
- 默认情况下 checks 失败会阻止 candidate；仅在明确的 `workflow_dispatch` 手动输入
  `run_candidate_after_failed_checks=true` 时，才允许生成用于定位的未签名候选，且
  该候选必须标记为 checks-failed，不能被当作可发布版本；
- 不读取签名、Shorebird、App Store、npm 发布或生产 Bridge 凭据；
- artifact 不是公开 Release，也不代表真实安装、运行、OTA 或真机验收通过。

候选清单必须同时记录源码完整 SHA、GitHub run id、平台/架构、文件名、大小、
SHA-256 和签名状态。构建失败、跳过、缓存命中和未运行必须原样报告。
