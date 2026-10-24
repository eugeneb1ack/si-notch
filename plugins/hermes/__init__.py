"""Hermes Agent observer plugin for si-notch. Task text is opt-in; raw tool content is excluded."""

from __future__ import annotations

import hashlib
from contextlib import closing
import math
import stat
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import sqlite3
import threading
import time
from uuid import uuid4


_SAFE_TOOL_NAMES = frozenset({
    "terminal", "browser", "web_search", "web_fetch", "read_file",
    "write_file", "edit_file", "delegate_task", "search", "python", "grep",
})
_LOCK = threading.Lock()
_STARTED: set[str] = set()
_TASK_TITLES: dict[str, str] = {}
_METADATA: dict[str, dict] = {}
_TODO_IDS: dict[str, set[str]] = {}
_CONTEXT = None
_PARENTS: dict[str, tuple[str, str]] = {}
_TURN_PARENTS: dict[tuple[str, str], tuple[str, str]] = {}
_SPOOL_LOCK = threading.RLock()
_SPOOL_LIMIT = 2000
_EFFORTS = frozenset({"none", "off", "minimal", "low", "medium", "high", "xhigh", "max", "ultra", "auto", "adaptive", "enabled", "disabled"})
_DISABLED_UNTIL = 0.0
_TIMEOUT_SECONDS = 2.5
_RETRY_SECONDS = 5.0
_HEARTBEAT_SECONDS = 30.0
_HEARTBEAT: tuple[threading.Event, threading.Thread] | None = None
_EXECUTION_LOCK = threading.Lock()
_TRACKED_EXECUTIONS: dict[tuple[str, str], Path | None] = {}
_EXECUTION_CURSOR = 0


def _opaque_id(value: object, prefix: str) -> str | None:
    if not isinstance(value, str) or not value or len(value) > 4096:
        return None
    return prefix + hashlib.sha256(value.encode("utf-8")).hexdigest()[:32]


def _settings() -> dict:
    config = Path(__file__).resolve().parent / "si-notch.json"
    try:
        if not config.is_symlink() and config.is_file() and config.stat().st_size <= 8192:
            value = json.loads(config.read_text())
            if isinstance(value, dict):
                return value
    except (OSError, ValueError):
        pass
    return {}


def _display_name() -> str:
    value = _settings().get("displayName")
    if isinstance(value, str):
        value = value.strip()
        if 0 < len(value) <= 128 and not any(ord(char) < 32 or ord(char) == 127 for char in value):
            return value
    return "Hermes Agent"


def _connection_id() -> str | None:
    return _opaque_id(_settings().get("instanceId"), "hermes-instance-")


def _session_key(value: object) -> str | None:
    opaque = _opaque_id(value, "hermes-")
    if opaque is None:
        return None
    connection = _connection_id()
    return _opaque_id(connection + ":" + opaque, "hermes-") if connection else opaque


def _session_text(value: object, *, prompt: bool = False) -> str | None:
    if _settings().get("showSessionText") is not True or not isinstance(value, str):
        return None
    if prompt:
        # A brief task description also avoids displaying a connector's trailing instructions.
        value = value.removeprefix("message:\n").split("\n\n", 1)[0]
    value = "".join(char for char in value if ord(char) >= 32 or char in "\n\t").replace("\x7f", "").strip()
    limit = 1600 if prompt else 4000
    return (value[:limit - 1] + "…" if len(value) > limit else value) or None


def _metadata_text(value: object, limit: int = 256) -> str | None:
    if not isinstance(value, str) or not value.strip() or len(value.encode("utf-8")) > limit:
        return None
    return value.strip() if not any(ord(c) < 32 or ord(c) == 127 for c in value) else None


def _reasoning(body: dict) -> str | None:
    reasoning = body.get("reasoning")
    candidates = [body.get("reasoning_effort"), reasoning.get("effort") if isinstance(reasoning, dict) else None]
    extra = body.get("extra_body")
    if isinstance(extra, dict):
        candidates += [extra.get("reasoning_effort")]
        if isinstance(extra.get("reasoning"), dict): candidates.append(extra["reasoning"].get("effort"))
    for value in candidates:
        if isinstance(value, str) and value in _EFFORTS: return value
    thinking = body.get("thinking")
    if isinstance(thinking, dict):
        if thinking.get("type") == "disabled": return "off"
        budget = thinking.get("budget_tokens")
        if type(budget) is int and 0 < budget <= 10_000_000: return str(budget) + " tokens"
        if thinking.get("type") in ("adaptive", "enabled"): return thinking["type"]
    return None


