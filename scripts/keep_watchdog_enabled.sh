#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Stefano Campanella
# SPDX-License-Identifier: MIT

# scripts/keep_watchdog_enabled.sh
#
# Keep the forecast watchdog's schedule enabled. GitHub disables the scheduled workflows of a
# public repository after 60 days without activity (a warning by email first): this script,
# run daily from the machine that collects (systemd/arco-ocean-watchdog-keepalive.timer),
# enables the watchdog again if GitHub disabled it for inactivity, and otherwise asks GitHub to
# enable it anyway, which, as reported by tools that do the same (not documented by GitHub), also
# resets the count of days. A workflow disabled by hand is left disabled.
#
# It needs gh (GitHub CLI) and a token in a file only its owner can read: a fine-grained personal
# access token for the repository alone, with the permission "Actions: Read and write".

usage() {
    cat <<EOF
keep_watchdog_enabled.sh
    Enable the forecast watchdog's schedule again if GitHub disabled it for inactivity.

SYNOPSIS
    $0 [options]

DESCRIPTION
    Options:
        --repo OWNER/REPO    The repository (default: inogs/arco-ocean).
        --workflow FILE      The workflow (default: forecast-watchdog.yml).
        --token-file FILE    The token (default: \${XDG_CONFIG_HOME:-~/.config}/arco-ocean/github-token);
                             it must not be readable by group or others.
        -h, --help           Show this help.
EOF
}

REPO="inogs/arco-ocean"
WORKFLOW="forecast-watchdog.yml"
TOKEN_FILE="${XDG_CONFIG_HOME:-${HOME}/.config}/arco-ocean/github-token"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) REPO="$2"; shift 2 ;;
        --repo=*) REPO="${1#*=}"; shift ;;
        --workflow) WORKFLOW="$2"; shift 2 ;;
        --workflow=*) WORKFLOW="${1#*=}"; shift ;;
        --token-file) TOKEN_FILE="$2"; shift 2 ;;
        --token-file=*) TOKEN_FILE="${1#*=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Error: unrecognized argument '$1'." >&2; usage >&2; exit 1 ;;
    esac
done

set -euo pipefail

if ! command -v gh >/dev/null 2>&1; then
    echo "Error: gh (GitHub CLI) is needed." >&2
    exit 1
fi
if [[ ! -f "${TOKEN_FILE}" ]]; then
    echo "Error: no token file '${TOKEN_FILE}'." >&2
    exit 1
fi
if [[ "$(stat -c %a "${TOKEN_FILE}")" != [4567]00 ]]; then
    echo "Error: '${TOKEN_FILE}' is readable by others: chmod 600 it." >&2
    exit 1
fi

# The token goes to gh in its environment only, never on a command line.
api() {
    GH_TOKEN="$(< "${TOKEN_FILE}")" gh api "$@"
}

ENDPOINT="repos/${REPO}/actions/workflows/${WORKFLOW}"
STATE="$(api "${ENDPOINT}" --jq .state)"
case "${STATE}" in
    active)
        api --method PUT "${ENDPOINT}/enable" >/dev/null
        echo "${REPO} ${WORKFLOW}: active (enabled again, to reset the count of days)."
        ;;
    disabled_inactivity)
        api --method PUT "${ENDPOINT}/enable" >/dev/null
        echo "${REPO} ${WORKFLOW}: was disabled for inactivity, enabled again."
        ;;
    disabled_manually)
        echo "${REPO} ${WORKFLOW}: disabled by hand, left disabled."
        ;;
    *)
        echo "Error: ${REPO} ${WORKFLOW} is '${STATE}': not enabled by this script." >&2
        exit 1
        ;;
esac
