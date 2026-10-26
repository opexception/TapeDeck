#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        [[ -z "$key" ]] && continue
        [[ "$key" =~ ^[a-zA-Z_][a-zA-Z_0-9]*$ ]] || {
            printf 'Invalid configuration key: %s\n' "$key" >&2
            exit 1
        }
        value="${value%$'\r'}"
        if [[ "$value" == \"*\" || "$value" == \'*\' ]]; then
            value="${value:1:${#value}-2}"
        fi
        export "$key=$value"
    done < "${SCRIPT_DIR}/.env"
fi

DEBUG_LEVEL="${DEBUG_LEVEL:-3}"
TAPE_DEVICE="${TAPE_DEVICE:-/dev/st0}"
NFS_SOURCE="${NFS_SOURCE:-10.0.4.25:/xfer}"
MOUNT_POINT="${MOUNT_POINT:-/nas/qnap}"
BACKUP_DB_DIR="${BACKUP_DB_DIR:-/root/backup_db}"
METADATA_FILE="${METADATA_FILE:-/global/tapeback-metadata/backups.jsonl}"
LOCK_FILE="${LOCK_FILE:-/tmp/tapeBackup.lock}"
LOCK_TIMEOUT="${LOCK_TIMEOUT:-60}"
ENABLE_LOCKING="${ENABLE_LOCKING:-false}"
ENABLE_ROOT_CHECK="${ENABLE_ROOT_CHECK:-false}"
TAR_COMMAND="${TAR_COMMAND:-tar}"
MODE=backup
FULL_BACKUP=false

disp_help() {
    printf 'Usage: %s [OPTIONS]\n' "$0"
    printf '%s\n' \
        'Incremental tape backup from an NFS-mounted source.' \
        '' \
        '  -h, --help             Show help' \
        '  -L, --list-archive     List the loaded archive without mounting NFS' \
        '  --full                Start a new full backup chain' \
        '  -v, -vv, -vvv, -vvvv  Set verbosity by count (1-4)' \
        '  -v N, -V N            Set verbosity explicitly (0-4)' \
        '  --verbose[=N]         Set verbosity (default: 4)' \
        '' \
        'Configuration is loaded from .env beside this script.' \
        'Metadata: METADATA_FILE (JSONL catalog), BACKUP_DB_DIR (snapshots).' \
        'Multi-volume backups/listings prompt for subsequent tapes via GNU tar.'
}

while (( $# )); do
    case "$1" in
        -h|--help) disp_help; exit 0 ;;
        -L|--list-archive) MODE=list ;;
        --full) FULL_BACKUP=true ;;
        -v|--verbose)
            if [[ "${2:-}" =~ ^[0-4]$ ]]; then
                DEBUG_LEVEL="$2"
                shift
            elif [[ "$1" == -v ]]; then
                DEBUG_LEVEL=1
            else
                DEBUG_LEVEL=4
            fi
            ;;
        -vv) DEBUG_LEVEL=2 ;;
        -vvv) DEBUG_LEVEL=3 ;;
        -vvvv) DEBUG_LEVEL=4 ;;
        -V)
            [[ $# -ge 2 ]] || { printf '%s\n' '-V requires a level' >&2; exit 2; }
            DEBUG_LEVEL="$2"
            shift
            ;;
        --verbose=*) DEBUG_LEVEL="${1#*=}" ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; disp_help >&2; exit 2 ;;
    esac
    shift
done
[[ "$DEBUG_LEVEL" =~ ^[0-4]$ && "$LOCK_TIMEOUT" =~ ^[0-9]+$ ]] || {
    printf '%s\n' 'DEBUG_LEVEL must be 0-4; LOCK_TIMEOUT must be a nonnegative integer' >&2
    exit 2
}

START_EPOCH=$(date +%s)
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "$LOG_DIR" || exit 1
LOG_FILE="${LOG_DIR}/tape_backup_$(date -u +%Y%m%d_%H%M%S)_$$.log"
MOUNTED_NFS=false
WORK_DIR=""

logger() {
    local level="$1" threshold line
    shift
    case "$level" in
        ERROR) threshold=1 ;;
        WARNING) threshold=2 ;;
        INFO) threshold=3 ;;
        *) threshold=4 ;;
    esac
    line="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
    printf '%s\n' "$line" >> "$LOG_FILE"
    if (( DEBUG_LEVEL >= threshold )); then
        if [[ "$level" == ERROR || "$MODE" == list ]]; then
            printf '%s\n' "$line" >&2
        else
            printf '%s\n' "$line"
        fi
    fi
}

