#!/usr/bin/env bash

# scripts/download_manager_local.sh
#
# A much simpler version of scripts/download_manager.sh for systems without SLURM.
# Instead of submitting job arrays with sbatch, it runs scripts/download.slurm as a
# plain bash script, sequentially incrementing a phony SLURM_ARRAY_TASK_ID
# environment variable from START_INDEX to MAX_INDEX (included).
#
# Each task writes its own log file in LOG_DIR, named local_INDEX.log.
# Failing tasks do not stop the loop: their indices are reported at the end.
# Any additional argument is forwarded to scripts/download.slurm (e.g. --overwrite).

CONFIG=$1
START_INDEX=${2:-0}
MAX_INDEX=${3:-40}
LOG_DIR=$4
shift 4 2>/dev/null || shift $#
DOWNLOAD_ARGS=("${@}")

# Change current directory to project root
PROJECT_ROOT=$(git rev-parse --show-toplevel)
cd "${PROJECT_ROOT}" || exit 1

# Check arguments
if [[ -z "${CONFIG}" ]]; then
    echo "Usage: $0 CONFIG_NAME [START_INDEX] [MAX_INDEX] [LOG_DIR] [DOWNLOAD_OPTIONS...]"
    echo "Example: $0 arco-ocean_tres-1d_res-0p25_levels-10 0 40 \"\${PROJECT_ROOT}/logs/download\" --log-level=debug"
    exit 1
fi

if [[ "${START_INDEX}" -gt "${MAX_INDEX}" ]]; then
    echo "Error: START_INDEX (${START_INDEX}) cannot exceed MAX_INDEX (${MAX_INDEX})."
    exit 1
fi

# Set default LOG_DIR and ensure it exists
if [[ -z "${LOG_DIR}" ]]; then
    LOG_DIR="${PROJECT_ROOT}/logs/download"
fi
mkdir -p "${LOG_DIR}"

echo "============================================================"
echo "Local download run started at: $(date)"
echo "Config: ${CONFIG}, StartIndex: ${START_INDEX}, MaxIndex: ${MAX_INDEX}, PID: $$, Hostname: $(hostname)"
echo "============================================================"

FAILED_INDICES=()

for (( SLURM_ARRAY_TASK_ID=START_INDEX; SLURM_ARRAY_TASK_ID<=MAX_INDEX; SLURM_ARRAY_TASK_ID++ )); do
    export SLURM_ARRAY_TASK_ID
    TASK_LOG="${LOG_DIR}/local_${SLURM_ARRAY_TASK_ID}.log"

    if grep -q "Download completed successfully." "${TASK_LOG}" 2>/dev/null; then
        echo "Task ${SLURM_ARRAY_TASK_ID}: already finished successfully (verified from logs), skipping."
        continue
    fi

    echo "Task ${SLURM_ARRAY_TASK_ID}: running (log: ${TASK_LOG})..."
    bash scripts/download.slurm "${DOWNLOAD_ARGS[@]+"${DOWNLOAD_ARGS[@]}"}" "${CONFIG}" > "${TASK_LOG}" 2>&1
    TASK_EXIT_CODE=$?

    if [[ ${TASK_EXIT_CODE} -eq 0 ]]; then
        echo "Task ${SLURM_ARRAY_TASK_ID}: finished successfully."
    else
        echo "Task ${SLURM_ARRAY_TASK_ID}: failed with exit code ${TASK_EXIT_CODE}."
        FAILED_INDICES+=("${SLURM_ARRAY_TASK_ID}")
    fi
done

echo "------------------------------------------------------------"
if [[ ${#FAILED_INDICES[@]} -eq 0 ]]; then
    echo "All tasks from ${START_INDEX} to ${MAX_INDEX} finished successfully."
else
    echo "Some tasks failed: ${FAILED_INDICES[*]}"
    exit 1
fi
