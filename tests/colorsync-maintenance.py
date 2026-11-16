import importlib.util
from pathlib import Path
import plistlib
import tempfile
import subprocess
import unittest
from unittest.mock import patch
import uuid

spec = importlib.util.spec_from_file_location("maintenance", Path(__file__).resolve().parents[1] / "scripts/colorsync-maintenance.py")
maintenance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(maintenance)


def record(number, name="UUyc companion · test"):
    identity = str(uuid.UUID(int=number)).upper()
    return "Device.mntr." + identity, {
        "DeviceDescriptions": {"en": name, "zh_CN": name},
        "FactoryProfiles": {
            "1": {"DeviceProfileURL": str(maintenance.PROFILE_DIRECTORY / (name + "-" + identity + ".icc"))},
            "DeviceDefaultProfileID": "1",
        },
    }


class MaintenanceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        self.cache_path = self.directory / "cache.plist"
        self.output = self.directory / "plan"
        self.cache = dict([record(1), record(2, "DELL U2414H"), record(3, "DELL U2414H")])
        self.original = plistlib.dumps(self.cache, fmt=plistlib.FMT_BINARY)
        self.cache_path.write_bytes(self.original)
        self.cache_path.chmod(0o640)
        self.offline = patch.object(maintenance, "require_offline", return_value=set())
        self.quiet = patch.object(maintenance, "require_quiet", return_value=set())
        self.missing = patch.object(Path, "lstat", side_effect=FileNotFoundError)
        for mock in (self.offline, self.quiet, self.missing):
            mock.start()
            self.addCleanup(mock.stop)
        self.addCleanup(self.temporary.cleanup)

    def test_backup_apply_and_rollback_preserve_other_displays_and_metadata(self):
        before = self.cache_path.stat()
        plan = maintenance.prepare(self.cache_path, self.output)
        self.assertEqual(self.cache_path.read_bytes(), self.original)
        self.assertEqual((self.output / "backup.plist").read_bytes(), self.original)
        self.assertEqual(len(plan["removed"]), 1)
        maintenance.apply_plan(self.output)
        after = self.cache_path.stat()
        expected = {key: value for key, value in self.cache.items() if not maintenance.owned_record(key, value)}
        self.assertEqual(plistlib.loads(self.cache_path.read_bytes()), expected)
        self.assertEqual((after.st_uid, after.st_gid, after.st_mode), (before.st_uid, before.st_gid, before.st_mode))
        maintenance.apply_plan(self.output, rollback=True)
        self.assertEqual(self.cache_path.read_bytes(), self.original)

    def test_online_or_incomplete_or_unrelated_records_are_preserved(self):
        key, value = record(1)
        self.assertEqual(maintenance.stale_records({key: value}, {str(uuid.UUID(int=1))}), [])
        for name in ("DELL U2414H", "UUyc companion impostor", "UUDisplay-other"):
            key, value = record(4, name)
            self.assertEqual(maintenance.stale_records({key: value}, set()), [])
        key, value = record(5)
        value["DeviceDescriptions"]["en"] = "DELL"
        self.assertEqual(maintenance.stale_records({key: value}, set()), [])
        key, value = record(6)
        value["FactoryProfiles"] = {"DeviceDefaultProfileID": "1"}
        self.assertEqual(maintenance.stale_records({key: value}, set()), [])

    def test_existing_inaccessible_custom_or_mismatched_profiles_are_preserved(self):
        key, value = record(7)
        for outcome in (object(), PermissionError()):
            with patch.object(Path, "lstat", return_value=outcome, side_effect=outcome if isinstance(outcome, Exception) else None):
                self.assertEqual(maintenance.stale_records({key: value}, set()), [])
        for path in ("/private/tmp/test.icc", "file://remote/Library/ColorSync/Profiles/Displays/test.icc", "/Library/ColorSync/Profiles/Displays/wrong-uuid.icc", "relative.icc"):
            value["FactoryProfiles"]["1"]["DeviceProfileURL"] = path
            self.assertEqual(maintenance.stale_records({key: value}, set()), [])
        key, value = record(8)
        value["CustomProfiles"] = {"DeviceProfileURL": "/private/tmp/custom.icc"}
        self.assertEqual(maintenance.stale_records({key: value}, set()), [])

    def test_cache_changes_abort_apply_and_rollback(self):
        maintenance.prepare(self.cache_path, self.output)
        newer = self.original + b"new system data"
        self.cache_path.write_bytes(newer)
        with self.assertRaises(ValueError):
            maintenance.apply_plan(self.output)
        self.assertEqual(self.cache_path.read_bytes(), newer)
        with self.assertRaises(ValueError):
            maintenance.apply_plan(self.output, rollback=True)
        self.assertEqual(self.cache_path.read_bytes(), newer)

    def test_profile_appearing_after_preview_aborts_apply(self):
        maintenance.prepare(self.cache_path, self.output)
        with patch.object(Path, "lstat", return_value=object()):
            with self.assertRaises(ValueError):
                maintenance.apply_plan(self.output)
        self.assertEqual(self.cache_path.read_bytes(), self.original)

    def test_tampered_preview_or_backup_aborts(self):
        maintenance.prepare(self.cache_path, self.output)
        (self.output / "cleaned.plist").write_bytes(self.original)
        with self.assertRaises(ValueError):
            maintenance.apply_plan(self.output)
        self.assertEqual(self.cache_path.read_bytes(), self.original)

    def test_failed_snapshot_or_running_service_aborts(self):
        with patch.object(maintenance, "require_offline", side_effect=ValueError("snapshot unavailable")):
            with self.assertRaises(ValueError):
                maintenance.prepare(self.cache_path, self.output)
        maintenance.prepare(self.cache_path, self.output)
        with patch.object(maintenance, "require_quiet", side_effect=ValueError("service running")):
            with self.assertRaises(ValueError):
                maintenance.apply_plan(self.output)
        self.assertEqual(self.cache_path.read_bytes(), self.original)

    def test_symlink_cache_is_rejected(self):
        link = self.directory / "link.plist"
        link.symlink_to(self.cache_path)
        with self.assertRaises(OSError):
            maintenance.prepare(link, self.output)
        self.assertEqual(self.cache_path.read_bytes(), self.original)

    def test_legacy_name_and_file_url_are_supported(self):
        key, value = record(9, "UUDisplay · old")
        value["FactoryProfiles"]["1"]["DeviceProfileURL"] = Path(value["FactoryProfiles"]["1"]["DeviceProfileURL"]).as_uri()
        self.assertEqual(maintenance.stale_records({key: value}, set()), [key])

    def test_color_service_query_is_bounded_in_a_child_process(self):
        with patch.object(subprocess, "run", side_effect=subprocess.TimeoutExpired("query", 1)) as run:
            with self.assertRaises(subprocess.TimeoutExpired):
                maintenance.check_color_service(1)
            self.assertEqual(run.call_args.kwargs["timeout"], 1)
        with self.assertRaises(ValueError):
            maintenance.check_color_service(0)


if __name__ == "__main__":
    unittest.main()
