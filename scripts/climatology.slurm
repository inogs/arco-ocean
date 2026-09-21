#! /usr/bin/env bash
#SBATCH --partition=dcgp_usr_prod
#SBATCH --nodes=8
#SBATCH --ntasks-per-node=7
#SBATCH --cpus-per-task=16
#SBATCH --exclusive
#SBATCH --time=500
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
    This script computes the climatology and the anomaly standard deviation from a Zarr dataset using arco-make.
    The script reads the input dataset named CONFIG_NAME from INPUT_DIR and writes the climatology and the anomaly
    standard deviation respectively to "OUTPUT_DIR/CONFIG_NAME_climatology" and "OUTPUT_DIR/CONFIG_NAME_anomaly_std".
    The script will look into CONFIG_DIR for a TOML recipe named CONFIG_NAME.

SYNOPSIS
    usage: $0 --help
    usage: $0 [options] CONFIG_NAME

DESCRIPTION
    Options
        --config-dir                            Where to look for configs (default to \${PROJECT_ROOT}/configs/climatology).
        --input-dir                             Where to look for data (default to \$DATA_ROOT/data/datasets).
        --output-dir                            Where to place the outputs (default to \$DATA_ROOT/data/datasets).
        --log-dir                               Where to place the logs (default to \${PROJECT_ROOT}/logs/climatology).
        --image                                 Apptainer image path (default oras://ghcr.io/stefanocampanella/arco-make:latest).
        --virtual-env PATH                      Run from a local virtual environment (VIRTUAL_ENV path) instead of Apptainer.
        --env-file FILE                         Environment file to source (default scripts/.env).
        --bind SRC[:DST[:OPTS]]                 Path to bind within the Apptainer container (can be repeated).
        --overwrite                             Whether to overwrite destination (default false).
        --no-sync-step                          Whether to synchronize steps (default true).
        --log-level LEVEL                       Logging level (debug, info, warning, error, critical). Default: info.
        --help                                  Shows this help.
EOF
}

# Default options
OVERWRITE=false
SYNC_STEP=true
LOG_LEVEL="info"
IMAGE="oras://ghcr.io/stefanocampanella/arco-make:latest"
VENV=""
ENV_FILE="scripts/.env"
BINDS=()

# Parse command line options
ARGS=$(getopt --options '' --longoptions "config-dir:,input-dir:,output-dir:,log-dir:,image:,virtual-env:,env-file:,bind:,overwrite,no-sync-step,log-level:,help" --name "$0" -- "${@}")
if [[ ${?} -ne 0 ]]; then
    usage
    exit 1
fi

eval "set -- ${ARGS}"
while true; do
    case "$1" in
        (--config-dir)
            CONFIG_DIR="${2}"
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
        (--no-sync-step)
            SYNC_STEP=false
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
            echo "Error: unrecognized option $1" >&2
            usage
            exit 1
            ;;
    esac
done

# Remaining args: config name
if [[ $# -lt 1 ]]; then
    echo "Error: missing required argument config name" >&2
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
FLAGS="--scheduler-type=mpi \
       --log-level=${LOG_LEVEL}"

if [[ ${OVERWRITE} == true ]]; then
    FLAGS="${FLAGS} --overwrite"
else
    FLAGS="${FLAGS} --no-overwrite"
fi

if [[ ${SYNC_STEP} == true ]]; then
    FLAGS="${FLAGS} --sync-step"
else
    FLAGS="${FLAGS} --no-sync-step"
fi

# Determine config file and input/output paths using the remaining argument
if [[ -z ${CONFIG_DIR} ]]; then
    CONFIG_DIR="${PROJECT_ROOT}/configs/climatology"
fi
CONFIG_PATH="${CONFIG_DIR}/${1}.toml"

# Set default INPUT_DIR
if [[ -z ${INPUT_DIR} ]]; then
    INPUT_DIR="${DATA_ROOT}/data/datasets"
fi
INPUT_PATH="${INPUT_DIR}/${1}"

# Set default OUTPUT_DIR and ensure it exists
if [[ -z ${OUTPUT_DIR} ]]; then
    OUTPUT_DIR="${DATA_ROOT}/data/datasets"
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

# Increase all timers trying to avoid "Futures cancelled for reason: scheduler-connection-lost."
export DASK_DISTRIBUTED__COMM__TIMEOUTS__CONNECT="300s"
export DASK_DISTRIBUTED__COMM__TIMEOUTS__TCP="300s"
export DASK_DISTRIBUTED__SCHEDULER__WORKER_TTL="600s"
export DASK_DISTRIBUTED__CLIENT__HEARTBEAT="10s"

# Build the run command: either a local virtual environment or an Apptainer image
if [[ -n ${VENV} ]]; then
    RUN_CMD=(env UV_PROJECT_ENVIRONMENT="${VENV}" uv run --no-sync arco-make)
else
    APPTAINER_FLAGS=()
    for BIND in "${BINDS[@]+"${BINDS[@]}"}"; do
        APPTAINER_FLAGS+=(--bind "${BIND}")
    done
    RUN_CMD=(apptainer run "${APPTAINER_FLAGS[@]+"${APPTAINER_FLAGS[@]}"}" "${IMAGE}")
fi

srun --output="${LOG_DIR}"/%j_%N_%t.out --error="${LOG_DIR}"/%j_%N_%t.err \
  "${RUN_CMD[@]}" compute-climatology ${FLAGS} -- "${CONFIG_PATH}" "${INPUT_PATH}" "${CLIMATOLOGY_OUTPUT_PATH}" "${ANOMALY_STD_OUTPUT_PATH}"

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
