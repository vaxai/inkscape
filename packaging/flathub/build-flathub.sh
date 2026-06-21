#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Build Inkscape as a Flatpak using the vendored Flathub manifest, targeting the
# local source tree.  Intended for reproducing / debugging Flathub packaging
# issues without pushing to Flathub.
#
# Usage (from the repo; prefer a Linux host/VM such as Colima for the builder):
#   packaging/flathub/build-flathub.sh [extra flatpak-builder args...]
#
# Environment:
#   FLATHUB_REPO_DIR   - Flatpak local repo (default: <repo>/build/flathub-repo)
#   FLATHUB_STATE_DIR  - flatpak-builder state/cache (default: <repo>/build/flathub-state,
#                        or ~/.cache/inkscape-flathub/state on virtiofs/9p mounts)
#   FLATHUB_BUILD_DIR  - flatpak-builder build dir (default: <repo>/build/flathub-build,
#                        or ~/.cache/inkscape-flathub/build on virtiofs/9p mounts)
#   FLATHUB_JOBS       - parallel jobs (default: nproc)
#   FLATHUB_NO_CCACHE  - set to 1 to disable ccache (saves disk on small VMs)
#   SKIP_SDK_INSTALL   - set to 1 to skip installing/updating the GNOME SDK/runtime
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MANIFEST="${SCRIPT_DIR}/org.inkscape.Inkscape.json"
APP_ID="org.inkscape.Inkscape"

BUILD_ROOT="${REPO_ROOT}/build"
FLATHUB_REPO_DIR="${FLATHUB_REPO_DIR:-${BUILD_ROOT}/flathub-repo}"
# Default build/state dirs: prefer a VM-local path when the repo is on a
# virtiofs/9p mount (Colima/Lima).  Flatpak-builder sets restrictive modes on
# installed headers; those can become unreadable through virtiofs and abort
# the build with "Permission denied".  State dir must live on the *same*
# filesystem as the build dir (flatpak-builder requirement), so both move
# together.  Override with FLATHUB_BUILD_DIR / FLATHUB_STATE_DIR if needed.
_on_virtiofs_repo=0
if mount 2>/dev/null | grep -Eq "${REPO_ROOT}.*(virtiofs|9p|fuse\.sshfs)"; then
    _on_virtiofs_repo=1
elif findmnt -T "${REPO_ROOT}" 2>/dev/null | grep -Eq 'virtiofs|9p|fuse.sshfs'; then
    _on_virtiofs_repo=1
fi
if [[ -z "${FLATHUB_BUILD_DIR:-}" ]]; then
    if [[ "${_on_virtiofs_repo}" -eq 1 ]]; then
        FLATHUB_BUILD_DIR="${HOME}/.cache/inkscape-flathub/build"
    else
        FLATHUB_BUILD_DIR="${BUILD_ROOT}/flathub-build"
    fi
fi
if [[ -z "${FLATHUB_STATE_DIR:-}" ]]; then
    if [[ "${_on_virtiofs_repo}" -eq 1 ]]; then
        FLATHUB_STATE_DIR="${HOME}/.cache/inkscape-flathub/state"
    else
        FLATHUB_STATE_DIR="${BUILD_ROOT}/flathub-state"
    fi
fi
FLATHUB_JOBS="${FLATHUB_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

RUNTIME_REMOTE="${RUNTIME_REMOTE:-flathub}"
RUNTIME_REMOTE_URL="${RUNTIME_REMOTE_URL:-https://flathub.org/repo/flathub.flatpakrepo}"

log() { printf '[flathub-build] %s\n' "$*"; }
die() { printf '[flathub-build] ERROR: %s\n' "$*" >&2; exit 1; }

command -v flatpak >/dev/null 2>&1 || die "flatpak not found; install flatpak first"
command -v flatpak-builder >/dev/null 2>&1 || die "flatpak-builder not found; install flatpak-builder first"
[[ -f "${MANIFEST}" ]] || die "manifest not found: ${MANIFEST}"

