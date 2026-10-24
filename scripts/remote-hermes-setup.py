#!/usr/bin/env python3
"""Bounded si-notch setup inside Hermes' existing Python environment. JSON in/out."""

import base64
import copy
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import stat
import subprocess
import sys
import tempfile

import yaml


MAX_BYTES = 512 * 1024


def sha(data):
    return hashlib.sha256(data).hexdigest()


def safe(path):
    for item in [*reversed(path.parents), path]:
        if item.is_symlink():
            raise ValueError("Symlink is not supported: " + str(item))
    return path


def read(path, limit=MAX_BYTES):
    safe(path)
    if not path.exists():
        return None
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > limit:
        raise ValueError("Unsafe or oversized file: " + str(path))
    return path.read_bytes()


def object_file(path, *, is_yaml=False):
    data = read(path)
    value = (yaml.safe_load(data) if is_yaml else json.loads(data)) if data else {}
    if value is None:
        value = {}
    if not isinstance(value, dict):
        raise ValueError("Expected a settings object: " + str(path))
    return value


def plugin_enabled(config):
    plugins = config.get("plugins") or {}
    if not isinstance(plugins, dict):
        raise ValueError("Invalid plugins settings")
    enabled, disabled = plugins.get("enabled") or [], plugins.get("disabled") or []
    if not isinstance(enabled, list) or not isinstance(disabled, list):
        raise ValueError("Invalid plugin allow-list")
    ours = lambda value: isinstance(value, str) and value.rsplit("/", 1)[-1] == "si-notch"
    return any(map(ours, enabled)) and not any(map(ours, disabled))


def inspect(home, relay, socket_path):
    safe(home)
    if not home.is_dir() or home.stat().st_uid != os.getuid():
        raise ValueError("Hermes directory must belong to this user")
    if not (home / "config.yaml").is_file():
        raise ValueError("Hermes config.yaml was not found")
    roots = [("default", home)]
    profiles_dir = safe(home / "profiles")
    if profiles_dir.is_dir():
        roots += [(p.name, safe(p)) for p in sorted(profiles_dir.iterdir())
                  if p.is_dir() and (p / "config.yaml").is_file()]
    profiles, files = [], {}
    identities = set()
    for identifier, root in roots:
        if not identifier or len(identifier) > 80 or not all(c.isascii() and (c.isalnum() or c in "-_") for c in identifier):
            raise ValueError("Unsupported profile identifier")
        config = object_file(root / "config.yaml", is_yaml=True)
        plugin = root / "plugins/si-notch"
        settings = object_file(plugin / "si-notch.json")
        metadata = object_file(root / "profile.yaml", is_yaml=True)
        name = settings.get("displayName") or metadata.get("display_name") or identifier
        if not isinstance(name, str) or not name.strip() or len(name) > 128:
            name = identifier
        instance = settings.get("instanceId")
        if not isinstance(instance, str) or not instance or len(instance) > 4096:
            instance = sha((platform.node() + ":" + str(root)).encode())
        connection_id = "hermes-instance-" + sha(instance.encode())[:32]
        if connection_id in identities:
            raise ValueError("Hermes profiles share an instanceId. Give only the new clone a distinct identity with configure.py setup --new-instance; preserve existing profile IDs.")
        identities.add(connection_id)
        profiles.append({"connection_id": connection_id, "id": identifier, "home": str(root), "display_name": name,
                         "enabled": plugin_enabled(config), "show_session_text": settings.get("showSessionText") is True,
                         "plugin_installed": (plugin / "__init__.py").is_file()})
        for path in [root / "config.yaml", root / "profile.yaml", plugin / "__init__.py", plugin / "plugin.yaml", plugin / "configure.py", plugin / "si-notch.json"]:
            data = read(path)
            files[str(path)] = sha(data) if data is not None else None
    data = read(relay)
    files[str(relay)] = sha(data) if data is not None else None
    parent = safe(socket_path.parent)
    mode = None
    if parent.exists():
        info = parent.stat()
        if not parent.is_dir() or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
            raise ValueError("Socket directory must belong to this user and have mode 0700")
        mode = stat.S_IMODE(info.st_mode)
    snapshot = sha(json.dumps({"files": files, "socket_parent_mode": mode}, sort_keys=True).encode())
    return {"snapshot": snapshot, "home": str(home), "relay_path": str(relay), "socket_path": str(socket_path),
            "profiles": profiles, "socket_ready": socket_path.is_socket()}, files


