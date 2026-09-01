#! /usr/bin/env bash

# scripts/watchdog.sh
#
# Watchdog script that monitors a directory and uploads new or modified files
# to a destination using rsync at configurable intervals.

usage() {
    more <<EOF
watchdog.sh
    This script monitors a source directory and uploads new or modified files
    to a given destination using rsync.

SYNOPSIS
    usage: $0 --help
    usage: $0 [options] [source] [destination]

DESCRIPTION
    Positional arguments
        source                                  Source directory to monitor (optional if --source is set).
        destination                             Destination path or remote target (optional if --destination is set).

    Options
        --source PATH                           Source directory to monitor (default to \$DATA_ROOT/data).
        --destination PATH                      Destination target for rsync (e.g., user@host:/path or /local/path).
        --identity-file FILE                    SSH identity file (private key) for rsync authentication.
        --interval SECONDS                      Polling interval in seconds between checks (default: 60).
        --rsync-options OPTS                    Options to pass to rsync (default: "-av --partial").
        --remove-source-files                   Remove successfully transferred files from source directory.
        --dry-run                               Run rsync in dry-run mode without making actual changes.
        --once                                  Run sync once and exit instead of continuous monitoring.
        --log-dir DIR                           Directory where logs are stored (default: \${PROJECT_ROOT}/logs/watchdog).
        --log-file FILE                         Explicit path to log file (overrides --log-dir default file).
        --env-file FILE                         Environment file to source (default: scripts/.env).
        --help                                  Shows this help.
EOF
}

# Default options
SOURCE=""
DESTINATION=""
IDENTITY_FILE=""
INTERVAL=60
RSYNC_OPTIONS="-av --partial"
REMOVE_SOURCE_FILES=false
DRY_RUN=false
RUN_ONCE=false
LOG_DIR=""
LOG_FILE=""
ENV_FILE="scripts/.env"

# Parse command line options
ARGS=$(getopt --options '' --longoptions "source:,destination:,identity-file:,interval:,rsync-options:,remove-source-files,dry-run,once,log-dir:,log-file:,env-file:,help" --name "$0" -- "${@}")
if [[ ${?} -ne 0 ]]; then
    usage
    exit 1
fi

eval "set -- ${ARGS}"
while true; do
    case "$1" in
        (--source)
            SOURCE="${2}"
            shift 2
            ;;
        (--destination)
            DESTINATION="${2}"
            shift 2
            ;;
        (--identity-file)
            IDENTITY_FILE="${2}"
            shift 2
            ;;
        (--interval)
            INTERVAL="${2}"
            shift 2
            ;;
        (--rsync-options)
            RSYNC_OPTIONS="${2}"
            shift 2
            ;;
        (--remove-source-files)
            REMOVE_SOURCE_FILES=true
            shift
            ;;
        (--dry-run)
            DRY_RUN=true
            shift
            ;;
        (--once)
            RUN_ONCE=true
            shift
            ;;
        (--log-dir)
            LOG_DIR="${2}"
            shift 2
            ;;
        (--log-file)
            LOG_FILE="${2}"
            shift 2
            ;;
        (--env-file)
            ENV_FILE="${2}"
            shift 2
            ;;
        (--help)
            usage
            exit 0
            ;;
        (--)
            shift
            break
            ;;
        (*)
            echo "Error: unrecognized option $1" >&2
            usage
            exit 1
            ;;
    esac
done

