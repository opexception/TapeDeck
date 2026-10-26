#!/usr/bin/env python3
"""Build and commit restore indexes; invoked by tapeBackup.sh, not a restore UI."""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import stat
import sys
import tempfile
import time
from datetime import datetime, timezone


def atomic_write(path, data):
    path = Path(path)
    fd, temporary = tempfile.mkstemp(prefix=".metadata-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=True, separators=(",", ":")) + "\n").encode()


def atomic_copy(source, destination):
    destination = Path(destination)
    fd, temporary = tempfile.mkstemp(prefix=".metadata-", dir=destination.parent)
    try:
        with os.fdopen(fd, "wb") as output, open(source, "rb") as stream:
            shutil.copyfileobj(stream, output)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def validate(args):
    source = Path(args.source)
    if not source.is_absolute() or source.resolve() == Path("/"):
        raise ValueError("MOUNT_POINT must be an absolute path other than /")
    # Canonical source names keep inventories and tar member names consistent.
    if args.source != str(source.resolve()):
        raise ValueError("MOUNT_POINT must be canonical (no symlinks or '..')")
    if not Path(args.db_dir).is_absolute() or not Path(args.catalog).is_absolute():
        raise ValueError("BACKUP_DB_DIR and METADATA_FILE must be absolute paths")
    db = Path(args.db_dir).resolve()
    catalog = Path(args.catalog).resolve()
    for path in (db, catalog.parent):
        if source.resolve() in (path, *path.parents):
            raise ValueError("Snapshot and catalog storage must be outside the backup tree")
    if catalog == db or (db in catalog.parents and catalog.name.endswith(".tardb")):
        raise ValueError("Catalog must not overwrite snapshot storage")
    snapshot_name = source.name + ".tardb"
    if catalog.parent == db and (catalog.name == snapshot_name or catalog.name.startswith(snapshot_name + ".")):
        raise ValueError("Catalog must not overwrite snapshot history, locks, or latest manifest")


def inventory(source, output):
    """Index the source tree, like tar -l: no symlink or filesystem traversal."""
    source = Path(source)
    device = source.stat().st_dev
    count = size = 0
    pending = [source]
    with output.open("wb") as stream:
        while pending:
            path = pending.pop()
            info = path.lstat()
            kind = ("directory" if stat.S_ISDIR(info.st_mode) else
                    "file" if stat.S_ISREG(info.st_mode) else
                    "symlink" if stat.S_ISLNK(info.st_mode) else "special")
            item = {"path": str(path).lstrip("/"), "type": kind,
                    "size": info.st_size, "mtime_ns": info.st_mtime_ns}
            if kind == "symlink":
                item["target"] = os.readlink(path)
            stream.write(json_bytes(item))
            if kind == "file":
                count += 1
                size += info.st_size
            if kind == "directory" and info.st_dev == device:
                with os.scandir(path) as entries:
                    children = sorted((Path(entry.path) for entry in entries), reverse=True)
                pending.extend(child for child in children if child != source / ".tapebackup")
    return count, size


def prepare(args):
    validate(args)
    work = Path(args.work_dir)
    snapshot = Path(args.snapshot).resolve()
    latest = Path(str(snapshot) + ".latest.json")
    previous = None
    if snapshot.exists():
        # Copy, never move: tar must read the prior state to stay incremental.
        shutil.copy2(snapshot, str(snapshot) + "." + args.backup_id + ".prev")
        if args.full == "false":
            if not latest.exists():
                raise ValueError("Existing snapshot has no restore metadata; use --full to start a tracked chain")
            previous = json.loads(latest.read_text())
            digest = hashlib.sha256(snapshot.read_bytes()).hexdigest()
            if previous["snapshot_sha256"] != digest:
                raise ValueError("Snapshot does not match its latest manifest; use --full to start a new chain")
            if previous["source_dir"] != args.source or previous["nfs_source"] != args.nfs_source:
                raise ValueError("Snapshot belongs to another source; use --full or another BACKUP_DB_DIR")
            shutil.copy2(snapshot, work / "snapshot.tardb")
    elif latest.exists() and args.full == "false":
        raise ValueError("Latest manifest exists but snapshot is missing; use --full to start a new chain")

    metadata_dir = Path(args.catalog).resolve().parent
    # Fail before writing tape if permanent storage is not writable.
    with tempfile.TemporaryFile(dir=metadata_dir):
        pass
    with open(args.catalog, "ab"):
        pass
    (work / ".tapebackup").mkdir()
    manifest_name = "backup_manifest_" + args.backup_id + ".json"
    inventory_name = "files_" + args.backup_id + ".jsonl"
    count, size = inventory(args.source, work / ".tapebackup" / inventory_name)
    server, separator, export = args.nfs_source.partition(":/")
    if separator:
        export = "/" + export
    else:
        raise ValueError("NFS_SOURCE must use server:/export syntax")
    manifest = {
        "schema_version": 1,
        "backup_id": args.backup_id,
        "run_date": datetime.fromtimestamp(args.start_epoch, timezone.utc).isoformat(),
        "run_epoch": args.start_epoch,
        "hostname": socket.gethostname(),
        "tape_device": args.tape_device,
        "tape_label": args.backup_id,
        "volume_count": None,
        "source_dir": args.source,
        "archive_source": args.source.lstrip("/"),
        "nfs_source": args.nfs_source,
        "nfs_server": server,
        "nfs_export": export,
        "backup_db_dir": str(snapshot.parent),
        "snapshot_db": str(snapshot),
        "snapshot_history": str(snapshot) + "." + args.backup_id,
        "previous_snapshot": str(snapshot) + "." + args.backup_id + ".prev" if snapshot.exists() else None,
        "incremental": previous is not None,
        "parent_backup_id": previous["backup_id"] if previous else None,
        "full_backup_id": previous["full_backup_id"] if previous else args.backup_id,
        "required_backups": (previous["required_backups"] if previous else []) + [args.backup_id],
        "required_tapes": (previous["required_tapes"] if previous else []) + [
            {"backup_id": args.backup_id, "tape_label": args.backup_id, "volume_count": None}],
        "manifest_path": str(metadata_dir / manifest_name),
        "manifest_member": ".tapebackup/" + manifest_name,
        "inventory_path": str(metadata_dir / inventory_name),
        "inventory_member": ".tapebackup/" + inventory_name,
        "catalog_path": str(Path(args.catalog).resolve()),
        "inventory_scope": "source_tree_before_backup",
        "file_count": count,
        "disk_usage_bytes": size,
        "elapsed_seconds": None,
        "status": "prepared",
    }
    atomic_write(work / manifest["manifest_member"], json_bytes(manifest))
    atomic_write(work / "run.json", json_bytes(manifest))


def complete(args):
    work = Path(args.work_dir)
    manifest = json.loads((work / "run.json").read_text())
    snapshot = Path(manifest["snapshot_db"])
    latest = Path(str(snapshot) + ".latest.json")
    old_latest = latest.read_bytes() if latest.exists() else None
    snapshot_data = (work / "snapshot.tardb").read_bytes()
    manifest.update(status="complete", elapsed_seconds=int(time.time()) - manifest["run_epoch"],
                    volume_count=int((work / "volume-number").read_text().strip()),
                    snapshot_sha256=hashlib.sha256(snapshot_data).hexdigest())
    manifest["required_tapes"][-1]["volume_count"] = manifest["volume_count"]
    data = json_bytes(manifest)
    # Persist both indexes outside NFS, and alongside the snapshot DB. No tar
    # append, external tape label pass, or auto-rewind device reopening occurs.
    for directory in {snapshot.parent, Path(manifest["manifest_path"]).parent}:
        atomic_copy(work / manifest["inventory_member"], directory / Path(manifest["inventory_path"]).name)
        atomic_write(directory / Path(manifest["manifest_path"]).name, data)
    atomic_write(Path(manifest["snapshot_history"]), snapshot_data)
    atomic_write(work / manifest["manifest_member"], data)

    # Serialize JSONL writers, rollback a partial line and state promotion on
    # ordinary I/O errors. Per-source flock spans prepare, tar, and completion.
    with open(manifest["catalog_path"], "a+b", buffering=0) as catalog:
        fcntl.flock(catalog, fcntl.LOCK_EX)
        catalog.seek(0, os.SEEK_END)
        length = catalog.tell()
        try:
            atomic_write(snapshot, snapshot_data)
            atomic_write(latest, data)
            if catalog.write(data) != len(data):
                raise OSError("Incomplete catalog write")
            catalog.flush()
            os.fsync(catalog.fileno())
        except OSError:
            if manifest["previous_snapshot"]:
                atomic_write(snapshot, Path(manifest["previous_snapshot"]).read_bytes())
            elif snapshot.exists():
                snapshot.unlink()
            if old_latest is not None:
                atomic_write(latest, old_latest)
            elif latest.exists():
                latest.unlink()
            catalog.truncate(length)
            os.fsync(catalog.fileno())
            raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("validate", "prepare"):
        command = commands.add_parser(name)
        command.add_argument("--source", required=True)
        command.add_argument("--db-dir", required=True)
        command.add_argument("--catalog", required=True)
        if name == "prepare":
            for option in ("snapshot", "work-dir", "backup-id", "nfs-source", "tape-device"):
                command.add_argument("--" + option, required=True)
            command.add_argument("--start-epoch", required=True, type=int)
            command.add_argument("--full", choices=("true", "false"), default="false")
    commands.add_parser("complete").add_argument("--work-dir", required=True)
    args = parser.parse_args()
    try:
        {"validate": validate, "prepare": prepare, "complete": complete}[args.command](args)
    except (OSError, ValueError, KeyError) as error:
        print("Metadata error: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
