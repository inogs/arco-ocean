#!/usr/bin/env bash

# scripts/download_manager_local.sh
#
# A local runner for systems without SLURM.
# Directly invokes 'arco-make download' sequentially across task indices from
# START_INDEX to MAX_INDEX (inclusive), computing date ranges for each task slice.
#
# Each task writes its own log file in LOG_DIR, named local_INDEX.log.
# If a task fails, it is retried a configurable number of times (MAX_RETRIES, default: 3) before moving to the next task.
# Failing tasks do not stop the loop: their indices are reported at the end.

usage() {
    cat <<EOF
download_manager_local.sh
    Sequential local runner for downloading datasets using arco-make without SLURM.
    If the dataset is a timeseries, it downloads date chunks sequentially from START_INDEX to MAX_INDEX.
    Each task writes its own log file in LOG_DIR and is retried up to MAX_RETRIES upon failure.

SYNOPSIS
    $0 [options] CONFIG_NAME [START_INDEX] [MAX_INDEX] [LOG_DIR]
    $0 --help

DESCRIPTION
    Positional Arguments:
        CONFIG_NAME                             Config recipe name (looks in CONFIG_DIR for CONFIG_NAME.toml).
        START_INDEX                             Starting task index (default: 0).
        MAX_INDEX                               Ending task index (inclusive, default: 44).
        LOG_DIR                                 Directory for task logs (default: \${PROJECT_ROOT}/logs/download).

    Options:
        --project-dir DIR                       Project root directory (default: current working directory).
        --config-dir DIR                        Where to look for configs (default: \${PROJECT_ROOT}/configs/download).
        --output-dir DIR                        Where to place the outputs (default: \$DATA_ROOT/data/archive/\${CONFIG_NAME}).
        --log-dir DIR                           Where to place the logs (default: \${PROJECT_ROOT}/logs/download).
        --no-array                              Whether to download dataset in a single shot, without array slicing (default: false).
        --start DATE                            Overwrite config start date (YYYY-MM-DD).
        --end DATE                              Overwrite config end date (YYYY-MM-DD).
        --image IMAGE                           Apptainer image path (default: oras://ghcr.io/stefanocampanella/arco-make:latest).
        --virtual-env PATH                      Run from a local virtual environment (VIRTUAL_ENV path) instead of Apptainer.
        --env-file FILE                         Environment file to source (default: scripts/.env).
        --bind SRC[:DST[:OPTS]]                 Path to bind within Apptainer container (can be repeated).
        --replace                             Write a new version of an existing output (arco-make --replace; default: false).
        --no-replace                          Refuse an existing output.
        --log-level LEVEL                       Logging level (debug, info, warning, error, critical). Default: info.
        --retries, --max-retries N              Maximum retries per task (default: 3).
        --retry-delay N                         Delay in seconds between retries (default: 5).
        -h, --help                              Shows this help.
EOF
}

# Helper function to perform date arithmetic portably (GNU date, gdate, python, or BSD date)
add_days() {
    local base_date="$1"
    local days="$2"
    if date -d "${base_date} + ${days} days" +"%Y-%m-%d" 2>/dev/null; then
        return 0
    elif command -v gdate >/dev/null 2>&1 && gdate -d "${base_date} + ${days} days" +"%Y-%m-%d" 2>/dev/null; then
        return 0
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "import datetime; print((datetime.date.fromisoformat('${base_date}') + datetime.timedelta(days=${days})).strftime('%Y-%m-%d'))"
    elif command -v python >/dev/null 2>&1; then
        python -c "import datetime; print((datetime.date.fromisoformat('${base_date}') + datetime.timedelta(days=${days})).strftime('%Y-%m-%d'))"
    elif date -j -v+"${days}"d -f "%Y-%m-%d" "${base_date}" +"%Y-%m-%d" 2>/dev/null; then
        return 0
    else
        echo "Error: unable to perform date arithmetic (no GNU date, python, or BSD date available)." >&2
        return 1
    fi
}

# Default options
PROJECT_ROOT=""
CONFIG_DIR=""
OUTPUT_DIR=""
CLI_LOG_DIR=""
OUTPUT_EXTENSION="zarr"
ARRAY=true
REPLACE=false
LOG_LEVEL="info"
IMAGE="oras://ghcr.io/stefanocampanella/arco-make:latest"
VENV=""
ENV_FILE="scripts/.env"
BINDS=()
CLI_START_DATE=""
CLI_END_DATE=""
MAX_RETRIES=${MAX_RETRIES:-${RETRIES:-3}}
RETRY_DELAY=${RETRY_DELAY:-5}

POSITIONAL_ARGS=()

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --project-dir=*)
            PROJECT_ROOT="${1#*=}"
            shift
            ;;
        --project-dir)
            PROJECT_ROOT="$2"
            shift 2
            ;;
        --config-dir=*)
            CONFIG_DIR="${1#*=}"
            shift
            ;;
        --config-dir)
            CONFIG_DIR="$2"
            shift 2
            ;;
        --output-dir=*)
            OUTPUT_DIR="${1#*=}"
            shift
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --log-dir=*)
            CLI_LOG_DIR="${1#*=}"
            shift
            ;;
        --log-dir)
            CLI_LOG_DIR="$2"
            shift 2
            ;;
        --no-array)
            ARRAY=false
            shift
            ;;
        --start=*)
            CLI_START_DATE="${1#*=}"
            shift
            ;;
        --start)
            CLI_START_DATE="$2"
            shift 2
            ;;
        --end=*)
            CLI_END_DATE="${1#*=}"
            shift
            ;;
        --end)
            CLI_END_DATE="$2"
            shift 2
            ;;
        --image=*)
            IMAGE="${1#*=}"
            shift
            ;;
        --image)
            IMAGE="$2"
            shift 2
            ;;
        --virtual-env=*)
            VENV="${1#*=}"
            shift
            ;;
        --virtual-env)
            VENV="$2"
            shift 2
            ;;
        --env-file=*)
            ENV_FILE="${1#*=}"
            shift
            ;;
        --env-file)
            ENV_FILE="$2"
            shift 2
            ;;
        --bind=*)
            BINDS+=("${1#*=}")
            shift
            ;;
        --bind)
            BINDS+=("$2")
            shift 2
            ;;
        --replace)
            REPLACE=true
            shift
            ;;
        --no-replace)
            REPLACE=false
            shift
            ;;
        --log-level=*)
            LOG_LEVEL="${1#*=}"
            shift
            ;;
        --log-level)
            LOG_LEVEL="$2"
            shift 2
            ;;
        --retries=*|--max-retries=*)
            MAX_RETRIES="${1#*=}"
            shift
            ;;
        --retries|--max-retries)
            MAX_RETRIES="$2"
            shift 2
            ;;
        --retry-delay=*)
            RETRY_DELAY="${1#*=}"
            shift
            ;;
        --retry-delay)
            RETRY_DELAY="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            POSITIONAL_ARGS+=("$@")
            break
            ;;
        -*)
            echo "Error: unrecognized option '$1'." >&2
            usage
            exit 1
            ;;
        *)
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done

