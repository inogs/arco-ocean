#! /usr/bin/env bash
#SBATCH --partition=lrd_all_serial
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --time=240
#SBATCH --mem=30800M
#SBATCH --gres=tmpfs:1T
#SBATCH --requeue

usage() {
    more <<EOF
download_dataset.slurm
    This script downloads datasets using arco-make.
    If the dataset is a timeseries, it will download a range of dates computed from SLURM_ARRAY_TASK_ID.
    The script will look into CONFIG_DIR for a TOML recipe named CONFIG_NAME,
    and the output path will computed as "OUTPUT_DIR/CONFIG_NAME".

SYNOPSIS
    usage: $0 --help
    usage: $0 [options] CONFIG_NAME

DESCRIPTION
    Options
        --config-dir                            Where to look for configs (default to \${PROJECT_ROOT}/configs/download).
        --output-dir                            Where to place the ouputs (default to $DATA_ROOT/data/datasets).
        --log-dir                               Where to place the logs (default to \${PROJECT_ROOT}/logs/download).
        --no-array                              Whether to download dataset in a single shot, without using SLURM arrays (default false).
        --start                                 Overwrite config start date.
        --end                                   Overwrite config end date.
        --image                                 Apptainer image path (default oras://ghcr.io/stefanocampanella/arco-make:latest).
        --virtual-env PATH                      Run from a local virtual environment (VIRTUAL_ENV path) instead of Apptainer.
        --env-file FILE                         Environment file to source (default scripts/.env).
        --bind SRC[:DST[:OPTS]]                 Path to bind within the Apptainer container (can be repeated).
        --overwrite                             Whether to overwrite destination (default false).
        --log-level LEVEL                       Logging level (debug, info, warning, error, critical). Default: info.
        --help                                  Shows this help.
EOF
}

ARCO_OCEAN_ARRAY_START=1993-01-01
ARCO_OCEAN_ARRAY_END=2021-07-01
ARCO_OCEAN_ARRAY_STEP=256

# Default options
ARRAY=true
OVERWRITE=false
LOG_LEVEL="info"
IMAGE="oras://ghcr.io/stefanocampanella/arco-make:latest"
VENV=""
ENV_FILE="scripts/.env"
BINDS=()

# Parse command line options
ARGS=$(getopt --options '' --longoptions "config-dir:,output-dir:,log-dir:,no-array,start:,end:,image:,virtual-env:,env-file:,bind:,overwrite,log-level:,help" --name "$0" -- "${@}")
if [[ ${?} -ne 0 ]]; then
    usage
    exit 1
fi
eval "set -- ${ARGS}"
while true; do
    case "${1}" in
        (--config-dir)
            CONFIG_DIR="${2}"
            shift 2
            ;;
        (--output-dir)
            OUTPUT_DIR="${2}"
            shift 2
            ;;
        (--log-dir)
            LOG_DIR="${2}"
            shift 2
            ;;
        (--no-array)
            ARRAY=false
            shift
            ;;
        (--start)
            START_DATE="${2}"
            shift 2
            ;;
        (--end)
            END_DATE="${2}"
            shift 2
            ;;
        (--image)
            IMAGE="${2}"
            shift 2
            ;;
        (--virtual-env)
            VENV="${2}"
            shift 2
            ;;
        (--env-file)
            ENV_FILE="${2}"
            shift 2
            ;;
        (--bind)
            BINDS+=("${2}")
            shift 2
            ;;
        (--overwrite)
            OVERWRITE=true
            shift
            ;;
        (--log-level)
            LOG_LEVEL="$2"; shift 2
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
            echo "Error: unrecognized option ${1}."
            usage
            exit 1
            ;;
    esac
done

# Change current directory to project root
PROJECT_ROOT=$(git rev-parse --show-toplevel)
cd "${PROJECT_ROOT}" || exit 1

# Set default path envs and module loading 
if [[ -n ${ENV_FILE} ]]; then
    if [[ ! -f ${ENV_FILE} ]]; then
        echo "Error: environment file ${ENV_FILE} not found."
        exit 1
    fi
    source "${ENV_FILE}"
fi

# Load default modules
load_modules

# Check that apptainer is installed (only when not running from a local virtual environment)
if [[ -z ${VENV} ]]; then
    apptainer --version || exit 1
fi

# Build command line flags
FLAGS="--no-progress --log-level=${LOG_LEVEL}"

if [[ ${OVERWRITE} == true ]]; then
    FLAGS="${FLAGS} --overwrite"
else
    FLAGS="${FLAGS} --no-overwrite"
fi

if [[ ${ARRAY} == true ]]; then
    START_DATE=$(date -d "$ARCO_OCEAN_ARRAY_START + $(( ARCO_OCEAN_ARRAY_STEP * SLURM_ARRAY_TASK_ID ))  days" +"%Y-%m-%d")
    END_DATE=$(date -d "$ARCO_OCEAN_ARRAY_START + $(( ARCO_OCEAN_ARRAY_STEP * (SLURM_ARRAY_TASK_ID + 1) )) days" +"%Y-%m-%d")
    if [[ "$ARCO_OCEAN_ARRAY_END" < "$END_DATE" ]]; then
       END_DATE=$ARCO_OCEAN_ARRAY_END
    fi
fi

if [[ -n ${START_DATE} ]]; then
    FLAGS="${FLAGS} --start=${START_DATE}"
fi

if [[ -n ${END_DATE} ]]; then
    FLAGS="${FLAGS} --end=${END_DATE}"
fi

# Determine config file and input/output paths using the remaining argument
if [[ -z ${CONFIG_DIR} ]]; then
    CONFIG_DIR="${PROJECT_ROOT}/configs/download"
fi
CONFIG_PATH="${CONFIG_DIR}/${1}.toml"

# Set OUTPUT_PATH and ensure parent exists
if [[ -z ${OUTPUT_DIR} ]]; then
    OUTPUT_DIR="${DATA_ROOT}/data/archive/${1}"
fi
if [[ ! -d "${OUTPUT_DIR}" ]]; then
    mkdir -p "${OUTPUT_DIR}"
fi
OUTPUT_PATH="${OUTPUT_DIR}/${START_DATE}_${END_DATE}.zip"

# Set default LOG_DIR and ensure it exists
if [[ -z ${LOG_DIR} ]]; then
    LOG_DIR="${PROJECT_ROOT}/logs/download"
fi
if [[ ! -d "${LOG_DIR}" ]]; then
    mkdir -p "${LOG_DIR}"
fi

# Build the run command: either a local virtual environment or an Apptainer image
if [[ -n ${VENV} ]]; then
    RUN_CMD=(env VIRTUAL_ENV="${VENV}" uv run --no-sync arco-make)
else
    APPTAINER_FLAGS=()
    for BIND in "${BINDS[@]+"${BINDS[@]}"}"; do
        APPTAINER_FLAGS+=(--bind "${BIND}")
    done
    RUN_CMD=(apptainer run "${APPTAINER_FLAGS[@]+"${APPTAINER_FLAGS[@]}"}" "${IMAGE}")
fi

# Run arco-make
"${RUN_CMD[@]}" download ${FLAGS} -- "${CONFIG_PATH}" "${OUTPUT_PATH}"

DOWNLOAD_EXIT_CODE=$?

if [[ ${DOWNLOAD_EXIT_CODE} -eq 0 ]]; then
    echo "----------------------------------------"
    echo "Download completed successfully."
else
    echo "----------------------------------------"
    echo "Download failed with exit code: ${DOWNLOAD_EXIT_CODE}"
    exit ${DOWNLOAD_EXIT_CODE}
fi

# Deactivate all environments
unload_modules
