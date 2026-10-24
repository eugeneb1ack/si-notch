[English](README.md) · [Русский](README.ru.md) · [简体中文](README.zh-CN.md)

# si-notch for Hermes

Show Hermes tasks in your Mac's notch: session state, tools, subagents, optional assistant text, token usage and separate profile availability. Works locally on the Mac or through an existing SSH connection.

Plugin **1.15**, bundled with **si-notch 0.4.34**. Use Python 3.10+ from the existing Hermes installation. The plugin needs no pip packages, model credentials, TCP listener or additional service. Remote use also requires trusted key-based SSH login and Unix-socket forwarding. [Revision and verification](REVISION.md).

The plugin is an observer. Human-input notifications direct you to the original Hermes chat or terminal; it does not approve actions or submit answers. Metadata and usage depend on hooks exposed by the installed Hermes version. [Developer guide](../../docs/hermes-plugin-development.md).

## Local Mac installation

1. Open **si-notch → Settings → Connection**, select Hermes and choose **Connect**. Choose the existing local profile and review its destination home.
2. Enable the installed plugin with `hermes plugins enable si-notch`. For a named profile use `hermes -p PROFILE plugins enable si-notch`.
3. Confirm activation, then start a new turn. If the running host did not reload, start a new Hermes session after the current turn finishes.
4. Keep si-notch running. Check **Settings → Diagnostics** for received events and open **Sessions** for the task.

The app records its helper's absolute installation path, including custom app locations. Manual copies also discover `/Applications/si-notch.app` and `~/Applications/si-notch.app`. `SI_NOTCH_CLI` overrides helper selection; a configured override must point to the intended executable. Finder does not inherit shell environment variables: review the destination shown by the app when using a custom `HERMES_HOME` or named profile.

## Independent local and remote profiles

A profile is identified by its stable `instanceId`, not its display name or the fact that Hermes is installed. Local profiles can coexist with profiles on multiple SSH hosts. Choose the local profile in **Settings → Connection → Hermes** before applying setup, or use native `hermes -p PROFILE plugins` commands and that profile's real home. The copied activation command includes the exact local home. Each loaded profile sends its own heartbeat; idle profiles remain listed.

Use a different ID for every new profile. Keep the same ID when updating an existing profile. Native `configure.py setup` creates an ID only if missing; app setup creates one per local profile directory. If a newly cloned profile copied another profile's settings, run `configure.py setup --name "Clone name" --new-instance` only in the new clone. This backs up the clone's settings and leaves the original untouched. Do not copy another profile's pending usage queue or rotate a working profile's ID as an update step.

The Mac binds app-managed SSH traffic to its connection's own endpoint. Keep using the same remote socket path; no plugin configuration migration is needed. Local identity is confirmed through the bundled native helper. Unknown/manual relay origins retain a conservative application fallback rather than hiding a possibly separate local agent. One profile's heartbeat never refreshes another profile or an independent unnamed session.

## Remote installation from si-notch

1. Update the Mac app to 0.4.34 or newer. Open **Settings → Remote SSH → Add connection** and enter a connection name and SSH host/alias.
2. **Check connection** verifies login only. **Check profiles** discovers existing Hermes profiles; select the profiles and their display names.
3. Choose whether each profile may share task/assistant text. Text sharing defaults to off.
4. **Preview changes → Apply plugin changes** installs the bundled observer and relay with backups and asks Hermes to reload. Review the result; a profile without a running gateway loads it on its next start.
5. Use the inspected absolute remote socket path and click **Connect**. A login check alone does not start forwarding.
6. Start a new task. **Sessions** shows tasks; **Agents → your connection** shows each configured profile, including when idle.

Profile names and count are discovered, not predefined. A connected tunnel proves transport only; Online requires a fresh profile event. The loaded plugin announces presence every 30 seconds, so reconnecting normally restores idle presence within one interval. Presence expires after 120 seconds without delivery.

App-managed setup installs the plugin bundled with that app. A native Git installation below owns its selected revision. Reapplying app-managed setup replaces that code; choose one update method per profile.

