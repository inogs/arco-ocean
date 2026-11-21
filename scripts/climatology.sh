#!/usr/bin/env bash

# scripts/climatology.sh
#
# Compute the climatology and the anomaly standard deviation of one ARCO-OCEAN dataset with
# arco-make, on one machine (the project VM).
#
# Reads the dataset <product>/res=<res> and writes statistics/res=<res>, one Icechunk repository
# with the groups climatology and anomaly_std, from a recipe named <product>_res-<res>.

usage() {
    cat <<EOF
climatology.sh
    Compute the climatology and the anomaly standard deviation of one dataset with arco-make.

SYNOPSIS
    $0 [options] RECIPE
    $0 --help

DESCRIPTION
    Positional arguments:
        RECIPE                  Recipe name (looked up as CONFIG_DIR/RECIPE.toml) or path, named
                                <product>_res-<res>.toml (e.g. historical_res-0p25).

    Options:
        --project-dir DIR       Project root directory (default: current working directory).
        --config-dir DIR        Where to look for recipes (default: \${PROJECT_ROOT}/configs/climatology).
        --input PATH            Input dataset (default: \$DATA_ROOT/data/<product>/res=<res>).
        --output PATH           Statistics output, groups climatology and anomaly_std
                                (default: \$DATA_ROOT/data/statistics/res=<res>).
        --log-dir DIR           Where to write the log (default: \${PROJECT_ROOT}/logs/climatology).
        --replace               Write a new version of an existing output (arco-make --replace).
        --streaming             One series at a time (arco-make --streaming; default: one graph).
        --dask-setup SETUP      arco-make's Dask scheduler (default: threads).
        --image IMAGE           Apptainer image (default: oras://ghcr.io/stefanocampanella/arco-make:latest).
        --virtual-env PATH      Run from a local virtual environment instead of Apptainer.
        --env-file FILE         Environment file to source (default: scripts/.env).
        --bind SRC[:DST[:OPTS]] Path to bind within the Apptainer container (repeatable).
        --log-level LEVEL       debug, info, warning, error or critical (default: info).
        -h, --help              Show this help.
EOF
}

PROJECT_ROOT=""
CONFIG_DIR=""
INPUT=""
OUTPUT=""
STREAMING=false
LOG_DIR=""
REPLACE=false
DASK_SETUP="threads"
IMAGE="oras://ghcr.io/stefanocampanella/arco-make:latest"
VENV=""
ENV_FILE="scripts/.env"
BINDS=()
LOG_LEVEL="info"
POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project-dir) PROJECT_ROOT="$2"; shift 2 ;;
        --project-dir=*) PROJECT_ROOT="${1#*=}"; shift ;;
        --config-dir) CONFIG_DIR="$2"; shift 2 ;;
        --config-dir=*) CONFIG_DIR="${1#*=}"; shift ;;
        --input) INPUT="$2"; shift 2 ;;
        --input=*) INPUT="${1#*=}"; shift ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --output=*) OUTPUT="${1#*=}"; shift ;;
        --streaming) STREAMING=true; shift ;;
        --log-dir) LOG_DIR="$2"; shift 2 ;;
        --log-dir=*) LOG_DIR="${1#*=}"; shift ;;
        --replace) REPLACE=true; shift ;;
        --dask-setup) DASK_SETUP="$2"; shift 2 ;;
        --dask-setup=*) DASK_SETUP="${1#*=}"; shift ;;
        --image) IMAGE="$2"; shift 2 ;;
        --image=*) IMAGE="${1#*=}"; shift ;;
        --virtual-env) VENV="$2"; shift 2 ;;
        --virtual-env=*) VENV="${1#*=}"; shift ;;
        --env-file) ENV_FILE="$2"; shift 2 ;;
        --env-file=*) ENV_FILE="${1#*=}"; shift ;;
        --bind) BINDS+=("$2"); shift 2 ;;
        --bind=*) BINDS+=("${1#*=}"); shift ;;
        --log-level) LOG_LEVEL="$2"; shift 2 ;;
        --log-level=*) LOG_LEVEL="${1#*=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; POSITIONAL_ARGS+=("$@"); break ;;
        -*) echo "Error: unrecognized option '$1'." >&2; usage >&2; exit 1 ;;
        *) POSITIONAL_ARGS+=("$1"); shift ;;
    esac
