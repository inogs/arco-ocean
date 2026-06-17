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
    The script will look into "configs/download" for a TOML recipe named CONFIG_NAME,
    and the output path will computed as "OUTPUT_DIR/CONFIG_NAME".

SYNOPSIS
    usage: $0 --help
    usage: $0 [options] CONFIG_NAME

DESCRIPTION
    Options
        --no-array                              Whether to download dataset in a single SLURM job (default false).
        --overwrite                             Whether to overwrite destination (default false).
        --start                                 Overwrite config start date.
        --end                                   Overwrite config end date.
        --output-dir                            Where to place the ouputs (default to $LEONARDO_DATA_ROOT/data/dataset).
        --help                                  Shows this help.
EOF
}

# Options default values
ARRAY=true
OVERWRITE=false
# Parse command line options
ARGS=$(getopt --options '' --longoptions "overwrite,no-array,start:,end:,output-dir:,help" --name "$0" -- "${@}")
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
        (--overwrite)
            OVERWRITE=true
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
PROJECTROOT=$(git rev-parse --show-toplevel)
cd "${PROJECTROOT}" || exit 1

# Check that apptainer is installed
apptainer --version || exit 1

# Load default modules
source leonardo/modules.sh
load_modules

# Set default path envs
source leonardo/.env

# Build command line flags
FLAGS="--no-progress"

if [[ ${OVERWRITE} == true ]]; then
    FLAGS="${FLAGS} --overwrite"
else
    FLAGS="${FLAGS} --no-overwrite"
fi

FLAGS="${FLAGS} --log-level=info"

if [[ ${ARRAY} == true ]]; then
    FLAGS="${FLAGS} --array-id=${SLURM_ARRAY_TASK_ID}"
fi

if [[ -n ${START_DATE} ]]; then
    FLAGS="${FLAGS} --start=${START_DATE}"
fi

if [[ -n ${END_DATE} ]]; then
    FLAGS="${FLAGS} --end=${END_DATE}"
fi

# Determine config file and output paths using the remaining argument
CONFIG_PATH="${PROJECTROOT}/configs/download/${1}.toml"

# Set OUTPUT_PATH and ensure parent exists
if [[ -z ${OUTPUT_DIR} ]]; then
    OUTPUT_DIR="${LEONARDO_DATA_ROOT}/data"
fi
if [[ ! -d "${OUTPUT_DIR}" ]]; then
    mkdir -p "${OUTPUT_DIR}"
fi
OUTPUT_PATH="${OUTPUT_DIR}/${1}"

# Run arco-make
export PYTHONWARNINGS='ignore::RuntimeWarning'
apptainer exec oras://ghcr.io/arco-make:latest arco-make download ${FLAGS} -- "${CONFIG_PATH}" "${OUTPUT_PATH}"

DOWNLOAD_EXIT_CODE=$?

if [[ ${DOWNLOAD_EXIT_CODE} -eq 0 ]]; then
    echo "----------------------------------------"
    echo "Download completed successfully."
else
    echo "----------------------------------------"
    echo "Download failed with exit code: ${DOWNLOAD_EXIT_CODE}"
    exit ${DOWNLOAD_EXIT_CODE}
fi

# Deactivate all environments (useless when run in a SLURM job)
unload_modules
