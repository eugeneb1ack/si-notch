#!/usr/bin/env python3
"""Check si-notchctl observation delivery against a private local socket fixture.

Run after building the helper: python3 scripts/smoke-cli.py --helper PATH
The fixture never starts the GUI or an agent and never makes a permission decision.
"""

import argparse
import errno
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import uuid


class Fixture:
    def __init__(self, path):
        self.path = path
        self.events = []
        self.errors = []
        self.seen = set()
        self.stop = threading.Event()
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(path)
        os.chmod(path, 0o600)
        self.listener.listen(8)
        self.listener.settimeout(0.1)
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        while not self.stop.is_set():
            try:
                connection, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError as error:
                if not self.stop.is_set():
                    self.errors.append(error)
                break
            try:
                with connection:
                    connection.settimeout(3)
                    frame = bytearray()
                    while b"\n" not in frame:
                        chunk = connection.recv(8192)
                        if not chunk:
                            raise AssertionError("helper closed before sending a complete frame")
                        frame.extend(chunk)
                    raw = bytes(frame[:frame.index(b"\n") + 1])
                    event = json.loads(raw)
                    self.events.append((raw, event))
                    if event.get("fixture_response") == "hold":
                        time.sleep(1.5)
                        continue
                    if event.get("fixture_response") == "reject":
                        answer = {"ok": False, "error": "fixture_reject"}
                    else:
                        key = (event.get("thread-id"), event.get("turn-id"), event.get("type"))
                        disposition = "duplicate" if key in self.seen else "applied"
                        self.seen.add(key)
                        answer = {"ok": True, "disposition": disposition}
                    connection.sendall(json.dumps(answer).encode() + b"\n")
            except (OSError, ValueError, AssertionError) as error:
                self.errors.append(error)

    def close(self):
        self.stop.set()
        self.listener.close()
        self.thread.join(timeout=2)
        if self.errors:
            raise AssertionError(f"fixture errors: {self.errors}")


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def raw_replay(path, frame):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(2)
        client.connect(path)
        client.sendall(frame)
        try:
            client.shutdown(socket.SHUT_WR)
        except OSError as error:
            # A fast fixture may send its acknowledgement and close first.
            # Darwin then returns ENOTCONN; the queued reply still must be read.
            if error.errno != errno.ENOTCONN:
                raise
        response = bytearray()
        while b"\n" not in response:
            chunk = client.recv(4096)
            require(chunk, "fixture closed without an acknowledgement")
            response.extend(chunk)
    return json.loads(bytes(response).split(b"\n", 1)[0])


