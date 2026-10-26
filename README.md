# Tape Backup Script

A Bash script for incremental tape backups from an NFS-mounted source, with
persistent restore indexes and multi-volume tape labels.

The backup prerequisites in [RESTORE_REQUIRES.md](RESTORE_REQUIRES.md) are
implemented. The interactive `restore.sh` described there is a future tool.

## Requirements and setup

- Linux, Bash 4.1+, GNU tar, Python 3.7+, `flock`, `mountpoint`, NFS mount tools,
  and `mt` (commonly provided by `mt-st`). Python uses only its standard library.
- A writable NFS mount point that is not already mounted. The script mounts
  `NFS_SOURCE`, verifies the mount, and unmounts it on exit.
- A tape drive with GNU tar multi-volume support. Tape changes use GNU tar's
  interactive prompts; run from a terminal for backups spanning multiple tapes.

Copy `.env.example` to `.env` and configure the paths:

```bash
cp .env.example .env
sudo bash ./tapeBackup.sh
```

`MOUNT_POINT` must be an absolute, canonical path (no symlinks, trailing slash,
or `..`). `BACKUP_DB_DIR` and `METADATA_FILE` must be absolute and outside that
tree. Place the catalog and its neighboring files on separately protected
storage, and replicate them to survive loss of the backup host. Merely choosing
a local directory cannot protect against host or disk loss.

## Usage

```bash
sudo bash ./tapeBackup.sh                  # full on first run, incremental thereafter
sudo bash ./tapeBackup.sh --full           # start a new full backup chain
sudo bash ./tapeBackup.sh -vvvv            # maximum logging
sudo bash ./tapeBackup.sh -L               # list the loaded archive
bash ./tapeBackup.sh --help
```

| Option | Meaning |
|--------|---------|
| `-h`, `--help` | Show help without starting a backup |
| `-L`, `--list-archive` | List the entire archive, preserving tar's exit status; no NFS mount or snapshot/catalog writes |
| `--full` | Start a new full chain, preserving the previous snapshot |
| `-v`, `-vv`, `-vvv`, `-vvvv` | Set console verbosity to 1–4 |
| `-v N`, `-V N`, `--verbose=N` | Explicit verbosity 0–4 |
| `--verbose [N]` | Verbosity 4, or the supplied level |

Archive listing reads from the tape's current position; load/rewind the first
volume first. GNU tar prompts for subsequent volumes. Errors and volume-change
prompts are not suppressed or truncated.

## Configuration (`.env`)

Values are read literally as `KEY=value`, optionally with matching outer quotes.
Shell commands and variable expansion in values are not evaluated.

| Variable | Description | Default |
|----------|-------------|---------|
| `DEBUG_LEVEL` | Console logging: 0=silent, 1=errors, 2=+warnings, 3=+info, 4=+debug | `3` |
| `TAPE_DEVICE` | Tape device used for tar, rewind, and eject | `/dev/st0` |
| `NFS_SOURCE` | NFS export to mount | `10.0.4.25:/xfer` |
| `MOUNT_POINT` | Local NFS mount directory | `/nas/qnap` |
| `BACKUP_DB_DIR` | Snapshot state, history, and local metadata copies | `/root/backup_db` |
| `METADATA_FILE` | Permanent JSONL catalog; per-run files are stored beside it | `/global/tapeback-metadata/backups.jsonl` |
| `TAR_COMMAND` | GNU tar executable | `tar` |
| `ENABLE_LOCKING` | Enable shared tape lock | `false` |
| `LOCK_FILE` | Shared lock path for all processes using this tape drive | `/tmp/tapeBackup.lock` |
| `LOCK_TIMEOUT` | Maximum lock wait in seconds | `60` |
| `ENABLE_ROOT_CHECK` | Enforce root execution | `false` |

Enable root checking and tape locking for production. Snapshot state is always
locked across the entire run, even when the optional tape lock is disabled.
Timestamped script logs are written under `logs/`; verbosity controls console
messages, while the log retains all script log levels. Tar's file listing and
operator prompts are independent of script verbosity.

