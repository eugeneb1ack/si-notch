"""Hermes plugin -> built si-notchctl -> private Unix socket ACK, without a model."""

import importlib.util
import json
import os
from pathlib import Path
import socket
import tempfile
import threading
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
PLUGIN = ROOT / "plugins/hermes/__init__.py"
spec = importlib.util.spec_from_file_location("si_notch_hermes_socket_test", PLUGIN)
plugin = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plugin)


class HermesSocketTests(unittest.TestCase):
    @unittest.skipUnless(os.environ.get("SI_NOTCH_HELPER"), "set SI_NOTCH_HELPER to test the built helper")
    def test_completion_retries_real_helper_rejection_without_changing_event_identity(self):
        helper = str(Path(os.environ["SI_NOTCH_HELPER"]).resolve())
        with tempfile.TemporaryDirectory(prefix="completion-ack-", dir="/private/tmp") as directory:
            os.chmod(directory, 0o700)
            endpoint = str(Path(directory) / "events.sock")
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            listener.bind(endpoint); os.chmod(endpoint, 0o600); listener.listen(2); listener.settimeout(4)
            seen, errors = [], []
            def serve():
                try:
                    for accepted in (False, True):
                        connection, _ = listener.accept()
                        with connection:
                            frame = bytearray()
                            while b"\n" not in frame: frame.extend(connection.recv(8192))
                            seen.append(json.loads(bytes(frame).split(b"\n", 1)[0]))
                            connection.sendall(json.dumps({"ok": accepted, "disposition": "applied"}).encode() + b"\n")
                except Exception as error: errors.append(error)
            thread = threading.Thread(target=serve, daemon=True); thread.start()
            try:
                with mock.patch.dict(os.environ, {"SI_NOTCH_CLI": helper, "SI_NOTCH_SOCKET": endpoint}), \
                     mock.patch.object(plugin, "_lifecycle_directory", return_value=Path(directory) / "outbox"):
                    plugin._DISABLED_UNTIL = 0
                    plugin.on_session_end(session_id="s", turn_id="t", completed=True)
                    self.assertEqual(len(list(plugin._lifecycle_directory().glob("*.json"))), 1)
                    plugin._DISABLED_UNTIL = 0; plugin._drain_lifecycle()
                    self.assertEqual(list(plugin._lifecycle_directory().glob("*.json")), [])
                thread.join(4)
                self.assertEqual(errors, []); self.assertFalse(thread.is_alive())
                self.assertEqual(len(seen), 2)
                for field in ["id", "session_id", "turn_id", "timestamp", "event"]:
                    self.assertEqual(seen[0][field], seen[1][field])
            finally: listener.close()

    @unittest.skipUnless(os.environ.get("SI_NOTCH_HELPER"), "set SI_NOTCH_HELPER to test the built helper")
    def test_usage_waits_for_commit_ack_and_replays_identical_request_after_failure(self):
        helper = str(Path(os.environ["SI_NOTCH_HELPER"]).resolve())
        with tempfile.TemporaryDirectory(prefix="usage-ack-", dir="/private/tmp") as directory:
            os.chmod(directory, 0o700)
            endpoint = str(Path(directory) / "events.sock")
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            listener.bind(endpoint); os.chmod(endpoint, 0o600); listener.listen(3); listener.settimeout(4)
            seen, errors = [], []
            def serve():
                try:
                    for disposition in ("applied", "usage_committed"):
                        connection, _ = listener.accept()
                        with connection:
                            frame = bytearray()
                            while b"\n" not in frame: frame.extend(connection.recv(8192))
                            seen.append(json.loads(bytes(frame).split(b"\n", 1)[0]))
                            connection.sendall(json.dumps({"ok": True, "disposition": disposition}).encode() + b"\n")
                except Exception as error: errors.append(error)
            thread = threading.Thread(target=serve, daemon=True); thread.start()
            try:
                with mock.patch.dict(os.environ, {"SI_NOTCH_CLI": helper, "SI_NOTCH_SOCKET": endpoint}), mock.patch.object(plugin, "_spool_directory", return_value=Path(directory) / "outbox"):
                    plugin._DISABLED_UNTIL = 0
                    plugin.post_api_request(session_id="s", turn_id="t", api_request_id="r", usage={"input_tokens": 20, "output_tokens": 2})
                    self.assertEqual(len(list(plugin._spool_directory().glob("*.json"))), 1)
                    plugin._DISABLED_UNTIL = 0; plugin._drain_usage()
                    self.assertEqual(list(plugin._spool_directory().glob("*.json")), [])
                thread.join(4)
                self.assertEqual(errors, []); self.assertFalse(thread.is_alive())
                self.assertEqual(len(seen), 2); self.assertEqual(seen[0], seen[1])
            finally: listener.close()

    @unittest.skipUnless(os.environ.get("SI_NOTCH_HELPER"), "set SI_NOTCH_HELPER to test the built helper")
    def test_plugin_to_real_helper_to_acknowledging_socket(self):
        helper = Path(os.environ["SI_NOTCH_HELPER"]).resolve()
        self.assertTrue(helper.is_file() and os.access(helper, os.X_OK))
        seen = []
        errors = []
        with tempfile.TemporaryDirectory(prefix="si-notch-hermes-", dir="/private/tmp") as directory:
            os.chmod(directory, 0o700)
            endpoint = str(Path(directory) / "events.sock")
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            listener.bind(endpoint)
            os.chmod(endpoint, 0o600)
            listener.listen(5)
            listener.settimeout(3)

            def serve():
                try:
                    for _ in range(5):
                        connection, _ = listener.accept()
                        with connection:
                            connection.settimeout(2)
                            frame = bytearray()
                            while b"\n" not in frame:
                                chunk = connection.recv(8192)
                                if not chunk:
                                    raise AssertionError("helper closed without a complete frame")
                                frame.extend(chunk)
                            seen.append(json.loads(bytes(frame).split(b"\n", 1)[0]))
                            connection.sendall(b'{"ok":true,"disposition":"applied"}\n')
                except Exception as error:
                    errors.append(error)

            thread = threading.Thread(target=serve, daemon=True)
            thread.start()
            try:
                with mock.patch.dict(os.environ, {"SI_NOTCH_CLI": str(helper), "SI_NOTCH_SOCKET": endpoint}), \
                     mock.patch.object(plugin, "_lifecycle_directory", return_value=Path(directory) / "lifecycle"):
                    plugin.on_session_start(session_id="secret-id", model="test-model", prompt="PRIVATE PROMPT")
                    plugin.pre_api_request(session_id="secret-id", model="test-model", user_message="PRIVATE PROMPT",
                                           request={"body": {"model": "test-model", "reasoning_effort": "high", "messages": ["PRIVATE PROMPT"]}})
                    plugin.post_tool_call(session_id="secret-id", tool_name="terminal", status="success",
                                          args={"token": "PRIVATE TOKEN"}, result="PRIVATE RESULT")
                    plugin.on_session_end(session_id="secret-id", completed=True, output="PRIVATE RESULT")
                    plugin.on_session_finalize(session_id="secret-id")
                thread.join(timeout=3)
                self.assertFalse(thread.is_alive())
                self.assertEqual(errors, [])
                self.assertEqual([event["event"] for event in seen], [
                    "session.start", "agent.working", "tool.finish", "agent.completed", "session.end",
                ])
                self.assertTrue(all("sequence" not in event for event in seen))
                self.assertEqual(len({event["id"] for event in seen}), len(seen))
                for event in seen:
                    self.assertEqual(event["provider"], "hermes")
                    self.assertEqual(event["session_id"], seen[0]["session_id"])
                    self.assertEqual(event["model"], "test-model")
                    self.assertEqual(set(event) - {"tool_name"}, {
                        "event", "session_id", "provider", "id", "timestamp", "title", "model", "reasoning_effort",
                    })
                self.assertEqual(seen[1]["reasoning_effort"], "high")
                combined = json.dumps(seen)
                for secret in ("secret-id", "PRIVATE PROMPT", "PRIVATE TOKEN", "PRIVATE RESULT"):
                    self.assertNotIn(secret, combined)
            finally:
                listener.close()


if __name__ == "__main__":
    unittest.main()
