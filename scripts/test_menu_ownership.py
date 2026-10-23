import copy
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
import plistlib
import subprocess
import tempfile

spec = importlib.util.spec_from_file_location("repair_menu", Path(__file__).with_name("repair-menu-ownership.py"))
repair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repair)


def location(bundle):
    return {"bundle": {"_0": bundle}}


def entry(owner, items, allowed=True):
    key = location(owner)
    return [key, {"location": key, "menuItemLocations": [location(x) for x in items],
                  "isAllowed": allowed, "futureField": "preserve"}]


class MenuOwnershipTests(unittest.TestCase):
    def test_real_plist_filename_backup_and_single_key_write(self):
        source = entry(repair.BUNDLE_ID, [repair.BUNDLE_ID]) + entry("launcher", [repair.BUNDLE_ID])
        repaired, _ = repair.detach_aliases(source)
        before = {"trackedApplications": plistlib.dumps(source), "showWiFi": True}
        after = {"trackedApplications": plistlib.dumps(repaired), "showWiFi": True}
        original = plistlib.dumps(before)
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            path = home / "Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist"
            path.parent.mkdir(parents=True)
            path.write_bytes(original)
            with patch.object(repair.Path, "home", return_value=home), \
                    patch.object(repair, "read_preferences", side_effect=[(original, before), (original, before), (plistlib.dumps(after), after)]), \
                    patch.object(repair.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as run:
                repair.main()
            command = run.call_args_list[0].args[0]
            self.assertEqual(command[:5], ["/usr/bin/defaults", "write", str(path)[:-6], "trackedApplications", "-data"])
            self.assertEqual(plistlib.loads(bytes.fromhex(command[5])), repaired)
            backups = list((home / ".local/share/ai-pulse/backups").glob("*/controlcenter-before.plist"))
            self.assertEqual(len(backups), 1)
            self.assertEqual(backups[0].read_bytes(), original)

    def test_detaches_only_pulse_from_historical_owners(self):
        pulse = repair.BUNDLE_ID
        source = (entry(pulse, [pulse])
                  + entry("com.openai.codex", ["com.openai.codex", pulse, "other.helper"], False)
                  + entry("com.apple.Terminal", [pulse, "app.sshmonitor.menubar"])
                  + entry("com.anysphere.sand", ["io.tailscale.ipn.macsys"], False))
        original = copy.deepcopy(source)
        result, owners = repair.detach_aliases(source)
        expected = copy.deepcopy(source)
        expected[3]["menuItemLocations"].remove(location(pulse))
        expected[5]["menuItemLocations"].remove(location(pulse))
        self.assertEqual(result, expected)
        self.assertEqual(source, original)
        self.assertEqual(owners, [location("com.openai.codex"), location("com.apple.Terminal")])
        self.assertEqual(repair.detach_aliases(result), (result, []))

    def test_preserves_explicit_pulse_disable_and_other_app_choices(self):
        source = entry(repair.BUNDLE_ID, [repair.BUNDLE_ID], False) + entry("launcher", [repair.BUNDLE_ID], False)
        result, _ = repair.detach_aliases(source)
        self.assertFalse(result[1]["isAllowed"])
        self.assertFalse(result[3]["isAllowed"])
        self.assertEqual(result[3]["menuItemLocations"], [])

    def test_no_detach_without_an_independent_owner(self):
        source = entry("launcher", [repair.BUNDLE_ID])
        self.assertEqual(repair.detach_aliases(source), (source, []))

    def test_similar_names_are_not_aliases(self):
        source = entry(repair.BUNDLE_ID, [repair.BUNDLE_ID]) + entry("launcher", [repair.BUNDLE_ID + ".helper"])
        self.assertEqual(repair.detach_aliases(source), (source, []))

    def test_unknown_formats_are_rejected_without_mutation(self):
        for source in ({}, [location("odd")], [location("owner"), {"location": location("other")}],
                       [location("owner"), {"location": location("owner"), "isAllowed": True,
                                            "menuItemLocations": "invalid"}]):
            original = copy.deepcopy(source)
            with self.assertRaises(ValueError):
                repair.detach_aliases(source)
            self.assertEqual(source, original)


if __name__ == "__main__":
    unittest.main()
