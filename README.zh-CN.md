**si-notch 演示**

https://github.com/user-attachments/assets/9cf4d09d-76f1-4195-9552-4372971dfd0f

[English](README.md) · [Русский](README.ru.md) · [简体中文](README.zh-CN.md)

# si-notch

在 Mac 刘海中查看 AI 智能体任务。

## 功能

- 分别显示会话和智能体连接状态。
- 实时状态、消息、工具和子智能体，每个智能体有独立配色。
- 动画伙伴和可选的声音通知。
- 支持 Codex、Pi、Claude Code、OpenCode、Hermes、Gemini CLI、Copilot CLI、Cursor Agent 和自定义智能体。
- 按任务和会话统计令牌用量，包含子智能体归属和缓存明细。
- 本地文本历史、JSON API 和 SSH 连接。

## 安装

从 [Releases](https://github.com/eugeneb1ack/si-notch/releases/latest) 下载并打开 DMG，将 `si-notch.app` 拖入 Applications。
在 **设置 → 连接** 中连接智能体。

需要 macOS 14 或更高版本及 Apple Silicon。当前构建使用 ad hoc 签名，尚未公证。Intel 构建尚未测试。

[连接智能体](docs/zh-CN/agent-integrations.md) · [API](docs/zh-CN/architecture.md) · [SSH](docs/zh-CN/remote-connections.md) · [功能状态](docs/zh-CN/parity.md)

集成能力取决于各智能体的 API。Hermes 和 Pi 的输入通知会引导用户回到原始聊天或终端，不会提交回答。刘海内的决策需要与当前请求绑定的有效响应通道。

完整开发指南：[自定义智能体（英文）](docs/custom-agents.md) · [俄文](docs/ru/custom-agents.md) · [Hermes 插件开发（英文）](docs/hermes-plugin-development.md)。

启动时及每六小时检查更新。在 **设置 → 关于** 中下载、验证并安装新版本，支持稳定版和测试版渠道。[发布更新](docs/zh-CN/updates.md)。

## 支持的语言

英语、俄语、简体中文。

## 构建

```sh
scripts/test.sh
scripts/build-app.sh release
scripts/build-dmg.sh
```

需要 Xcode 26+、Python 3 和 Node.js。输出文件：`build/si-notch-macos-arm64-VERSION.dmg` 和 `build/si-notch.zip`，其中 `VERSION` 为 `release.json` 中的版本号。

## 数据与许可

会话数据在本机处理。历史将请求、回复和可用命令文本保存在此 Mac 上，不包含命令输出。默认上限为 1,000 条记录和 200 MB；可在设置 → 历史中调整上限、关闭记录或清空存档。不导入旧对话。

[si-notch Source License 1.0](LICENSE) 允许研究、安装、构建、修改和免费分发。禁止出售本应用及其修改版本。这是自定义的 **source-available** 许可证，不是 MIT 许可证，也不是 OSI 批准的开源许可证。允许企业内部使用；分发和禁止销售的完整条件以许可证为准。

联系：[dis/root](https://disroot.website/)。

[代理插件](plugins/README.md) · [Hermes 安装及提示词](plugins/hermes/README.zh-CN.md)
