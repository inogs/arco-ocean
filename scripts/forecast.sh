#!/usr/bin/env bash

# scripts/forecast.sh
#
# Collect the ARCO-OCEAN forecast runs, at every resolution, with scripts/download.sh.
#
# Daily (cron), it adds the runs after each repository's last one up to today's (arco-make
# download --extend: a day missed is caught up the next time, its GLO12 values then from later
# releases, flagged). The first time, --start backfills from that day (the end of the historical
# dataset). The forecast recipes (configs/download/forecast_res-<res>.toml) keep the last five
# years of runs. A run fails while one of its sources has not published it yet (a release
# late): it is attempted again (--attempts, --retry-delay), and else caught up the next day.
# Runs of this script never overlap (a lock in the log directory): a late run makes the next
# one wait.

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
        -h, --help              Show this help.

    Other options (--image, --virtual-env, --env-file, --bind, --config-dir, --log-level) go to
    scripts/download.sh, as given. Outputs are download.sh's defaults:
    \$DATA_ROOT/data/forecast/res=<res>.

    Examples:
        $0 --start 2026-07-01                 # the first time: backfill to today's run
        $0                                    # every day, from cron (see README)
EOF
}

RESOLUTIONS="0p25,0p5,1p0"
START_DATE=""
END_DATE=""
ATTEMPTS=6
RETRY_DELAY=1800
PROJECT_ROOT=""
LOG_DIR=""
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
        --image|--virtual-env|--env-file|--bind|--config-dir|--log-level)
            PASS+=("$1" "$2"); shift 2 ;;
        --image=*|--virtual-env=*|--env-file=*|--bind=*|--config-dir=*|--log-level=*)
            PASS+=("$1"); shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Error: unrecognized argument '$1'." >&2; usage >&2; exit 1 ;;
    esac
done

PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
cd "${PROJECT_ROOT}" || exit 1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
END_DATE="${END_DATE:-$(date -u -d tomorrow +%Y-%m-%d)}"
LOG_DIR="${LOG_DIR:-${PROJECT_ROOT}/logs/forecast}"
mkdir -p "${LOG_DIR}"

# One collection at a time: cron may start the next while a late one still runs.
exec 9> "${LOG_DIR}/.forecast.lock"
if ! flock -n 9; then
    echo "Another forecast collection is running (lock ${LOG_DIR}/.forecast.lock): waiting for it."
    flock 9
fi

if [[ -n "${START_DATE}" ]]; then
    MODE=(--start "${START_DATE}")
else
    MODE=(--extend)
fi

FAILED=()
IFS=',' read -r -a RES_LIST <<< "${RESOLUTIONS}"
for RES in "${RES_LIST[@]}"; do
    echo "== forecast_res-${RES}: runs to ${END_DATE} (excluded) ($(date -u))"
    if ! "${SCRIPT_DIR}/download.sh" --project-dir "${PROJECT_ROOT}" --log-dir "${LOG_DIR}" \
        "${MODE[@]}" --end "${END_DATE}" --attempts "${ATTEMPTS}" --retry-delay "${RETRY_DELAY}" \
        "${PASS[@]+"${PASS[@]}"}" "forecast_res-${RES}"; then
        FAILED+=("${RES}")
    fi
done

if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo "Forecast collection failed at ${FAILED[*]} (see ${LOG_DIR}): the next run catches up." >&2
    exit 1
fi
echo "Forecast collection done ($(date -u))."
