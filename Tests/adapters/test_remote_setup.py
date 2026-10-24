"""Exercise remote setup with JSON-compatible YAML fixtures; no user profiles or SSH."""
import base64
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
# The helper runs in Hermes' environment (PyYAML is already installed there).
# These fixtures use YAML's JSON subset so the repository needs no dependency.
yaml_fixture = types.SimpleNamespace(safe_load=json.loads)
with mock.patch.dict(sys.modules, yaml=yaml_fixture):
    spec = importlib.util.spec_from_file_location("remote_setup", ROOT / "scripts/remote-hermes-setup.py")
    setup = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(setup)


class RemoteSetupTests(unittest.TestCase):
    def test_new_bundle_updates_configure_tool_and_tracks_it_in_snapshot(self):
        source = (ROOT / 'plugins/hermes/configure.py').read_bytes()
        self.request['sources']['configure'] = base64.b64encode(source).decode()
        result = self.preview()
        self.assertIn(str(self.home / 'plugins/si-notch/configure.py'), result['paths'])
        self.assertIn(str(self.profile / 'plugins/si-notch/configure.py'), result['paths'])
        self.assertEqual(result['file_count'], 9)
        receipt = setup.apply(self.request, self.home, self.cli, self.relay, self.socket)
        self.assertTrue(receipt['changed'])
        self.assertEqual((self.profile / 'plugins/si-notch/configure.py').read_bytes(), source)
        snapshot = setup.inspect(self.home, self.relay, self.socket)[0]['snapshot']
        (self.profile / 'plugins/si-notch/configure.py').write_bytes(source + b'\n')
        self.assertNotEqual(setup.inspect(self.home, self.relay, self.socket)[0]['snapshot'], snapshot)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.home = self.root / ".hermes"
        self.home.mkdir(mode=0o700)
        self.config = self.home / "config.yaml"
        self.original = {"model": "unchanged", "hooks": {"notify": ["keep"]}, "plugins": {"enabled": ["other"], "disabled": ["disabled-other"]}}
        self.config.write_text(json.dumps(self.original))
        self.profile = self.home / "profiles/editor"
        self.profile.mkdir(parents=True)
        (self.profile / "config.yaml").write_text(json.dumps({"tools": ["keep"]}))
        self.relay = self.root / ".local/bin/si-notchctl"
        self.socket = self.root / "run/events.sock"
        self.cli = self.root / "hermes"
        self.cli.write_text('''#!/usr/bin/python3
import json,sys
from pathlib import Path
home=Path(__file__).parent/'.hermes'
profile=sys.argv[2]
if profile!='default': home=home/'profiles'/profile
path=home/'config.yaml'
config=json.loads(path.read_text())
plugins=config.setdefault('plugins',{})
for key in ('enabled','disabled'):
    plugins[key]=[v for v in plugins.get(key,[]) if v!='si-notch']
plugins['enabled' if sys.argv[4]=='enable' else 'disabled'].append('si-notch')
path.write_text(json.dumps(config))
''')
        self.cli.chmod(0o700)
        self.activation = types.SimpleNamespace(reload_running_gateway=lambda: {"reloaded": True, "plugins": ["si-notch"]})
        patcher = mock.patch.dict(sys.modules, {"hermes_cli": types.ModuleType("hermes_cli"), "hermes_cli.plugins_activation": self.activation})
        patcher.start(); self.addCleanup(patcher.stop)
        patcher = mock.patch.dict(setup.os.environ, {}, clear=False)
        patcher.start(); self.addCleanup(patcher.stop)
        self.request = {"profiles": [{"id": "default", "display_name": "lain", "enabled": True, "show_session_text": True},
                                      {"id": "editor", "display_name": "Editor", "enabled": True, "show_session_text": False}],
                        "sources": {key: base64.b64encode((ROOT / path).read_bytes()).decode()
                                    for key, path in {"plugin_python": "plugins/hermes/__init__.py",
                                                      "manifest": "plugins/hermes/plugin.yaml",
                                                      "relay": "plugins/hermes/relay.py"}.items()}}
        self.request["snapshot"] = setup.inspect(self.home, self.relay, self.socket)[0]["snapshot"]

    def preview(self):
        result, _, _ = setup.plan(self.request, self.home, self.relay, self.socket)
        self.request["plan_id"] = result["plan_id"]
        return result

    def test_inspection_and_preview_are_read_only_and_omit_private_configuration(self):
        before = sorted(str(p) for p in self.root.rglob('*'))
        result = self.preview()
        self.assertEqual(before, sorted(str(p) for p in self.root.rglob('*')))
        self.assertEqual(self.original, json.loads(self.config.read_text()))
        self.assertEqual(result["config_count"], 2)
        self.assertEqual(result["file_count"], 7)
        snapshot, _ = setup.inspect(self.home, self.relay, self.socket)
        self.assertNotIn("unchanged", json.dumps(snapshot))
        self.assertTrue(snapshot["profiles"][0]["connection_id"].startswith("hermes-instance-"))

    def test_cloned_profiles_with_shared_identity_are_rejected_without_changing_either(self):
        files = []
        for home in (self.home, self.profile):
            directory = home / 'plugins/si-notch'
            directory.mkdir(parents=True)
            path = directory / 'si-notch.json'
            path.write_text(json.dumps({'instanceId': 'copied-profile', 'displayName': 'Same name'}))
            files.append(path)
        before = [path.read_bytes() for path in files]
        with self.assertRaisesRegex(ValueError, 'share an instanceId'):
            setup.inspect(self.home, self.relay, self.socket)
        self.assertEqual([path.read_bytes() for path in files], before)

    def test_apply_is_bound_to_preview_preserves_hooks_and_backs_up_exact_files(self):
        original = self.config.read_bytes()
        self.preview()
        with mock.patch.object(setup.Path, "home", return_value=self.root):
            receipt = setup.apply(self.request, self.home, self.cli, self.relay, self.socket)
            replay = setup.apply(self.request, self.home, self.cli, self.relay, self.socket)
        self.assertEqual(receipt, replay)
        self.request["profiles"][0]["display_name"] = "different intent"
        with self.assertRaisesRegex(ValueError, "preview does not match"):
            setup.apply(self.request, self.home, self.cli, self.relay, self.socket)
        self.assertTrue(all(p["loaded"] for p in receipt["profiles"]))
        config = json.loads(self.config.read_text())
        self.assertEqual(setup.scrub(config), setup.scrub(self.original))
        self.assertIn("si-notch", config["plugins"]["enabled"])
        settings = json.loads((self.home / "plugins/si-notch/si-notch.json").read_text())
        self.assertEqual(settings["displayName"], "lain")
        self.assertEqual(settings["socketPath"], str(self.socket))
        backup = Path(receipt["backup"])
        manifest = json.loads((backup / "files.json").read_text())
        entry = next(p for p in manifest if p["path"] == str(self.config))
        self.assertEqual((backup / entry["backup"]).read_bytes(), original)
        self.assertEqual(self.socket.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.relay.stat().st_mode & 0o777, 0o700)

    def test_stale_snapshot_or_changed_selection_cannot_apply(self):
        self.preview()
        self.request["profiles"][0]["display_name"] = "changed"
        with self.assertRaisesRegex(ValueError, "preview does not match"):
            setup.apply(self.request, self.home, self.cli, self.relay, self.socket)
        self.assertFalse((self.home / "plugins").exists())
        self.request["profiles"][0]["display_name"] = "lain"
        self.config.write_text(json.dumps({**self.original, "model": "changed externally"}))
        with self.assertRaisesRegex(ValueError, "Remote settings changed"):
            setup.apply(self.request, self.home, self.cli, self.relay, self.socket)
        self.assertFalse((self.home / "plugins").exists())

    def test_foreign_files_and_loose_socket_directory_are_rejected(self):
        plugin = self.home / "plugins/si-notch"
        plugin.mkdir(parents=True)
        (plugin / "__init__.py").write_text("another integration")
        self.request["snapshot"] = setup.inspect(self.home, self.relay, self.socket)[0]["snapshot"]
        with self.assertRaisesRegex(ValueError, "overwrite another integration"):
            self.preview()
        self.socket.parent.mkdir(mode=0o755)
        with self.assertRaisesRegex(ValueError, "0700"):
            setup.inspect(self.home, self.relay, self.socket)

    def test_disable_changes_only_allow_list_and_keeps_plugin_files(self):
        self.preview()
        with mock.patch.object(setup.Path, "home", return_value=self.root):
            setup.apply(self.request, self.home, self.cli, self.relay, self.socket)
        before = (self.home / "plugins/si-notch/__init__.py").read_bytes()
        self.request["snapshot"] = setup.inspect(self.home, self.relay, self.socket)[0]["snapshot"]
        self.request["profiles"][0]["enabled"] = False
        self.preview()
        with mock.patch.object(setup.Path, "home", return_value=self.root):
            setup.apply(self.request, self.home, self.cli, self.relay, self.socket)
        self.assertFalse(setup.plugin_enabled(json.loads(self.config.read_text())))
        self.assertEqual((self.home / "plugins/si-notch/__init__.py").read_bytes(), before)

    def test_profile_identity_matches_the_plugin(self):
        spec = importlib.util.spec_from_file_location("plugin_identity_fixture", ROOT / "plugins/hermes/__init__.py")
        plugin = importlib.util.module_from_spec(spec); spec.loader.exec_module(plugin)
        current, _ = setup.inspect(self.home, self.relay, self.socket)
        instance = setup.sha((setup.platform.node() + ":" + str(self.home)).encode())
        with mock.patch.object(plugin, "_settings", return_value={"instanceId": instance}):
            self.assertEqual(plugin._connection_id(), current["profiles"][0]["connection_id"])

    def test_single_default_profile_install_and_repeat(self):
        (self.profile / "config.yaml").unlink()
        self.profile.rmdir()
        self.request["profiles"] = [{"id": "default", "display_name": "Personal assistant", "enabled": True, "show_session_text": False}]
        snapshot, _ = setup.inspect(self.home, self.relay, self.socket)
        self.assertEqual([p["id"] for p in snapshot["profiles"]], ["default"])
        self.request["snapshot"] = snapshot["snapshot"]
        self.preview()
        with mock.patch.object(setup.Path, "home", return_value=self.root):
            receipt = setup.apply(self.request, self.home, self.cli, self.relay, self.socket)
        self.assertEqual([p["id"] for p in receipt["profiles"]], ["default"])
        self.assertTrue(receipt["profiles"][0]["loaded"])
        current, _ = setup.inspect(self.home, self.relay, self.socket)
        self.request["snapshot"] = current["snapshot"]
        repeated = self.preview()
        self.assertEqual(repeated["file_count"], 0)
        self.assertEqual(repeated["config_count"], 0)
        self.assertEqual(setup.scrub(json.loads(self.config.read_text())), setup.scrub(self.original))

    def test_arbitrary_profile_names_and_selective_installation(self):
        self.profile.rename(self.profile.with_name("lab_17"))
        extra = self.home / "profiles/qa-204"
        extra.mkdir()
        (extra / "config.yaml").write_text(json.dumps({"hooks": {"notify": ["preserve"]}, "model": "other"}))
        snapshot, _ = setup.inspect(self.home, self.relay, self.socket)
        self.assertEqual({p["id"] for p in snapshot["profiles"]}, {"default", "lab_17", "qa-204"})
        identities = {p["id"]: p["connection_id"] for p in snapshot["profiles"]}
        self.assertEqual(len(set(identities.values())), 3)
        self.request["snapshot"] = snapshot["snapshot"]
        self.request["profiles"] = [{"id": p["id"], "display_name": "Assistant " + p["id"],
                                      "enabled": p["id"] != "default", "show_session_text": p["id"] == "qa-204"}
                                     for p in snapshot["profiles"]]
        self.preview()
        with mock.patch.object(setup.Path, "home", return_value=self.root):
            receipt = setup.apply(self.request, self.home, self.cli, self.relay, self.socket)
        self.assertEqual({p["id"] for p in receipt["profiles"]}, {"lab_17", "qa-204"})
        self.assertEqual(json.loads(self.config.read_text()), self.original)
        self.assertFalse((self.home / "plugins/si-notch").exists())
        for name in ("lab_17", "qa-204"):
            plugin = self.home / "profiles" / name / "plugins/si-notch"
            self.assertEqual((plugin / "__init__.py").read_bytes(), (ROOT / "plugins/hermes/__init__.py").read_bytes())
            settings = json.loads((plugin / "si-notch.json").read_text())
            self.assertEqual(settings["showSessionText"], name == "qa-204")
        current, _ = setup.inspect(self.home, self.relay, self.socket)
        self.assertEqual({p["id"]: p["connection_id"] for p in current["profiles"]}, identities)
        self.assertEqual(json.loads((extra / "config.yaml").read_text())["hooks"], {"notify": ["preserve"]})


if __name__ == '__main__':
    unittest.main()
