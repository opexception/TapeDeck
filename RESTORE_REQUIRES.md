# restore.sh Requires These Changes to tapeBackup.sh First

## Goal
`restore.sh` will be an interactive script that:
1. Lists available backups by scanning all tapes for label/index metadata → lets user pick a backup number/date to restore from
2. For the chosen backup, lists files/directories contained in it → lets user select specific items to extract (partial restore)
3. Handles multi-tape restores (sequential tape insertion prompts) when restoring incrementals
4. Asks for a destination path and performs `tar` extract onto that path

To make any of this possible, **backup runs must produce persistent, searchable metadata**. Below is the required change list.

---

## Task List — Changes to tapeBackup.sh Required Before Restore Is Possible

### 1. Write a per-backup label index file ON every tape at end of backup

Every backup archive should contain, as its very first file, an index/manifest describing what follows. This lets any future restore script find the right tape and know what's inside it *before* loading the full archive.

**What to add (approx. lines after current `tar` command):**

```bash
###############################################################################
## Step: Write backup manifest file ON-TAPE as first file in archive
###############################################################################

MANIFEST_FILE="${MOUNT_POINT}/restore_manifest_$(date +%Y%m%d_%H%M%S).txt"

# Create manifest describing the backup we just wrote
{
    echo "BACKUP_RUN_DATE=$(date '+%Y-%m-%d %H:%M:%S')"
    echo "TAPE_DEVICE=${TAPE_DEVICE}"
    echo "BACKUP_DB_DIR=${BACKUP_DB_DIR}"
    echo "INCREMENTAL_BASE=$(cat "${BACKUP_DB_DIR}/${DIRNAME}.tardb.prev" 2>/dev/null || echo 'FULL_BACKUP')"
    echo ""
    echo "### Backed-up directories ===="
    find "$DIR" -maxdepth 0 -printf "%p\n" 2>/dev/null || echo "$DIR"
} > "${MANIFEST_FILE}"

# Append manifest to the tape (as a separate file) or write it as first file
# Option A: create a new tar containing only the manifest and stream-first, then append
tar -cvf "${TAPE}" "${TAPE}:${MANIFEST_FILE}.new"  # or better yet …
```

**Recommended approach** — write the manifest to a standalone file on the mounted NFS (or on first tape in its own archive pass), AND write it out-of-band to permanent non-tape storage (see Task 2 below). The simplest reliable option:

```bash
# Write a manifest alongside the backup DB dir so it survives on disk
MANIFEST_PATH="${BACKUP_DB_DIR}/backup_manifest_$(date +%Y%m%d_%H%M%S).json"
cat > "${MANIFEST_PATH}" <<EOF_MARKER
{
    "run_date": "$(date -u '+%Y-%m-%d %H:%M:%S UTC')",
    "run_epoch": $(date +%s),
    "hostname": "$(hostname)",
    "tape_device": "${TAPE_DEVICE}",
    "source_dir": "${DIR}",
    "src_server": "$(echo ${NFS_SOURCE} | cut -d: -f1)",
    "export_path": "$(echo ${NFS_SOURCE} | cut -d: -f2)",
    "incremental": true,
    "base_snapshot_db": "${LISTED_INCREMENTAL}",
    "backup_db_dir": "${BACKUP_DB_DIR}",
    "file_count": $(find "$DIR" -depth 1 -maxdepth 1 | wc -l),
    "disk_usage_bytes": $(du -sb "$DIR" | awk '{print $1}'),
    "elapsed_seconds": ${ELAPSED}
}
EOF_MARKER

# Also write manifest to its own tape archive (appended to end of current run)
# so it is available offline without needing NFS access anywhere
echo "${MANIFEST_PATH}" >> "$DIR/.manifests_included"

# Write label to tape device so operator knows which backup this tape corresponds to
printf "tapebackup $(date '+%Y%m%d')\n%s\n" "$(hostname):${DIR}:${ELAPSED}s" | lmslabel -f "${TAPE_DEVICE}" - 2>/dev/null || \
    logger WARNING "tm label write failed on ${TAPE_DEVICE} (may require label tape first)"
```

### 2. Write backup metadata to permanent non-tape storage

