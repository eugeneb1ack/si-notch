[English](../updates.md) · [Русский](../ru/updates.md) · [简体中文](updates.md)

# 更新

应用在启动时及每六小时检查 GitHub Releases。在 **设置 → 关于** 中可以关闭后台检查、选择稳定版或测试版，也可以手动检查。新版本会显示在关于页和菜单栏菜单中。点击 **安装并重新启动** 后开始安装，保留应用和智能体配置。

首次安装使用 DMG，更新使用 ZIP 和 `update.json`。应用会验证 Ed25519 签名、ZIP 大小和 SHA-256、应用标识符、版本、构建号以及代码签名。替换或启动失败时恢复上一版本，不安装常驻特权助手。

更新来自此仓库的公开 Releases，无需 GitHub 账号。当前构建采用 ad hoc 签名；Developer ID 签名和公证尚未完成。

## 发布版本

修改 `release.json` 中的 `version` 和 `build`，添加发布说明并提交。测试版使用 `-beta.1` 后缀。构建和发布命令见[英文说明](../updates.md#publish-a-release)。

在 `docs/release-VERSION.md` 中用英文描述用户可见的问题修复。GitHub Releases 和应用更新说明使用同一文件。

Ed25519 私钥必须保存在仓库之外并安全备份；应用内固定公钥。不要将私钥提交到 Git 或发布附件。测试版不会替换最新稳定版。

[GitHub Actions](../../.github/workflows/ci.yml)在每次推送和 pull request 时运行测试、验证 ZIP 并构建 DMG。维护者在本机使用私钥签名和发布，应用不包含 GitHub 令牌。

## 保留发布版本

[Release retention](../../.github/workflows/release-retention.yml) 在每次发布稳定版或测试版后自动运行，包括在 GitHub 上手动发布。按照发布时间保留三个已发布版本，其中一个名额始终保留给当前的稳定版 **Latest**。旧版本及其附件会被删除；草稿、Git 标签和源代码历史保持不变。

清理任务按顺序执行，每次删除前重新检查 Latest。API 错误或元数据不一致会停止清理，不会撤销新版本。修复错误后可通过 **Actions → Release retention → Run workflow** 重新运行。任务仅使用 GitHub 的临时令牌和 `contents: write` 权限，无需添加密钥。如果将发布移入使用 `GITHUB_TOKEN` 的工作流，发布后必须显式调度清理工作流，因为此类发布事件不会触发其他工作流。

在已登录 GitHub CLI 的本机上运行 `python3 scripts/prune-releases.py --repo eugeneb1ack/si-notch` 可预览清理计划；只有添加 `--apply` 才会删除。正常发布命令无需额外操作。

## 插件更新

“关于”和菜单栏会显示此版本新增或更新的插件，包括名称、版本和 GitHub 安装指南。插件需要单独安装，应用更新后仍可查看这些链接。此列表说明版本中的变更，不代表已检查每个远程配置中的插件版本。
