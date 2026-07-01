#!/usr/bin/env bash

# scripts/download_manager.sh
#
# The script work around CINECA Leonardo restrictions on lrd_all_serial partition.
# 1. Batched Submission: Manages SLURM job arrays in small batches (MAX_ARRAY_SIZE) to stay within
#    cluster limits (e.g., max 10 elements per array, one job at a time).
# 2. Recursive Management: Uses 'setsid --fork' to relaunch itself, resetting the process timer on login
#    nodes to bypass CPU time limits (e.g., 10 minutes).
# 3. State Tracking:
#    - If no Job ID is provided: Submits a new batch of tasks starting from START_INDEX.
#    - If Job ID is provided: Monitors the existing batch.
# 4. Task Monitoring: Waits 5 minutes, then evaluates each task index in the current batch:
#    - SUCCESS: Log file contains "Download completed successfully."
#    - RUNNING: Task is still active in 'squeue' for the tracked Job ID.
#    - FAILED: Neither successful nor running.
# 5. Iteration Logic:
#    - RUNNING tasks remain: Relaunch with same Job ID and same START_INDEX.
#    - ALL FINISHED: Calculate NEXT_INDEX and relaunch for the next batch (skip failures).
# 6. Termination: Exits when START_INDEX exceeds MAX_INDEX.
# 
# Note: The script will NOT retry failed tasks; it moves to the next batch once all 
#       tasks in the current batch have finished (successfully or not).

CONFIG=$1
JOB_ID=$2
START_INDEX=$3
MAX_INDEX=${4:-41}
MAX_ARRAY_SIZE=${5:-10}

# Change current directory to project root
PROJECTROOT=$(git rev-parse --show-toplevel)
cd "${PROJECTROOT}" || exit 1

# Check arguments
if [[ -z "${CONFIG}" ]]; then
    echo "Usage: $0 CONFIG_NAME [JOB_ID] [START_INDEX] [MAX_INDEX] [MAX_ARRAY_SIZE]"
    echo "Example: $0 arco-ocean_tres-1d_res-0p25_levels-10 \"\" 0 41 10"
    exit 1
fi

if [[ -z "${START_INDEX}" ]]; then
    echo "Error: Start index is required."
    exit 1
fi

if [[ "${MAX_ARRAY_SIZE}" -le 0 ]]; then
    echo "Error: MAX_ARRAY_SIZE must be greater than 0."
    exit 1
fi

if [[ "${MAX_ARRAY_SIZE}" -gt 10 ]]; then
    echo "Error: MAX_ARRAY_SIZE cannot exceed 10 due to cluster restrictions."
    exit 1
fi

# Redirect all output to a log file to avoid cluttering standard output
mkdir -p logs
MANAGER_LOG="logs/download_manager_${CONFIG}.log"
exec >> "${MANAGER_LOG}" 2>&1

echo "============================================================"
echo "Manager run started at: $(date)"
echo "Config: ${CONFIG}, JobID: ${JOB_ID:-None}, StartIndex: ${START_INDEX}"
echo "============================================================"

if [[ -n "${MAX_INDEX}" && -n "${START_INDEX}" && "${START_INDEX}" -gt "${MAX_INDEX}" ]]; then
    echo "Start index ${START_INDEX} exceeds MAX_INDEX ${MAX_INDEX}. Finished."
    exit 0
fi

if [[ -z "${JOB_ID}" ]]; then
    if [[ -z "${START_INDEX}" ]]; then
        echo "Error: Start index is required when Job ID is null."
        exit 1
    fi
    
    # Submit a new job array
    START=${START_INDEX}
    END=$((START_INDEX + MAX_ARRAY_SIZE - 1))
    if [[ ${END} -gt ${MAX_INDEX} ]]; then
        END=${MAX_INDEX}
    fi
    
    echo "Submitting new SLURM array for ${CONFIG}, indices ${START} to ${END}..."
    # Using --parsable to get only the job ID. 
    # Log name includes job ID and array task ID.
    JOB_ID=$(sbatch --parsable --array=${START}-${END} --output="logs/%A_%a.log" scripts/download.slurm "${CONFIG}")
    
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to submit job array."
        exit 1
    fi
    echo "Job submitted: ${JOB_ID}"
fi

# Wait and check
echo "Waiting 5 minutes before checking status of Job ${JOB_ID}..."
sleep 300

# We need START_INDEX to know which indices were submitted if we are resuming
# If START_INDEX was not passed but JOB_ID was, we might have an issue.
if [[ -z "${START_INDEX}" ]]; then
    echo "Error: Start index is required to check status of Job ID ${JOB_ID}."
    exit 1
fi

START=${START_INDEX}
END=$((START_INDEX + MAX_ARRAY_SIZE - 1))
if [[ ${END} -gt ${MAX_INDEX} ]]; then
    END=${MAX_INDEX}
fi
ALL_FINISHED=true
ALL_SUCCESSFUL=true
FAILED_INDICES=()

# Cache squeue output once to avoid repeated calls and handle array ranges correctly with -r
SQUEUE_OUTPUT=$(squeue -j "${JOB_ID}" -r 2>/dev/null)

for i in $(seq "${START}" "${END}"); do
    # Check if this index has finished successfully in the current job
    if grep -q "Download completed successfully." logs/"${JOB_ID}"_"${i}".log 2>/dev/null; then
        echo "Task ${i}: Finished successfully (verified from logs)."
    else
        # Not successful yet, check if it's currently running in the tracked JOB_ID
        # We use a regex that ensures the task index is not a prefix of another one (e.g., 1 vs 10)
        if [[ -n "${SQUEUE_OUTPUT}" ]] && echo "${SQUEUE_OUTPUT}" | grep -q -E "${JOB_ID}(_|\[)${i}($|[^0-9])"; then
            echo "Task ${i}: Still running or in queue."
            ALL_FINISHED=false
        else
            echo "Task ${i}: Failed or not yet started."
            ALL_SUCCESSFUL=false
            FAILED_INDICES+=("${i}")
        fi
    fi
done

if [[ "${ALL_FINISHED}" == "true" ]]; then
    if [[ "${ALL_SUCCESSFUL}" == "true" ]]; then
        echo "All tasks in batch ${START_INDEX} to ${END} finished successfully."
    else
        echo "Some tasks in batch ${START_INDEX} to ${END} failed: ${FAILED_INDICES[*]}"
    fi
    
    # Calculate next batch start index
    NEXT_INDEX=$((START_INDEX + MAX_ARRAY_SIZE))
    
    if [[ -n "${MAX_INDEX}" && "${NEXT_INDEX}" -gt "${MAX_INDEX}" ]]; then
        echo "Reached MAX_INDEX (${MAX_INDEX}). Download cycle finished."
        exit 0
    fi
    
    echo "Relaunching for next batch with index=${NEXT_INDEX}..."
    setsid --fork bash "$0" "${CONFIG}" "" "${NEXT_INDEX}" "${MAX_INDEX}" "${MAX_ARRAY_SIZE}"
else
    # Still running
    echo "Job array ${JOB_ID} is still in progress."
    echo "Waiting and relaunching with same Job ID to check again..."
    setsid --fork bash "$0" "${CONFIG}" "${JOB_ID}" "${START_INDEX}" "${MAX_INDEX}" "${MAX_ARRAY_SIZE}"
fi
