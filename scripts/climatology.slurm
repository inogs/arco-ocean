#! /usr/bin/env bash
#SBATCH --partition=dcgp_usr_prod
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=14
#SBATCH --cpus-per-task=8
#SBATCH --exclusive
#SBATCH --time=60
#SBATCH --gres=tmpfs:3T

# NOTICE: While computing the stats (mean, std, and diff std) scales well, computing the climatology using the 
#   implementation in arco-make is slow and bounded by communications. As for the latter, it would make more sense
#   to have a longer job running on a single node and using a LocalCluster with the  inproc:// protocol 
#   (i.e., processes=False), thus reducing the communication (and serialization) time.
#   That said, it turns out that in that case there is a single core very busy, while the rest of the node sits idle. 
#   (The problem does not appear in experiments using dask-mpi and the infiniband/loopback interface).
#   Moreover, large computational graphs are generated. Why? And what cause such a large amount of reshuffling?

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
        --input-dir                             Where to look for data (default to \$DATA_ROOT/data/dataset).
        --output-dir                            Where to place the ouputs (default to \$DATA_ROOT/data/stats).
        --log-dir                               Where to place the logs (default to \${PROJECT_ROOT}/logs/compute_climatology).
        --image                                 Apptainer image path (default oras://ghcr.io/stefanocampanella/arco-make:latest).
        --virtual-env PATH                      Run from a local virtual environment (VIRTUAL_ENV path) instead of Apptainer.
        --env-file FILE                         Environment file to source (default scripts/.env).
        --bind SRC[:DST[:OPTS]]                 Path to bind within the Apptainer container (can be repeated).
        --overwrite                             Whether to overwrite destination (default false).
        --time-dim DIM                          Name of the time dimension (default: time).
        --climatology-bin-dim DIM               Name of the climatology bin dimension (default: dayofyear).
        --window WINDOW                         Window size (default: 15).
        --calendar CALENDAR                     Calendar to use (default: 365_day).
        --log-level LEVEL                       Logging level (debug, info, warning, error, critical). Default: info.
        --help                                  Shows this help.
EOF
}

# Default options
OVERWRITE=false
TIME_DIM="time"
CLIMATOLOGY_BIN_DIM="dayofyear"
CALENDAR="365_day"
WINDOW=15
LOG_LEVEL="info"
IMAGE="oras://ghcr.io/stefanocampanella/arco-make:latest"
VENV=""
ENV_FILE="scripts/.env"
BINDS=()

# Parse command line options
ARGS=$(getopt --options '' --longoptions "input-dir:,output-dir:,log-dir:,image:,virtual-env:,env-file:,bind:,overwrite,time-dim:,climatology-bin-dim:,window:,calendar:,log-level:,help" --name "$0" -- "${@}")
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
        (--time-dim)
            TIME_DIM="$2"; shift 2
            ;;
        (--climatology-bin-dim)
            CLIMATOLOGY_BIN_DIM="$2"; shift 2
            ;;
        (--window)
            WINDOW="$2"; shift 2
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
FLAGS="--time-dim=${TIME_DIM} \
       --in-chunks=time:auto,level:-1,lat:-1,lon:-1 \
       --out-chunks=dayofyear:1,level:-1,lat:-1,lon:-1 \
       --climatology-bin-dim=${CLIMATOLOGY_BIN_DIM} \
       --window=${WINDOW} \
       --scheduler-type=mpi \
       --calendar=${CALENDAR} \
       --no-raise \
       --sync-step \
       --log-level=${LOG_LEVEL}"

if [[ ${OVERWRITE} == true ]]; then
    FLAGS="${FLAGS} --overwrite"
else
    FLAGS="${FLAGS} --no-overwrite"
fi

# Set default INPUT_DIR
if [[ -z ${INPUT_DIR} ]]; then
    INPUT_DIR="${DATA_ROOT}/data/dataset"
fi
INPUT_PATH="${INPUT_DIR}/${1}"

# Set default OUTPUT_DIR and ensure it exists
if [[ -z ${OUTPUT_DIR} ]]; then
    OUTPUT_DIR="${DATA_ROOT}/data/stats"
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
# https://github.com/open-mpi/ompi/issues/6240
# https://developer.skao.int/projects/ska-sdp-exec-iotest/en/latest/content/mpi_settings.html#slurm-specific-settings
# https://docs.open-mpi.org/en/main/tuning-apps/networking/tcp.html
export OMPI_MCA_btl=self,tcp
export OMPI_MCA_btl_tcp_if_include=ib0

# see:
# https://github.com/open-mpi/ompi/issues/9763
# https://docs.nvidia.com/networking/display/hpcxv211/hcoll
export OMPI_MCA_coll=^hcoll

# see:
# https://docs.hpc.cineca.it/services/singularity.html#containers-in-hpc-environment
export PMIX_MCA_gds=hash

export DASK_MPI__INTERFACE=ib0
export DASK_MPI__PROTOCOL="tcp://"
export DASK_MPI__NTHREADS=${SLURM_CPUS_PER_TASK}
export DASK_MPI__LOCAL_DIRECTORY=${TMPDIR}

# Build the run command: either a local virtual environment or an Apptainer image
if [[ -n ${VENV} ]]; then
    RUN_CMD=(env VIRTUAL_ENV="${VENV}" uv run arco-make)
else
    APPTAINER_FLAGS=()
    for BIND in "${BINDS[@]+"${BINDS[@]}"}"; do
        APPTAINER_FLAGS+=(--bind "${BIND}")
    done
    RUN_CMD=(apptainer run "${APPTAINER_FLAGS[@]+"${APPTAINER_FLAGS[@]}"}" "${IMAGE}")
fi

srun --output="${LOG_DIR}"/%j_%N_%t.out --error="${LOG_DIR}"/%j_%N_%t.err \
  "${RUN_CMD[@]}" compute-climatology ${FLAGS} -- "${INPUT_PATH}" "${CLIMATOLOGY_OUTPUT_PATH}" "${ANOMALY_STD_OUTPUT_PATH}"

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
