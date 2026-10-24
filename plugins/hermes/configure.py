#!/usr/bin/env python3
"""Configure or diagnose only this si-notch plugin. No Hermes config or service edits."""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import uuid

PLUGIN = Path(__file__).resolve().parent


def safe(path: Path) -> Path:
    if not path.is_absolute() or any(p in (".", "..") for p in path.parts):
        raise ValueError("Use an absolute path without . or .. components")
    for ancestor in [*reversed(path.parents), path]:
        if ancestor.is_symlink():
            raise ValueError("Symlink is not supported: " + str(ancestor))
    return path


def settings() -> dict:
    path = safe(PLUGIN / "si-notch.json")
    if not path.exists():
        return {}
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > 8192:
        raise ValueError("Unsafe or oversized si-notch.json")
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError("si-notch.json must be an object")
    return value


def endpoint(value: str | None) -> Path:
    value = value or str(Path.home() / ".si-notch/run/events.sock")
    if not value.startswith("/") or len(os.fsencode(value)) >= 100 or ":" in value or any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise ValueError("Unsupported Unix socket path")
    return safe(Path(value))


def private_directory(path: Path, create: bool = False):
    safe(path)
    if create and not path.exists():
        missing, current = [], path
        while not current.exists():
            missing.append(current); current = current.parent
        for ancestor in [*reversed(current.parents), current]:
            info = ancestor.stat()
            if not stat.S_ISDIR(info.st_mode) or info.st_uid not in (0, os.getuid()) or (info.st_mode & 0o022 and not info.st_mode & stat.S_ISVTX):
                raise ValueError("Unsafe socket directory ancestor: " + str(ancestor))
        for directory in reversed(missing):
            directory.mkdir(mode=0o700)
    info = path.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
        raise ValueError("Socket directory must belong to this user and have mode 0700: " + str(path))


