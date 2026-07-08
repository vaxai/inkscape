#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Build baseline (target branch) and current tree, run memcheck on both, compare.
# Intended for local use and as the core of the GitHub Action.
#
# Usage:
#   ./buildtools/memleak/run_branch_diff.sh [--target master] [--build-root /tmp/ink-memleak]
#
# The script assumes it is invoked from anywhere; it locates the repo via git.
# Current working tree / HEAD is the "current" side. Target is fetched/checked
# out into a worktree for an isolated baseline build.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "${SCRIPT_DIR}/../.." rev-parse --show-toplevel 2>/dev/null || cd "${SCRIPT_DIR}/../.." && pwd)"

TARGET_REF="${MEMLEAK_TARGET_REF:-master}"
BUILD_ROOT="${MEMLEAK_BUILD_ROOT:-${REPO_ROOT}/../inkscape-memleak-builds}"
TOOL="${MEMLEAK_TOOL:-memcheck}"
TESTS_MODE="${MEMLEAK_TESTS_MODE:-unit}"
CMAKE_BUILD_TYPE="${MEMLEAK_CMAKE_BUILD_TYPE:-RelWithDebInfo}"
JOBS="${MEMLEAK_BUILD_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)}"
RUN_JOBS="${MEMLEAK_JOBS:-1}"
SKIP_BASELINE="${MEMLEAK_SKIP_BASELINE:-0}"
SKIP_BUILD="${MEMLEAK_SKIP_BUILD:-0}"
ALLOW_GROWTH_BYTES="${MEMLEAK_ALLOW_GROWTH_BYTES:-0}"
EXTRA_CMAKE_ARGS="${MEMLEAK_CMAKE_ARGS:-}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --target REF          Target branch/commit for baseline (default: master)
  --build-root DIR      Where to place baseline/current build dirs
  --tool memcheck|helgrind
  --tests unit|all|auto
  --build-type TYPE     CMake build type (default: RelWithDebInfo)
  --jobs N              Build parallelism
  --run-jobs N          Valgrind/ctest parallelism (default: 1)
  --skip-baseline       Only run current side (reuse existing baseline artifacts if present)
  --skip-build          Assume builds already exist under build-root
  --allow-growth-bytes N  Fail if existing signature grows by more than N bytes
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET_REF="$2"; shift 2 ;;
    --build-root) BUILD_ROOT="$2"; shift 2 ;;
    --tool) TOOL="$2"; shift 2 ;;
    --tests) TESTS_MODE="$2"; shift 2 ;;
    --build-type) CMAKE_BUILD_TYPE="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --run-jobs) RUN_JOBS="$2"; shift 2 ;;
    --skip-baseline) SKIP_BASELINE=1; shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --allow-growth-bytes) ALLOW_GROWTH_BYTES="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

mkdir -p "${BUILD_ROOT}"
BUILD_ROOT="$(cd "${BUILD_ROOT}" && pwd)"
REPORT_ROOT="${BUILD_ROOT}/reports"
mkdir -p "${REPORT_ROOT}"

CURRENT_SRC="${REPO_ROOT}"
CURRENT_BUILD="${BUILD_ROOT}/build-current"
BASELINE_SRC="${BUILD_ROOT}/src-baseline"
BASELINE_BUILD="${BUILD_ROOT}/build-baseline"

configure_and_build() {
  local src="$1" bdir="$2" tag="$3"
  echo "==> [${tag}] configure ${src} -> ${bdir}"
  mkdir -p "${bdir}"
  # shellcheck disable=SC2086
  # TESTS_WITH_ASAN conflicts with Valgrind (ASan runtime must not be first in
  # the library list); always force it off for memleak builds.
  cmake -S "${src}" -B "${bdir}" -G Ninja \
    -DCMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE}" \
    -DBUILD_TESTING=ON \
    -DBUILD_SHARED_LIBS=ON \
    -DWITH_INTERNAL_2GEOM=ON \
    -DTESTS_WITH_ASAN=OFF \
    -DWITH_ASAN=OFF \
    ${EXTRA_CMAKE_ARGS}
  echo "==> [${tag}] build (jobs=${JOBS})"
  cmake --build "${bdir}" --parallel "${JOBS}" --target tests unit_tests inkscape 2>/dev/null \
    || cmake --build "${bdir}" --parallel "${JOBS}"
}

