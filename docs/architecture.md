[English](architecture.md) · [Русский](ru/architecture.md) · [简体中文](zh-CN/architecture.md)

# Local API

The bundled helper sends JSON to `~/.si-notch/run/events.sock`. Use a stable `session_id` and your agent’s name as `provider`.

```sh
~/Applications/si-notch.app/Contents/Helpers/si-notchctl emit \
  '{"event":"agent.working","session_id":"my-task","provider":"custom","title":"Check build","message":"Running tests"}'
```

Common events: `session.start`, `agent.working`, `agent.waiting`, `agent.completed`, `agent.failed`, `session.end`, `tool.start`, `tool.finish`. Optional fields include `title`, `message`, `cwd`, `tool_name`, `model`, `id` and `sequence`. Unique event IDs and ordered sequences prevent duplicate or stale updates. Use the same `turn_id` across observers of one turn to deduplicate its sounds; use a new ID for the next turn. The parser in [AgentEvent.swift](../Sources/SINotchCore/AgentEvent.swift) defines the accepted fields.

## Decisions

```sh
~/Applications/si-notch.app/Contents/Helpers/si-notchctl request \
  '{"session_id":"my-task","provider":"custom","message":"Allow this action?"}' --timeout 60
```

`request` waits for a response for this request only. Exit codes: **0** allow/answer, **1** deny, **2** invalid input, timeout or disconnection. The caller must enforce the returned decision. si-notch does not run the requested action.

## Transport and code

### Interaction boundaries

`AgentInteraction` is the provider-independent presentation contract: an opaque identity, session, deadline, questions/options and explicitly offered actions. `AgentInteractionView` renders that contract for every provider. It contains no provider wire format or permission policy. `AppModel` revalidates the current identity and deadline before routing an explicit click to its owning adapter. A live hook takes precedence over a Desktop observation of the same session, so two channels cannot offer competing buttons.

The hook transport retains its existing per-connection reply closure and one-shot token. It supports Allow once/Deny and free-text questions. `CodexInteractionState` projects Desktop request content into ephemeral memory; `CodexInteractionBridge` owns versioned Desktop responses and their confirmation lifecycle. A new adapter must supply a real request-bound response channel before it can expose actions. Observing `waiting` or `approval` alone never creates response capabilities.

Desktop IPC is an internal compatibility interface, not a public extension API. The adapter accepts stream version 11, refreshes the exact request and discovers its owner before sending a decision once. It requires a matching RPC acknowledgement and stream resolution; asynchronous answers also require the original turn and an accepted question identity. Unknown versions, unsupported kinds, changed ownership, expired requests, disconnects and uncertain acknowledgements fall back to the originating app. Uncertain mutations are never replayed. Questions expire locally after five minutes; expiration grants nothing. A future upstream change can therefore remove inline controls without granting permissions or submitting guessed responses.

Permanent or session-scoped permissions are shown only when the exact request advertises them. A command-rule grant carries precisely its advertised rule. There is no global auto-approve policy. Request bodies and answers are not added to history or usage storage. Native asynchronous reply envelopes are excluded from titles and public snippets.

When no response channel is available, the card explicitly asks the user to approve/reject or answer in the named harness. It opens the exact task or originating application when navigation metadata exists; otherwise it instructs the user to open the original chat or terminal. A missing navigation destination never produces a fictitious Open action in the fallback panel.

| Integration | Inline response path | Fallback |
| --- | --- | --- |
| Codex Desktop | Versioned owner-bound compatibility adapter: command/file approvals, blocking questions, asynchronous choices/free text | Unsupported request/version, unavailable owner, stale or unconfirmed response: open Codex |
| Codex CLI | Existing explicitly configured PermissionRequest hook: Allow once/Deny | Native Codex permission UI |
| Claude Code | Existing optional permission bridge: Allow once/Deny | Native Claude UI for unsupported tools/inputs or absent bridge |
| Pi | Current extension observes UI prompt start/end; no response capability is claimed | Original Pi terminal |
| Hermes | Current plugin observes human-input request/resolved; no response capability is claimed | Original Hermes chat or terminal |
| Custom local producer | Existing request/reply socket, using the same shared controls | Producer's own UI on timeout/disconnect |

