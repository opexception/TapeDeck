"""Integration tests with GNU tar and regular-file tapes, without root or NFS."""

import json
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
GNU_TAR = shutil.which(os.environ.get("TAR_COMMAND", "tar"))
BASH = shutil.which("bash")
SPEC = importlib.util.spec_from_file_location("tape_metadata", ROOT / "tape_metadata.py")
METADATA = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(METADATA)


class BackupIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not GNU_TAR or "GNU tar" not in subprocess.check_output(
                [GNU_TAR, "--version"], text=True):
            raise unittest.SkipTest("GNU tar required; set TAR_COMMAND=gtar if necessary")
        if not shutil.which("flock"):
            raise unittest.SkipTest("flock required")
        version = subprocess.check_output([BASH, "-c", 'echo "${BASH_VERSINFO[0]}"'], text=True)
        if int(version) < 4:
            raise unittest.SkipTest("Bash 4.1+ required")

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir=os.environ.get("TAPEBACKUP_TEST_TMPDIR"))
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve() / 'backup "test"'
        self.root.mkdir()
        self.scripts = self.root / "scripts"
        self.scripts.mkdir()
        for name in ("tapeBackup.sh", "tape_metadata.py"):
            shutil.copy2(ROOT / name, self.scripts / name)
        self.source = self.root / "source"
        self.source.mkdir()
        (self.source / "unchanged.txt").write_text("retain me\n")
        (self.source / "deleted.txt").write_text("remove me\n")
        (self.source / 'quotes" and\nnewline.txt').write_text("JSON escaping\n")
        (self.source / "link").symlink_to("unchanged.txt")
        self.db = self.root / "db"
        self.catalog = self.root / "permanent" / "backups.jsonl"
        self.state = self.root / "mounted"
        self.commands = self.root / "commands.log"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        stub = '''#!/usr/bin/env python3
import os
from pathlib import Path
import sys
name = Path(sys.argv[0]).name
with open(os.environ["TEST_COMMANDS"], "a") as log:
    log.write(name + " " + repr(sys.argv[1:]) + "\\n")
state = Path(os.environ["TEST_STATE"])
if name == "mountpoint":
    sys.exit(0 if state.exists() else 1)
if name == "mount":
    if os.environ.get("TEST_MOUNT_FAIL"):
        sys.exit(1)
    state.touch()
elif name == "umount":
    state.unlink()
'''
        for name in ("mount", "mountpoint", "umount", "mt"):
            path = self.bin / name
            path.write_text(stub)
            path.chmod(0o755)
        wrapper = self.bin / "test-tar"
        wrapper.write_text('''#!/usr/bin/env python3
import os
from pathlib import Path
import sys
args = sys.argv[1:]
if "--create" in args and os.environ.get("TEST_TAR_FAIL"):
    for arg in args:
        if arg.startswith("--listed-incremental="):
            Path(arg.split("=", 1)[1]).write_text("failed snapshot")
    sys.exit(42)
if "--create" in args and os.environ.get("TEST_COMMIT_FAIL"):
    # Let tar finish, then make permanent catalog promotion fail.
    import subprocess
    status = subprocess.call([os.environ["TEST_REAL_TAR"], *args])
    if status == 0:
        catalog = Path(os.environ["METADATA_FILE"])
        catalog.unlink()
        catalog.mkdir()
    sys.exit(status)
if "--create" in args and os.environ.get("TEST_MULTIVOLUME"):
    args += ["--tape-length=20K"]
    args += ["--file=" + os.environ["TAPE_DEVICE"] + "." + str(i) for i in range(2, 16)]
os.execv(os.environ["TEST_REAL_TAR"], [os.environ["TEST_REAL_TAR"], *args])
''')
        wrapper.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        MOUNT_POINT=str(self.source), BACKUP_DB_DIR=str(self.db),
                        METADATA_FILE=str(self.catalog), NFS_SOURCE='nas:/export/"quoted"',
                        TAR_COMMAND=str(wrapper), ENABLE_ROOT_CHECK="false", ENABLE_LOCKING="true",
                        LOCK_FILE=str(self.root / "drive.lock"), LOCK_TIMEOUT="0", DEBUG_LEVEL="0",
                        TEST_COMMANDS=str(self.commands), TEST_STATE=str(self.state), TEST_REAL_TAR=GNU_TAR)

    def run_backup(self, tape="tape.tar", options=(), success=True, **environment):
        env = dict(self.env, TAPE_DEVICE=str(self.root / tape), **environment)
        result = subprocess.run([BASH, str(self.scripts / "tapeBackup.sh"), *options],
                                env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.state.exists(), "script must unmount even after failures")
        return result

    def records(self):
        return [json.loads(line) for line in self.catalog.read_text().splitlines()]

    def restore(self, tapes, destination):
        destination.mkdir(exist_ok=True)
        command = [GNU_TAR, "--extract", "--multi-volume", "--listed-incremental=/dev/null",
                   "--no-same-owner", "-C", str(destination)]
        command.extend("--file=" + str(tape) for tape in tapes)
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_full_incremental_indexes_and_restore(self):
        self.run_backup("full.tar")
        first = self.records()[0]
        self.assertFalse(first["incremental"])
        self.assertEqual(first["required_backups"], [first["backup_id"]])
        self.assertEqual(first["status"], "complete")
        self.assertEqual(first["file_count"], 3)
        self.assertEqual(first["volume_count"], 1)
        names = subprocess.check_output([GNU_TAR, "--list", "--file=" + str(self.root / "full.tar")], text=True)
        # GNU tar prints the volume label first, followed by archive members.
        self.assertEqual(names.splitlines()[1], first["manifest_member"])
        embedded = json.loads(subprocess.check_output([
            GNU_TAR, "--extract", "--to-stdout", "--occurrence=1",
            "--file=" + str(self.root / "full.tar"), first["manifest_member"]], text=True))
        self.assertEqual(embedded["status"], "prepared")
        self.assertEqual(embedded["backup_id"], first["backup_id"])
        self.assertIn(".manifests_included", names.splitlines())
        for directory in (self.db, self.source / ".tapebackup", self.catalog.parent):
            self.assertEqual(json.loads((directory / Path(first["manifest_path"]).name).read_text()), first)
            self.assertTrue((directory / Path(first["inventory_path"]).name).is_file())
        indexed = [json.loads(line) for line in Path(first["inventory_path"]).read_text().splitlines()]
        self.assertTrue(any(item["path"].endswith('quotes" and\nnewline.txt') for item in indexed))
        self.assertTrue(any(item.get("target") == "unchanged.txt" for item in indexed))
        before = Path(first["snapshot_db"]).read_bytes()
        time.sleep(1.05)
        (self.source / "deleted.txt").unlink()
        (self.source / "added.txt").write_text("new file\n")
        self.run_backup("incremental.tar")
        second = self.records()[1]
        self.assertTrue(second["incremental"])
        self.assertEqual(second["parent_backup_id"], first["backup_id"])
        self.assertEqual(second["full_backup_id"], first["backup_id"])
        self.assertEqual(second["required_backups"], [first["backup_id"], second["backup_id"]])
        self.assertEqual(Path(second["previous_snapshot"]).read_bytes(), before)
        self.assertEqual(Path(first["snapshot_history"]).read_bytes(), before)
        names = subprocess.check_output([
            GNU_TAR, "--list", "--file=" + str(self.root / "incremental.tar")], text=True).splitlines()
        self.assertNotIn(second["archive_source"] + "/unchanged.txt", names)
        self.assertFalse(any(name.startswith(second["archive_source"] + "/.tapebackup") for name in names))
        destination = self.root / "restore"
        self.restore([self.root / "full.tar"], destination)
        self.restore([self.root / "incremental.tar"], destination)
        restored = destination / second["archive_source"]
        self.assertEqual((restored / "unchanged.txt").read_text(), "retain me\n")
        self.assertEqual((restored / "added.txt").read_text(), "new file\n")
        self.assertFalse((restored / "deleted.txt").exists())
        self.assertTrue((restored / "link").is_symlink())

    def test_failed_tar_does_not_advance_snapshot_or_catalog(self):
        self.run_backup()
        record = self.records()[0]
        snapshot = Path(record["snapshot_db"])
        before = snapshot.read_bytes()
        catalog = self.catalog.read_bytes()
        latest = Path(str(snapshot) + ".latest.json").read_bytes()
        self.run_backup("failed.tar", success=False, TEST_TAR_FAIL="1")
        self.assertEqual(snapshot.read_bytes(), before)
        self.assertEqual(self.catalog.read_bytes(), catalog)
        self.assertEqual(Path(str(snapshot) + ".latest.json").read_bytes(), latest)
        self.assertFalse(list(self.db.glob(".tapebackup.*")))

    def test_manifest_first_with_source_sorting_before_database(self):
        source = self.root / "aaa-source"
        self.source.rename(source)
        self.source = source
        self.env.update(MOUNT_POINT=str(source), BACKUP_DB_DIR=str(self.root / "zzz-database"))
        self.run_backup()
        record = self.records()[0]
        names = subprocess.check_output([GNU_TAR, "--list", "--file=" + str(self.root / "tape.tar")], text=True)
        self.assertEqual(names.splitlines()[1], record["manifest_member"])

    def test_metadata_failure_preserves_previous_snapshot(self):
        self.run_backup()
        record = self.records()[0]
        snapshot = Path(record["snapshot_db"])
        before = snapshot.read_bytes()
        latest = Path(str(snapshot) + ".latest.json").read_bytes()
        self.run_backup("uncommitted.tar", success=False, TEST_COMMIT_FAIL="1")
        self.assertEqual(snapshot.read_bytes(), before)
        self.assertEqual(Path(str(snapshot) + ".latest.json").read_bytes(), latest)

    def test_catalog_sync_failure_rolls_back_promoted_state(self):
        self.run_backup()
        record = self.records()[0]
        snapshot = Path(record["snapshot_db"])
        latest = Path(str(snapshot) + ".latest.json")
        before = (snapshot.read_bytes(), latest.read_bytes(), self.catalog.read_bytes())
        work = self.db / ".tapebackup.rollback-test"
        work.mkdir()
        METADATA.prepare(SimpleNamespace(source=str(self.source), db_dir=str(self.db),
                                        catalog=str(self.catalog), snapshot=str(snapshot),
                                        work_dir=str(work), backup_id="rollback-test", full="false",
                                        start_epoch=int(time.time()), nfs_source=self.env["NFS_SOURCE"],
                                        tape_device=str(self.root / "test.tar")))
        (work / "snapshot.tardb").write_bytes(before[0] + b"new snapshot")
        (work / "volume-number").write_text("1\n")
        catalog_inode = self.catalog.stat().st_ino
        real_fsync = os.fsync
        failed = False

        def fail_catalog_sync(fd):
            nonlocal failed
            if os.fstat(fd).st_ino == catalog_inode and not failed:
                failed = True
                raise OSError("simulated catalog fsync failure")
            return real_fsync(fd)

        with mock.patch.object(METADATA.os, "fsync", side_effect=fail_catalog_sync):
            with self.assertRaisesRegex(OSError, "simulated catalog fsync failure"):
                METADATA.complete(SimpleNamespace(work_dir=str(work)))
        self.assertTrue(failed)
        self.assertEqual((snapshot.read_bytes(), latest.read_bytes(), self.catalog.read_bytes()), before)

    def test_listing_is_read_only_and_preserves_errors(self):
        self.run_backup()
        snapshot = Path(self.records()[0]["snapshot_db"])
        before = (self.catalog.read_bytes(), snapshot.read_bytes())
        self.commands.unlink()
        result = self.run_backup(options=("--list-archive",))
        self.assertIn("unchanged.txt", result.stdout)
        self.assertEqual(before, (self.catalog.read_bytes(), snapshot.read_bytes()))
        self.assertFalse(self.commands.exists())
        result = self.run_backup("missing.tar", options=("-L",), success=False)
        self.assertEqual(result.returncode, 2)
        self.assertFalse(self.commands.exists())

    def test_legacy_snapshot_requires_explicit_full_and_preserves_history(self):
        self.db.mkdir()
        snapshot = self.db / "source.tardb"
        snapshot.write_bytes(b"legacy snapshot")
        self.run_backup(success=False)
        self.assertEqual(snapshot.read_bytes(), b"legacy snapshot")
        self.assertFalse((self.root / "tape.tar").exists())
        self.run_backup(options=("--full",))
        record = self.records()[0]
        self.assertFalse(record["incremental"])
        self.assertEqual(Path(record["previous_snapshot"]).read_bytes(), b"legacy snapshot")

    def test_full_option_starts_a_new_chain(self):
        self.run_backup()
        old = self.records()[0]
        self.run_backup("new-full.tar", options=("--full",))
        new = self.records()[1]
        self.assertFalse(new["incremental"])
        self.assertIsNone(new["parent_backup_id"])
        self.assertEqual(new["full_backup_id"], new["backup_id"])
        self.assertEqual(new["required_backups"], [new["backup_id"]])
        self.assertTrue(Path(old["snapshot_history"]).exists())

    def test_rejects_metadata_inside_source_before_mount(self):
        self.run_backup(success=False, METADATA_FILE=str(self.source / "metadata" / "backups.jsonl"))
        self.assertFalse(self.commands.exists())
        self.assertFalse((self.root / "tape.tar").exists())

    def test_rejects_catalog_overwriting_snapshot_pointer(self):
        self.run_backup(success=False, METADATA_FILE=str(self.db / "source.tardb.latest.json"))
        self.assertFalse(self.commands.exists())

    def test_mount_failure_never_writes_tape(self):
        self.run_backup(success=False, TEST_MOUNT_FAIL="1")
        self.assertFalse((self.root / "tape.tar").exists())
        self.assertFalse(self.catalog.exists())

    def test_multivolume_labels_counts_and_restore(self):
        payload = os.urandom(65000)
        (self.source / "large.bin").write_bytes(payload)
        self.run_backup(TEST_MULTIVOLUME="1")
        record = self.records()[0]
        self.assertGreater(record["volume_count"], 1)
        self.assertEqual(record["required_tapes"][-1]["volume_count"], record["volume_count"])
        tapes = [self.root / "tape.tar"]
        tapes.extend(self.root / ("tape.tar." + str(n)) for n in range(2, record["volume_count"] + 1))
        for number, tape in enumerate(tapes, 1):
            label = subprocess.check_output([GNU_TAR, "--test-label", "--file=" + str(tape)], text=True).strip()
            self.assertEqual(label, record["backup_id"] + " Volume " + str(number))
        destination = self.root / "restore"
        self.restore(tapes, destination)
        self.assertEqual((destination / record["archive_source"] / "large.bin").read_bytes(), payload)
        (self.source / "new.txt").write_text("after multi-volume base\n")
        self.run_backup("incremental.tar")
        incremental = self.records()[1]
        self.assertEqual([tape["volume_count"] for tape in incremental["required_tapes"]],
                         [record["volume_count"], 1])
        self.restore([self.root / "incremental.tar"], destination)
        self.assertEqual((destination / record["archive_source"] / "large.bin").read_bytes(), payload)
        self.assertEqual((destination / record["archive_source"] / "new.txt").read_text(),
                         "after multi-volume base\n")


if __name__ == "__main__":
    unittest.main()
