#!/usr/bin/env bash

###############################################################################
## Load environment variables from .env file
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/.env" ]; then
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" =~ ^# ]] && continue
        key="${key%%[[:space:]]}"
        key="${key##[[:space:]]}"
        value="${value#\~}"
        value="${value#[\"\']}"
        value="${value%[\"\']}"
        export "$key=$value"
    done < "${SCRIPT_DIR}/.env"
fi

###############################################################################
## Initialize some variables
###############################################################################
HOSTNAME=$(uname -n)


# Remove the first ".", and everything after it from $HOSTNAME
SHORT_NAME=${HOSTNAME%%.*} 

  # Remove the first ".", and everything before it from $HOSTNAME
FULL_DOMAIN=${HOSTNAME#*.}

# Remove the first ".", and everything after it from $FULL_DOMAIN
DOMAIN=${FULL_DOMAIN%%.*} 

# Full path to the script that we'll use to retrieve YAML variables.
YAML_SCRIPT="${YAML_SCRIPT:-/global/bin/yaml/yaml.py}"

# Get this processes PID
MYPID=$$

# Get a timestamp
tstamp=$(date +%Y%m%d%H%M%S)

# Get the base directory of this script
SOURCE_DIR="${BASH_SOURCE[0]}"
while [ -h "$SOURCE_DIR" ]; do # resolve $SOURCE_DIR until the file is no longer a symlink
  BIN_DIR="$( cd -P "$( dirname "$SOURCE_DIR" )" >/dev/null 2>&1 && pwd )"
  SOURCE_DIR="$(readlink "$SOURCE_DIR")"
  [[ $SOURCE_DIR != /* ]] && SOURCE_DIR="$BIN_DIR/$SOURCE_DIR" # if $SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
BIN_DIR="$( cd -P "$( dirname "$SOURCE_DIR" )" >/dev/null 2>&1 && pwd )"


# NFS mount cleanup flag
MOUNTED_NFS=false

# Lock file in the /tmp directory
LOCK_FILE="/tmp/${0}.lck"
LOCK_FD=""

cleanup() {
    exit_code=$?
    if [[ "$MOUNTED_NFS" == "true" && -n "${DIR:-}" ]]; then
        debugit INFO "Cleaning up: unmounting ${DIR}..."
        umount "${DIR}" 2>/dev/null || true
    fi
    if [[ -n "${LOCK_FD:-}" ]]; then
        exec {LOCK_FD}>&-
    fi
    rm -f "${LOCK_FILE}" 2>/dev/null || true
    exit $exit_code
}

trap cleanup EXIT INT TERM HUP

###############################################################################
## SETUP DEBUGGING/LOGGING
###############################################################################
# use the "-x" argument to set debugging.
# Initial debug level. Will be overwritten by "-x" argument, once it has been parsed.
debug_level="${DEBUG_LEVEL:-3}"

debugit()
    { # Output debug messages depending on how $debug_level is set.
      # first argument is the type of message. Must be one of the following:
      #    ERROR
      #    WARNING
      #    INFO
      #    DEBUG
      # Example: 
      #   debugit INFO "This is how you use the debug feature."
      # Example output:
      #   INFO: This is how you use the debug feature.

    case ${debug_level} in
        0)
            return 0
        ;;
        1)
            case ${1} in
                ERROR)
                    shift
                    >&2 echo -e "ERROR: $@"
                    return 0
                ;;
                WARNING)
                    return 0
                ;;
                INFO)
                    return 0
                ;;
                DEBUG)
                    return 0
                ;;
                *)
                    >&2 echo -e "INTERNAL ERROR - Debug message type '$1' is invalid."
                    return 1
                ;;
            esac
        ;;
        2)
            case ${1} in
                ERROR)
                    shift
                    >&2 echo -e "ERROR: $@"
                    return 0
                ;;
                WARNING)
                    shift
                    echo -e "WARNING: $@"
                    return 0
                ;;
                INFO)
                    return 0
                ;;
                DEBUG)
                    return 0
                ;;
                *)
                    >&2 echo -e "INTERNAL ERROR - Debug message type '$1' is invalid."
                    return 1
                ;;
            esac
        ;;
        3)
            case ${1} in
                ERROR)
                    shift
                    >&2 echo -e "ERROR: $@"
                    return 0
                ;;
                WARNING)
                    shift
                    echo -e "WARNING: $@"
                    return 0
                ;;
                INFO)
                    shift
                    echo -e "INFO: $@"
                    return 0
                ;;
                DEBUG)
                    return 0
                ;;
                *)
                    >&2 echo "INTERNAL ERROR - Debug message type '$1' is invalid."
                    return 1
                ;;
            esac
        ;;
        4)
            case ${1} in
                ERROR)
                    shift
                    >&2 echo -e "ERROR: $@"
                    return 0
                ;;
                WARNING)
                    shift
                    echo -e "WARNING: $@"
                    return 0
                ;;
                INFO)
                    shift
                    echo -e "INFO: $@"
                    return 0
                ;;
                DEBUG)
                    shift
                    echo -e "DEBUG: $@"
                    return 0
                ;;
                *)
                    >&2 echo "INTERNAL ERROR - Debug message type '$1' is invalid."
                    return 1
                ;;
            esac
        ;;
        *)
            echo "INTERNAL ERROR - Invalid debug level '${debug_level}'"
            echo "Setting debug level to default of 3"
            debug_level=3
        ;;
    esac
    }


yay_nay()
    { # A yes/no prompt
        if (( $# > 0 ))
            then
                MSG="$@"
            else
                MSG="Would you like to continue?"
        fi
        read -p "${MSG} [y/N]: " yaynay
        yaynay=$(echo ${yaynay:0:1} | tr "[a-z]" "[A-Z]")
        case ${yaynay} in
            Y)
                return 0
            ;;
            N)
                return 1
            ;;
            "")
                return 1 # Default to No
                #return 0 # Default to Yes
            ;;
            *)
                yay_nay $@
                return $?
            ;;
        esac
    }


disp_help()
    { # Print script help to screen, and exit.
      # Optional argument will set exit value.
        echo "Usage:"
        echo "  $0 [OPTIONS]"
        echo ""
        echo "Incremental tape backup from an NFS-mounted source."
        echo ""
        echo "Options:"
        echo "  -h                    Show this help message"
        echo "  -v <level>            Set debug level explicitly (0-4)"
        echo "      0 = Silent (no output)"
        echo "      1 = ERROR only (stderr)"
        echo "      2 = ERROR + WARNING"
        echo "      3 = ERROR + WARNING + INFO (default)"
        echo "      4 = All levels including DEBUG"
        echo "  -v, -vv, -vvv, -vvvv  Set debug level by verbosity count (1-4)"
        echo "  --verbose [level]     Long-form debug level flag"
        echo "  --verbose=<level>     Long-form debug level with value"
        echo ""
        echo "Configuration:"
        echo "  Set variables in .env for: TAPE_DEVICE, NFS_SOURCE, MOUNT_POINT,"
        echo "  BACKUP_DB_DIR, LOCK_TIMEOUT, ENABLE_LOCKING, ENABLE_ROOT_CHECK."
        echo ""
        echo "Examples:"
        echo "  sudo $0                       Run with default configuration"
        echo "  $0 -vvv                      Verbose error output"
        echo "  $0 -v 4                      Maximum debug logging"
        if [ $# = 1 ]
            then
                if [[ "$1" =~ '^[0-9]+$' ]]
                    then exit $1
                    else exit 2
                fi
            else
                exit
        fi
    }


acquire_lock() {
    debugit INFO "Attempting to acquire lock..."

    timeout_count=0
    max_timeout="${LOCK_TIMEOUT:-60}"

    exec {LOCK_FD}>"${LOCK_FILE}" || {
        debugit ERROR "Failed to open lock file for writing"
        return 1
    }

    while ! flock -n "$LOCK_FD" echo $$ 2>/dev/null; do
        if [[ $timeout_count -ge $max_timeout ]]; then
            debugit ERROR "Lock acquisition timed out after ${max_timeout} seconds"
            exec {LOCK_FD}>&-
            return 1
        fi

        existing_pid=$(head -n1 "${LOCK_FILE}" 2>/dev/null | awk '{print $2}')
        if [[ -n "$existing_pid" ]]; then
            debugit INFO "Waiting for PID ${existing_pid} to release lock (timeout: $((max_timeout - timeout_count))s)..."
        fi

        sleep 1
        ((timeout_count++))
    done

    {
        echo "$USER $$ $(date +%Y%m%d%H%M%S)"
    } >&$LOCK_FD || {
        debugit WARNING "Could not write lock metadata"
    }

    GOT_LOCK="true"
    return 0
}


# Make sure user has Root privileges before allowing to continue.

Check_Root() {
    debugit INFO "Checking user permissions..."
    if (( $(id -u) != 0 )); then
        debugit ERROR "Sorry! Only root can do that"
        exit 1
    fi
    debugit INFO " OK"
}

if [ "${ENABLE_ROOT_CHECK:-true}" == "true" ]; then
    Check_Root
fi

if [ "${ENABLE_LOCKING:-true}" == "true" ]; then
    if ! acquire_lock; then
        exit 1
    fi
fi

# Commands
if [ $# -ge 1 ]
    then
        debugit "Parsing command"
        if [ ${1#-} = $1 ]
            then
                commandArg="$1"
                shift
                debugit "Command specified is: ${commandArg}"

                case ${commandArg} in
                    yyyy)
                        debugit "Recognized command: ${commandArg}"
                    ;;
                    *)
                        debugit "Unknown command: ${commandArg}"
                        echo "${0}: Unknown command: ${commandArg}" >&2
                        disp_help 1
                esac
            else
                commandArg="NULL"
        fi
    else
        debugit "No command specified"
        disp_help
fi


# Options
optspec="hv:-:"
while getopts "${optspec}" opt
    do
        case "${opt}" in
            -)
                case "${OPTARG}" in
                    xxxx)
                        opt_xxxx="${!OPTIND}"
                        (( OPTIND++ ))
                    ;;
                    xxxx=*)
                        opt_xxxx=${OPTARG#*=}
                    ;;
                    verbose)
                        debug_level="${!OPTIND}"
                        (( OPTIND++ ))
                        debugit DEBUG "debug_level set to '${debug_level}'"
                    ;;
                    verbose=*)
                        debug_level=${OPTARG#*=}
                        debugit DEBUG "debug_level set to '${debug_level}'"
                    ;;
                    v|vv|vvv|vvvv)
                        case "${OPTARG}" in
                            v)
                                debug_level=1
                            ;;
                            vv)
                                debug_level=2
                            ;;
                            vvv)
                                debug_level=3
                            ;;
                            vvvv)
                                debug_level=4
                            ;;
                        esac
                        debugit DEBUG "debug_level set to '${debug_level}'"
                    ;;
                    *)
                        if [ "$OPTERR" = 1 ] && [ "${optspec:0:1}" != ":" ]; then
                            echo "Unknown option --${OPTARG}" >&2
                        fi
                    ;;
                esac
            ;;
            v)
                case ${OPTARG} in
                    "0")
                        debug_level=0
                    ;;
                    "1")
                        debug_level=1
                    ;;
                    "2")
                        debug_level=2
                    ;;
                    "3")
                        debug_level=3
                    ;;
                    "4")
                        debug_level=4
                    ;;
                    v*)
                        case "${OPTARG}" in
                            v)
                                debug_level=2
                            ;;
                            vv)
                                debug_level=3
                            ;;
                            vvv)
                                debug_level=4
                            ;;
                            *)
                                >&2 echo "invalid debug level specified: 'v$(OPTARG)'"
                                disp_help 1
                            ;;
                        esac
                        debugit DEBUG "debug_level set to '${debug_level}'"
                    ;;
                    *)
                        >&2 echo "invalid debug level specified: '$(OPTARG)'"
                        disp_help 1
                    ;;
                esac
                debugit DEBUG "debug_level set to '${debug_level}'"
            ;;
            h)
                disp_help 0
            ;;
        esac
    done
shift $((OPTIND-1))

# Arguments
if [ $# -gt 0 ]
    then
        debugit "Parsing arguments"
        #Set argument variables here, like arg_file=$1
fi

#####################
## SCRIPT STARTS HERE  
#####################

debugit INFO "Scanning for SCSI devices..."
lsscsi || debugit WARNING "lsscsi failed"

TAPE="${TAPE_DEVICE:?TAPE_DEVICE not set in .env}"
SRC="${NFS_SOURCE:-/nfs/src}"
DIR="${MOUNT_POINT:?MOUNT_POINT not set in .env}"
BACKUP_DB_DIR="${BACKUP_DB_DIR:-/root/backup_db}"

debugit INFO "Mounting NFS share ${SRC} to ${DIR}..."
if ! mount "$SRC" "$DIR"; then
    debugit ERROR "Failed to mount ${SRC} on ${DIR}"
    exit 1
fi
MOUNTED_NFS=true

mkdir -p "$BACKUP_DB_DIR" || {
    debugit ERROR "Failed to create backup directory ${BACKUP_DB_DIR}"
    exit 1
}

DIRNAME=$(basename "$DIR")
LISTED_INCREMENTAL="${BACKUP_DB_DIR}/${DIRNAME}.tardb"

debugit INFO "Starting incremental backup of ${DIR} to ${TAPE}..."
if ! tar -clpMvf "$TAPE" -g "$LISTED_INCREMENTAL" "$DIR"; then
    debugit ERROR "Backup failed"
    exit 1
fi

debugit INFO "Rewinding tape device..."
mt rewind || {
    debugit WARNING "Failed to rewind tape"
}

debugit INFO "Ejecting tape device..."
mt -f "$TAPE" eject || {
    debugit WARNING "Failed to eject tape"
}

debugit INFO "Backup completed successfully"
ls -al "$BACKUP_DB_DIR/"