def atomic_write(path: Path, data: bytes):
    safe(path)
    descriptor, temporary = tempfile.mkstemp(prefix=".si-notch-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def setup(args):
    before = settings()
    value = dict(before)
    name = args.name.strip()
    if not 1 <= len(name) <= 128 or any(ord(c) < 32 or ord(c) == 127 for c in name):
        raise ValueError("Display name must contain 1–128 characters without control characters")
    path = endpoint(args.socket or value.get("socketPath"))
    value.update(displayName=name, socketPath=str(path))
    instance = value.get("instanceId")
    if args.new_instance:
        outbox = safe(PLUGIN / "usage-outbox")
        if outbox.exists() and (not outbox.is_dir() or any(outbox.iterdir())):
            raise ValueError("Pending usage belongs to the existing identity. Deliver it with that identity before assigning a new one; do not copy another profile's usage-outbox into a clone.")
        lifecycle = safe(PLUGIN / "lifecycle-outbox")
        if lifecycle.exists() and (not lifecycle.is_dir() or any(lifecycle.iterdir())):
            raise ValueError("Pending lifecycle events belong to the existing identity. Deliver them before assigning a new one.")
    if args.new_instance or not isinstance(instance, str) or not instance or len(instance) > 4096:
        value["instanceId"] = uuid.uuid4().hex
    if args.show_text is not None:
        value["showSessionText"] = args.show_text
    else:
        value.setdefault("showSessionText", False)
    if args.helper:
        helper = safe(Path(args.helper))
        if not helper.is_file() or not os.access(helper, os.X_OK):
            raise ValueError("The explicit helper must be an executable file")
        value["helperPath"] = str(helper)
    elif args.bundled_relay:
        value.pop("helperPath", None)
    # Validate everything before writing or creating directories.
    if value.get("showSessionText") not in (True, False) or not isinstance(value.get("showSessionText"), bool):
        raise ValueError("showSessionText must be a boolean")
    data = (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode()
    if len(data) > 8192:
        raise ValueError("Settings exceed 8 KiB")
    private_directory(path.parent, create=True)
    target = safe(PLUGIN / "si-notch.json")
    backup = None
    changed = value != before
    if changed:
        if target.exists():
            backup = target.with_name("si-notch.backup-" + uuid.uuid4().hex + ".json")
            atomic_write(backup, target.read_bytes())
        atomic_write(target, data)
    return {"ok": True, "state": "configured", "changed": changed, "settings_path": str(target),
            "backup": str(backup) if backup else None, "socket_path": str(path),
            "display_name": name, "show_session_text": value["showSessionText"],
            "next": "Enable si-notch in this Hermes profile. Keep the local Mac app running, or click Connect for a remote SSH profile, then run check."}


def socket_state(path: Path):
    safe(path)
    private_directory(path.parent)
    info = path.lstat()
    if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("Expected this user's private Unix socket (0600)")
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(2)
        try:
            client.connect(str(path))
        except ConnectionRefusedError:
            return "refused", info
    return "listening", info


def _native_helper():
    return next((str(path) for path in (
        Path('/Applications/si-notch.app/Contents/Helpers/si-notchctl'),
        Path.home() / 'Applications/si-notch.app/Contents/Helpers/si-notchctl',
    ) if path.is_file() and os.access(path, os.X_OK)), None)


def check(args):
    value = settings()
    path = endpoint(args.socket or value.get("socketPath"))
    try:
        state, _ = socket_state(path)
    except FileNotFoundError:
        return {"ok": False, "state": "not_connected", "socket_path": str(path),
                "next": "Start si-notch for a local profile, or click Connect in Remote SSH for a remote profile. Check connection verifies SSH login only."}
    if state == "refused":
        return {"ok": False, "state": "stale_socket", "socket_path": str(path),
                "next": "Disconnect in si-notch, then preview repair-socket. It preserves an unused stale socket under a backup name."}
    instance = value.get("instanceId")
    if not isinstance(instance, str) or not instance or len(instance) > 4096:
        raise ValueError("Run setup to create a stable profile identity first")
    name = value.get("displayName", "Hermes Agent")
    payload = {"event": "agent.presence", "session_id": "si-notch-check-" + uuid.uuid4().hex,
               "id": uuid.uuid4().hex, "provider": "hermes", "connection_name": name,
               "connection_id": "hermes-instance-" + hashlib.sha256(instance.encode()).hexdigest()[:32]}
    explicit_helper = "SI_NOTCH_CLI" in os.environ or "helperPath" in value
    helper = os.environ.get("SI_NOTCH_CLI") if "SI_NOTCH_CLI" in os.environ else value.get("helperPath")
    if not explicit_helper:
        helper = _native_helper()
    if explicit_helper or helper is not None:
        if not isinstance(helper, str) or not helper:
            raise ValueError("Configured helper is invalid")
        helper_path = safe(Path(helper))
        if not helper_path.is_file() or not os.access(helper_path, os.X_OK):
            raise ValueError("Configured helper is not executable")
        command = [str(helper_path)]
        with helper_path.open('rb') as stream:
            if stream.read(128).startswith(b'#!/usr/bin/env python3\n"""Portable remote-side si-notchctl subset'):
                command.insert(0, sys.executable)
    else:
        command = [sys.executable, str(safe(PLUGIN / "relay.py"))]
    env = dict(os.environ)
    env["SI_NOTCH_SOCKET"] = str(path)
    result = subprocess.run([*command, "emit", json.dumps(payload)], env=env, stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=5, check=False)
    if result.returncode:
        return {"ok": False, "state": "relay_failed", "detail": result.stderr.decode(errors="replace")[:1500]}
    return {"ok": True, "state": "delivered", "socket_path": str(path),
            "next": "Presence was acknowledged. Run a real Hermes turn to verify messages, tools and completion."}


def repair_socket(args):
    value = settings()
    path = endpoint(args.socket or value.get("socketPath"))
    state, before = socket_state(path)
    if state != "refused":
        raise ValueError("Socket accepts connections; refusing to move it")
    lsof = shutil.which("lsof")
    if lsof is None:
        raise ValueError("lsof is required to prove that no process holds the socket; no change made")
    result = subprocess.run([lsof, "-nP", "-Fpfnt", "--", str(path)], capture_output=True, timeout=5)
    if result.returncode != 1 or result.stdout.strip() or result.stderr.strip():
        raise ValueError("Socket may be held by a process; no change made")
    if not args.apply:
        return {"ok": True, "state": "repair_preview", "socket_path": str(path),
                "next": "Disconnect in si-notch. Re-run repair-socket --apply to preserve this stale socket and free its path."}
    current = path.lstat()
    if (before.st_dev, before.st_ino, before.st_mtime_ns) != (current.st_dev, current.st_ino, current.st_mtime_ns):
        raise ValueError("Socket changed during inspection; no change made")
    backup = path.with_name(path.name + ".stale-" + datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8])
    path.rename(backup)
    return {"ok": True, "state": "socket_preserved", "backup": str(backup),
            "next": "Click Connect in si-notch, then run check again."}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    configure = commands.add_parser("setup", help="Merge only si-notch.json; preserve other settings and hooks")
    configure.add_argument("--name", required=True)
    configure.add_argument("--socket")
    configure.add_argument("--new-instance", action="store_true", help="Give an intentionally cloned profile a new identity; never use for an update")
    text = configure.add_mutually_exclusive_group()
    text.add_argument("--show-text", dest="show_text", action="store_true")
    text.add_argument("--hide-text", dest="show_text", action="store_false")
    configure.set_defaults(show_text=None)
    helper = configure.add_mutually_exclusive_group()
    helper.add_argument("--helper")
    helper.add_argument("--bundled-relay", action="store_true")
    diagnostic = commands.add_parser("check", help="Read-only checks plus one acknowledged presence event")
    diagnostic.add_argument("--socket")
    repair = commands.add_parser("repair-socket", help="Preview recovery of an unused stale socket")
    repair.add_argument("--socket")
    repair.add_argument("--apply", action="store_true")
    args = parser.parse_args(argv)
    try:
        result = {"setup": setup, "check": check, "repair-socket": repair_socket}[args.command](args)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        result = {"ok": False, "state": "error", "detail": str(error)[:1500]}
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