def sources(request):
    result = {}
    markers = {"plugin_python": b"Hermes Agent observer plugin for si-notch",
               "manifest": b"name: si-notch", "relay": b"Portable remote-side si-notchctl subset"}
    for key, marker in markers.items():
        data = base64.b64decode(request.get("sources", {}).get(key, ""), validate=True)
        if not data or len(data) > 128 * 1024 or marker not in data:
            raise ValueError("Invalid bundled adapter: " + key)
        result[key] = data
    if "configure" in request.get("sources", {}):
        data = base64.b64decode(request["sources"]["configure"], validate=True)
        if not data or len(data) > 128 * 1024 or b"Configure or diagnose only this si-notch plugin" not in data:
            raise ValueError("Invalid bundled adapter: configure")
        result["configure"] = data
    return result


def plan_identity(request, bundled, home, socket_path):
    identity = {"snapshot": request.get("snapshot"), "profiles": request.get("profiles"),
                "sources": {k: sha(v) for k, v in bundled.items()}, "socket_path": str(socket_path),
                "home": str(home), "cli": request.get("hermes_cli", "~/.local/bin/hermes")}
    return sha(json.dumps(identity, sort_keys=True).encode())


def plan(request, home, relay, socket_path):
    current, _ = inspect(home, relay, socket_path)
    if request.get("snapshot") != current["snapshot"]:
        raise ValueError("Remote settings changed. Check profiles and preview again.")
    bundled = sources(request)
    selected = request.get("profiles")
    if not isinstance(selected, list) or len(selected) > 64:
        raise ValueError("Invalid profile selection")
    by_id = {p["id"]: p for p in current["profiles"]}
    writes, actions, changes, seen = {}, [], [], set()

    def propose(path, data, marker=None, mode=0o600):
        previous = read(path)
        if previous is not None and marker is not None and marker not in previous:
            raise ValueError("Refusing to overwrite another integration: " + str(path))
        if previous != data:
            writes[str(path)] = (data, mode)

    for value in selected:
        identifier = value.get("id")
        if identifier not in by_id or identifier in seen:
            raise ValueError("Profile selection is stale or contains duplicates")
        seen.add(identifier)
        profile = by_id[identifier]
        enabled, text = value.get("enabled"), value.get("show_session_text")
        name = value.get("display_name")
        if not isinstance(enabled, bool) or not isinstance(text, bool) or not isinstance(name, str) or not name.strip() or len(name) > 128 or any(ord(c) < 32 or ord(c) == 127 for c in name):
            raise ValueError("Invalid profile settings")
        root = Path(profile["home"])
        before_count = len(writes)
        if enabled:
            plugin = root / "plugins/si-notch"
            propose(plugin / "__init__.py", bundled["plugin_python"], b"Hermes Agent observer plugin for si-notch")
            propose(plugin / "plugin.yaml", bundled["manifest"], b"name: si-notch")
            if "configure" in bundled:
                propose(plugin / "configure.py", bundled["configure"], b"Configure or diagnose only this si-notch plugin")
            settings = object_file(plugin / "si-notch.json")
            if not isinstance(settings.get("instanceId"), str) or not settings["instanceId"] or len(settings["instanceId"]) > 4096:
                settings["instanceId"] = sha((platform.node() + ":" + str(root)).encode())
            settings.update(helperPath=str(relay), socketPath=str(socket_path), displayName=name.strip(), showSessionText=text)
            propose(plugin / "si-notch.json", (json.dumps(settings, ensure_ascii=False, indent=2) + "\n").encode())
        if enabled != profile["enabled"]:
            actions.append((identifier, enabled))
        if enabled != profile["enabled"] or len(writes) > before_count:
            changes.append({"id": identifier, "display_name": name.strip(), "action": "connect" if enabled and not profile["enabled"] else "update" if enabled else "disconnect"})
    if any(value["enabled"] for value in selected):
        propose(relay, bundled["relay"], b"Portable remote-side si-notchctl subset", 0o700)
    result = {"plan_id": plan_identity(request, bundled, home, socket_path), "snapshot": current["snapshot"],
              "changes": changes, "file_count": len(writes), "config_count": len(actions), "paths": sorted(writes)}
    return result, writes, actions