def _observe_metadata(session_id: object, model=None, request=None, reasoning_effort=None) -> None:
    session = _session_key(session_id)
    if session is None: return
    body = request.get("body", request) if isinstance(request, dict) else None
    if not isinstance(body, dict): body = None
    name = _metadata_text(body.get("model")) if body is not None else None
    name = name or _metadata_text(model)
    effort = reasoning_effort if isinstance(reasoning_effort, str) and reasoning_effort in _EFFORTS else None
    cwd = None
    try:
        value = _CONTEXT.session_cwd() if _CONTEXT is not None else None
        if isinstance(value, str) and value.startswith("/"):
            cwd = _metadata_text(value, 4096)
    except Exception:
        pass  # Older Hermes versions need not expose the session-cwd API.
    with _LOCK:
        data = _METADATA.setdefault(session, {})
        if name:
            if name != data.get("model"): data["reasoning_effort"] = ""
            data["model"] = name
        if body is not None: data["reasoning_effort"] = _reasoning(body) or ""
        elif effort is not None: data["reasoning_effort"] = effort
        if cwd: data["cwd"] = cwd


def _observe_todos(session_id: object, outcome: dict) -> None:
    todos = outcome.get("todos")
    session = _session_key(session_id)
    if session is None or not isinstance(todos, list) or len(todos) > 256: return
    current = {}
    for index, item in enumerate(todos):
        if not isinstance(item, dict): continue
        identifier = _opaque_id(item.get("id"), "task-")
        if not identifier: continue
        title = _session_text(item.get("content"), prompt=True) or "Task " + str(index + 1)
        title = title.encode("utf-8")[:512].decode("utf-8", errors="ignore")
        status = {"completed": "completed", "cancelled": "ended", "in_progress": "working"}.get(item.get("status"), "idle")
        current[identifier] = {"id": identifier, "title": title, "status": status}
    with _LOCK:
        previous = _TODO_IDS.get(session, set())
        _TODO_IDS[session] = set(current)
    for identifier in sorted(previous - current.keys()):
        _emit("task.update", session_id, task={"id": identifier, "title": "Task", "status": "ended"})
    for item in current.values(): _emit("task.update", session_id, task=item)


def _helper_path() -> Path | None:
    def executable(value) -> Path | None:
        if not isinstance(value, (str, Path)) or any(ord(char) < 32 for char in str(value)):
            return None
        path = Path(value)
        return path if path.is_absolute() and path.is_file() and os.access(path, os.X_OK) else None

    configured = os.environ.get("SI_NOTCH_CLI")
    if configured is not None:
        return executable(configured)
    directory = Path(__file__).resolve().parent
    settings = _settings()
    if "helperPath" in settings:
        return executable(settings["helperPath"])
    for candidate in (directory.parent.parent.parent / "Helpers/si-notchctl",
                      Path("/Applications/si-notch.app/Contents/Helpers/si-notchctl"),
                      Path.home() / "Applications/si-notch.app/Contents/Helpers/si-notchctl"):
        if path := executable(candidate):
            return path
    return None


def _send(payload: dict) -> bool:
    """Bounded, fail-open delivery; never invoke a shell or capture helper output."""
    global _DISABLED_UNTIL
    if time.monotonic() < _DISABLED_UNTIL:
        return False
    helper = _helper_path()
    command = [str(helper)] if helper else None
    if helper:
        try:
            with helper.open("rb") as stream:
                portable_relay = stream.read(128).startswith(
                    b'#!/usr/bin/env python3\n"""Portable remote-side si-notchctl subset')
            if portable_relay:
                # Hermes may put a Python bootstrap shim first on PATH. Reuse
                # its running interpreter and leave time for the relay's ACK.
                command.insert(0, sys.executable)
        except OSError:
            return False
    if command is None and "SI_NOTCH_CLI" not in os.environ and "helperPath" not in _settings():
        # Git subdirectory installs may not preserve executable bits. Use the
        # running Hermes interpreter for our bundled, dependency-free relay.
        relay = Path(__file__).resolve().parent / "relay.py"
        if relay.is_file() and not relay.is_symlink():
            command = [sys.executable, str(relay)]
    if command is None:
        return False
    environment = dict(os.environ)
    socket_path = _settings().get("socketPath")
    if isinstance(socket_path, str) and socket_path.startswith("/") and not any(ord(c) < 32 for c in socket_path):
        environment["SI_NOTCH_SOCKET"] = socket_path
    try:
        result = subprocess.run(
            [*command, "emit", json.dumps(payload, separators=(",", ":"))],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=_TIMEOUT_SECONDS,
            check=False,
            env=environment,
        )
        if result.returncode == 0:
            return True
    except (OSError, subprocess.TimeoutExpired):
        pass
    _DISABLED_UNTIL = time.monotonic() + _RETRY_SECONDS
    return False


