#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Stefano Campanella
# SPDX-License-Identifier: MIT

# scripts/install_units.sh
#
# Install the daily forecast collection as systemd user units, from this checkout: the units in
# systemd/ are linked (so a git pull changes them; then systemctl --user daemon-reload), and a
# drop-in per service gives this machine's part, the checkout and the options of forecast.sh.
# Run it again to change the options; --uninstall removes everything it installed.

usage() {
    cat <<EOF
install_units.sh
    Install (or remove) the ARCO-OCEAN forecast collection's systemd user units.

SYNOPSIS
    $0 [--keepalive] [--no-start] [-- FORECAST.SH OPTIONS...]
    $0 --uninstall

DESCRIPTION
    Options:
        --keepalive     Also install the daily keepalive of the forecast watchdog
                        (scripts/keep_watchdog_enabled.sh; needs its token file).
        --no-start      Install and enable the timers, but do not start them now.
        --uninstall     Stop and remove the units and their drop-ins.
        -h, --help      Show this help.

    The options after -- go to every collection (scripts/forecast.sh), e.g. --image FILE or
    --virtual-env DIR, and --env-file FILE; relative paths are from the checkout. They cannot
    hold spaces, quotes, backslashes or dollar signs.

    The units run only while their user is logged in, unless lingering is on (once, by root):
        sudo loginctl enable-linger \$USER
EOF
}

KEEPALIVE=false
START=true
UNINSTALL=false
OPTIONS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keepalive) KEEPALIVE=true; shift ;;
        --no-start) START=false; shift ;;
        --uninstall) UNINSTALL=true; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; OPTIONS=("$@"); break ;;
        *) echo "Error: unrecognized argument '$1' (options of forecast.sh go after --)." >&2
           usage >&2; exit 1 ;;
    esac
done

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"
FORECAST=arco-ocean-forecast
KEEPER=arco-ocean-watchdog-keepalive

# systemd expands % specifiers in unit files: a literal % is %%.
escape() {
    printf '%s' "${1//%/%%}"
}

if ${UNINSTALL}; then
    for NAME in "${FORECAST}" "${KEEPER}"; do
        systemctl --user disable --now "${NAME}.timer" 2>/dev/null || true
        for UNIT in "${NAME}.service" "${NAME}.timer"; do
            # The links into this checkout, made by systemctl --user link.
            if [[ -L "${UNIT_DIR}/${UNIT}" ]]; then rm -f "${UNIT_DIR}/${UNIT}"; fi
        done
        rm -rf "${UNIT_DIR}/${NAME}.service.d"
    done
    systemctl --user daemon-reload
    echo "Removed the units of ${FORECAST} and ${KEEPER}."
    exit 0
fi

for OPTION in "${OPTIONS[@]+"${OPTIONS[@]}"}"; do
    if [[ "${OPTION}" =~ [[:space:]\"\'\\\$] ]]; then
        echo "Error: option '${OPTION}' holds a space, a quote, a backslash or a dollar sign." >&2
        exit 1
    fi
done

NAMES=("${FORECAST}")
if ${KEEPALIVE}; then NAMES+=("${KEEPER}"); fi

mkdir -p "${UNIT_DIR}"
for NAME in "${NAMES[@]}"; do
    systemctl --user link "${ROOT}/systemd/${NAME}.service" "${ROOT}/systemd/${NAME}.timer"
    mkdir -p "${UNIT_DIR}/${NAME}.service.d"
    {
        echo "# Written by ${ROOT}/scripts/install_units.sh: this machine's part."
        echo "[Service]"
        echo "WorkingDirectory=$(escape "${ROOT}")"
        if [[ "${NAME}" == "${FORECAST}" ]]; then
            echo "Environment=\"FORECAST_OPTIONS=$(escape "${OPTIONS[*]+"${OPTIONS[*]}"}")\""
        fi
    } > "${UNIT_DIR}/${NAME}.service.d/local.conf"
done
systemctl --user daemon-reload
for NAME in "${NAMES[@]}"; do
    if ${START}; then
        systemctl --user enable --now "${NAME}.timer"
    else
        systemctl --user enable "${NAME}.timer"
    fi
done

echo "Installed: ${NAMES[*]} (systemctl --user list-timers; journalctl --user -u ${FORECAST})."
if [[ "$(loginctl show-user "${USER:-$(id -un)}" --property=Linger --value 2>/dev/null)" != "yes" ]]; then
    echo "Lingering is off: the timers run only while you are logged in. Turn it on, once:"
    echo "    sudo loginctl enable-linger ${USER:-$(id -un)}"
fi