done

RECIPE="${POSITIONAL_ARGS[0]:-}"
if [[ -z "${RECIPE}" || ${#POSITIONAL_ARGS[@]} -gt 1 ]]; then
    echo "Error: give exactly one RECIPE." >&2
    usage >&2
    exit 1
fi

PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
cd "${PROJECT_ROOT}" || exit 1

if [[ -n "${ENV_FILE}" ]]; then
    if [[ ! -f "${ENV_FILE}" ]]; then
        echo "Error: environment file '${ENV_FILE}' not found." >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
fi

CONFIG_DIR="${CONFIG_DIR:-${PROJECT_ROOT}/configs/climatology}"
if [[ -f "${RECIPE}" ]]; then
    CONFIG_PATH="${RECIPE}"
else
    CONFIG_PATH="${CONFIG_DIR}/${RECIPE%.toml}.toml"
fi
if [[ ! -f "${CONFIG_PATH}" ]]; then
    echo "Error: recipe '${CONFIG_PATH}' not found." >&2
    exit 1
fi
NAME="$(basename "${CONFIG_PATH}" .toml)"

# Default paths: <product>/res=<res> in, statistics/ at the same resolution out.
if [[ -z "${INPUT}" || -z "${OUTPUT}" ]]; then
    if [[ ! "${NAME}" =~ ^([a-z0-9-]+)_res-([0-9]+p[0-9]+)$ ]]; then
        echo "Error: cannot derive paths from '${NAME}' (expected <product>_res-<res>): give --input and --output." >&2
        exit 1
    fi
    DATA="${DATA_ROOT:-${PROJECT_ROOT}}/data"
    INPUT="${INPUT:-${DATA}/${BASH_REMATCH[1]}/res=${BASH_REMATCH[2]}}"
    OUTPUT="${OUTPUT:-${DATA}/statistics/res=${BASH_REMATCH[2]}}"
fi
if [[ "${OUTPUT}" != *://* ]]; then
    mkdir -p "$(dirname "${OUTPUT}")"
fi

LOG_DIR="${LOG_DIR:-${PROJECT_ROOT}/logs/climatology}"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/${NAME}_$(date -u +%Y%m%dT%H%M%SZ).log"

if [[ -n "${VENV}" ]]; then
    RUN_CMD=(env VIRTUAL_ENV="${VENV}" uv run --no-sync arco-make)
else
    if ! command -v apptainer >/dev/null 2>&1; then
        echo "Error: Apptainer is required without --virtual-env." >&2
        exit 1
    fi
    APPTAINER_FLAGS=()
    for BIND in "${BINDS[@]+"${BINDS[@]}"}"; do
        APPTAINER_FLAGS+=(--bind "${BIND}")
    done
    RUN_CMD=(apptainer run "${APPTAINER_FLAGS[@]+"${APPTAINER_FLAGS[@]}"}" "${IMAGE}")
fi

FLAGS=(--dask-setup="${DASK_SETUP}" --log-level="${LOG_LEVEL}")
if [[ "${REPLACE}" == true ]]; then
    FLAGS+=(--replace)
fi
if [[ "${STREAMING}" == true ]]; then
    FLAGS+=(--streaming)
fi

echo "Statistics of ${INPUT} to ${OUTPUT}, log: ${LOG_FILE} (started $(date -u), host $(hostname))"
"${RUN_CMD[@]}" compute-climatology "${FLAGS[@]}" -- \
    "${CONFIG_PATH}" "${INPUT}" "${OUTPUT}" >> "${LOG_FILE}" 2>&1
STATUS=$?
if [[ ${STATUS} -eq 0 ]]; then
    echo "Statistics of ${NAME} finished ($(date -u))."
else
    echo "Statistics of ${NAME} failed (exit code ${STATUS}): see ${LOG_FILE}." >&2
fi
exit ${STATUS}