def _spool_directory() -> Path:
    return Path(__file__).resolve().parent / "usage-outbox"


def _private_spool(directory: Path | None = None) -> Path:
    directory = directory if directory is not None else _spool_directory()
    directory.mkdir(mode=0o700, exist_ok=True)
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise OSError("unsafe usage queue")
    return directory


def _queue_usage(payload: dict) -> bool:
    # Store only numeric usage and opaque identity. Session text stays ephemeral.
    keep = {"event", "session_id", "provider", "timestamp", "connection_id", "connection_name", "model", "turn_id", "usage"}
    value = {key: data for key, data in payload.items() if key in keep}
    try:
        with _SPOOL_LOCK:
            directory = _private_spool()
            if len(list(directory.glob("*.json"))) >= _SPOOL_LIMIT:
                marker = directory / "incomplete"
                fd = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
                os.close(fd)
                return False
            if (directory / "incomplete").exists(): value["usage"] = {**value["usage"], "incomplete": True}
            key = hashlib.sha256((value.get("connection_id", "") + ":" + value["session_id"] + ":" + value["usage"]["request_id"]).encode()).hexdigest()
            path = directory / (key + ".json")
            if not path.exists():
                data = json.dumps(value, separators=(",", ":")).encode()
                if len(data) > 8192: return False
                temporary = directory / (".write-" + str(uuid4()))
                fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                try:
                    with os.fdopen(fd, "wb") as stream:
                        stream.write(data); stream.flush(); os.fsync(stream.fileno())
                    os.replace(temporary, path)
                    directory_fd = os.open(directory, os.O_RDONLY)
                    try: os.fsync(directory_fd)
                    finally: os.close(directory_fd)
                finally:
                    temporary.unlink(missing_ok=True)
        _drain_usage()
        return True
    except (OSError, ValueError):
        return False


def _drain_usage() -> None:
    if not _SPOOL_LOCK.acquire(blocking=False): return
    try:
        directory = _spool_directory()
        if not directory.exists(): return
        _private_spool()
        for path in sorted(directory.glob("*.json"))[:1]:
            info = path.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_size > 8192: continue
            value = json.loads(path.read_text())
            if value.get("event") != "usage.update" or not isinstance(value.get("usage"), dict): continue
            if _send(value): path.unlink()
    except (OSError, ValueError):
        pass
    finally:
        _SPOOL_LOCK.release()


_LIFECYCLE_LOCK = threading.Lock()
_LIFECYCLE_KINDS = frozenset({"agent.completed", "agent.failed", "agent.waiting", "session.end"})


def _lifecycle_directory() -> Path:
    return Path(__file__).resolve().parent / "lifecycle-outbox"


def _queue_lifecycle(payload: dict) -> bool:
    # Persist outcome and opaque routing only; never persist task text/tool output.
    keep = {"event", "session_id", "provider", "id", "timestamp", "connection_id", "connection_name", "turn_id"}
    value = {key: data for key, data in payload.items() if key in keep}
    try:
        with _LIFECYCLE_LOCK:
            directory = _private_spool(_lifecycle_directory())
            if len(list(directory.glob("*.json"))) >= _SPOOL_LIMIT:
                marker = directory / "incomplete"
                fd = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
                os.close(fd)
                return _send(payload)
            path = directory / (hashlib.sha256(value["id"].encode()).hexdigest() + ".json")
            temporary = directory / (".write-" + str(uuid4()))
            fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            try:
                with os.fdopen(fd, "w") as stream:
                    json.dump(value, stream, separators=(",", ":")); stream.flush(); os.fsync(stream.fileno())
                os.replace(temporary, path)
                directory_fd = os.open(directory, os.O_RDONLY)
                try: os.fsync(directory_fd)
                finally: os.close(directory_fd)
            finally:
                temporary.unlink(missing_ok=True)
        if _send(payload): path.unlink(missing_ok=True)
        return True
    except (OSError, ValueError):
        return _send(payload)


