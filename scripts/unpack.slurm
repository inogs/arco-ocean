#! /usr/bin/env bash
#SBATCH --partition=dcgp_usr_prod
#SBATCH --ntasks-per-node=112
#SBATCH --cpus-per-task=1
#SBATCH --exclusive
#SBATCH --gres=tmpfs:3T
#SBATCH --requeue

usage() {
    more <<EOF
unpack_dataset.slurm
    This script unpack a dataset stored as a collection of zipped Zarrs.

SYNOPSIS
    usage: $0 --help
    usage: $0 [options] dataset_name

DESCRIPTION
    Positional arguments
        dataset_name                            Name of the input dataset

    Options
        --start                                 Overwrite config start date.
        --end                                   Overwrite config end date.
        --input-dir                             Where to look for data (defaut to $LEONARDO_DATA_ROOT/data/archive).
        --output-dir                            Where to place the ouputs (default to $LEONARDO_DATA_ROOT/data/dataset).
        --log-dir                               Where to place the logs (default to \${PROJECT_ROOT}/logs/unpack).
        --image                                 Apptainer image path (default oras://ghcr.io/stefanocampanella/arco-make:latest).
        --overwrite                             Whether to overwrite destination (default false).
        --log-level LEVEL                       Logging level (debug, info, warning, error, critical). Default: info.
        --help                                  Shows this help.
EOF
}

# Default options
START_DATE=1993-01-01
END_DATE=2021-07-01
OVERWRITE=false
TIME_DIM="time"
LOG_LEVEL="info"
IMAGE="oras://ghcr.io/stefanocampanella/arco-make:latest"

# Parse command line options
ARGS=$(getopt --options '' --longoptions "start:,end:,input-dir:,output-dir:,log-dir:,image:,overwrite,time-dim:,log-level:,help" --name "$0" -- "${@}")
if [[ ${?} -ne 0 ]]; then
    usage
    exit 1
fi

eval "set -- ${ARGS}"
while true; do
    case "$1" in
        (--start)
            START_DATE="${2}"
            shift 2
            ;;
        (--end)
            END_DATE="${2}"
            shift 2
            ;;
        (--input-dir)
            INPUT_DIR="${2}"
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
        (--image)
            IMAGE="${2}"
            shift 2
            ;;
        (--overwrite)
            OVERWRITE=true;
            shift
            ;;
        (--time-dim)
            TIME_DIM="$2"; shift 2
            ;;
        (--log-level)
            LOG_LEVEL="$2"; shift 2
            ;;
        (--help)
            usage;
            exit 0
            ;;
        (--)
            shift;
            break
            ;;
        (*)
            echo "Error: unrecognized option $1" >&2
            usage
            exit 1
            ;;
    esac
done

# Remaining args: input_path and output_path
if [[ $# -lt 1 ]]; then
    echo "Error: missing required argument dataset name" >&2
    usage
    exit 1
fi

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
FLAGS="--time-dim=${TIME_DIM} --log-level=${LOG_LEVEL} --scheduler-type=mpi --chunks=time:auto,level:-1,lat:-1,lon:-1"

if [[ ${OVERWRITE} == true ]]; then
    FLAGS="${FLAGS} --overwrite"
else
    FLAGS="${FLAGS} --no-overwrite"
fi

if [[ -n ${START_DATE} ]]; then
    FLAGS="${FLAGS} --start=${START_DATE}"
fi

if [[ -n ${END_DATE} ]]; then
    FLAGS="${FLAGS} --end=${END_DATE}"
fi

# Set default INPUT_PATH
if [[ -z ${INPUT_DIR} ]]; then
    INPUT_DIR="${LEONARDO_DATA_ROOT}/data/archive"
fi
INPUT_PATH="${INPUT_DIR}/${1}"

# Set OUTPUT_PATH and ensure parent exists
if [[ -z ${OUTPUT_DIR} ]]; then
    OUTPUT_DIR="${LEONARDO_DATA_ROOT}/data/dataset"
fi
if [[ ! -d "${OUTPUT_DIR}" ]]; then
    mkdir -p "${OUTPUT_DIR}"
fi
OUTPUT_PATH="${OUTPUT_DIR}/${1}"

if [[ "${INPUT_DIR}" == "${OUTPUT_DIR}" ]]; then
    echo "INPUT_DIR must be different from OUTPUT_DIR"
    exit 1
fi

# Set default LOG_DIR and ensure it exists
if [[ -z ${LOG_DIR} ]]; then
    LOG_DIR="${PROJECT_ROOT}/logs/unpack"
fi
if [[ ! -d "${LOG_DIR}" ]]; then
    mkdir -p "${LOG_DIR}"
fi

# Compactify logs: concatenate all logs for this job and remove the originals
compactify_logs() {
    local ext combined f
    for ext in out err; do
        combined="${LOG_DIR}/${SLURM_JOB_ID}.${ext}"
        while IFS= read -r f; do
            [[ -e "${f}" ]] || continue
            echo "===== ${f##*/} =====" >> "${combined}"
            cat "${f}" >> "${combined}"
            rm -f "${f}"
        done < <(printf '%s\n' "${LOG_DIR}/${SLURM_JOB_ID}"_*."${ext}" | sort -V)
    done
}
trap compactify_logs EXIT


# see:
# https://bitbucket.org/mpi4py/mpi4py/issues/80/mpi_thread_multiple-vs-mpi_thread_single
# https://github.com/open-mpi/ompi/issues/6240
# https://github.com/open-mpi/ompi/issues/9763
# https://developer.skao.int/projects/ska-sdp-exec-iotest/en/latest/content/mpi_settings.html#slurm-specific-settings
# https://docs.nvidia.com/networking/display/hpcxv211/hcoll
export OMPI_MCA_btl_tcp_if_exclude=brmgt,enp1s0,lo,virbr0
export OMPI_MCA_coll=^hcoll
export DASK_MPI__INTERFACE=ib0
export DASK_MPI__PROTOCOL="tcp://"
export DASK_MPI__NTHREADS=${SLURM_CPUS_PER_TASK}
export DASK_MPI__LOCAL_DIRECTORY=${TMPDIR}

srun --output="${LOG_DIR}"/%j_%N_%t.out --error="${LOG_DIR}"/%j_%N_%t.err \
  apptainer exec "${IMAGE}" arco-make unpack ${FLAGS} -- "${INPUT_PATH}" "${OUTPUT_PATH}"

UNPACK_EXIT_CODE=$?

if [[ ${UNPACK_EXIT_CODE} -eq 0 ]]; then
    echo "----------------------------------------"
    echo "Dataset unpacked successfully."
else
    echo "----------------------------------------"
    echo "Dataset unpack failed with exit code: ${UNPACK_EXIT_CODE}"
    exit ${UNPACK_EXIT_CODE}
fi

# Deactivate all environments
unload_modules