run_side() {
  local bdir="$1" label="$2" out="$3"
  echo "==> memcheck side=${label}"
  MEMLEAK_JOBS="${RUN_JOBS}" \
    "${SCRIPT_DIR}/run_memcheck.sh" \
      --build-dir "${bdir}" \
      --out-dir "${out}" \
      --label "${label}" \
      --tool "${TOOL}" \
      --tests "${TESTS_MODE}"
}

# --- baseline worktree ---
if [[ "${SKIP_BASELINE}" != "1" ]]; then
  echo "==> preparing baseline worktree for ${TARGET_REF}"
  if [[ ! -d "${BASELINE_SRC}/.git" && ! -f "${BASELINE_SRC}/CMakeLists.txt" ]]; then
    rm -rf "${BASELINE_SRC}"
    # Prefer git worktree for speed/space; fall back to clone
    if git -C "${CURRENT_SRC}" rev-parse --git-dir >/dev/null 2>&1; then
      git -C "${CURRENT_SRC}" fetch origin "${TARGET_REF}" 2>/dev/null || true
      if git -C "${CURRENT_SRC}" worktree list | grep -q "${BASELINE_SRC}"; then
        :
      else
        rm -rf "${BASELINE_SRC}"
        git -C "${CURRENT_SRC}" worktree add --force --detach "${BASELINE_SRC}" "origin/${TARGET_REF}" 2>/dev/null \
          || git -C "${CURRENT_SRC}" worktree add --force --detach "${BASELINE_SRC}" "${TARGET_REF}" 2>/dev/null \
          || {
            mkdir -p "${BASELINE_SRC}"
            git clone --depth 50 --branch "${TARGET_REF}" "${CURRENT_SRC}" "${BASELINE_SRC}" 2>/dev/null \
              || git clone --depth 50 "${CURRENT_SRC}" "${BASELINE_SRC}" && git -C "${BASELINE_SRC}" checkout "${TARGET_REF}"
          }
      fi
    fi
  fi
fi

if [[ "${SKIP_BUILD}" != "1" ]]; then
  if [[ "${SKIP_BASELINE}" != "1" ]]; then
    configure_and_build "${BASELINE_SRC}" "${BASELINE_BUILD}" "baseline"
  fi
  configure_and_build "${CURRENT_SRC}" "${CURRENT_BUILD}" "current"
fi

BASE_OUT="${REPORT_ROOT}/baseline"
CUR_OUT="${REPORT_ROOT}/current"
if [[ "${SKIP_BASELINE}" != "1" ]]; then
  run_side "${BASELINE_BUILD}" "baseline" "${BASE_OUT}"
fi
run_side "${CURRENT_BUILD}" "current" "${CUR_OUT}"

BASE_JSONL="${BASE_OUT}/baseline.${TOOL}.jsonl"
CUR_JSONL="${CUR_OUT}/current.${TOOL}.jsonl"
if [[ ! -f "${BASE_JSONL}" ]]; then
  echo "warning: baseline jsonl missing; treating baseline as empty" >&2
  mkdir -p "${BASE_OUT}"
  : > "${BASE_JSONL}"
fi

DIFF_JSON="${REPORT_ROOT}/diff.json"
DIFF_MD="${REPORT_ROOT}/diff.md"
set +e
python3 "${SCRIPT_DIR}/compare_leaks.py" \
  --baseline "${BASE_JSONL}" \
  --current "${CUR_JSONL}" \
  --baseline-label "${TARGET_REF}" \
  --current-label "HEAD" \
  --allow-growth-bytes "${ALLOW_GROWTH_BYTES}" \
  --report-md "${DIFF_MD}" \
  --report-json "${DIFF_JSON}"
rc=$?
set -e

echo "==> reports in ${REPORT_ROOT}"
echo "==> diff exit code: ${rc}"
exit "${rc}"