def _drain_lifecycle() -> None:
    if not _LIFECYCLE_LOCK.acquire(blocking=False): return
    try:
        directory = _lifecycle_directory()
        if not directory.exists(): return
        _private_spool(directory)
        # One bounded exchange per heartbeat iteration; a backlog cannot stall Hermes.
        for path in sorted(directory.glob("*.json"), key=lambda p: p.lstat().st_mtime)[:1]:
            info = path.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_size > 8192: continue
            value = json.loads(path.read_text())
            if not isinstance(value, dict) or value.get("event") not in _LIFECYCLE_KINDS or value.get("provider") != "hermes": continue
            if _send(value): path.unlink(missing_ok=True)
    except (OSError, ValueError):
        pass
    finally:
        _LIFECYCLE_LOCK.release()


def _execution_directory() -> Path:
    return Path(__file__).resolve().parent / "active-executions"


def _native_database() -> Path:
    # A multiplexer serves several profiles; process-global HERMES_HOME is not
    # the authority for this installed plugin's own native database.
    return Path(__file__).resolve().parents[2] / "state.db"


def _open_native_database():
    path = _native_database()
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
        raise OSError("unsafe native state")
    return sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=0.05)


def _write_execution(path: Path, value: dict) -> None:
    temporary = path.parent / (".write-" + str(uuid4()))
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, separators=(",", ":")); stream.flush(); os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try: os.fsync(directory_fd)
        finally: os.close(directory_fd)
    finally:
        temporary.unlink(missing_ok=True)


def _track_execution(native_session: str, payload: dict) -> None:
    turn = payload.get("turn_id")
    identity = (payload["session_id"], turn)
    if not turn or not payload.get("connection_id") or identity in _TRACKED_EXECUTIONS:
        return
    try:
        with _EXECUTION_LOCK, closing(_open_native_database()) as database:
            # Require one exact, executing native reservation. API threads and
            # unsupported schemas retain their existing hook-only behavior.
            rows = database.execute("""SELECT w.execution_id, w.generation, w.owner_epoch,
                       a.admission_id, a.generation, a.owner_epoch
                FROM worker_executions w JOIN session_admissions a
                  ON w.execution_id = 'admission-worker:' || a.admission_id
                WHERE w.session_id = ? AND w.status = 'running' AND a.status = 'started'
                LIMIT 2""", (native_session,)).fetchall()
            if len(rows) != 1: return
            execution, generation, epoch, admission, admission_generation, admission_epoch = rows[0]
            directory = _private_spool(_execution_directory())
            if len(list(directory.glob("*.json"))) >= _SPOOL_LIMIT: return
            value = {key: payload[key] for key in ("session_id", "provider", "connection_id", "turn_id")}
            value.update(execution_id=execution, generation=generation, owner_epoch=epoch,
                         admission_id=admission, admission_generation=admission_generation,
                         admission_epoch=admission_epoch)
            # An admission can contain several goal-loop turns. Its final native
            # verdict belongs only to the latest observed turn, never its predecessors.
            name = hashlib.sha256(execution.encode()).hexdigest() + ".json"
            path = directory / name
            _write_execution(path, value)
            if len(_TRACKED_EXECUTIONS) >= _SPOOL_LIMIT:
                _TRACKED_EXECUTIONS.pop(next(iter(_TRACKED_EXECUTIONS)))
            _TRACKED_EXECUTIONS[identity] = path
    except (OSError, ValueError, TypeError, sqlite3.Error):
        pass


def _forget_execution(session_id: object, turn_id: object) -> None:
    identity = (_session_key(session_id), _opaque_id(turn_id, "turn-"))
    with _EXECUTION_LOCK:
        path = _TRACKED_EXECUTIONS.get(identity)
        if path is not None:
            try:
                value = json.loads(path.read_text())
                if (value.get("session_id"), value.get("turn_id")) == identity:
                    path.unlink(missing_ok=True)
            except FileNotFoundError:
                pass
            except (OSError, ValueError, AttributeError):
                return
            _TRACKED_EXECUTIONS[identity] = None