def scrub(config):
    result = copy.deepcopy(config)
    plugins = result.get("plugins")
    if isinstance(plugins, dict):
        for key in ("enabled", "disabled"):
            if key in plugins:
                plugins[key] = [value for value in plugins[key] if not (isinstance(value, str) and value.rsplit("/", 1)[-1] == "si-notch")]
                if not plugins[key]:
                    del plugins[key]
        if not plugins:
            del result["plugins"]
    return result


def atomic_write(path, data, mode):
    safe(path)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".si-notch-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def apply_locked(request, home, cli, relay, socket_path):
    supplied_id = request.get("plan_id", "")
    if not isinstance(supplied_id, str) or len(supplied_id) != 64 or any(c not in "0123456789abcdef" for c in supplied_id):
        raise ValueError("Preview is required before applying changes")
    if plan_identity(request, sources(request), home, socket_path) != supplied_id:
        raise ValueError("The preview does not match this request")
    backup = safe(home / "backups" / ("si-notch-setup-" + supplied_id))
    receipt_path = backup / "receipt.json"
    if receipt_path.is_file():
        receipt = object_file(receipt_path)
        current, _ = inspect(home, relay, socket_path)
        if receipt.get("after_snapshot") == current["snapshot"]:
            return receipt
        raise ValueError("Previous setup receipt differs from current settings. Inspect before retrying.")
    preview, writes, actions = plan(request, home, relay, socket_path)
    if preview["plan_id"] != supplied_id:
        raise ValueError("The preview does not match this request")
    if not preview["changes"] and not writes:
        return {"plan_id": supplied_id, "backup": "", "profiles": [], "changed": False}
    if actions and not os.access(cli, os.X_OK):
        raise ValueError("Hermes executable was not found")
    backup.mkdir(mode=0o700, parents=True, exist_ok=False)
    before, _ = inspect(home, relay, socket_path)
    roots = {p["id"]: Path(p["home"]) for p in before["profiles"]}
    configs = {key: object_file(root / "config.yaml", is_yaml=True) for key, root in roots.items()}
    targets = set(writes) | {str(roots[key] / "config.yaml") for key, _ in actions}
    manifest = []
    for index, name in enumerate(sorted(targets)):
        path = Path(name)
        data = read(path)
        saved = str(index) + ".backup"
        if data is not None:
            atomic_write(backup / saved, data, stat.S_IMODE(path.stat().st_mode) & 0o700)
        manifest.append({"path": name, "backup": saved if data is not None else None})
    atomic_write(backup / "files.json", json.dumps(manifest, indent=2).encode(), 0o600)
    socket_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    for name, (data, mode) in writes.items():
        atomic_write(Path(name), data, mode)
    activations = []
    env = dict(os.environ)
    for key in ("HERMES_HOME", "HERMES_PROFILE", "HERMES_KANBAN_TASK", "HERMES_KANBAN_RUN_ID"):
        env.pop(key, None)
    for identifier, enabled in actions:
        action = "enable" if enabled else "disable"
        proc = subprocess.run([str(cli), "-p", identifier, "plugins", action, "si-notch"], env=env,
                              cwd=str(Path.home()), stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=90)
        atomic_write(backup / (identifier + ".log"), (proc.stdout + proc.stderr).encode(), 0o600)
        if proc.returncode:
            raise ValueError("Hermes rejected " + action + " for " + identifier + ". Backup: " + str(backup))
    # Reload updated adapters too: enable is intentionally a no-op for an already enabled profile.
    from hermes_cli.plugins_activation import reload_running_gateway
    for change in preview["changes"]:
        identifier = change["id"]
        os.environ["HERMES_HOME"] = str(roots[identifier])
        answer = reload_running_gateway()
        desired = next(p["enabled"] for p in request["profiles"] if p["id"] == identifier)
        activations.append({"id": identifier, "enabled": desired, "loaded": bool(answer and answer.get("reloaded") and "si-notch" in (answer.get("plugins") or []))})
    for identifier, root in roots.items():
        after = object_file(root / "config.yaml", is_yaml=True)
        expected = next((p["enabled"] for p in request["profiles"] if p["id"] == identifier), plugin_enabled(configs[identifier]))
        if plugin_enabled(after) != expected:
            raise ValueError("Plugin state did not match preview for " + identifier + ". Backup: " + str(backup))
        if (scrub(after) != scrub(configs[identifier]) or
                (identifier not in {key for key, _ in actions} and after != configs[identifier])):
            raise ValueError("Unrelated settings changed for " + identifier + ". Backup: " + str(backup))
    after, _ = inspect(home, relay, socket_path)
    receipt = {"plan_id": supplied_id, "after_snapshot": after["snapshot"], "backup": str(backup),
               "profiles": activations, "changed": True}
    atomic_write(receipt_path, json.dumps(receipt, indent=2).encode(), 0o600)
    return receipt


