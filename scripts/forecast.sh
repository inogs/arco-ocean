#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Stefano Campanella
# SPDX-License-Identifier: MIT

# scripts/forecast.sh
#
# Collect the ARCO-OCEAN forecast runs, at every resolution, with scripts/download.sh.
#
# Daily (systemd/arco-ocean-forecast.timer), it adds the runs after each repository's last one
# up to today's (arco-make download --extend: a day missed is caught up the next time, its GLO12
# values then from later
# releases, flagged). The first time, --start backfills from that day (the end of the historical
# dataset). The forecast recipes (configs/download/forecast_res-<res>.toml) keep the last five
# years of runs. A run fails while one of its sources has not published it yet (a release
# late): it is attempted again (--attempts, --retry-delay), and else caught up the next day.
# Runs of this script never overlap (a lock in the log directory): a late run makes the next
# one wait. With --status-url, the collection publishes a heartbeat, a JSON document the
# ARCO-OCEAN web page reads (scripts/forecast_status.py): its state, each resolution's, the newest
# run stored, updated every few minutes while it runs.

usage() {
    cat <<EOF
forecast.sh
    Add the forecast runs up to today's to the ARCO-OCEAN forecast repositories.

SYNOPSIS
    $0 [options]
    $0 --help

DESCRIPTION
    Options:
        --res LIST              Resolutions, comma-separated (default: 0p25,0p5,1p0).
        --start DATE            Backfill from this run (YYYY-MM-DD) into new repositories, instead
                                of extending existing ones (the first time).
        --end DATE              The day after the last run (default: tomorrow, UTC: today's run).
        --attempts N            Runs per resolution, the later ones resuming (default: 6).
        --retry-delay SECONDS   Wait between them (default: 1800: a late release).
        --project-dir DIR       Project root directory (default: current working directory).
        --log-dir DIR           Where the logs go (default: \${PROJECT_ROOT}/logs/forecast).
        --status-url URL        Publish the heartbeat there: an s3:// URL (through arco-make's
                                AWS profile) or a local path (default: none, no heartbeat).
        --heartbeat SECONDS     Between heartbeats while the collection runs (default: 300).
        --missing-after DAYS    Published with the heartbeat: the recipes' [forecast]
                                missing_after; the page calls the collection stale when a
                                resolution's newest run is older, or has waited longer for its
                                sources (default: 2).
        --stale-after HOURS     Published with the heartbeat: the page calls the collection
                                stale when none finished for that long (default: 30).
        -h, --help              Show this help.

    Other options (--image, --virtual-env, --env-file, --bind, --config-dir, --log-level) go to
    scripts/download.sh, as given. Outputs are download.sh's defaults:
    \$DATA_ROOT/data/forecast/res=<res>.

    Examples:
        $0 --start 2026-07-01                 # the first time: backfill to today's run
        $0                                    # every day, from systemd (see README)
        $0 --status-url s3://BUCKET/status/forecast.json   # with the web page's heartbeat
EOF
}

