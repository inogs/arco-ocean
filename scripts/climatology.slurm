#! /usr/bin/env bash
#SBATCH --account=OGS23_PRACE_IT_1
#SBATCH --partition=dcgp_usr_prod
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=28
#SBATCH --cpus-per-task=4
#SBATCH --exclusive
#SBATCH --time=60
#SBATCH --gres=tmpfs:3T
#SBATCH --requeue

# TODO: The current script used to compute both the climatology and other stats (mean, std, std_diff). However,
#   computing the stats scales well, and these can be computed one after the other in a short job on, say, 4 nodes.
#   Instead, the climatology does not scale due to communications, hence it would make more sense
#   to have a longer job running on a single node and using a LocalCluster (one node) with the  inproc:// protocol,
#   thus reducing the communication time.
#   However, it turns out that this way there is a single core very busy, while the rest of the node sits idle. This is
#   Probably due to the rading from zipped Zar files happening serially. Things to try next:
#       1. Use a Dask-MPI cluster, as with other stats, but using the loopback interface to speedup communications.
#       2. Create another version of the dataset, using the `365_day` calendar, and then read from it using a chunk size
#           of 365 elements along the time dimension. This should avoid some communication due to chunk shuffling.
#   Apparently, the first attempt was sufficient.

usage() {
    more <<EOF
compute_climatology.slurm
    This script computes the daily climatology from a Zarr dataset using arco-make.
    It requires Apptainer to be installed. The script reads the input dataset named dataset_name from
    INPUT_DIR and writes the climatology to "OUTPUT_DIR/dataset_name_climatology".

SYNOPSIS
    usage: $0 --help
    usage: $0 [options] dataset_name

DESCRIPTION
    Positional arguments
        dataset_name                            Name of the input dataset

    Options
        --input-dir                             Where to look for data (default to \$LEONARDO_DATA_ROOT/data/dataset).
        --output-dir                            Where to place the ouputs (default to \$LEONARDO_DATA_ROOT/data/stats).
        --log-dir                               Where to place the logs (default to \${PROJECT_ROOT}/logs/compute_climatology).
        --image                                 Apptainer image path (default oras://ghcr.io/stefanocampanella/arco-make:latest).
        --overwrite                             Whether to overwrite destination (default false).
        --skipna                                Skip NaNs when averaging (default false).
        --time-dim DIM                          Name of the time dimension (default: time).
        --climatology-bin-dim DIM               Name of the climatology bin dimension (default: dayofyear).
        --calendar CALENDAR                     Calendar to use (default: 365_day).
        --log-level LEVEL                       Logging level (debug, info, warning, error, critical). Default: info.
        --help                                  Shows this help.
EOF
}

# Default options
OVERWRITE=false
SKIPNA=false
TIME_DIM="time"
CLIMATOLOGY_BIN_DIM="dayofyear"
CALENDAR="365_day"
LOG_LEVEL="info"
IMAGE="oras://ghcr.io/stefanocampanella/arco-make:latest"

# Parse command line options
ARGS=$(getopt --options '' --longoptions "input-dir:,output-dir:,log-dir:,image:,overwrite,skipna,time-dim:,climatology-bin-dim:,calendar:,log-level:,help" --name "$0" -- "${@}")
if [[ ${?} -ne 0 ]]; then
    usage
    exit 1
fi

eval "set -- ${ARGS}"
while true; do
    case "$1" in
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
            OVERWRITE=true
            shift
            ;;
        (--skipna)
            SKIPNA=true
            shift
            ;;
        (--time-dim)
            TIME_DIM="$2"; shift 2
            ;;
        (--climatology-bin-dim)
            CLIMATOLOGY_BIN_DIM="$2"; shift 2
            ;;
        (--calendar)
            CALENDAR="$2"; shift 2
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
            echo "Error: unrecognized option $1" >&2
            usage
            exit 1
            ;;
    esac
done

# Remaining args: dataset name
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
FLAGS="--time-dim=${TIME_DIM} \
       --in-chunks=time:auto,level:-1,lat:-1,lon:-1 \
       --out-chunks=time:1,level:-1,lat:-1,lon:-1 \
       --climatology-bin-dim=${CLIMATOLOGY_BIN_DIM} \
       --scheduler-type=mpi \
       --calendar=${CALENDAR} \
       --no-raise \
       --log-level=${LOG_LEVEL}"

if [[ ${OVERWRITE} == true ]]; then
    FLAGS="${FLAGS} --overwrite"
else
    FLAGS="${FLAGS} --no-overwrite"
fi

if [[ ${SKIPNA} == true ]]; then
    FLAGS="${FLAGS} --skipna"
else
    FLAGS="${FLAGS} --no-skipna"
fi

# Set default INPUT_DIR
if [[ -z ${INPUT_DIR} ]]; then
    INPUT_DIR="${LEONARDO_DATA_ROOT}/data/dataset"
fi
INPUT_PATH="${INPUT_DIR}/${1}"

# Set default OUTPUT_DIR and ensure it exists
if [[ -z ${OUTPUT_DIR} ]]; then
    OUTPUT_DIR="${LEONARDO_DATA_ROOT}/data/stats"
fi
if [[ ! -d "${OUTPUT_DIR}" ]]; then
    mkdir -p "${OUTPUT_DIR}"
fi
CLIMATOLOGY_OUTPUT_PATH="${OUTPUT_DIR}/${1}_climatology"
ANOMALY_STD_OUTPUT_PATH="${OUTPUT_DIR}/${1}_anomaly_std"

# Set default LOG_DIR and ensure it exists
if [[ -z ${LOG_DIR} ]]; then
    LOG_DIR="${PROJECT_ROOT}/logs/climatology"
fi
if [[ ! -d "${LOG_DIR}" ]]; then
    mkdir -p "${LOG_DIR}"
fi

# Compactify logs: concatenate all logs for this job and remove the originals
compactify_logs() {
    local ext combined f
    for ext in out err; do
        combined="${LOG_DIR}/${SLURM_JOB_ID}.${ext}"
        for f in "${LOG_DIR}/${SLURM_JOB_ID}"_*."${ext}"; do
            [[ -e "${f}" ]] || continue
            echo "===== ${f##*/} =====" >> "${combined}"
            cat "${f}" >> "${combined}"
            rm -f "${f}"
        done
    done
}
trap compactify_logs EXIT


# see:
# https://bitbucket.org/mpi4py/mpi4py/issues/80/mpi_thread_multiple-vs-mpi_thread_single
# https://github.com/open-mpi/ompi/issues/6240
# https://github.com/open-mpi/ompi/issues/9763
# https://developer.skao.int/projects/ska-sdp-exec-iotest/en/latest/content/mpi_settings.html#slurm-specific-settings
# https://docs.nvidia.com/networking/display/hpcxv211/hcoll
export OMPI_MCA_btl_tcp_if_exclude=brmgt,enp1s0,ib0,virbr0
export OMPI_MCA_coll=^hcoll
export DASK_MPI__INTERFACE=lo
export DASK_MPI__PROTOCOL="tcp://"
export DASK_MPI__NTHREADS=${SLURM_CPUS_PER_TASK}
export DASK_MPI__LOCAL_DIRECTORY=${TMPDIR}

srun --output="${LOG_DIR}"/%j_%N_%t.out --error="${LOG_DIR}"/%j_%N_%t.err \
  apptainer exec "${IMAGE}" arco-make compute-climatology ${FLAGS} -- "${INPUT_PATH}" "${CLIMATOLOGY_OUTPUT_PATH}" "${ANOMALY_STD_OUTPUT_PATH}"

CLIMATOLOGY_EXIT_CODE=$?

if [[ ${CLIMATOLOGY_EXIT_CODE} -eq 0 ]]; then
    echo "----------------------------------------"
    echo "Climatology computed successfully."
else
    echo "----------------------------------------"
    echo "Climatology computation failed with exit code: ${CLIMATOLOGY_EXIT_CODE}"
    exit ${CLIMATOLOGY_EXIT_CODE}
fi

# Deactivate all environments
unload_modules