def _reconcile_executions() -> None:
    """Recover a missing worker hook from a committed native execution verdict.

    No transcript scan, PID heuristic, native mutation or inference from silence.
    Only opaque execution/routing identities enter the private journal.
    """
    global _EXECUTION_CURSOR
    if not _EXECUTION_LOCK.acquire(blocking=False): return
    try:
        directory = _execution_directory()
        if not directory.exists(): return
        _private_spool(directory)
        paths = sorted(directory.glob("*.json"))[:_SPOOL_LIMIT]
        if not paths: return
        with closing(_open_native_database()) as database:
            for _ in range(min(32, len(paths))):
                path = paths[_EXECUTION_CURSOR % len(paths)]
                _EXECUTION_CURSOR += 1
                try:
                    info = path.lstat()
                    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_size > 8192: continue
                    value = json.loads(path.read_text())
                    if (not isinstance(value, dict) or value.get("provider") != "hermes"
                            or value.get("connection_id") != _connection_id()): continue
                    text_keys = ("execution_id", "admission_id", "session_id", "turn_id")
                    numbers = ("generation", "owner_epoch", "admission_generation", "admission_epoch")
                    if (any(not isinstance(value.get(k), str) or not 0 < len(value[k]) <= 4096 for k in text_keys)
                            or any(type(value.get(k)) is not int or value[k] < 0 for k in numbers)): continue
                    if value["execution_id"] != "admission-worker:" + value["admission_id"]: continue
                    # Stamp before the snapshot: later turns sort after this
                    # receipt even if delivery is delayed by a disconnected Mac.
                    observed_at = time.time()
                    row = database.execute("""SELECT w.status, a.status, a.outcome,
                            (SELECT MAX(n.generation) FROM worker_executions n WHERE n.session_id=w.session_id)
                        FROM worker_executions w JOIN session_admissions a
                          ON w.execution_id='admission-worker:' || a.admission_id
                        WHERE w.execution_id=? AND w.generation=? AND w.owner_epoch=?
                          AND a.admission_id=? AND a.generation=? AND a.owner_epoch=?""",
                        tuple(value[k] for k in ("execution_id", "generation", "owner_epoch",
                                                "admission_id", "admission_generation", "admission_epoch"))).fetchone()
                    if row is None or row[0] != "terminal": continue
                    if row[3] != value["generation"]:
                        path.unlink(missing_ok=True); continue  # A newer worker owns this session.
                    if row[1] == "unknown":
                        kind = "agent.waiting"
                    elif row[1] == "terminal":
                        kind = {"completed": "agent.completed", "failed": "agent.failed",
                                "interrupted": "session.end"}.get(row[2])
                    else:
                        continue
                    if kind is None or value.get("notified") == kind: continue
                    pending_at = value.get("pending_at")
                    if (value.get("pending_kind") != kind or type(pending_at) not in (int, float)
                            or not math.isfinite(pending_at) or pending_at < 0):
                        value.update(pending_kind=kind, pending_at=observed_at)
                        _write_execution(path, value)
                    payload = {key: value[key] for key in ("session_id", "provider", "connection_id", "turn_id")}
                    payload.update(event=kind, timestamp=value["pending_at"],
                                   id=hashlib.sha256((value["execution_id"] + "\0" + value["turn_id"] + "\0" + kind).encode()).hexdigest())
                    if _queue_lifecycle(payload):
                        if row[1] == "unknown":
                            value["notified"] = kind; _write_execution(path, value)
                        else:
                            path.unlink(missing_ok=True)
                    break  # One bounded delivery per iteration, including offline paths.
                except (OSError, ValueError, TypeError):
                    continue
    except (OSError, ValueError, sqlite3.Error):
        pass
    finally:
        _EXECUTION_LOCK.release()