RESOLUTIONS="0p25,0p5,1p0"
START_DATE=""
END_DATE=""
ATTEMPTS=6
RETRY_DELAY=1800
PROJECT_ROOT=""
LOG_DIR=""
STATUS_URL=""
HEARTBEAT=300
STALE_AFTER=30
MISSING_AFTER=2
IMAGE="oras://ghcr.io/stefanocampanella/arco-make:latest"
VENV=""
ENV_FILE="scripts/.env"
BINDS=()
PASS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --res) RESOLUTIONS="$2"; shift 2 ;;
        --res=*) RESOLUTIONS="${1#*=}"; shift ;;
        --start) START_DATE="$2"; shift 2 ;;
        --start=*) START_DATE="${1#*=}"; shift ;;
        --end) END_DATE="$2"; shift 2 ;;
        --end=*) END_DATE="${1#*=}"; shift ;;
        --attempts) ATTEMPTS="$2"; shift 2 ;;
        --attempts=*) ATTEMPTS="${1#*=}"; shift ;;
        --retry-delay) RETRY_DELAY="$2"; shift 2 ;;
        --retry-delay=*) RETRY_DELAY="${1#*=}"; shift ;;
        --project-dir) PROJECT_ROOT="$2"; shift 2 ;;
        --project-dir=*) PROJECT_ROOT="${1#*=}"; shift ;;
        --log-dir) LOG_DIR="$2"; shift 2 ;;
        --log-dir=*) LOG_DIR="${1#*=}"; shift ;;
        --status-url) STATUS_URL="$2"; shift 2 ;;
        --status-url=*) STATUS_URL="${1#*=}"; shift ;;
        --heartbeat) HEARTBEAT="$2"; shift 2 ;;
        --heartbeat=*) HEARTBEAT="${1#*=}"; shift ;;
        --missing-after) MISSING_AFTER="$2"; shift 2 ;;
        --missing-after=*) MISSING_AFTER="${1#*=}"; shift ;;
        --stale-after) STALE_AFTER="$2"; shift 2 ;;
        --stale-after=*) STALE_AFTER="${1#*=}"; shift ;;
        # Given to download.sh; the heartbeat runs in the same environment, with the same paths.
        --image) IMAGE="$2"; PASS+=("$1" "$2"); shift 2 ;;
        --image=*) IMAGE="${1#*=}"; PASS+=("$1"); shift ;;
        --virtual-env) VENV="$2"; PASS+=("$1" "$2"); shift 2 ;;
        --virtual-env=*) VENV="${1#*=}"; PASS+=("$1"); shift ;;
        --env-file) ENV_FILE="$2"; PASS+=("$1" "$2"); shift 2 ;;
        --env-file=*) ENV_FILE="${1#*=}"; PASS+=("$1"); shift ;;
        --bind) BINDS+=("$2"); PASS+=("$1" "$2"); shift 2 ;;
        --bind=*) BINDS+=("${1#*=}"); PASS+=("$1"); shift ;;
        --config-dir|--log-level)
            PASS+=("$1" "$2"); shift 2 ;;
        --config-dir=*|--log-level=*)
            PASS+=("$1"); shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Error: unrecognized argument '$1'." >&2; usage >&2; exit 1 ;;
    esac
done

