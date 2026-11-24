#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Stefano Campanella
# SPDX-License-Identifier: MIT

# scripts/download.sh
#
# Download one ARCO-OCEAN dataset with arco-make, in one resumable run.
#
# The recipes have no dates: [--start, --end) is written to one Icechunk repository, or, with
# --extend, the days after the repository's last up to --end. Block after block, each block a
# commit on the run's own branch; the repository's `main` moves to the new version only when
# every block is written. If the run fails, it is attempted again with `arco-make download
# --resume` (`--extend --resume` for an extension), which keeps the blocks already committed and
# writes the others (up to --attempts runs in all). A forecast download stopped at a run its
# sources have not published yet (exit status 75: the runs before are stored) is attempted again
# with --extend. Transient network errors are already retried
# inside arco-make, block by block (the recipe's [retries]). It needs arco-make with `--extend`
# and recipes without dates: an image built after the arco-make stack is merged.

usage() {
    cat <<EOF
download.sh
    Download one dataset with arco-make into one Icechunk repository, resuming after failures.

SYNOPSIS
    $0 [options] RECIPE
    $0 --help

DESCRIPTION
    Positional arguments:
        RECIPE                  Recipe name (looked up as CONFIG_DIR/RECIPE.toml) or path, named
                                <product>_res-<res>.toml (e.g. historical_res-0p25).

    Options:
        --project-dir DIR       Project root directory (default: current working directory).
        --config-dir DIR        Where to look for recipes (default: \${PROJECT_ROOT}/configs/download).
        --output PATH           Output repository: a directory, s3:// or gs:// URL (default:
                                \$DATA_ROOT/data/<product>/res=<res>, from the recipe name).
        --log-dir DIR           Where to write the log (default: \${PROJECT_ROOT}/logs/download).
        --start DATE            First day (YYYY-MM-DD): the recipes have no dates. Not with --extend.
        --end DATE              The day after the last (YYYY-MM-DD). Required.
        --extend                Append the days after the output's last, up to --end, as a new
                                version (arco-make --extend; resumed with --resume).
        --replace               Write a new version of an existing output (arco-make --replace).
        --resume                Continue a run that failed earlier (arco-make --resume).
        --attempts N            Runs in all, the later ones resuming (default: 3).
        --retry-delay SECONDS   Wait between runs (default: 60).
        --image IMAGE           Apptainer image (default: oras://ghcr.io/stefanocampanella/arco-make:latest).
        --virtual-env PATH      Run from a local virtual environment instead of Apptainer.
        --env-file FILE         Environment file to source (default: scripts/.env).
        --bind SRC[:DST[:OPTS]] Path to bind within the Apptainer container (repeatable).
        --log-level LEVEL       debug, info, warning, error or critical (default: info).
        -h, --help              Show this help.

    Examples:
        $0 --start 1993-01-01 --end 2026-07-01 historical_res-0p25
        $0 --extend --end 2026-08-01 historical_res-0p25
EOF
}

PROJECT_ROOT=""
CONFIG_DIR=""
OUTPUT=""
LOG_DIR=""
START_DATE=""
END_DATE=""
REPLACE=false
RESUME=false
EXTEND=false
ATTEMPTS=3
RETRY_DELAY=60
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
        --output) OUTPUT="$2"; shift 2 ;;
        --output=*) OUTPUT="${1#*=}"; shift ;;
        --log-dir) LOG_DIR="$2"; shift 2 ;;
        --log-dir=*) LOG_DIR="${1#*=}"; shift ;;
        --start) START_DATE="$2"; shift 2 ;;
        --start=*) START_DATE="${1#*=}"; shift ;;
        --end) END_DATE="$2"; shift 2 ;;
        --end=*) END_DATE="${1#*=}"; shift ;;
        --replace) REPLACE=true; shift ;;
        --extend) EXTEND=true; shift ;;
        --resume) RESUME=true; shift ;;
        --attempts) ATTEMPTS="$2"; shift 2 ;;
        --attempts=*) ATTEMPTS="${1#*=}"; shift ;;
        --retry-delay) RETRY_DELAY="$2"; shift 2 ;;
        --retry-delay=*) RETRY_DELAY="${1#*=}"; shift ;;
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
if [[ -z "${END_DATE}" ]]; then
    echo "Error: give --end (the recipes have no dates)." >&2
    exit 1
fi
if [[ "${EXTEND}" == true && ( -n "${START_DATE}" || "${REPLACE}" == true ) ]]; then
    echo "Error: --extend starts the day after the output's last: not with --start nor --replace." >&2
    exit 1
fi
if [[ "${EXTEND}" == false && -z "${START_DATE}" ]]; then
    echo "Error: give --start (the recipes have no dates), or --extend an existing output." >&2
    exit 1
fi
if [[ "${REPLACE}" == true && "${RESUME}" == true ]]; then
    echo "Error: --replace starts over, --resume continues: give one of them." >&2
    exit 1
