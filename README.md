# Tape Backup Script

**STATUS: WORK IN PROGRESS -- not functional, incomplete.** See [RESTORE_REQUIRES.md](RESTORE_REQUIRES.md) for known gaps and required changes.

A bash script for performing incremental tape backups from an NFS-mounted source.

![WIP](https://img.shields.io/badge/status-WIP-yellow?style=for-the-badge)

## Features

- **Incremental backups**: Uses tar's listed incremental mode (`-g`) to track changes between backup runs
- **NFS mounting**: Automatically mounts NFS shares before backup and includes tape ejection
- **Lock file mechanism**: Prevents concurrent script execution with configurable timeout
- **Configurable logging**: Four debug levels from silent (0) to full debug output (4)
- **Root privilege check**: Optional enforcement of root user execution

## Setup

1. Copy `.env.example` to `.env`:
   ```bash
   cp .env.example .env
   ```

2. Edit `.env` to configure your environment:
   - Set `TAPE_DEVICE` to your tape device (e.g., `/dev/st0`)
   - Configure `NFS_SOURCE` with your NFS export path
   - Set `MOUNT_POINT` as the local mount directory
   - Adjust `BACKUP_DB_DIR` for storing incremental backup databases

## Usage

```bash
# Run with default configuration (from .env)
sudo ./tapeBackup.sh

# Enable verbose output
./tapeBackup.sh -vvv

# Enable all features including locking and root check
# Set ENABLE_LOCKING=true and ENABLE_ROOT_CHECK=true in .env
```

## Configuration Options (`.env`)

| Variable | Description | Default |
|----------|-------------|---------|
| `DEBUG_LEVEL` | Log verbosity: 0=silent, 1=errors only, 2=+warnings, 3=+info, 4=+debug | 3 |
| `LOCK_TIMEOUT` | Seconds to wait for lock file availability | 60 |
| `TAPE_DEVICE` | Path to tape device | `/dev/st0` |
| `NFS_SOURCE` | NFS export path (e.g., `10.0.4.25:/xfer`) | `10.0.4.25:/xfer` |
| `MOUNT_POINT` | Local directory to mount NFS share | `/nas/qnap` |
| `BACKUP_DB_DIR` | Directory for `.tardb` incremental state files | `/root/backup_db` |
| `YAML_SCRIPT` | Path to external YAML variable retrieval script | `/global/bin/yaml/yaml.py` |
| `ENABLE_LOCKING` | Enable lock file mechanism (`true`/`false`) | `false` |
| `ENABLE_ROOT_CHECK` | Require root privileges (`true`/`false`) | `false` |

## Command Line Options

- `-h` : Display help message
- `-v`, `-vv`, `-vvv`, `-vvvv` : Set debug level (1-4)
- `-V <level>` : Set debug level explicitly

## Backup Flow

1. Scans for SCSI devices (`lsscsi`)
2. Mounts NFS share to specified mount point
3. Creates backup database directory if needed
4. Runs incremental tar backup to tape device
5. Rewinds and ejects the tape
6. Lists backup database contents

## Notes

- The script generates `.tardb` files for tracking incremental backups (one per backup directory)
- Tape operations (`mt rewind`, `mt eject`) require appropriate device permissions
- NFS mount point must exist or be creatable with proper permissions
- For production use, enable both `ENABLE_ROOT_CHECK` and `ENABLE_LOCKING`
