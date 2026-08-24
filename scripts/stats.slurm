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
compute_stats.slurm
    This script computes dataset statistics (mean, std, diff_std) from a Zarr dataset using arco-make.
    It requires Apptainer to be installed. The script reads the input dataset named dataset_name from
    INPUT_DIR and writes each statistic to "OUTPUT_DIR/dataset_name_<stats>".

SYNOPSIS
    usage: $0 --help
    usage: $0 [options] dataset_name

DESCRIPTION
    Positional arguments
        dataset_name                            Name of the input dataset

    Options
        --input-dir                             Where to look for data (default to \$DATA_ROOT/data/dataset).
        --output-dir                            Where to place the ouputs (default to \$DATA_ROOT/data/stats).
        --log-dir                               Where to place the logs (default to \${PROJECT_ROOT}/logs/compute_stats).
        --image                                 Apptainer image path (default oras://ghcr.io/stefanocampanella/arco-make:latest).
        --env-file FILE                         Environment file to source (default scripts/.env).
        --bind SRC[:DST[:OPTS]]                 Path to bind within the Apptainer container (can be repeated).
        --overwrite                             Whether to overwrite destination (default false).
        --skipna                                Skip NaNs when averaging (default false).
        --time-dim DIM                          Name of the time dimension (default: time).
        --log-level LEVEL                       Logging level (debug, info, warning, error, critical). Default: info.
        --help                                  Shows this help.
EOF
}

# Default options
OVERWRITE=false
SKIPNA=false
TIME_DIM="time"
LOG_LEVEL="info"
IMAGE="oras://ghcr.io/stefanocampanella/arco-make:latest"
ENV_FILE="scripts/.env"
BINDS=()

# Parse command line options
ARGS=$(getopt --options '' --longoptions "input-dir:,output-dir:,log-dir:,image:,env-file:,bind:,overwrite,skipna,time-dim:,log-level:,help" --name "$0" -- "${@}")
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
        (--skipna)
            SKIPNA=true
            shift
            ;;
        (--time-dim)
            TIME_DIM="$2"; shift 2
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

# Check that apptainer is installed
apptainer --version || exit 1

# Build command line flags
FLAGS="--time-dim=${TIME_DIM} \
       --in-chunks=time:auto,level:-1,lat:-1,lon:-1 \
       --out-chunks=time:1,level:-1,lat:-1,lon:-1 \
       --scheduler-type=mpi \
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

# Set default LOG_DIR and ensure it exists
if [[ -z ${LOG_DIR} ]]; then
    LOG_DIR="${PROJECT_ROOT}/logs/stats"
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

# Build apptainer flags
APPTAINER_FLAGS=()
for BIND in "${BINDS[@]+"${BINDS[@]}"}"; do
    APPTAINER_FLAGS+=(--bind "${BIND}")
done

ALL_STATS=(mean std diff_std)
for STATS in "${ALL_STATS[@]}"; do
    OUTPUT_PATH="${OUTPUT_DIR}/${1}_${STATS}"
    srun --output="${LOG_DIR}"/%j_%N_%t.out --error="${LOG_DIR}"/%j_%N_%t.err \
      apptainer run "${APPTAINER_FLAGS[@]+"${APPTAINER_FLAGS[@]}"}" "${IMAGE}" compute-stats ${FLAGS} -- "${STATS}" "${INPUT_PATH}" "${OUTPUT_PATH}"

    STATS_EXIT_CODE=$?

    if [[ ${STATS_EXIT_CODE} -eq 0 ]]; then
        echo "----------------------------------------"
        echo "Stats ${STATS} computed successfully."
    else
        echo "----------------------------------------"
        echo "Stats ${STATS} computation failed with exit code: ${STATS_EXIT_CODE}"
        exit ${STATS_EXIT_CODE}
    fi
done

# Deactivate all environments
unload_modules