def _emit(kind: str, session_id: object, *, tool_name: object = None,
          approval_id: object = None, attention_request_id: object = None, message: str | None = None,
          first_prompt: str | None = None, turn_id: object = None,
          task: dict | None = None, subagent: dict | None = None,
          usage: dict | None = None, durable: bool = False) -> bool:
    session = _session_key(session_id)
    if session is None:
        return False
    with _LOCK:
        task_title = _TASK_TITLES.get(session)
        metadata = dict(_METADATA.get(session, {}))
    title = _display_name()
    if task_title and _settings().get("showSessionText") is True:
        title += " · " + task_title
    title = title.encode("utf-8")[:512].decode("utf-8", errors="ignore")
    payload = {
        "event": kind,
        "session_id": session,
        "provider": "hermes",
        "id": str(uuid4()),
        # A process-local counter cannot order a durable session across workers
        # or plugin reloads. Receivers order these events by timestamp and UUID.
        "timestamp": time.time(),
        "title": title,
        **metadata,
    }
    if usage is not None: payload["usage"] = usage
    if task is not None: payload["task"] = task
    if subagent is not None: payload["subagent"] = subagent
    if connection := _connection_id():
        payload["connection_id"] = connection
        payload["connection_name"] = _display_name()
    if tool_name is not None:
        payload["tool_name"] = tool_name if isinstance(tool_name, str) and (tool_name in _SAFE_TOOL_NAMES or re.fullmatch(r"[a-z][a-z0-9_]{0,127}", tool_name)) else "tool"
    if approval_id is not None:
        safe_id = _opaque_id(approval_id, "request-")
        if safe_id:
            payload["approval_id"] = safe_id
    if safe_id := _opaque_id(attention_request_id, "input-"):
        payload["attention_request_id"] = safe_id
    if message:
        payload["message"] = message
    if first_prompt:
        payload["first_prompt"] = first_prompt
    if safe_turn := _opaque_id(turn_id, "turn-"):
        payload["turn_id"] = safe_turn
    if kind in {"agent.working", "tool.start"} and isinstance(session_id, str):
        _track_execution(session_id, payload)
    if usage is not None: return _queue_usage(payload)
    return _queue_lifecycle(payload) if durable else _send(payload)


def _start_once(session_id: object) -> None:
    session = _session_key(session_id)
    if session is None:
        return
    with _LOCK:
        if session in _STARTED:
            return
        _STARTED.add(session)
    _emit("session.start", session_id)


def on_session_start(session_id=None, model=None, **kwargs) -> None:
    _observe_metadata(session_id, model, reasoning_effort=kwargs.get("reasoning_effort"))
    _start_once(session_id)


def pre_api_request(session_id=None, turn_id=None, model=None, request=None, call_kind=None, **kwargs) -> None:
    if call_kind in ("auxiliary", "compression"):
        return  # Usage is still recorded by post_api_request; this is not a new task.
    with _LOCK:
        if session_id in _PARENTS and turn_id:
            _TURN_PARENTS.setdefault((session_id, turn_id), _PARENTS[session_id])
    _observe_metadata(session_id, model, request, kwargs.get("reasoning_effort"))
    _start_once(session_id)
    _emit("agent.working", session_id, turn_id=turn_id)


def post_api_request(session_id=None, task_id=None, turn_id=None, api_request_id=None,
                     usage=None, model=None, started_at=None, ended_at=None, call_kind=None, **kwargs) -> None:
    # Hermes supplies normalized CanonicalUsage. Its input excludes cache buckets.
    # A stable request ID makes retries/replayed deliveries idempotent in the app.
    request_id = _opaque_id(api_request_id, "usage-")
    if request_id is None or not isinstance(usage, dict):
        return
    names = ("input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens", "reasoning_tokens")
    values = {}
    for name in names:
        value = usage.get(name, 0 if name not in ("input_tokens", "output_tokens") else None)
        if type(value) is not int or value < 0 or value >= 10**15:
            return
        values[name] = value
    session_id = session_id or task_id
    _observe_metadata(session_id, model)
    def stamp(value):
        return value if type(value) in (int, float) and math.isfinite(value) and 0 <= value <= time.time() + 60 else None
    with _LOCK:
        parent = _TURN_PARENTS.get((session_id, turn_id)) or _PARENTS.get(session_id)
    _emit("usage.update", session_id, turn_id=turn_id, usage={
        "request_id": request_id,
        **({"parent_session_id": _session_key(parent[0]), "parent_turn_id": _opaque_id(parent[1], "turn-")} if parent else {}),
        **({"started_at": stamp(started_at)} if stamp(started_at) is not None else {}),
        **({"ended_at": stamp(ended_at)} if stamp(ended_at) is not None else {}),
        **({"call_kind": call_kind} if call_kind in ("auxiliary", "compression") else {}),
        "input_tokens": values["input_tokens"] + values["cache_read_tokens"] + values["cache_write_tokens"],
        "output_tokens": values["output_tokens"],
        "cached_input_tokens": values["cache_read_tokens"],
        "cache_write_input_tokens": values["cache_write_tokens"],
        "reasoning_output_tokens": values["reasoning_tokens"],
    })