CONFIG="${POSITIONAL_ARGS[0]:-}"
START_INDEX="${POSITIONAL_ARGS[1]:-0}"
MAX_INDEX="${POSITIONAL_ARGS[2]:-44}"
POS_LOG_DIR="${POSITIONAL_ARGS[3]:-}"

# Check required configuration name
if [[ -z "${CONFIG}" ]]; then
    echo "Error: missing required argument CONFIG_NAME." >&2
    usage
    exit 1
fi

# Change current directory to project root
if [[ -z "${PROJECT_ROOT}" ]]; then
    PROJECT_ROOT="$(pwd)"
fi
cd "${PROJECT_ROOT}" || exit 1

# Source environment file if available
if [[ -n "${ENV_FILE}" ]]; then
    if [[ ! -f "${ENV_FILE}" && -f "${PROJECT_ROOT}/${ENV_FILE}" ]]; then
        ENV_FILE="${PROJECT_ROOT}/${ENV_FILE}"
    fi
    if [[ ! -f "${ENV_FILE}" ]]; then
        echo "Error: environment file '${ENV_FILE}' not found." >&2
        exit 1
    fi
    source "${ENV_FILE}"
fi

# Load default modules if module system is present
if command -v module >/dev/null 2>&1; then
    for MODULE_TO_LOAD in "${MODULES[@]+"${MODULES[@]}"}"; do
        module load "${MODULE_TO_LOAD}"
    done
fi

# Cleanup handler to unload modules on exit
cleanup() {
    if command -v module >/dev/null 2>&1; then
        for MODULE_TO_LOAD in "${MODULES[@]+"${MODULES[@]}"}"; do
            module unload "${MODULE_TO_LOAD}" 2>/dev/null || true
        done
    fi
}
trap cleanup EXIT

