#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Configure a non-Flatpak CMake build that mirrors Flathub compiler flags /
# options, using the `build/` directory and the Ninja generator.  Useful when
# you want to iterate on Inkscape itself with Flathub-like settings without
# paying the full flatpak-builder cost on every change.
#
# Usage:
#   packaging/flathub/configure-flathub-cmake.sh [extra cmake args...]
#   ninja -C build
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"

mkdir -p "${BUILD_DIR}"

cmake -S "${REPO_ROOT}" -B "${BUILD_DIR}" -G Ninja \
    -DCMAKE_BUILD_TYPE=Flathub \
    -DWITH_INTERNAL_2GEOM=ON \
    -DBUILD_TESTING=OFF \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
    "$@"

echo
echo "Configured Flathub-style build in ${BUILD_DIR}"
echo "Build with:  ninja -C ${BUILD_DIR}"