# Handle positional arguments if not provided by flags
if [[ $# -ge 1 && -z "${SOURCE}" ]]; then
    SOURCE="$1"
    shift
fi

if [[ $# -ge 1 && -z "${DESTINATION}" ]]; then
    DESTINATION="$1"
    shift
fi

# Change current directory to project root
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [[ -z "${PROJECT_ROOT}" ]]; then
    PROJECT_ROOT="$(pwd)"
fi
cd "${PROJECT_ROOT}" || exit 1

# Source environment file if available
if [[ -n ${ENV_FILE} ]]; then
    if [[ ! -f ${ENV_FILE} && -f "${PROJECT_ROOT}/${ENV_FILE}" ]]; then
        ENV_FILE="${PROJECT_ROOT}/${ENV_FILE}"
    fi
    if [[ -f ${ENV_FILE} ]]; then
        source "${ENV_FILE}"
    fi
fi

# Fallback default source if DATA_ROOT is defined in env
if [[ -z "${SOURCE}" && -n "${DATA_ROOT}" ]]; then
    SOURCE="${DATA_ROOT}/data"
fi

# Validate arguments
if [[ -z "${SOURCE}" ]]; then
    echo "Error: missing required argument: source directory (--source or positional)." >&2
    usage
    exit 1
fi

if [[ -z "${DESTINATION}" ]]; then
    echo "Error: missing required argument: destination (--destination or positional)." >&2
    usage
    exit 1
fi

if [[ -n "${IDENTITY_FILE}" && ! -f "${IDENTITY_FILE}" ]]; then
    echo "Error: identity file '${IDENTITY_FILE}' not found." >&2
    exit 1
fi

if ! [[ "${INTERVAL}" =~ ^[0-9]+$ ]] || [[ "${INTERVAL}" -le 0 ]]; then
    echo "Error: interval must be a positive integer (got: ${INTERVAL})." >&2
    exit 1
fi

# Setup logging
if [[ -z "${LOG_DIR}" ]]; then
    LOG_DIR="${PROJECT_ROOT}/logs/watchdog"
fi
mkdir -p "${LOG_DIR}"

if [[ -z "${LOG_FILE}" ]]; then
    LOG_FILE="${LOG_DIR}/watchdog.log"
fi

log() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] $*" | tee -a "${LOG_FILE}"
}

# Signal handling for graceful termination
cleanup() {
    log "Watchdog received termination signal. Stopping watchdog (PID: $$)..."
    exit 0
}
trap cleanup SIGINT SIGTERM SIGHUP

# Build rsync flags
RSYNC_FLAGS=()
read -r -a EXTRA_ARGS <<< "${RSYNC_OPTIONS}"
RSYNC_FLAGS+=("${EXTRA_ARGS[@]}")

if [[ -n "${IDENTITY_FILE}" ]]; then
    RSYNC_FLAGS+=(-e "ssh -i ${IDENTITY_FILE}")
fi

if [[ "${REMOVE_SOURCE_FILES}" == true ]]; then
    RSYNC_FLAGS+=(--remove-source-files)
fi

if [[ "${DRY_RUN}" == true ]]; then
    RSYNC_FLAGS+=(--dry-run)
fi

log "============================================================"
log "Watchdog started at: $(date)"
log "Source: ${SOURCE}"
log "Destination: ${DESTINATION}"
log "Identity file: ${IDENTITY_FILE:-None}"
log "Interval: ${INTERVAL}s"
log "Rsync options: ${RSYNC_FLAGS[*]}"
log "Run once: ${RUN_ONCE}"
log "Log file: ${LOG_FILE}"
log "Hostname: $(hostname), PID: $$"
log "============================================================"

# Main watchdog loop
while true; do
    if [[ -d "${SOURCE}" ]]; then
        log "Running rsync from '${SOURCE%/}/' to '${DESTINATION}'..."
        
        rsync "${RSYNC_FLAGS[@]}" "${SOURCE%/}/" "${DESTINATION}" >> "${LOG_FILE}" 2>&1
        RSYNC_EXIT_CODE=$?
        
        if [[ ${RSYNC_EXIT_CODE} -eq 0 ]]; then
            log "Sync cycle completed successfully."
        else
            log "Warning: rsync finished with exit code ${RSYNC_EXIT_CODE}."
        fi
    else
        log "Warning: source directory '${SOURCE}' does not exist. Waiting..."
    fi

    if [[ "${RUN_ONCE}" == true ]]; then
        log "Run once mode finished. Exiting."
        break
    fi

    sleep "${INTERVAL}" &
    wait $!
done
