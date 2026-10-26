**si-notch in action**

https://github.com/user-attachments/assets/9cf4d09d-76f1-4195-9552-4372971dfd0f

[English](README.md) · [Русский](README.ru.md) · [简体中文](README.zh-CN.md)

# si-notch

AI agent tasks in your Mac’s notch.

## Features

- Separate views for sessions and agent availability.
- Live status, messages, tools and subagents, with distinct agent colors.
- Animated companions and optional notification sounds.
- Codex, Pi, Claude Code, OpenCode, Hermes, Gemini CLI, Copilot CLI, Cursor Agent and custom agents.
- Token usage by task and session, with subagent attribution and cache breakdown.
- Local text history, JSON API and SSH connections.

## Install

Download the DMG from [Releases](https://github.com/eugeneb1ack/si-notch/releases/latest), open it and drag `si-notch.app` to Applications.
Open **Settings → Connection** to connect agents.

macOS 14+, Apple Silicon. The current build is ad hoc signed and not notarized. Intel builds have not been tested.

[Agent setup](docs/agent-integrations.md) · [Custom agent guide](docs/custom-agents.md) · [SSH](docs/remote-connections.md) · [Feature status](docs/parity.md)

Integration depth depends on the agent and its available APIs. Hermes and Pi input notifications direct you to the original chat or terminal; they do not submit answers. Supported inline decisions require a live, request-bound response channel. See [interaction boundaries](docs/architecture.md#interaction-boundaries).

Updates are checked at launch and every six hours. Open **Settings → About** to download, verify and install a new version. Stable and beta channels are available. [Release setup](docs/updates.md).

## Supported Languages

English, Russian, Simplified Chinese.

## Build

```sh
scripts/test.sh
scripts/build-app.sh release
scripts/build-dmg.sh
```

Requires Xcode 26+, Python 3 and Node.js. Output: `build/si-notch-macos-arm64-VERSION.dmg` and `build/si-notch.zip`, where `VERSION` is the version in `release.json`.

## Data and license

Session data is processed locally. History stores requests, replies and available command text on this Mac, without command output. Defaults are 1,000 records and 200 MB; adjust either limit, disable recording or clear the archive in Settings → History. Older conversations are not imported.

[si-notch Source License 1.0](LICENSE) allows study, installation, building, modification and free redistribution. Selling the app or modified versions is prohibited. This is a custom **source-available** license, not the MIT License or an OSI-approved open-source license. Internal business use is permitted; the full license defines redistribution and no-sale conditions.

Bundled event sounds by Juhani Junkala (SubspaceAudio) are separately released under [CC0](Sources/SINotch/Resources/Sounds/SubspaceAudio-LICENSE.txt).

Contact: [dis/root](https://disroot.website/).

[Agent plugins](plugins/README.md) · [Hermes setup](plugins/hermes/README.md) · [Develop a Hermes plugin](docs/hermes-plugin-development.md) · [Contributing](CONTRIBUTING.md)