# Check that Apptainer is installed when not using a local virtual environment
if [[ -z "${VENV}" ]]; then
    if ! command -v apptainer >/dev/null 2>&1; then
        echo "Error: Apptainer is required when not using a virtual environment (--virtual-env)." >&2
        exit 1
    fi
    apptainer --version >/dev/null 2>&1 || exit 1
fi

# Resolve configuration file path
if [[ -z "${CONFIG_DIR}" ]]; then
    CONFIG_DIR="${PROJECT_ROOT}/configs/download"
fi

if [[ -f "${CONFIG}" ]]; then
    CONFIG_PATH="${CONFIG}"
    CONFIG_NAME="$(basename "${CONFIG}" .toml)"
elif [[ -f "${CONFIG_DIR}/${CONFIG}.toml" ]]; then
    CONFIG_PATH="${CONFIG_DIR}/${CONFIG}.toml"
    CONFIG_NAME="${CONFIG}"
elif [[ -f "${CONFIG_DIR}/${CONFIG}" ]]; then
    CONFIG_PATH="${CONFIG_DIR}/${CONFIG}"
    CONFIG_NAME="$(basename "${CONFIG}" .toml)"
else
    CONFIG_PATH="${CONFIG_DIR}/${CONFIG}.toml"
    CONFIG_NAME="${CONFIG}"
fi

if [[ ! -f "${CONFIG_PATH}" ]]; then
    echo "Error: config file '${CONFIG_PATH}' not found." >&2
    exit 1
fi

# Validate array variables if array slicing is enabled
if [[ "${ARRAY}" == true ]]; then
    for var in ARCO_OCEAN_ARRAY_START ARCO_OCEAN_ARRAY_END ARCO_OCEAN_ARRAY_STEP; do
        if [[ -z "${!var}" ]]; then
            echo "Error: ${var} environment variable not defined or empty." >&2
            exit 1
        fi
    done

    if [[ "${START_INDEX}" -gt "${MAX_INDEX}" ]]; then
        echo "Error: START_INDEX (${START_INDEX}) cannot exceed MAX_INDEX (${MAX_INDEX})." >&2
        exit 1
    fi
else
    START_INDEX=0
    MAX_INDEX=0
fi

# Set default OUTPUT_DIR and ensure it exists
if [[ -z "${OUTPUT_DIR}" ]]; then
    if [[ -n "${DATA_ROOT}" && "${DATA_ROOT}" != "/arco-ocean" ]]; then
        OUTPUT_DIR="${DATA_ROOT}/data/archive/${CONFIG_NAME}"
    elif [[ -n "${SCRATCH}" ]]; then
        OUTPUT_DIR="${SCRATCH}/arco-ocean/data/archive/${CONFIG_NAME}"
    else
        OUTPUT_DIR="${PROJECT_ROOT}/data/archive/${CONFIG_NAME}"
    fi
fi
mkdir -p "${OUTPUT_DIR}"

# Set default LOG_DIR and ensure it exists
if [[ -n "${CLI_LOG_DIR}" ]]; then
    LOG_DIR="${CLI_LOG_DIR}"
elif [[ -n "${POS_LOG_DIR}" ]]; then
    LOG_DIR="${POS_LOG_DIR}"
elif [[ -z "${LOG_DIR}" ]]; then
    LOG_DIR="${PROJECT_ROOT}/logs/download"
fi
mkdir -p "${LOG_DIR}"

# Build execution command (local virtual environment or Apptainer container)
if [[ -n "${VENV}" ]]; then
    RUN_CMD=(env VIRTUAL_ENV="${VENV}" uv run --no-sync arco-make)
else
    APPTAINER_FLAGS=()
    for BIND in "${BINDS[@]+"${BINDS[@]}"}"; do
        APPTAINER_FLAGS+=(--bind "${BIND}")
    done
    RUN_CMD=(apptainer run "${APPTAINER_FLAGS[@]+"${APPTAINER_FLAGS[@]}"}" "${IMAGE}")
fi

echo "============================================================"
echo "Local download run started at: $(date)"
echo "Config: ${CONFIG_NAME}, StartIndex: ${START_INDEX}, MaxIndex: ${MAX_INDEX}, Array: ${ARRAY}, MaxRetries: ${MAX_RETRIES}, PID: $$, Hostname: $(hostname)"
echo "============================================================"

FAILED_INDICES=()