def post_auxiliary_call(error=None, **kwargs) -> None:
    if error is None:
        post_api_request(call_kind="auxiliary", **{k: v for k, v in kwargs.items() if k != "call_kind"})


def pre_llm_call(session_id=None, user_message=None, turn_id=None, model=None, **kwargs) -> None:
    _observe_metadata(session_id, model, reasoning_effort=kwargs.get("reasoning_effort"))
    text = _session_text(user_message, prompt=True)
    if text and (session := _session_key(session_id)):
        with _LOCK:
            _TASK_TITLES[session] = " ".join(text.split())[:100]
    _start_once(session_id)
    _emit("agent.working", session_id, message=text, first_prompt=text, turn_id=turn_id)


def _tool_session(session_id, task_id):
    if _session_key(session_id) is not None: return session_id
    # A tool invocation ID is not necessarily a durable session. Older hooks
    # may reuse task_id only after session/LLM hooks established that identity.
    session = _session_key(task_id)
    with _LOCK:
        return task_id if session in _STARTED else None


def pre_tool_call(session_id=None, tool_name=None, turn_id=None, task_id=None, **kwargs) -> None:
    session_id = _tool_session(session_id, task_id)
    # Always return None: this callback observes tools and never supplies a directive.
    _start_once(session_id)
    _emit("tool.start", session_id, tool_name=tool_name, turn_id=turn_id)


def post_tool_call(session_id=None, tool_name=None, status=None, turn_id=None, task_id=None, result=None, **kwargs) -> None:
    session_id = _tool_session(session_id, task_id)
    failed = status in ("error", "failed", "blocked")
    outcome = None
    # Inspect outcome flags only; never forward result content or errors.
    if not failed and isinstance(result, str) and len(result) <= 128 * 1024:
        try:
            outcome = json.loads(result)
            if isinstance(outcome, dict):
                failed = bool(outcome.get("error")) or outcome.get("success") is False
        except ValueError:
            pass
    _start_once(session_id)
    _emit("tool.failed" if failed else "tool.finish", session_id,
          tool_name=tool_name, turn_id=turn_id)
    if not failed and tool_name in ("todo", "todo_list") and isinstance(outcome, dict):
        _observe_todos(session_id, outcome)


def _subagent(parent_session_id, child_session_id, child_role, status, parent_turn_id=None) -> None:
    identifier = _opaque_id(child_session_id, "subagent-")
    if identifier is None: return
    role = _metadata_text(child_role, 128)
    name = role if role and re.fullmatch(r"[a-zA-Z0-9_./ -]+", role) else "Subagent"
    _emit("subagent.start" if status == "working" else "subagent.end", parent_session_id,
          subagent={"id": identifier, "name": name, "status": status, "sessionID": _session_key(child_session_id),
                    **({"parentTurnID": _opaque_id(parent_turn_id, "turn-")} if parent_turn_id else {})})


def subagent_start(parent_session_id=None, child_session_id=None, child_role=None, parent_turn_id=None, **kwargs) -> None:
    if isinstance(parent_session_id, str) and isinstance(child_session_id, str) and isinstance(parent_turn_id, str) and parent_turn_id:
        with _LOCK: _PARENTS[child_session_id] = (parent_session_id, parent_turn_id)
    _subagent(parent_session_id, child_session_id, child_role, "working", parent_turn_id)


def subagent_stop(parent_session_id=None, child_session_id=None, child_role=None, child_status=None, **kwargs) -> None:
    _subagent(parent_session_id, child_session_id, child_role, "failed" if child_status == "failed" else "completed")


def on_interim_message(session_id=None, text=None, turn_id=None, **kwargs) -> None:
    if message := _session_text(text):
        _emit("agent.working", session_id, message=message, turn_id=turn_id)


def post_llm_call(session_id=None, assistant_response=None, turn_id=None, **kwargs) -> None:
    if message := _session_text(assistant_response):
        # The canonical on_session_end hook owns the completed/failed state.
        _emit("agent.working", session_id, message=message, turn_id=turn_id)


