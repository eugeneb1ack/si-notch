"""Native-ledger recovery after an observer worker dies before its final hook."""
from contextlib import closing, contextmanager
import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest import mock

SOURCE = Path(__file__).resolve().parents[2] / "plugins/hermes/__init__.py"
spec = importlib.util.spec_from_file_location("hermes_recovery_fixture", SOURCE)
plugin = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plugin)


class WorkerRecoveryTests(unittest.TestCase):
    @contextmanager
    def db(self):
        with closing(sqlite3.connect(self.database)) as db:
            with db: yield db

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.database = self.root / "state.db"
        with self.db() as db:
            db.executescript("""
                CREATE TABLE worker_executions(execution_id TEXT PRIMARY KEY,
                    session_id TEXT, generation INTEGER, owner_epoch INTEGER, status TEXT);
                CREATE TABLE session_admissions(admission_id TEXT PRIMARY KEY,
                    generation INTEGER, owner_epoch INTEGER, status TEXT, outcome TEXT);
            """)
        plugin._TRACKED_EXECUTIONS.clear(); plugin._EXECUTION_CURSOR = 0
        plugin._STARTED.clear(); plugin._METADATA.clear(); plugin._TASK_TITLES.clear()
        self.events = []
        self.patches = [
            mock.patch.object(plugin, "_native_database", return_value=self.database),
            mock.patch.object(plugin, "_execution_directory", return_value=self.root / "executions"),
            mock.patch.object(plugin, "_lifecycle_directory", return_value=self.root / "lifecycle"),
            mock.patch.object(plugin, "_settings", return_value={"instanceId": "profile", "showSessionText": True}),
            mock.patch.object(plugin, "_send", side_effect=lambda event: self.events.append(event) or True),
        ]
        for patch in self.patches: patch.start()

    def tearDown(self):
        for patch in reversed(self.patches): patch.stop()
        self.tmp.cleanup()

    def start(self, session="native-session", admission="a", turn="native-turn"):
        with self.db() as db:
            db.execute("INSERT INTO worker_executions VALUES(?,?,1,7,'running')",
                       ("admission-worker:" + admission, session))
            db.execute("INSERT INTO session_admissions VALUES(?,1,7,'started',NULL)", (admission,))
        plugin.pre_llm_call(session_id=session, turn_id=turn, user_message="PRIVATE TASK TEXT")

    def settle(self, outcome, admission="a", status="terminal"):
        with self.db() as db:
            db.execute("UPDATE worker_executions SET status='terminal' WHERE execution_id=?",
                       ("admission-worker:" + admission,))
            db.execute("UPDATE session_admissions SET status=?,outcome=? WHERE admission_id=?",
                       (status, outcome, admission))

    def journal(self):
        return list((self.root / "executions").glob("*.json"))

    def test_killed_worker_keeps_only_private_opaque_execution_coordinates(self):
        self.start()
        path, = self.journal()
        text = path.read_text()
        self.assertNotIn("PRIVATE TASK TEXT", text)
        self.assertNotIn("native-session", text)
        self.assertNotIn("native-turn", text)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(json.loads(text)["execution_id"], "admission-worker:a")

    def test_native_interruption_closes_lost_worker_without_reporting_success(self):
        self.start(); self.settle("interrupted")
        before = self.database.read_bytes()
        self.events.clear(); plugin._TRACKED_EXECUTIONS.clear()  # The owning gateway recovers it.
        plugin._reconcile_executions()
        self.assertEqual([e["event"] for e in self.events], ["session.end"])
        self.assertEqual(self.events[0]["session_id"], plugin._session_key("native-session"))
        self.assertEqual(self.events[0]["turn_id"], plugin._opaque_id("native-turn", "turn-"))
        self.assertEqual(self.database.read_bytes(), before)
        self.assertEqual(self.journal(), [])

    def test_completed_and_failed_native_verdicts_survive_missing_hook_and_ack(self):
        for outcome, kind in [("completed", "agent.completed"), ("failed", "agent.failed")]:
            with self.subTest(outcome=outcome):
                self.start(session=outcome, admission=outcome, turn=outcome)
                self.settle(outcome, admission=outcome)
                with mock.patch.object(plugin, "_send", return_value=False):
                    plugin._reconcile_executions()
                receipt, = (self.root / "lifecycle").glob("*.json")
                saved = json.loads(receipt.read_text())
                self.assertEqual(saved["event"], kind)
                self.assertEqual(self.journal(), [])
                self.events.clear(); plugin._TRACKED_EXECUTIONS.clear()
                plugin._drain_lifecycle(); plugin._reconcile_executions()
                self.assertEqual(self.events, [saved])
                self.assertFalse(receipt.exists())

    def test_unknown_is_not_success_and_can_later_reconcile_a_committed_resolution(self):
        self.start(); self.settle(None, status="unknown"); self.events.clear()
        plugin._reconcile_executions(); plugin._reconcile_executions()
        self.assertEqual([e["event"] for e in self.events], ["agent.waiting"])
        self.assertEqual(len(self.journal()), 1)
        self.settle("completed"); plugin._reconcile_executions()
        self.assertEqual([e["event"] for e in self.events], ["agent.waiting", "agent.completed"])
        self.assertEqual(self.journal(), [])

    def test_pending_or_unrecognized_native_outcome_never_becomes_done(self):
        self.start(); self.events.clear(); plugin._reconcile_executions()
        self.assertEqual(self.events, [])
        self.settle("future-unknown-outcome"); plugin._reconcile_executions()
        self.assertEqual(self.events, [])
        self.assertEqual(len(self.journal()), 1)

    def test_admission_verdict_belongs_only_to_its_latest_goal_loop_turn(self):
        self.start()
        plugin.pre_llm_call(session_id="native-session", turn_id="second-turn")
        self.assertEqual(len(self.journal()), 1)
        plugin.on_session_end(session_id="native-session", turn_id="native-turn", completed=False, interrupted=False)
        self.assertEqual(len(self.journal()), 1, "a late old hook must not delete the newer turn's journal")
        self.settle("completed"); self.events.clear(); plugin._reconcile_executions()
        self.assertEqual(len(self.events), 1)
        self.assertEqual(self.events[0]["turn_id"], plugin._opaque_id("second-turn", "turn-"))

    def test_normal_hook_transfers_ownership_to_durable_outbox_before_forgetting(self):
        self.start()
        with mock.patch.object(plugin, "_send", return_value=False):
            plugin.on_session_end(session_id="native-session", turn_id="native-turn", completed=True)
        self.assertEqual(self.journal(), [])
        self.assertEqual(len(list((self.root / "lifecycle").glob("*.json"))), 1)

    def test_generation_epoch_and_profile_mismatches_cannot_recover_another_execution(self):
        self.start(); self.settle("completed"); path, = self.journal()
        original = json.loads(path.read_text()); self.events.clear()
        for key, value in [("generation", 2), ("owner_epoch", 8), ("admission_generation", 2),
                           ("admission_epoch", 8), ("connection_id", "another-profile")]:
            path.write_text(json.dumps(dict(original, **{key: value})))
            plugin._reconcile_executions()
            self.assertEqual(self.events, [], key)
            self.assertTrue(path.exists(), key)

    def test_newer_physical_execution_prevents_old_receipt_overwriting_its_turn(self):
        self.start(); self.settle("completed"); self.events.clear()
        with self.db() as db:
            db.execute("INSERT INTO worker_executions VALUES('new-execution','native-session',2,7,'running')")
        plugin._reconcile_executions()
        self.assertEqual(self.events, [])
        self.assertEqual(self.journal(), [])

    def test_retry_after_receipt_handoff_failure_keeps_original_id_and_timestamp(self):
        self.start(); self.settle("completed"); seen = []
        with mock.patch.object(plugin, "_queue_lifecycle", side_effect=lambda p: seen.append(p) or False):
            with mock.patch.object(plugin.time, "time", return_value=1000): plugin._reconcile_executions()
            with mock.patch.object(plugin.time, "time", return_value=2000): plugin._reconcile_executions()
        self.assertEqual(len(seen), 2)
        self.assertEqual(seen[0], seen[1])
        self.assertEqual(seen[0]["timestamp"], 1000)

    def test_bad_journal_does_not_poison_recovery_and_each_tick_delivers_at_most_one(self):
        self.start(session="s1", admission="a1", turn="t1")
        self.start(session="s2", admission="a2", turn="t2")
        self.settle("completed", admission="a1"); self.settle("interrupted", admission="a2")
        (self.root / "executions" / "000-invalid.json").write_text("[]")
        self.events.clear(); plugin._reconcile_executions()
        self.assertEqual(len(self.events), 1)
        plugin._reconcile_executions()
        self.assertEqual(len(self.events), 2)

    def test_history_without_a_recorded_execution_is_not_imported(self):
        self.start(); self.settle("completed")
        for path in self.journal(): path.unlink()
        self.events.clear(); plugin._reconcile_executions()
        self.assertEqual(self.events, [])

    def test_missing_or_changed_native_schema_fails_open_without_guessing(self):
        self.database.unlink()
        with self.db() as db: db.execute("CREATE TABLE newer_schema(id TEXT)")
        plugin.pre_llm_call(session_id="s", turn_id="t")
        plugin._reconcile_executions()
        self.assertEqual(self.journal(), [])
        self.assertEqual(self.events[-1]["event"], "agent.working")


if __name__ == "__main__": unittest.main()
