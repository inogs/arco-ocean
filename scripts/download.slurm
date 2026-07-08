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
    This script downloads datasets using arco-make. It requires Apptainer to be installed.
    If the dataset is static (e.g. bathymetry), it will download the entire dataset at once.
    If the dataset is a timeseries, it will download a range of dates computed from SLURM_ARRAY_TASK_ID.
    The script will look into "configs" for a TOML recipe named CONFIG_NAME,
    and the output path will computed as "OUTPUT_DIR/CONFIG_NAME".

SYNOPSIS
    usage: $0 --help
    usage: $0 [options] CONFIG_NAME

DESCRIPTION
    Options
        --no-array                              Whether to download dataset in a single SLURM job (default false).
        --start                                 Overwrite config start date.
        --end                                   Overwrite config end date.
        --output-dir                            Where to place the ouputs (default to $LEONARDO_DATA_ROOT/data/dataset).
        --image                                 Apptainer image path (default oras://ghcr.io/stefanocampanella/arco-make:latest).
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

# Parse command line options
ARGS=$(getopt --options '' --longoptions "no-array,start:,end:,output-dir:,image:,overwrite,log-level:,help" --name "$0" -- "${@}")
if [[ ${?} -ne 0 ]]; then
    usage
    exit 1
fi
eval "set -- ${ARGS}"
while true; do
    case "${1}" in
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
        (--output-dir)
            OUTPUT_DIR="${2}"
            shift 2
            ;;
        (--image)
            IMAGE="${2}"
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
source scripts/.env

# Load default modules
load_modules

# Check that apptainer is installed
apptainer --version || exit 1

# Build command line flags
FLAGS="--no-progress --log-level=${LOG_LEVEL} --no-raise"

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

# Determine config file and output paths using the remaining argument
CONFIG_PATH="${PROJECT_ROOT}/configs/${1}.toml"

# Set OUTPUT_PATH and ensure parent exists
if [[ -z ${OUTPUT_DIR} ]]; then
    OUTPUT_DIR="${LEONARDO_DATA_ROOT}/data/archive/${1}"
fi

if [[ ! -d "${OUTPUT_DIR}" ]]; then
    mkdir -p "${OUTPUT_DIR}"
fi

OUTPUT_PATH="${OUTPUT_DIR}/${START_DATE}_${END_DATE}.zip"


# Run arco-make
export PYTHONWARNINGS='ignore::RuntimeWarning'
apptainer exec "${IMAGE}" arco-make download ${FLAGS} -- "${CONFIG_PATH}" "${OUTPUT_PATH}"

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