if ! [[ "${HEARTBEAT}" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: --heartbeat takes a positive number of seconds (got '${HEARTBEAT}')." >&2
    exit 1
fi
if ! [[ "${MISSING_AFTER}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "Error: --missing-after takes a number of days (got '${MISSING_AFTER}')." >&2
    exit 1
fi
if ! [[ "${STALE_AFTER}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "Error: --stale-after takes a number of hours (got '${STALE_AFTER}')." >&2
    exit 1
fi

PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
cd "${PROJECT_ROOT}" || exit 1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
END_DATE="${END_DATE:-$(date -u -d tomorrow +%Y-%m-%d)}"
LOG_DIR="${LOG_DIR:-${PROJECT_ROOT}/logs/forecast}"
mkdir -p "${LOG_DIR}"

# One collection at a time: a collection by hand may meet the daily one.
exec 9> "${LOG_DIR}/.forecast.lock"
if ! flock -n 9; then
    echo "Another forecast collection is running (lock ${LOG_DIR}/.forecast.lock): waiting for it."
    flock 9
fi

# The heartbeat (--status-url): scripts/forecast_status.py, run by the Python of the arco-make
# that downloads, reads the repositories where scripts/download.sh writes them.
STATUS_FILE="${LOG_DIR}/status.json"
HEARTBEAT_PID=""
ENDED=false
if [[ -n "${STATUS_URL}" ]]; then
    if [[ -n "${ENV_FILE}" && -f "${ENV_FILE}" ]]; then
        # shellcheck source=/dev/null
        source "${ENV_FILE}"
    fi
    if [[ -n "${VENV}" ]]; then
        STATUS_PY=("${VENV}/bin/python")
    else
        APPTAINER_FLAGS=()
        for BIND in "${BINDS[@]+"${BINDS[@]}"}"; do
            APPTAINER_FLAGS+=(--bind "${BIND}")
        done
        STATUS_PY=(apptainer exec "${APPTAINER_FLAGS[@]+"${APPTAINER_FLAGS[@]}"}" "${IMAGE}" python)
    fi
fi

# Update the heartbeat (no-op without --status-url). It never stops the collection: a failure is
# logged in the log directory's status.log.
status() {
    [[ -n "${STATUS_URL}" ]] || return 0
    if ! "${STATUS_PY[@]}" -I "${SCRIPT_DIR}/forecast_status.py" --state-file "${STATUS_FILE}" \
        --publish "${STATUS_URL}" "$@" >> "${LOG_DIR}/status.log" 2>&1; then
        echo "Warning: the heartbeat ($1) could not be published: see ${LOG_DIR}/status.log." >&2
    fi
}

# Whatever ends the script (an error, a signal it can trap), the heartbeat says so: a collection
# that ends without ending its heartbeat was aborted. One killed outright stops beating, and the
# page calls it stale.
on_exit() {
    local code=$?
    if [[ -n "${HEARTBEAT_PID}" ]]; then
        kill "${HEARTBEAT_PID}" 2>/dev/null
    fi
    if [[ "${ENDED}" == false && -n "${HEARTBEAT_PID}" ]]; then
        status end aborted --detail "The collection stopped unexpectedly (exit status ${code})."
    fi
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -n "${STATUS_URL}" ]]; then
    REPOS=()
    IFS=',' read -r -a RES_LIST <<< "${RESOLUTIONS}"
    for RES in "${RES_LIST[@]}"; do
        # scripts/download.sh's default output for the recipe forecast_res-<res>.
        REPOS+=(--repo "${RES}=${DATA_ROOT:-${PROJECT_ROOT}}/data/forecast/res=${RES}")
    done
    status start --target-run "$(date -u -d "${END_DATE} - 1 day" +%Y-%m-%d)" \
        --heartbeat-seconds "${HEARTBEAT}" --stale-after-hours "${STALE_AFTER}" \
        --missing-after-days "${MISSING_AFTER}" "${REPOS[@]}"
    # The beat, until the collection ends. Stopped, it stops its sleep too (else left behind with
    # the script's output open); it does not hold the collection's lock.
    (
        exec 9>&-
        SLEEP_PID=""
        trap 'kill "${SLEEP_PID}" 2>/dev/null; exit 0' TERM
        while true; do
            sleep "${HEARTBEAT}" &
            SLEEP_PID=$!
            wait "${SLEEP_PID}"
            status beat
        done
    ) &
    HEARTBEAT_PID=$!
fi

if [[ -n "${START_DATE}" ]]; then
    MODE=(--start "${START_DATE}")
else
    MODE=(--extend)
fi

# Exit status of scripts/download.sh when a source has not published a run yet (the runs before
# it are stored).
NOT_PUBLISHED=75
FAILED=()
WAITING=()
IFS=',' read -r -a RES_LIST <<< "${RESOLUTIONS}"
for RES in "${RES_LIST[@]}"; do
    echo "== forecast_res-${RES}: runs to ${END_DATE} (excluded) ($(date -u))"
    status res "${RES}" downloading
    CODE=0
    "${SCRIPT_DIR}/download.sh" --project-dir "${PROJECT_ROOT}" --log-dir "${LOG_DIR}" \
        "${MODE[@]}" --end "${END_DATE}" --attempts "${ATTEMPTS}" --retry-delay "${RETRY_DELAY}" \
        "${PASS[@]+"${PASS[@]}"}" "forecast_res-${RES}" || CODE=$?
    if [[ ${CODE} -eq 0 ]]; then
        status res "${RES}" finished
    elif [[ ${CODE} -eq ${NOT_PUBLISHED} ]]; then
        WAITING+=("${RES}")
        status res "${RES}" not_published
    else
        FAILED+=("${RES}")
        status res "${RES}" failed
    fi
done

ENDED=true
if [[ ${#FAILED[@]} -gt 0 ]]; then
    status end aborted --detail "The download failed at ${FAILED[*]}: the next collection resumes it."
    echo "Forecast collection failed at ${FAILED[*]} (see ${LOG_DIR}): the next run catches up." >&2
    exit 1
fi
if [[ ${#WAITING[@]} -gt 0 ]]; then
    status end finished --detail "A source has not published the newest run yet (${WAITING[*]}): the next collection adds it."
    echo "Forecast collection: the newest run is not published yet at ${WAITING[*]}; the next run catches up." >&2
    # Not a failure (the unit counts it a success), but not every run stored: 75, as download.sh.
    exit 75
fi
status end finished
echo "Forecast collection done ($(date -u))."