The table describes capabilities, not live end-to-end verification of every provider. See [verification](verification.md) and [feature status](parity.md).

### Desktop task lifecycle

Thread discovery and read-state notifications subscribe to local state without creating a task. History-only rollout observations reconcile the archive without admitting a live session. A Desktop task requires a concrete in-progress turn or an explicit live lifecycle observation. Its completion is emitted only for an observed turn; subsequent history snapshots and metadata changes cannot replay that outcome. Concrete completed, failed or interrupted turn states take precedence over stale thread runtime flags. A genuinely new turn in the same conversation can establish activity again. Older file hints cannot replace a more recent observed turn; revision-checked stream activity takes precedence even when a file clock is ahead.

### Socket limits

- JSON messages are limited to 128 KiB; `emit` waits up to one second for acknowledgement.
- The socket and its directory use modes 0600 and 0700 and require the same user. Up to 16 clients and eight pending requests are supported.
- Override the socket with `SI_NOTCH_SOCKET` or `--socket /absolute/path`.
- `SINotchCore` contains session state and parsing; `SINotchTransport` handles IPC; `SINotch` contains AppKit/SwiftUI and observers.
- Live session state is held in memory; a separate local text archive survives clearing completed cards and app restarts. Preferences use UserDefaults.

Run `si-notchctl --help` for `run`, `hook`, `notify`, `paths` and `status`.

## Agent availability

Sessions contains working, waiting, approval, completed and failed tasks. Idle agent connections and Codex lifecycle placeholders without task context are listed only under Agents. Multiple sessions of one provider share one availability row. Online means a native application is running or an event was received in the last two minutes; older observations show Last seen. Installed alone does not mean online.

Codex sessions tagged `internal` or `subagent` are excluded from task lists. Custom and unclassified sources remain eligible. API clients can mark internal sessions with the optional `is_internal_session` field, including when the source becomes known after initial events.

## Local text history

History is the last Sessions filter, after All, Working, Attention and Done, and remains available without live cards. Each record contains one request/turn, public assistant replies and available command text. Codex Desktop and local rollouts and Pi files provide explicit text items. Other integrations retain the text they already share; si-notch does not enable optional remote content sharing or reconstruct missing commands. Reasoning, tool output, attachments and permission payloads are excluded. Old conversations are not imported.

`HistoryController` sends immutable events to a serial utility queue. `HistoryStore` stores private JSON records and a metadata-only index under `~/Library/Application Support/si-notch/History` (directory 0700, files 0600). The list shows 50 records at a time and reads a record only when opened. At most eight record bodies remain cached. There is no archive polling or idle timer. Changed text is coalesced for up to two seconds, terminal events flush promptly, and normal shutdown drains buffered writes.

Defaults are 1,000 records and 200 MiB including the index. Custom limits accept 1–10,000 records and 1–2,048 MiB; oldest records are removed until both limits hold. The metadata index is additionally capped at 4 MiB. Each text item is bounded at 16,384 characters and a record at 256 KiB; unusually long records keep the request and latest text and display a truncation notice. Search covers request titles, projects and providers. Clear History cancels buffered writes and fences recent cleared turns against late snapshots. Disabling recording preserves existing records. Known token/password forms are redacted; local text can still contain private information.

Custom event producers may supply `history_items`: an array of `{ "id": "stable-item-id", "role": "user|assistant|command", "text": "public text" }`. Use stable item IDs for streaming replacement and a fresh `turn_id` per request. The envelope accepts up to 64 items and 128 KiB of item text, within the transport's overall payload limit. Never send tool output or generic argument dictionaries in these items.

For an implementation walkthrough, field tables and runnable isolated checks, see [Connect a custom agent](custom-agents.md).

An archived `/goal` may span several turns. History separately reconciles its original record with an explicit goal completion, matching the local session, creation identity, objective and original turn. A resumed turn completing by itself is insufficient. The reader accepts native goal updates and narrowly correlated structured `update_goal` results, reads in bounded chunks on the history utility queue, and retains no generic tool output. It changes only the existing record's status; ordinary cancelled turns stay cancelled. Unknown log formats or missing evidence leave the record unchanged.