## Native Hermes installation

Install into the actual profile home, not a project-local `.hermes` directory. Read the full runtime SHA in the [release-specific REVISION.md](https://github.com/eugeneb1ack/si-notch/tree/v0.4.34/plugins/hermes/REVISION.md). The command below uses that immutable runtime commit:

```sh
hermes plugins install eugeneb1ack/si-notch/plugins/hermes --ref 52b6de6fba263745db245f4672e859ca24bc2754 --no-enable
python3 "$HOME/.hermes/plugins/si-notch/configure.py" setup --name "My Hermes" --hide-text
hermes plugins enable si-notch
hermes plugins list
```

For a named profile, put `-p PROFILE` before `plugins` and replace the `configure.py` path with that profile's actual home. Use the existing Hermes Python interpreter if `python3` is unavailable. Review the source and retain the installer's normal checks and consent prompts. The source is this repository, not a catalog entry.

`setup` merges only `si-notch.json`, preserves existing settings and `instanceId`, makes a backup before a change, and creates a private socket directory when needed. It does not edit Hermes `config.yaml`, hooks, `.env`, models, approval policy or services. Native `plugins enable` owns activation. Check its actual result; otherwise start a new session after the current turn.

Options:

| Option | Effect |
| --- | --- |
| `--name "Name"` | Required display label. |
| `--hide-text` / `--show-text` | Disable/enable public task and assistant excerpts. |
| `--socket /absolute/private/events.sock` | Use an explicit endpoint; local Mac or remote forwarded socket. |
| `--helper /absolute/executable` | Select the installed Mac app’s native helper explicitly. |
| `--new-instance` | Give only a newly cloned profile a separate ID, with a settings backup. Never use on an update. |
| `--bundled-relay` | Use the included Python relay instead of a previously configured helper. |

For a local native install, the default socket is the Mac application's `~/.si-notch/run/events.sock`; no SSH is needed. For a remote native install, enter the **absolute socket path printed by setup** in the Mac connection and click **Connect**. Applying app-managed changes after native installation is optional and can replace its code.

## Diagnostics and smoke check

For a native installation, after the Mac is connected:

```sh
python3 "$HOME/.hermes/plugins/si-notch/configure.py" check
```

`state: delivered` means the Mac acknowledged a presence event. This command sends one presence notification; it creates no task and proves no model/tool lifecycle. App-managed profiles may not include `configure.py`; use the app's receipts and the new-session smoke check instead.

Run the [smoke-test prompt](SMOKE_TEST_PROMPT.md) in a new session of the enabled profile. Verify task text when sharing is enabled, Working, two completed tools in Activity, final text and Done. Repeat in a second profile to check isolation. Newly observed request usage should appear when the runtime supplies its accounting hooks. Input questions must be answered in Hermes.

The native package includes [after-install.md](after-install.md) for agent-led connection steps. The [installation/update prompt](INSTALL_PROMPT.md) covers local and remote profiles; [Russian version](INSTALL_PROMPT.ru.md). Remote command success does not establish the state of the Mac UI. Report installation, activation, transport receipt and live UI behavior separately.

## Data and delivery

- Text sharing is off by default. When enabled, task excerpts are capped at 1,600 characters and visible assistant updates/final answers at 4,000 each. It does not stream every token.
- Tool arguments/results, conversation history, hidden reasoning and credentials are not forwarded. Bounded result flags are inspected locally to classify tool failures; todo titles follow text sharing.
- Current model/reasoning settings come from the API request. The project directory comes from Hermes's session-cwd API. Missing fields remain unknown.
- Profile/session IDs are hashed. Preserve `instanceId` across upgrades; use a distinct identity for a profile cloned to another machine. Display names are labels, not identity.
- Lifecycle delivery is bounded and fails open when disconnected. Outcome receipts remain in the private `lifecycle-outbox` until acknowledged. For managed workers, `active-executions` stores opaque native reservation and turn identities; the existing heartbeat reads only that profile’s native ledger to recover a missing final hook. A confirmed interrupted execution closes without success; unknown outcomes remain waiting. Other schemas keep hook-only behavior. Presence does not create work or extend task progress. The worker stops on plugin unload/reload; older runtimes without `on_unload` retain startup presence only.
- Numeric request usage uses the private `usage-outbox`: at most 2,000 records of 8 KiB, removed only after durable `usage_committed`. It contains numeric counts, opaque IDs, model/profile labels and timestamps, not prompts or results. Overflow marks subsequent data incomplete. The plugin never retries model requests.
- Input already includes cache reads/writes; output already includes reasoning. A request's stable ID prevents duplicate totals after replay. Child requests preserve their parent turn. Old remote history is not imported. Updating app sources alone does not update an already-installed remote plugin.

## Recovery

| Symptom | Check |
| --- | --- |
| Missing socket / `not_connected` | Start si-notch; verify the local endpoint or click **Connect** for the selected SSH host and absolute remote path. |
| `relay_failed` | Confirm helper/socket settings, plugin load and app pause state. Use the bounded diagnostic error; do not weaken permissions or host-key checks. |
| Tools but no text | Enable sharing for this profile and start a new turn. Some runtimes provide no interim-message hook. |
| Installed / Last seen | Plugin files exist but no recent event arrived. A tunnel alone does not establish profile activity. Allow one heartbeat interval after reconnect. |
| Forwarding failure / stale socket | Disconnect the affected tunnel. Use guarded recovery below, or the app's recovery result. Do not remove a live/held socket. |

For a native package, preview stale-socket recovery before applying:

```sh
python3 "$HOME/.hermes/plugins/si-notch/configure.py" repair-socket
python3 "$HOME/.hermes/plugins/si-notch/configure.py" repair-socket --apply
```

Recovery requires a refused connection, private ownership/permissions, a successful `lsof` check with no holder, and unchanged socket identity. It renames the stale socket to a backup. Missing or failed diagnostics leave it intact. Reconnect and run `check`. Never enable `StreamLocalBindUnlink` globally to bypass this check.

## Update, disable and remove

Choose the tested full release SHA explicitly. Back up `si-notch.json`, pending `usage-outbox` / `lifecycle-outbox`, and `active-executions` outside the plugin directory. Preserve `instanceId`, text/helper/socket settings and unknown fields. A pinned native install needs an explicit re-pin through the installed CLI; review its source/scan and use the same official source. Do not remove the plugin first or pass `--new-instance` during an update. Older observers remain compatible, but worker-outcome recovery requires updating the remote observer to 1.15; installing the Mac app alone does not update remote code. Confirm the native installer’s activation/reload result; use a new session when necessary. Do not force replacement of a plugin from an unrelated source.

```sh
hermes plugins disable si-notch
# To uninstall a native installation after reviewing its local settings/queue:
hermes plugins remove si-notch
```

Add `-p PROFILE` for a named profile. These commands stop/remove the selected plugin through Hermes; they do not disconnect the Mac tunnel. Disconnect it separately. For app-managed remote profiles, deselect them and apply the previewed changes before removing the Mac connection. Removing the connection alone does not uninstall the remote plugin. Existing local History/Usage records remain unless cleared separately in the app.

## Compatibility and verification

The official [plugin API](https://hermes-agent.nousresearch.com/docs/user-guide/features/plugins) and [hook contract](https://hermes-agent.nousresearch.com/docs/user-guide/features/hooks) can evolve. Missing hooks reduce available data; they do not grant response capabilities. Automated fixtures validate mappings, privacy, identity, numeric retries, transport and setup behavior. Live remote verification is revision-specific: see [REVISION.md](REVISION.md) and [feature status](../../docs/parity.md). Successful installation or presence delivery is not a substitute for a real turn on your Hermes version and entry point.

[SSH guide](../../docs/remote-connections.md) · [Custom agent API](../../docs/custom-agents.md) · [Plugin development](../../docs/hermes-plugin-development.md) · [License](LICENSE).
