---
status: accepted
---

# 从 GitHub Releases 检查更新并在应用内下载安装包

DevEnv 以 Private Preview 形式通过公开的 GitHub 仓库 `my-hosted/DevEnv` 发布，早期只能由测试者手动前往 Releases 页面下载。为了降低升级成本又不引入尚不具备的分发信任链，DevEnv 在应用内提供「检查更新 + 下载安装包」，但不自动替换已安装的 App。

## 已确认的决定

- 更新来源是公开 GitHub Releases API 的**列表**端点 `/repos/my-hosted/DevEnv/releases`，不使 `/releases/latest`：DevEnv 的所有发布都标记为 `prerelease`，而 `/latest` 只返回最新的非预发布 Release，会得到 404。
- 选择规则：过滤掉 `draft`，按语义化版本从高到低排序，取第一个带 `.dmg` 资产的版本；默认把 `prerelease` 视为候选，因为当前没有稳定版通道。
- 版本比较使用内置的语义化版本实现（支持 `v` 前缀、预发布标识与构建元数据），与 `CFBundleShortVersionString` 比较；`CURRENT_PROJECT_VERSION` 仅作展示，不参与比较。
- 下载在应用内完成，不打开浏览器：通过 `URLSessionDownloadTask` 下载匹配的 `.dmg` 到用户「下载」目录并上报进度。
- 下载后校验完整性：优先读取 Release 中的 `.sha256` 资产解析摘要，其次使用资产 `digest` 字段；校验通过才允许打开，失败则删除并提示重试。校验只说明文件与发布摘要一致，不构成代码签名或公证信任。
- 不自动安装。下载完成后只提供「打开安装包」与「在 Finder 中显示」，由用户手动把 App 拖入「应用程序」替换旧版；自动替换安装留待 Developer ID 签名与 Apple 公证（issue #77）具备条件后再评估。
- 检查时机：主窗口首次出现时静默检查一次；用户可随时通过菜单栏「检查更新…」和 App 菜单「检查更新…」手动触发。发现新版本且未被「跳过此版本」时自动呈现更新窗口。
- 限制检查频率：未登录的 GitHub API 每小时只有 60 次额度，自动检查限制为**每 24 小时最多一次**，并持久化上次自动检查时间（即使失败也记录，避免 403 后反复重试）；手动检查有 **30 秒冷却**，避免连续点击耗尽额度。只有真正的频率限制（`429`，或 `403` 且 `X-RateLimit-Remaining` 为 `0` / 带 `Retry-After`）才提示「访问频率受限」，并读取 `X-RateLimit-Reset` / `Retry-After` 给出可重试时间；其他 `403`（例如仓库无权限或被拦截）按普通 HTTP 错误处理，不误报为限流。
- 「跳过此版本」按 `CFBundleShortVersionString` 记录到 `UserDefaults`，之后启动不再主动提示该版本，但手动检查仍会显示。

## 对现有模型的影响

新增一个进程内的 Update Controller，持有检查与下载状态，不写入项目记录、运行配置或 Machine Snapshot，也不改变任何既有持久化 schema。除「跳过此版本」外不新增持久化状态。

## 实现边界

DevEnv 只读取公开的 Release 元数据与用户下载的 DMG，不据此安装依赖、不启动项目命令，也不修改正在运行的 Run Session。更新检查失败（网络错误、GitHub 频率限制、无可用版本）只影响更新窗口内的提示，不阻断 App 其他功能。