def run(helper):
    require(helper.is_file() and os.access(helper, os.X_OK), f"helper is not executable: {helper}")
    with tempfile.TemporaryDirectory(prefix="si-notch-cli-", dir="/private/tmp") as directory:
        os.chmod(directory, 0o700)
        endpoint = str(Path(directory) / "events.sock")
        fixture = Fixture(endpoint)
        environment = {key: value for key, value in os.environ.items() if key not in ("SSH_CONNECTION", "SSH_TTY")}
        environment.update({"SI_NOTCH_SOCKET": endpoint, "TERM_PROGRAM": "ghostty",
                            "__CFBundleIdentifier": "com.mitchellh.ghostty"})

        def call(command, payload):
            return subprocess.run([str(helper), command, json.dumps(payload)], env=environment,
                                  capture_output=True, text=True, timeout=3, check=False)

        try:
            # A new native SwiftPM debug binary can take over three seconds even
            # for --help. Separate cold launch from the strict IPC deadlines below.
            cold_start = time.monotonic()
            warmup = subprocess.run([str(helper), "--help"], env=environment,
                                    capture_output=True, text=True, timeout=15, check=False)
            cold_start = time.monotonic() - cold_start
            require(warmup.returncode == 0 and "si-notchctl" in warmup.stdout and not warmup.stderr,
                    "helper cold launch failed")
            first = {"type": "agent-turn-complete", "thread-id": str(uuid.uuid4()),
                     "turn-id": str(uuid.uuid4()), "last-assistant-message": "First synthetic turn"}
            result = call("notify", first)
            require(result.returncode == 0 and not result.stdout and not result.stderr,
                    f"first notify was not silent/successful: {result}")
            require(len(fixture.events) == 1, "notify exited before the fixture received its frame")
            require(fixture.events[0][1].get("thread-id") == first["thread-id"], "wrong first thread")

            replay = raw_replay(endpoint, fixture.events[0][0])
            require(replay == {"ok": True, "disposition": "duplicate"},
                    f"exact replay after helper exit was not duplicate: {replay}")

            second = {"type": "agent-turn-complete", "thread-id": str(uuid.uuid4()),
                      "turn-id": str(uuid.uuid4()), "last-assistant-message": "Second synthetic turn"}
            result = call("notify", second)
            require(result.returncode == 0 and not result.stdout and not result.stderr,
                    f"second notify was not silent/successful: {result}")
            require(len(fixture.events) == 3 and fixture.events[2][1].get("thread-id") == second["thread-id"],
                    "second helper process did not deliver its new thread")

            hook = {"hook_event_name": "UserPromptSubmit", "session_id": str(uuid.uuid4()),
                    "prompt": "Synthetic hook event"}
            result = subprocess.run([str(helper), "hook", "--agent", "claude"],
                                    input=json.dumps(hook), env=environment,
                                    capture_output=True, text=True, timeout=3, check=False)
            require(result.returncode == 0 and not result.stdout and not result.stderr,
                    f"hook was not silent/successful: {result}")
            require(len(fixture.events) == 4 and fixture.events[3][1].get("session_id") == hook["session_id"],
                    "hook helper process did not deliver its event")

            require(all(event.get("terminal_bundle_id") == "com.mitchellh.ghostty" for _, event in fixture.events),
                    "notify/hook lost the originating terminal")
            explicit = {"event": "agent.working", "session_id": "explicit-origin", "provider": "custom",
                        "terminal_bundle_id": "com.apple.Terminal"}
            require(call("emit", explicit).returncode == 0, "explicit-origin event failed")
            require(fixture.events[-1][1].get("terminal_bundle_id") == "com.apple.Terminal", "explicit origin overwritten")
            result = subprocess.run([str(helper), "emit", json.dumps({"event": "agent.working",
                "session_id": "remote-origin", "provider": "custom"})], env=environment | {"SSH_TTY": "/dev/pts/1"},
                capture_output=True, text=True, timeout=3, check=False)
            require(result.returncode == 0 and "terminal_bundle_id" not in fixture.events[-1][1],
                    "remote terminal incorrectly tagged as local")

            rejected = {"event": "agent.working", "session_id": "fixture-rejected",
                        "provider": "custom", "fixture_response": "reject"}
            result = call("emit", rejected)
            require(result.returncode == 2 and "fixture_reject" in result.stderr,
                    f"emit did not surface a negative acknowledgement: {result}")
            result = call("notify", first | {"fixture_response": "reject"})
            require(result.returncode == 0 and not result.stdout and not result.stderr,
                    f"notify did not fail open silently: {result}")

            for provider, hook_name, payload, expected_kind in [
                ("gemini", "BeforeAgent", {"session_id": "gemini-fixture"}, "agent.working"),
                ("copilot", "agentStop", {"sessionId": "copilot-fixture"}, "agent.completed"),
                ("cursor", "beforeSubmitPrompt", {"conversation_id": "cursor-fixture"}, "agent.working"),
            ]:
                payload["prompt"] = "DO-NOT-SEND"
                result = subprocess.run([str(helper), "harness-hook", "--agent", provider, "--event", hook_name],
                    input=json.dumps(payload), env=environment, capture_output=True, text=True, timeout=3, check=False)
                expected_output = {"continue": True} if provider == "cursor" else {}
                require(result.returncode == 0 and json.loads(result.stdout) == expected_output and not result.stderr,
                    f"wrong neutral hook response for {provider}")
                delivered = fixture.events[-1][1]
                require(delivered.get("provider") == provider and delivered.get("event") == expected_kind,
                    f"native {provider} hook was not delivered")
                require(delivered.get("terminal_bundle_id") == "com.mitchellh.ghostty", "harness hook lost its origin")
                require("DO-NOT-SEND" not in json.dumps(delivered), "native hook leaked content")

            result = subprocess.run([str(helper), "harness-hook", "--agent", "cursor", "--event", "beforeSubmitPrompt"],
                input="broken json", env=environment, capture_output=True, text=True, timeout=3, check=False)
            require(result.returncode == 0 and json.loads(result.stdout) == {"continue": True},
                "malformed observer input must not block Cursor")

            held = first | {"thread-id": str(uuid.uuid4()), "fixture_response": "hold"}
            started = time.monotonic()
            result = call("notify", held)
            elapsed = time.monotonic() - started
            require(result.returncode == 0 and not result.stdout and not result.stderr and 0.8 <= elapsed < 1.4,
                    f"notify did not bound its acknowledgement wait: {elapsed:.2f}s {result}")
            return {"ok": True, "helper_processes": 13, "frames": len(fixture.events),
                    "cold_start_seconds": round(cold_start, 3),
                    "raw_replay": "duplicate", "timeout_seconds": round(elapsed, 3)}
        finally:
            fixture.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", type=Path,
                        default=Path("build/si-notch.app/Contents/Helpers/si-notchctl"))
    args = parser.parse_args()
    try:
        print(json.dumps(run(args.helper.resolve()), sort_keys=True))
    except (AssertionError, OSError, subprocess.TimeoutExpired) as error:
        parser.exit(1, f"FAIL: {error}\n")


if __name__ == "__main__":
    main()
