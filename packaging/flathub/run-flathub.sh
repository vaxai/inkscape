#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Install (if needed) and run the locally built Flathub Flatpak of Inkscape.
#
# Usage:
#   packaging/flathub/run-flathub.sh [inkscape args...]
#
# Environment:
#   FLATHUB_REPO_DIR  - local flatpak repo (default: <repo>/build/flathub-repo)
#   FLATHUB_BRANCH    - branch to install/run (default: local-debug)
#   FLATHUB_REMOTE    - remote name (default: inkscape-flathub-local)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
APP_ID="org.inkscape.Inkscape"

FLATHUB_REPO_DIR="${FLATHUB_REPO_DIR:-${REPO_ROOT}/build/flathub-repo}"
FLATHUB_BRANCH="${FLATHUB_BRANCH:-local-debug}"
FLATHUB_REMOTE="${FLATHUB_REMOTE:-inkscape-flathub-local}"

log() { printf '[flathub-run] %s\n' "$*"; }
die() { printf '[flathub-run] ERROR: %s\n' "$*" >&2; exit 1; }

command -v flatpak >/dev/null 2>&1 || die "flatpak not found"
[[ -d "${FLATHUB_REPO_DIR}" ]] || die "local repo not found: ${FLATHUB_REPO_DIR} (run build-flathub.sh first)"

if ! flatpak remotes --user 2>/dev/null | awk '{print $1}' | grep -qx "${FLATHUB_REMOTE}"; then
    log "Adding local remote '${FLATHUB_REMOTE}' -> ${FLATHUB_REPO_DIR}"
    flatpak --user remote-add --no-gpg-verify --if-not-exists "${FLATHUB_REMOTE}" "${FLATHUB_REPO_DIR}"
else
    # Refresh metadata for an existing local remote.
    flatpak --user remote-modify --no-gpg-verify "${FLATHUB_REMOTE}" >/dev/null 2>&1 || true
fi

if ! flatpak --user info "${APP_ID}//${FLATHUB_BRANCH}" >/dev/null 2>&1; then
    log "Installing ${APP_ID}//${FLATHUB_BRANCH} from ${FLATHUB_REMOTE}"
    flatpak --user install -y "${FLATHUB_REMOTE}" "${APP_ID}//${FLATHUB_BRANCH}"
else
    log "Updating ${APP_ID}//${FLATHUB_BRANCH}"
    flatpak --user update -y "${APP_ID}//${FLATHUB_BRANCH}" || \
        flatpak --user install -y --reinstall "${FLATHUB_REMOTE}" "${APP_ID}//${FLATHUB_BRANCH}"
fi

log "Running ${APP_ID}//${FLATHUB_BRANCH}"
exec flatpak run "${APP_ID}//${FLATHUB_BRANCH}" "$@"