for (( TASK_INDEX=START_INDEX; TASK_INDEX<=MAX_INDEX; TASK_INDEX++ )); do
    TASK_LOG="${LOG_DIR}/local_${TASK_INDEX}.log"

    if grep -q "Download completed successfully." "${TASK_LOG}" 2>/dev/null; then
        echo "Task ${TASK_INDEX}: already finished successfully (verified from logs), skipping."
        continue
    fi

    # Calculate date ranges
    START_DATE=""
    END_DATE=""

    if [[ "${ARRAY}" == true ]]; then
        START_DATE=$(add_days "${ARCO_OCEAN_ARRAY_START}" $(( ARCO_OCEAN_ARRAY_STEP * TASK_INDEX )))
        END_DATE=$(add_days "${ARCO_OCEAN_ARRAY_START}" $(( ARCO_OCEAN_ARRAY_STEP * (TASK_INDEX + 1) )))
        if [[ "${ARCO_OCEAN_ARRAY_END}" < "${END_DATE}" ]]; then
            END_DATE="${ARCO_OCEAN_ARRAY_END}"
        fi
    fi

    if [[ -n "${CLI_START_DATE}" ]]; then
        START_DATE="${CLI_START_DATE}"
    fi

    if [[ -n "${CLI_END_DATE}" ]]; then
        END_DATE="${CLI_END_DATE}"
    fi

    # Build flags for arco-make download
    FLAGS=(--no-progress --log-level="${LOG_LEVEL}")

    if [[ "${REPLACE}" == true ]]; then
        FLAGS+=(--replace)
    else
        FLAGS+=(--no-replace)
    fi

    if [[ -n "${START_DATE}" ]]; then
        FLAGS+=(--start="${START_DATE}")
    fi

    if [[ -n "${END_DATE}" ]]; then
        FLAGS+=(--end="${END_DATE}")
    fi

    # Determine output path for this slice
    if [[ -n "${START_DATE}" && -n "${END_DATE}" ]]; then
        OUTPUT_PATH="${OUTPUT_DIR}/${START_DATE}_${END_DATE}.${OUTPUT_EXTENSION}"
    else
        OUTPUT_PATH="${OUTPUT_DIR}/${CONFIG_NAME}.${OUTPUT_EXTENSION}"
    fi

    TASK_SUCCESS=false
    for (( attempt=0; attempt<=MAX_RETRIES; attempt++ )); do
        if [[ ${attempt} -gt 0 ]]; then
            echo "Task ${TASK_INDEX}: retrying (${attempt}/${MAX_RETRIES}, log: ${TASK_LOG})..."
        else
            echo "Task ${TASK_INDEX}: running (log: ${TASK_LOG})..."
        fi

        # Execute arco-make download directly
        (
            "${RUN_CMD[@]}" download "${FLAGS[@]}" -- "${CONFIG_PATH}" "${OUTPUT_PATH}"
            DOWNLOAD_EXIT_CODE=$?
            if [[ ${DOWNLOAD_EXIT_CODE} -eq 0 ]]; then
                echo "----------------------------------------"
                echo "Download completed successfully."
                exit 0
            else
                echo "----------------------------------------"
                echo "Download failed with exit code: ${DOWNLOAD_EXIT_CODE}"
                exit ${DOWNLOAD_EXIT_CODE}
            fi
        ) > "${TASK_LOG}" 2>&1

        TASK_EXIT_CODE=$?

        if grep -q "Download completed successfully." "${TASK_LOG}" 2>/dev/null; then
            echo "Task ${TASK_INDEX}: finished successfully."
            TASK_SUCCESS=true
            break
        else
            echo "Task ${TASK_INDEX}: failed with exit code ${TASK_EXIT_CODE}."
            if [[ ${attempt} -lt ${MAX_RETRIES} && ${RETRY_DELAY} -gt 0 ]]; then
                sleep "${RETRY_DELAY}"
            fi
        fi
    done

    if [[ "${TASK_SUCCESS}" != "true" ]]; then
        FAILED_INDICES+=("${TASK_INDEX}")
    fi
done

echo "------------------------------------------------------------"
if [[ ${#FAILED_INDICES[@]} -eq 0 ]]; then
    if [[ "${ARRAY}" == true ]]; then
        echo "All tasks from ${START_INDEX} to ${MAX_INDEX} finished successfully."
    else
        echo "Download task finished successfully."
    fi
else
    echo "Some tasks failed: ${FAILED_INDICES[*]}"
    exit 1
fi