# Runtime / SDK version from the manifest (fallback to 50, matching upstream Flathub).
RUNTIME_VERSION="$(python3 -c "
import json
with open('${MANIFEST}') as f:
    print(json.load(f).get('runtime-version', '50'))
" 2>/dev/null || echo 50)"

mkdir -p "${BUILD_ROOT}" "${FLATHUB_REPO_DIR}" "${FLATHUB_STATE_DIR}"

# Drop transient build/rofiles trees from prior runs so we don't exhaust small
# VM disks (Colima default is ~20G).  Downloads + module caches are preserved.
if [[ "${FLATHUB_KEEP_TRANSIENT:-0}" != "1" ]]; then
    rm -rf "${FLATHUB_BUILD_DIR}" \
           "${FLATHUB_STATE_DIR}/build" \
           "${FLATHUB_STATE_DIR}/rofiles" 2>/dev/null || true
fi

if [[ "${SKIP_SDK_INSTALL:-0}" != "1" ]]; then
    if ! flatpak remotes --user 2>/dev/null | awk '{print $1}' | grep -qx "${RUNTIME_REMOTE}"; then
        log "Adding Flatpak remote '${RUNTIME_REMOTE}' (${RUNTIME_REMOTE_URL})"
        flatpak --user remote-add --if-not-exists "${RUNTIME_REMOTE}" "${RUNTIME_REMOTE_URL}"
    fi
    log "Installing/updating org.gnome.Platform//${RUNTIME_VERSION} and org.gnome.Sdk//${RUNTIME_VERSION}"
    flatpak --user install -y "${RUNTIME_REMOTE}" \
        "org.gnome.Platform//${RUNTIME_VERSION}" \
        "org.gnome.Sdk//${RUNTIME_VERSION}" || \
    flatpak --user install -y flathub \
        "org.gnome.Platform//${RUNTIME_VERSION}" \
        "org.gnome.Sdk//${RUNTIME_VERSION}"
fi

log "Repository root : ${REPO_ROOT}"
log "Manifest        : ${MANIFEST}"
log "Build dir       : ${FLATHUB_BUILD_DIR}"
log "State dir       : ${FLATHUB_STATE_DIR}"
log "Local repo      : ${FLATHUB_REPO_DIR}"
log "Jobs            : ${FLATHUB_JOBS}"
log "Runtime version : ${RUNTIME_VERSION}"

# flatpak-builder resolves relative source paths against the manifest directory,
# which is packaging/flathub/.  The inkscape module uses "path": "../.." which
# points at REPO_ROOT (local dir source for debugging).
#
# CMAKE_BUILD_TYPE=Flathub is set in the manifest config-opts for the inkscape
# module.  Ninja is used via the cmake-ninja buildsystem in the manifest.
EXTRA_ARGS=("$@")

# --ccache is helpful but costs disk; disable with FLATHUB_NO_CCACHE=1 on small VMs.
CCACHE_ARGS=()
if [[ "${FLATHUB_NO_CCACHE:-0}" != "1" ]]; then
    CCACHE_ARGS+=(--ccache)
fi

set -x
flatpak-builder \
    --force-clean \
    --user \
    --install-deps-from=flathub \
    --repo="${FLATHUB_REPO_DIR}" \
    --state-dir="${FLATHUB_STATE_DIR}" \
    --default-branch=local-debug \
    "${CCACHE_ARGS[@]}" \
    --jobs="${FLATHUB_JOBS}" \
    "${EXTRA_ARGS[@]}" \
    "${FLATHUB_BUILD_DIR}" \
    "${MANIFEST}"
set +x

log "Build finished.  Local Flatpak repo: ${FLATHUB_REPO_DIR}"
log "Install/run with:  ${SCRIPT_DIR}/run-flathub.sh"
log "Or manually:"
log "  flatpak --user remote-add --no-gpg-verify --if-not-exists inkscape-flathub-local ${FLATHUB_REPO_DIR}"
log "  flatpak --user install -y inkscape-flathub-local ${APP_ID}//local-debug"
log "  flatpak run ${APP_ID}//local-debug"