Backup metadata must survive even if the NAS, logs dir, or machine hosting `tapeBackup.sh` dies. Write a per-backup JSON/YAML manifest at end of every run to a file that is NOT inside the backup tree:

```bash
METADATA_FILE="/global/tapeback-metadata/backups.jsonl"   # <-- out-of-band
# Append one JSON object per backup line (JSONL format — append-only, easy to read)
jq -n \
    --arg run "$(date '+%Y-%m-%d %H:%M:%S UTC')" \
    --arg epoch "$(date +%s)" \
    --arg host "$(hostname)" \
    --arg device "${TAPE_DEVICE}" \
    --arg source "${DIR}" \
    --arg server "$(echo ${NFS_SOURCE} | cut -d: -f1)" \
    --arg export_path "$(echo ${NFS_SOURCE} | cut -d: -f2)" \
    --arg dbdir "${BACKUP_DB_DIR}" \
    --arg tardb "${LISTED_INCREMENTAL}" \
    --arg base_snapshot "full" \
    --arg elapsed "${ELAPSED}s" \
    '{
        run_date: $run,
        run_epoch: ($epoch | tonumber),
        hostname: $host,
        tape_device: $device,
        source_dir: $source,
        nfs_server: $server,
        nfs_export: $export_path,
        backup_db_dir: $dbdir,
        snapshot_db: $tardb,
        is_incremental: true,
        base_snapshot: $base_snapshot,
        elapsed: $elapsed
    }' >> "${METADATA_FILE}"
```

**Why this matters for `restore.sh`:** The restore script would read `/global/tapeback-metadata/backups.jsonl` to build the list of available backups without touching any tape. This is the *only* way to provide a browsable selectable list at all. **All other approaches require reading every tape manually.**

### 3. Preserve `.tardb` history instead of letting tar overwrite it

Each incremental backup overwrites the prior `.tardb`. To know which previous bases were used for any given run, we need history:

```bash
# BEFORE running tar (which will overwrite .tardb with new snapshot):
PREV_TARDB_BASENAME=$(basename "$LISTED_INCREMENTAL")
mv "${LISTED_INCREMENTAL}" "${LISTED_INCREMENTAL}.$(( $(ls -1 ${BACKUP_DB_DIR}/${DIRNAME}.tardb.* 2>/dev/null | wc -l) + 1 ))"

# AFTER tar completes, the new .tardb is already in place — old one is preserved with numbered suffix
```

**Why this matters for restore:** Each incremental base-tape depends on *all* preceding ones. We must track that dependency chain so `restore.sh` can tell the operator "you need tapes #1 through #5 and then #6" not just "#6".

### 4. (Optional but recommended) Add a `--list-archive` mode to tapeBackup.sh

This lets `restore.sh` probe a given tape without actually restoring:

```bash
if [ $# -ge 1 ] && [[ "$1" == "--list-archive" ]]; then
    # Read and print contents of current tape (for listing/restores)
    tar -tvf "$TAPE_DEVICE" 2>/dev/null | head -200
    exit $?
fi
```

This is a *small change* to `tapeBackup.sh` but essential for any restore tool. Without it, the restore script would have to duplicate all the tape-reading logic.

### 5. (Optional) Add `.manifests_included` as first file in archive

As noted above if we use Option A approach in Task 1, write each manifest filename to a dot-file at end of backup dir before running `tar`. On restore:
1. Extract just the manifests from the tape
2. Read filenames to discover which tapes need inserting
3. Build the list for the user

---

## Summary of Required Changes