def on_human_input_request(session_id=None, request_id=None, kind=None, **kwargs) -> None:
    _start_once(session_id)
    identity = request_id if request_id is not None else str(uuid4())
    if kind == "approval":
        _emit("approval.request", session_id, approval_id=request_id,
              attention_request_id=identity,
              message="Hermes is waiting for approval")
    else:
        _emit("agent.waiting", session_id, attention_request_id=identity, message="Hermes is waiting for input")


def on_human_input_resolved(session_id=None, **kwargs) -> None:
    _emit("agent.working", session_id)


def on_session_end(session_id=None, completed=None, failed=False,
                   interrupted=None, turn_id=None, **kwargs) -> None:
    # Hermes fires this once per turn; only finalize closes the durable session.
    if failed:
        kind = "agent.failed"
    elif interrupted:
        kind = "agent.waiting"
    elif completed:
        kind = "agent.completed"
    elif completed is False and interrupted is False:
        # The documented hook has no failed flag: an unsuccessful,
        # uninterrupted turn is terminal. Missing outcome fields stay unknown.
        kind = "agent.failed"
    else:
        kind = "agent.waiting"
    if _emit(kind, session_id, turn_id=turn_id, durable=True):
        if failed or interrupted or completed or (completed is False and interrupted is False):
            _forget_execution(session_id, turn_id)


def on_session_finalize(session_id=None, **kwargs) -> None:
    _emit("session.end", session_id, durable=True)
    session = _session_key(session_id)
    if session:
        with _LOCK:
            _STARTED.discard(session)
            _TASK_TITLES.pop(session, None)
            _METADATA.pop(session, None)
            _TODO_IDS.pop(session, None)
            _PARENTS.pop(session_id, None)
            for key in list(_TURN_PARENTS):
                if key[0] == session_id: _TURN_PARENTS.pop(key, None)


def _stop_heartbeat() -> None:
    global _HEARTBEAT
    heartbeat, _HEARTBEAT = _HEARTBEAT, None
    if heartbeat is not None:
        stop, worker = heartbeat
        stop.set()
        if worker is not threading.current_thread():
            worker.join(timeout=_TIMEOUT_SECONDS + 0.5)


def _start_heartbeat(ctx, connection: str) -> None:
    global _HEARTBEAT
    _stop_heartbeat()
    # Older runtimes retain the startup announcement, but must not acquire a
    # worker they cannot dispose when the plugin is disabled or reloaded.
    on_unload = getattr(ctx, "on_unload", None)
    if not callable(on_unload):
        return
    stop = threading.Event()

    def heartbeat() -> None:
        next_presence = time.monotonic() + _HEARTBEAT_SECONDS
        while not stop.wait(min(2.0, _HEARTBEAT_SECONDS)):
            if _connection_id() != connection: return
            _drain_usage()
            _drain_lifecycle()
            _reconcile_executions()
            if time.monotonic() >= next_presence:
                _emit("agent.presence", "presence-" + connection)
                next_presence = time.monotonic() + _HEARTBEAT_SECONDS

    worker = threading.Thread(target=heartbeat, name="si-notch-presence", daemon=True)
    def dispose() -> None:
        stop.set()
        if worker is not threading.current_thread():
            worker.join(timeout=_TIMEOUT_SECONDS + 0.5)
    on_unload(dispose)
    _HEARTBEAT = stop, worker
    worker.start()


def register(ctx) -> None:
    """Register only observer hooks; Hermes' authorization path is untouched."""
    global _CONTEXT
    _stop_heartbeat()
    _CONTEXT = ctx
    for name, callback in (
        ("on_session_start", on_session_start),
        ("pre_llm_call", pre_llm_call),
        ("pre_api_request", pre_api_request),
        ("post_api_request", post_api_request),
        ("post_auxiliary_call", post_auxiliary_call),
        ("pre_tool_call", pre_tool_call),
        ("post_tool_call", post_tool_call),
        ("on_interim_message", on_interim_message),
        ("post_llm_call", post_llm_call),
        ("on_human_input_request", on_human_input_request),
        ("on_human_input_resolved", on_human_input_resolved),
        ("on_session_end", on_session_end),
        ("on_session_finalize", on_session_finalize),
        ("subagent_start", subagent_start),
        ("subagent_stop", subagent_stop),
    ):
        ctx.register_hook(name, callback)
    if connection := _connection_id():
        # A loaded profile announces availability without creating a task.
        _emit("agent.presence", "presence-" + connection)
        _drain_lifecycle()
        _reconcile_executions()
        _start_heartbeat(ctx, connection)
