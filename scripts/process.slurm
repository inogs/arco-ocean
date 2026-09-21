#! /usr/bin/env bash
#SBATCH --partition=dcgp_usr_prod
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=28
#SBATCH --cpus-per-task=4
#SBATCH --exclusive
#SBATCH --time=120
#SBATCH --gres=tmpfs:3T

usage() {
    more <<EOF
process.slurm
    This script process a Zarr dataset using arco-make.
    The script reads the input dataset named CONFIG_NAME from
    INPUT_DIR and writes the result to "OUTPUT_DIR/OUTPUT_NAME".
    The script will look into CONFIG_DIR for a TOML recipe named CONFIG_NAME.

SYNOPSIS
    usage: $0 --help
    usage: $0 [options] CONFIG_NAME OUTPUT_NAME

DESCRIPTION
    Options
        --config-dir                            Where to look for configs (default to \${PROJECT_ROOT}/configs/process).
        --input-dir                             Where to look for data (default to \$DATA_ROOT/data/datasets).
        --output-dir                            Where to place the outputs (default to \$DATA_ROOT/data/datasets).
        --log-dir                               Where to place the logs (default to \${PROJECT_ROOT}/logs/process).
        --image                                 Apptainer image path (default oras://ghcr.io/stefanocampanella/arco-make:latest).
        --virtual-env PATH                      Run from a local virtual environment (VIRTUAL_ENV path) instead of Apptainer.
        --env-file FILE                         Environment file to source (default scripts/.env).
        --bind SRC[:DST[:OPTS]]                 Path to bind within the Apptainer container (can be repeated).
        --overwrite                             Whether to overwrite destination (default false).
        --log-level LEVEL                       Logging level (debug, info, warning, error, critical). Default: info.
        --help                                  Shows this help.
EOF
}

# Default options
OVERWRITE=false
LOG_LEVEL="info"
IMAGE="oras://ghcr.io/stefanocampanella/arco-make:latest"
VENV=""
ENV_FILE="scripts/.env"
BINDS=()

# Parse command line options
ARGS=$(getopt --options '' --longoptions "config-dir:,input-dir:,output-dir:,log-dir:,image:,virtual-env:,env-file:,bind:,overwrite,log-level:,help" --name "$0" -- "${@}")
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

# Remaining args: config name and output name
if [[ $# -lt 2 ]]; then
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


# Determine config file and input/output paths using the remaining argument
if [[ -z ${CONFIG_DIR} ]]; then
    CONFIG_DIR="${PROJECT_ROOT}/configs/process"
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

# Set default LOG_DIR and ensure it exists
if [[ -z ${LOG_DIR} ]]; then
    LOG_DIR="${PROJECT_ROOT}/logs/process"
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
    RUN_CMD=(env VIRTUAL_ENV="${VENV}" uv run --no-sync arco-make)
else
    APPTAINER_FLAGS=()
    for BIND in "${BINDS[@]+"${BINDS[@]}"}"; do
        APPTAINER_FLAGS+=(--bind "${BIND}")
    done
    RUN_CMD=(apptainer run "${APPTAINER_FLAGS[@]+"${APPTAINER_FLAGS[@]}"}" "${IMAGE}")
fi

OUTPUT_PATH="${OUTPUT_DIR}/${2}"
srun --output="${LOG_DIR}"/%j_%N_%t.out --error="${LOG_DIR}"/%j_%N_%t.err \
  "${RUN_CMD[@]}" process ${FLAGS} -- "${CONFIG_PATH}" "${INPUT_PATH}" "${OUTPUT_PATH}"

PROCESS_EXIT_CODE=$?

if [[ ${PROCESS_EXIT_CODE} -eq 0 ]]; then
    echo "----------------------------------------"
    echo "Processed successfully."
else
    echo "----------------------------------------"
    echo "Process failed with exit code: ${PROCESS_EXIT_CODE}"
    exit ${PROCESS_EXIT_CODE}
fi

# Deactivate all environments
unload_modules