def apply(request, home, cli, relay, socket_path):
    directory = safe(home / "backups")
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    lock_path = safe(directory / ".si-notch-setup.lock")
    read(lock_path)
    descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return apply_locked(request, home, cli, relay, socket_path)
    finally:
        os.close(descriptor)


def main(request):
    home = Path(request.get("hermes_home", "~/.hermes")).expanduser()
    cli = Path(request.get("hermes_cli", "~/.local/bin/hermes")).expanduser()
    relay = Path.home() / ".local/bin/si-notchctl"
    socket_path = Path(request.get("socket_path") or str(Path.home() / ".si-notch/run/events.sock")).expanduser()
    if not home.is_absolute() or not cli.is_absolute() or not socket_path.is_absolute() or len(os.fsencode(socket_path)) >= 100 or ":" in str(socket_path):
        raise ValueError("Expected absolute, supported remote paths")
    for path in (home, cli, socket_path):
        if any(part in ("..", ".") for part in path.parts) or any(ord(c) < 32 or ord(c) == 127 for c in str(path)):
            raise ValueError("Unsupported remote path")
    cli = cli.resolve(strict=False)
    safe(cli)
    operation = request.get("op")
    if operation == "inspect":
        return inspect(home, relay, socket_path)[0]
    if operation == "preview":
        return plan(request, home, relay, socket_path)[0]
    if operation == "apply":
        return apply(request, home, cli, relay, socket_path)
    raise ValueError("Unsupported setup operation")


if __name__ == "__main__":
    try:
        raw = sys.stdin.buffer.read(MAX_BYTES + 1)
        if len(raw) > MAX_BYTES:
            raise ValueError("Setup request is too large")
        request = json.loads(raw)
        if not isinstance(request, dict):
            raise ValueError("Expected a JSON object")
        print(json.dumps({"ok": True, "data": main(request)}, ensure_ascii=False))
    except Exception as error:
        print(json.dumps({"ok": False, "error": str(error)[:1500]}, ensure_ascii=False))
        sys.exit(1)