cleanup() {
    local exit_code=$?
    trap - EXIT
    if [[ "$MOUNTED_NFS" == true ]]; then
        umount "$MOUNT_POINT" || logger WARNING "Could not unmount ${MOUNT_POINT}"
    fi
    [[ -z "$WORK_DIR" ]] || rm -rf -- "$WORK_DIR"
    # flock descriptors are closed by exit. Never unlink a lock still in use.
    exit "$exit_code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

fail() { logger ERROR "$*"; exit 1; }

wait_for_lock() {
    if [[ "$LOCK_TIMEOUT" == 0 ]]; then
        flock -n "$1"
    else
        flock -w "$LOCK_TIMEOUT" "$1"
    fi
}

if [[ "$ENABLE_ROOT_CHECK" == true && "$(id -u)" != 0 ]]; then
    fail 'Root privileges are required'
fi
if [[ "$ENABLE_LOCKING" == true ]]; then
    exec {LOCK_FD}>"$LOCK_FILE" || fail "Cannot open lock ${LOCK_FILE}"
    wait_for_lock "$LOCK_FD" || fail 'Timed out waiting for tape lock'
fi
tar_version=$("$TAR_COMMAND" --version) || fail 'Cannot run tar'
[[ "$tar_version" == *'GNU tar'* ]] || fail 'GNU tar is required (set TAR_COMMAND if necessary)'

if [[ "$MODE" == list ]]; then
    logger INFO "Listing archive on ${TAPE_DEVICE}"
    # Preserve tar's status and all output, including multi-volume prompts.
    "$TAR_COMMAND" --list --verbose --multi-volume --file="$TAPE_DEVICE"
    exit $?
fi

command -v python3 >/dev/null || fail 'Python 3 is required for JSON metadata'
command -v flock >/dev/null || fail 'flock is required for snapshot locking'
logger INFO "=== TAPE BACKUP RUN — $(date -u '+%Y-%m-%d %H:%M:%S UTC') ==="
logger DEBUG "Host: $(hostname); OS: $(uname -s) $(uname -r); user: $(id -un)"
logger DEBUG "Source: ${NFS_SOURCE}; mount: ${MOUNT_POINT}; tape: ${TAPE_DEVICE}"
logger INFO "Log file: ${LOG_FILE}"

# Validate persistent paths before mounting or touching tape. Recheck after mount
# as well, since the mount can change symlink resolution.
python3 "${SCRIPT_DIR}/tape_metadata.py" validate \
    --source "$MOUNT_POINT" --db-dir "$BACKUP_DB_DIR" --catalog "$METADATA_FILE" \
    || fail 'Invalid metadata storage paths'
mkdir -p "$MOUNT_POINT" || fail 'Cannot create mount point'
if mountpoint -q "$MOUNT_POINT"; then
    fail "${MOUNT_POINT} is already mounted; refusing to back up an unverified source"
fi
mount "$NFS_SOURCE" "$MOUNT_POINT" || fail "Cannot mount ${NFS_SOURCE}"
MOUNTED_NFS=true
mountpoint -q "$MOUNT_POINT" && [[ -d "$MOUNT_POINT" && -r "$MOUNT_POINT" ]] \
    || fail "NFS mount at ${MOUNT_POINT} is not accessible"
python3 "${SCRIPT_DIR}/tape_metadata.py" validate \
    --source "$MOUNT_POINT" --db-dir "$BACKUP_DB_DIR" --catalog "$METADATA_FILE" \
    || fail 'Invalid metadata storage paths after mount'

mkdir -p "$BACKUP_DB_DIR" "$(dirname "$METADATA_FILE")" || fail 'Cannot create metadata storage'
DIRNAME=$(basename "$MOUNT_POINT")
LISTED_INCREMENTAL="${BACKUP_DB_DIR}/${DIRNAME}.tardb"
# Snapshot serialization is mandatory even when the optional tape lock is off.
exec {SNAPSHOT_FD}>"${LISTED_INCREMENTAL}.lock" || fail 'Cannot open snapshot lock'
wait_for_lock "$SNAPSHOT_FD" || fail 'Timed out waiting for snapshot lock'
WORK_DIR=$(mktemp -d "${BACKUP_DB_DIR}/.tapebackup.XXXXXXXX") || fail 'Cannot create working directory'
BACKUP_ID="$(date -u +%Y%m%dT%H%M%SZ)-$(python3 -c 'import uuid; print(uuid.uuid4().hex[:12])')"
MANIFEST_MEMBER=".tapebackup/backup_manifest_${BACKUP_ID}.json"
INVENTORY_MEMBER=".tapebackup/files_${BACKUP_ID}.jsonl"

python3 "${SCRIPT_DIR}/tape_metadata.py" prepare \
    --source "$MOUNT_POINT" --db-dir "$BACKUP_DB_DIR" --catalog "$METADATA_FILE" \
    --snapshot "$LISTED_INCREMENTAL" --work-dir "$WORK_DIR" \
    --backup-id "$BACKUP_ID" --start-epoch "$START_EPOCH" \
    --nfs-source "$NFS_SOURCE" --tape-device "$TAPE_DEVICE" --full "$FULL_BACKUP" \
    || fail 'Cannot prepare manifest and snapshot history'

printf '%s\n' "$MANIFEST_MEMBER" "$INVENTORY_MEMBER" > "${WORK_DIR}/.tapebackup/manifests_included"
printf '1\n' > "${WORK_DIR}/volume-number"
logger INFO "Writing backup ${BACKUP_ID}; use this ID to identify its tapes"
# GNU tar labels every volume with BACKUP_ID and its volume number. A separate
# label-writing pass on an auto-rewinding device could overwrite the backup.
# The JSON manifest is the first regular member, before inventory and source.
# Incremental mode allows one -C and sorts operands. Relative .tapebackup names
# sort before the absolute source; tar safely strips its leading / on output.
"$TAR_COMMAND" --create --one-file-system --preserve-permissions --multi-volume \
    --verbose --file="$TAPE_DEVICE" --label="$BACKUP_ID" \
    --volno-file="${WORK_DIR}/volume-number" \
    --listed-incremental="${WORK_DIR}/snapshot.tardb" \
    --anchored --no-wildcards --exclude="${MOUNT_POINT}/.tapebackup" \
    --transform='flags=r;s|^\.tapebackup/manifests_included$|.manifests_included|' \
    -C "$WORK_DIR" "$MANIFEST_MEMBER" "$INVENTORY_MEMBER" \
    .tapebackup/manifests_included "$MOUNT_POINT" \
    || fail 'Backup failed; last successful snapshot has not been advanced'

python3 "${SCRIPT_DIR}/tape_metadata.py" complete --work-dir "$WORK_DIR" \
    || fail "Tape written but metadata commit failed for ${BACKUP_ID}; snapshot not advanced"

# The source copy is a convenience only. The authoritative catalog and copies
# are outside the backup tree, and the embedded manifest needs no NAS access.
if mkdir -p "${MOUNT_POINT}/.tapebackup" && \
    cp "${WORK_DIR}/${MANIFEST_MEMBER}" "${WORK_DIR}/${INVENTORY_MEMBER}" "${MOUNT_POINT}/.tapebackup/" && \
    cp "${WORK_DIR}/.tapebackup/manifests_included" "${MOUNT_POINT}/.tapebackup/.manifests_included"; then
    logger DEBUG 'Manifest and inventory also copied to NFS'
else
    logger WARNING 'Cannot copy metadata to NFS; on-tape and permanent metadata are available'
fi

mt -f "$TAPE_DEVICE" rewind || logger WARNING 'Failed to rewind tape'
mt -f "$TAPE_DEVICE" eject || logger WARNING 'Failed to eject tape'
logger INFO "Backup ${BACKUP_ID} completed successfully in $(($(date +%s) - START_EPOCH))s"
logger INFO "Catalog: ${METADATA_FILE}"
logger INFO "Manifest: $(dirname "$METADATA_FILE")/backup_manifest_${BACKUP_ID}.json"