fi
if ! [[ "${ATTEMPTS}" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: --attempts takes a positive integer (got '${ATTEMPTS}')." >&2
    exit 1
fi
if ! [[ "${RETRY_DELAY}" =~ ^[0-9]+$ ]]; then
    echo "Error: --retry-delay takes a number of seconds (got '${RETRY_DELAY}')." >&2
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

# Resolve the recipe.
CONFIG_DIR="${CONFIG_DIR:-${PROJECT_ROOT}/configs/download}"
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

# Default output: <product>/res=<res>, from a recipe named <product>_res-<res>.
if [[ -z "${OUTPUT}" ]]; then
    if [[ ! "${NAME}" =~ ^([a-z0-9-]+)_res-([0-9]+p[0-9]+)$ ]]; then
        echo "Error: cannot derive the output from '${NAME}' (expected <product>_res-<res>): give --output." >&2
        exit 1
    fi
    OUTPUT="${DATA_ROOT:-${PROJECT_ROOT}}/data/${BASH_REMATCH[1]}/res=${BASH_REMATCH[2]}"
fi
if [[ "${OUTPUT}" != *://* ]]; then
    mkdir -p "$(dirname "${OUTPUT}")"
fi

LOG_DIR="${LOG_DIR:-${PROJECT_ROOT}/logs/download}"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/${NAME}_$(date -u +%Y%m%dT%H%M%SZ).log"

if [[ -n "${VENV}" ]]; then
    # The environment's own arco-make: `uv run` here would use this project's environment
    # (the tutorials'), ignoring VIRTUAL_ENV.
    if [[ ! -x "${VENV}/bin/arco-make" ]]; then
        echo "Error: no arco-make in the virtual environment '${VENV}'." >&2
        exit 1
    fi
    RUN_CMD=("${VENV}/bin/arco-make")
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

# Exit status of arco-make when a forecast run is not published yet: the runs before it are
# stored, and the next attempt extends the output (not --resume, not --start).
NOT_PUBLISHED=75

echo "Download of ${NAME} to ${OUTPUT}, log: ${LOG_FILE} (started $(date -u), PID $$, host $(hostname))"
STATUS=0
for (( attempt=1; attempt<=ATTEMPTS; attempt++ )); do
    FLAGS=(--no-progress --log-level="${LOG_LEVEL}" --end="${END_DATE}")
    MODE=()
    if [[ ${STATUS} -eq ${NOT_PUBLISHED} ]]; then
        # The runs before the one not published are stored: extend from there.
        EXTEND=true
        RESUME=false
        REPLACE=false
    fi
    if [[ "${EXTEND}" == true ]]; then
        MODE+=(--extend)
    else
        FLAGS+=(--start="${START_DATE}")
    fi
    if [[ ( ${attempt} -gt 1 && ${STATUS} -ne ${NOT_PUBLISHED} ) || "${RESUME}" == true ]]; then
        MODE+=(--resume)
    elif [[ "${REPLACE}" == true ]]; then
        MODE+=(--replace)
    fi
    echo "Run ${attempt}/${ATTEMPTS} ${MODE[*]+"${MODE[*]}"}"
    # Where this run's lines start in the log (none yet on the first run: the shell, not wc,
    # reported the missing file).
    RUN_START=0
    if [[ -f "${LOG_FILE}" ]]; then
        RUN_START=$(wc -l < "${LOG_FILE}")
    fi
    {
        echo "==== run ${attempt}/${ATTEMPTS} ${MODE[*]+"${MODE[*]}"} ($(date -u)) ===="
        "${RUN_CMD[@]}" download "${FLAGS[@]}" "${MODE[@]+"${MODE[@]}"}" -- "${CONFIG_PATH}" "${OUTPUT}"
    } >> "${LOG_FILE}" 2>&1
    STATUS=$?
    if [[ ${STATUS} -eq 0 ]]; then
        echo "Download of ${NAME} finished: ${OUTPUT} ($(date -u))."
        exit 0
    fi
    if [[ ${STATUS} -eq ${NOT_PUBLISHED} ]]; then
        echo "Run ${attempt}: a forecast run is not published yet; the runs before are stored."
    else
        echo "Run ${attempt} failed (exit code ${STATUS}): see ${LOG_FILE}."
    fi
    # A failed check of the recipe's [checks] fails again on the same data: no further attempt.
    if tail -n "+$((RUN_START + 1))" "${LOG_FILE}" | grep -q "A check of \[checks\] failed"; then
        echo "A check of the recipe failed (see the log): fix the cause, then rerun this command with --resume." >&2
        exit 1
    fi
    # Refused because an earlier run of this output failed (killed, say) and can be continued:
    # the next attempt resumes it (--resume, after the first), at once.
    if [[ ${attempt} -eq 1 ]] && tail -n "+$((RUN_START + 1))" "${LOG_FILE}" \
        | grep -q "A download run failed at .*--resume continues it"; then
        echo "Run 1: an earlier run failed and waits: resuming it."
        continue
    fi
    if [[ ${attempt} -lt ${ATTEMPTS} ]]; then
        sleep "${RETRY_DELAY}"
    fi
done
if [[ ${STATUS} -eq ${NOT_PUBLISHED} ]]; then
    echo "Download of ${NAME}: a forecast run is still not published after ${ATTEMPTS} runs; the runs before are stored, the next collection (--extend) continues." >&2
    exit "${NOT_PUBLISHED}"
fi
echo "Download of ${NAME} failed after ${ATTEMPTS} runs (see ${LOG_FILE}): rerun this command with --resume to continue, if the log shows a run waiting." >&2
exit 1