## Archive and metadata layout

Every run gets a unique UTC-based backup ID, also used as its GNU tar label.
Each physical volume has a label `<backup_id> Volume N`. The first volume begins
with these regular members, before the source data:

1. `.tapebackup/backup_manifest_<backup_id>.json`
2. `.tapebackup/files_<backup_id>.jsonl`
3. `.manifests_included`, listing those two members

The source follows with its leading `/` removed, matching existing backups.
For example, `/nas/qnap/photos/a.jpg` is stored as `nas/qnap/photos/a.jpg`.
The reserved source directory `/nas/qnap/.tapebackup` is excluded from backups
and inventories to avoid repeatedly archiving prior indexes.

The manifest records date/epoch, host, source/export, device, snapshot paths,
full/incremental status, parent and full-backup IDs, ordered `required_backups`
and `required_tapes`, inventory paths, file count, and logical regular-file bytes
(not compressed tape usage). The inventory is newline-delimited JSON with one
entry per source path, its type, size, mtime, and symlink target where applicable.
It does not follow symlinks or descend into other filesystems.

The inventory describes the **source tree before backup**, including unchanged
files needed from earlier incrementals. It is not a list of only changed archive
members; `--list-archive` gives the actual members of the loaded archive. The
source can change while tar runs; it is not a filesystem snapshot.

The on-tape manifest has `status: "prepared"`, with unknown final volume count
and elapsed time. A sequential tape cannot contain final runtime information at
its beginning. On success the completed manifest (`status: "complete"`) and
inventory are saved:

- Beside `METADATA_FILE` on permanent storage.
- In `BACKUP_DB_DIR` alongside snapshot history.
- In `MOUNT_POINT/.tapebackup/` as a best-effort convenience copy (a read-only
  source does not prevent a successful backup).

One compact completed JSON object is appended to `backups.jsonl` per successful
run. Catalog appends are locked, flushed, and synced. A future restore tool can
read this catalog, load the selected inventory, and follow `required_tapes` in
order without scanning all tapes or parsing binary `.tardb` files.

Only the first volume contains the manifest and inventory members; continuation
volumes contain tar continuation records and the run/volume label. They must be
read in order. A second tar/label-writing pass is deliberately avoided: reopening
an auto-rewinding drive for writing would destroy the archive. Probe a loaded
volume's label without scanning its contents using:

```bash
tar --test-label --file=/dev/st0
```

GNU tar's native labels implement tape identification without platform-specific
`tmlabel`/`lmslabel` tools.

## Incremental history and failure handling

For a mount named `qnap`, the current snapshot is `qnap.tardb`. Before tar, a
prior snapshot is copied to `qnap.tardb.<backup_id>.prev`. Tar operates on a
working copy, so a failed backup cannot advance the current snapshot. Successful
runs retain `qnap.tardb.<backup_id>` as the new immutable historical snapshot and
update `qnap.tardb.latest.json` with the completed manifest and snapshot checksum.
Metadata is committed before success is reported. Ordinary metadata commit
errors roll back the current snapshot and latest pointer.

Existing snapshots from older script versions have no known tape dependencies.
Use `--full` once to begin a tracked chain; the old snapshot is preserved.
`--full` also starts a new chain on demand without deleting previous history.

Keep every volume of a full backup and all intervening incrementals required by
the chosen run. Restore incrementals in order with GNU tar's incremental
extraction semantics (`--listed-incremental=/dev/null`), which also apply recorded
deletions. A plain extraction alone does not reconstruct an exact incremental
state. Actual tape hardware, end-of-media behavior, and operator tape changes
must be validated on the deployment system.

## Verification

The integration suite uses regular files as tape volumes and stubs only system
mount/device commands. It exercises real GNU tar archives and restoration:

```bash
python3 -m unittest discover -s tests -v
bash -n tapeBackup.sh
shellcheck tapeBackup.sh
```

On systems where GNU tar is named `gtar`, set `TAR_COMMAND=gtar` for the tests.