| # | Change | Effort | Priority |
|---|--------|--------|----------|
| 1 | Per-backup manifest file written to NFS + disk at end of each run | Medium | **HIGH** |
| 2 | Append-to-file metadata write (`backups.jsonl`) outside the backup tree | Low | **HIGH** |
| 3 | Preserve `.tardb` history (don't let tar overwrite) | Low | **HIGH** |
| 4 | Add `--list-archive / -L` mode to tapBackup.sh for tape listing | Very low | MEDIUM |
| 5 | Label tapes with `tmlabel`/`lmslabel` if available on your platform | Platform-dependent | LOW (helpful, not essential) |

Once Tasks 1–3 are complete, the restore script can:
- Read `backups.jsonl` to show all available backup dates/hosts in a numbered list
- When user picks one, read that manifest to know which files were backed up → present selectable directory/file choices
- For incrementals read dependency chain from preserved `.tardb`s → prompt user which physical tapes must be inserted
- Use `tar -xvf` with partial path extraction (`--warning=no-timestamped`)

---

## What a Restore Script Would Look Like (after prerequisites)

```bash
#!/usr/bin/env bash
# restore.sh — requires tapeBackup.sh changes in RESTORE_REQUIRES.md before use

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SOURCE_DIR}/.env"
metadata_file="/global/tapeback-metadata/backups.jsonl"      # from Task 2
BACKUP_DB_DIR=""
TAPE_DEVICE=""

# Load environment — same as tapeBackup.sh
if [ -f "$ENV_FILE" ]; then
    while IFS='=' read -r key value; do ...; done < "$ENV_FILE"
fi
BACKUP_DB_DIR="${BACKUP_DB_DIR:-/root/backup_db}"
TAPE_DEVICE="${TAPE_DEVICE:-/dev/st0}"

echo "=== Tape Backup Restore ==="
echo ""

# Step 1: List available backups from per-backup metadata
if [ ! -f "$metadata_file" ]; then
    echo "ERROR: $metadata_file not found. Install it as described in RESTORE_REQUIRES.md Task 2."
    exit 1
fi
echo "Available backup runs:"
cat -n "$metadata_file" | while IFS= read -r line; do
    run_data=$(echo "$line" | awk '{print $NF}')  # JSON object is always last field on line
    echo "$line" | jq -r --arg r "$run_data" \
        '[($r | run_date), ($r | tape_device // "?"), ($r | elapsed)] | join("\t")' 2>/dev/null
done

# (user picks N)
read -p "Select backup number: " pick
selected=$(sed -n "${pick}p" "$metadata_file")

# Step 2: Extract manifest to know files/tapes involved
manifest_json=$(echo "$selected" | jq .)
backed_up_dir=$(echo "$manifest_json" | jq -r '.source_dir')
base_tardb=$(echo "$manifest_json" | jq -r '.snapshot_db')

# Step 3: List files for selective restore (using tape probe mode, which needs Task 4)
echo ""
echo "Files/directories in this backup:"
tar -tvf "${TAPE_DEVICE}" 2>/dev/null | sort -u | column -t | head -100

# Step 4: Ask for destination path and dependencies
read -p "Restore to directory path: " dest_path

if [ "$(echo "$manifest_json" | jq -r '.incremental')" == "true" ]; then
    echo ""
    echo "This is an INCREMENTAL backup. You will also need these tapes in order:"
    # Walk .tardb history from Task 3 to find all base tapes
    current_tardb="$base_tardb"
    tape_num=1
    while [ -f "${BACKUP_DB_DIR}/$(basename "$current_tardb").${tape_num}" ] || \
          read_manifest_tape "$(cat "${BACKUP_DB_DIR}/$(basename "$current_tardb").prev")" 2>/dev/null; do
        echo "  Tape #${tape_num}: $(read_tape_label)"
        tape_num=$((tape_num + 1))
    done
fi

# Step 5: Confirm and extract
yay_nay "Begin restore to ${dest_path}? [Yes/no]"; [[ $? -eq 1 ]] && exit 0

mkdir -p "$dest_path"
read tape_label
cd "$dest_path"
tar -xvpf "${TAPE_DEVICE}" --no-same-owner 2>/dev/null || true
echo "Restore complete to ${dest_path}"

# (loop for any more tapes if incremental)
```

---

## Notion for restore.sh authors

When restoring from an incremental tape archive, tar requires you to feed ALL preceding tapes. If your data spans 10 tapes, the operator must: insert tape 1 → press enter → insert tape 2 → press enter ... all the way through. **The script cannot pre-fetch or auto-insert; it can only wait for a keypress.** The restore UI should make this very clear with numbered prompts and tape labels from Task 1 (tmlabel).

Also note: `tar -cM` (multi-volume) requires manual operator intervention between volumes *every time* because `-M` stands for "manual multi-volume" — this is how tapes work on Linux. If you want to reduce operator work, write each backup as a single continuous file on tape and use tape libraries or autosamplers where possible.
