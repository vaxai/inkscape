#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Run Inkscape CTest suite (or a subset) under Valgrind memcheck and emit
# normalized JSONL + markdown summaries consumable by compare_leaks.py / CI.
#
# Usage:
#   ./buildtools/memleak/run_memcheck.sh --build-dir build [--label current]
#   ./buildtools/memleak/run_memcheck.sh --build-dir build --tests unit --jobs 2
#
# Environment overrides:
#   MEMLEAK_TOOL=memcheck|helgrind
#   MEMLEAK_KINDS=definite
#   MEMLEAK_MIN_BYTES=1
#   MEMLEAK_CTEST_LABELS=unit
#   MEMLEAK_CTEST_EXCLUDE_REGEX='perf_|render_'
#   MEMLEAK_TIMEOUT_PER_TEST=300
#   MEMLEAK_VALGRIND_EXTRA='--track-origins=yes'
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

BUILD_DIR=""
OUT_DIR=""
LABEL="run"
TOOL="${MEMLEAK_TOOL:-memcheck}"
KINDS="${MEMLEAK_KINDS:-definite}"
MIN_BYTES="${MEMLEAK_MIN_BYTES:-1}"
MIN_BLOCKS="${MEMLEAK_MIN_BLOCKS:-1}"
INKSCAPE_ONLY="${MEMLEAK_INKSCAPE_ONLY:-1}"
CTEST_LABELS="${MEMLEAK_CTEST_LABELS:-}"
CTEST_INCLUDE_REGEX="${MEMLEAK_CTEST_INCLUDE_REGEX:-}"
CTEST_EXCLUDE_REGEX="${MEMLEAK_CTEST_EXCLUDE_REGEX:-^perf_}"
JOBS="${MEMLEAK_JOBS:-1}"
TIMEOUT_PER_TEST="${MEMLEAK_TIMEOUT_PER_TEST:-300}"
VALGRIND_EXTRA="${MEMLEAK_VALGRIND_EXTRA:-}"
SUPP_FILE="${MEMLEAK_SUPP_FILE:-${SCRIPT_DIR}/valgrind.supp}"
DRY_LIST=0
TESTS_MODE="auto"   # auto|unit|all|list

usage() {
  cat <<EOF
Usage: $(basename "$0") --build-dir DIR [options]

Options:
  --build-dir DIR       CMake build directory (required)
  --out-dir DIR         Output directory (default: BUILD_DIR/memleak_reports/LABEL)
  --label NAME          Run label used in artifact names (default: run)
  --tool memcheck|helgrind
  --kinds LIST          Leak kinds to keep (default: definite)
  --tests auto|unit|all Select default ctest filters
  --labels LIST         CTest -L filter (comma-separated ok; converted to -L)
  --include-regex RE    CTest -R include regex
  --exclude-regex RE    CTest -E exclude regex (default: ^perf_)
  --jobs N              Parallel test runners (default: 1; valgrind prefers 1)
  --timeout SEC         Per-test timeout including valgrind overhead (default: 300)
  --min-bytes N         Ignore leaks smaller than N bytes (default: 1)
  --no-inkscape-only    Do not require an Inkscape frame in the stack
  --supp FILE           Extra/override suppression file
  --list                Only list tests that would run, then exit
  -h, --help            Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-dir) BUILD_DIR="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --tool) TOOL="$2"; shift 2 ;;
    --kinds) KINDS="$2"; shift 2 ;;
    --tests) TESTS_MODE="$2"; shift 2 ;;
    --labels) CTEST_LABELS="$2"; shift 2 ;;
    --include-regex) CTEST_INCLUDE_REGEX="$2"; shift 2 ;;
    --exclude-regex) CTEST_EXCLUDE_REGEX="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --timeout) TIMEOUT_PER_TEST="$2"; shift 2 ;;
    --min-bytes) MIN_BYTES="$2"; shift 2 ;;
    --no-inkscape-only) INKSCAPE_ONLY=0; shift ;;
    --supp) SUPP_FILE="$2"; shift 2 ;;
    --list) DRY_LIST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "${BUILD_DIR}" ]]; then
  echo "error: --build-dir is required" >&2
  exit 2
fi
BUILD_DIR="$(cd "${BUILD_DIR}" && pwd)"
if [[ ! -f "${BUILD_DIR}/CTestTestfile.cmake" && ! -f "${BUILD_DIR}/DartConfiguration.tcl" ]]; then
  echo "error: ${BUILD_DIR} does not look like a CMake build tree with tests" >&2
  exit 2
fi

if ! command -v valgrind >/dev/null 2>&1; then
  echo "error: valgrind not found in PATH" >&2
  exit 127
fi

case "${TESTS_MODE}" in
  auto)
    if [[ -z "${CTEST_LABELS}" && -z "${CTEST_INCLUDE_REGEX}" ]]; then
      # Fast default: pure unit tests (exclude integration test_* + heavy suites)
      CTEST_EXCLUDE_REGEX="${CTEST_EXCLUDE_REGEX:-^perf_|^render_|^cli_|^test_}"
      CTEST_INCLUDE_REGEX="${CTEST_INCLUDE_REGEX:-.*}"
    fi
    ;;
  unit)
    # Inkscape "unit" tests are names like colors-color-test / version-test.
    # Integration suite uses the test_* prefix and is far too heavy for Valgrind CI.
    CTEST_EXCLUDE_REGEX="^perf_|^render_|^cli_|^test_"
    CTEST_INCLUDE_REGEX=".*"
    ;;
  all)
    CTEST_EXCLUDE_REGEX="^perf_"
    CTEST_INCLUDE_REGEX=".*"
    ;;
  *) echo "error: unknown --tests mode ${TESTS_MODE}" >&2; exit 2 ;;
esac

# Optional CI cap (0 = unlimited). Keeps free-tier minutes under control.
MAX_TESTS="${MEMLEAK_MAX_TESTS:-0}"

OUT_DIR="${OUT_DIR:-${BUILD_DIR}/memleak_reports/${LABEL}}"
mkdir -p "${OUT_DIR}/logs" "${OUT_DIR}/raw"

PARSE_PY="${SCRIPT_DIR}/parse_valgrind.py"
chmod +x "${PARSE_PY}" 2>/dev/null || true

# Build valgrind command template
VG_LOG_TEMPLATE="${OUT_DIR}/raw/%q.log"
VG_COMMON=(
  valgrind
  --tool="${TOOL}"
  --error-exitcode=0
  --num-callers=30
)

if [[ "${TOOL}" == "memcheck" ]]; then
  VG_COMMON+=(
    --leak-check=full
    --show-leak-kinds=definite,indirect,possible,reachable
    --errors-for-leak-kinds=none
    --track-origins=no
    --leak-resolution=high
    --keep-debuginfo=yes
  )
  if [[ -f "${SUPP_FILE}" ]]; then
    VG_COMMON+=(--suppressions="${SUPP_FILE}")
  fi
elif [[ "${TOOL}" == "helgrind" ]]; then
  VG_COMMON+=(
    --history-level=approx
    --conflict-cache-size=1000000
  )
else
  echo "error: unsupported tool ${TOOL}" >&2
  exit 2
fi

# shellcheck disable=SC2206
if [[ -n "${VALGRIND_EXTRA}" ]]; then
  # Intentional word-split for extra flags
  EXTRA_ARR=( ${VALGRIND_EXTRA} )
  VG_COMMON+=("${EXTRA_ARR[@]}")
fi

# Compose CTest launcher. CTest expands %q to the test name in some versions;
# we use a wrapper that logs to OUT_DIR/raw/<sanitized>.log
# Persist the valgrind argv to a file the wrapper can exec without eval issues
VG_ARGV_FILE="${OUT_DIR}/vg_argv.txt"
: > "${VG_ARGV_FILE}"
for a in "${VG_COMMON[@]}"; do
  printf '%s\0' "$a" >> "${VG_ARGV_FILE}"
done

WRAPPER="${OUT_DIR}/vg_wrapper.sh"
cat > "${WRAPPER}" <<'WRAP'
#!/usr/bin/env bash
set -euo pipefail
LOG_DIR="${MEMLEAK_LOG_DIR:?}"
VG_ARGV_FILE="${MEMLEAK_VG_ARGV_FILE:?}"
TEST_CMD=("$@")
base="$(basename "${TEST_CMD[0]}")"
hash="$(printf '%s' "${TEST_CMD[*]}" | sha1sum 2>/dev/null | cut -c1-8 || printf '%s' "${TEST_CMD[*]}" | cksum | cut -d' ' -f1)"
log="${LOG_DIR}/${base}-${hash}.log"
meta="${LOG_DIR}/${base}-${hash}.meta"
{
  echo "cmd: ${TEST_CMD[*]}"
  echo "started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "${meta}"
# Rebuild valgrind argv from NUL-delimited file
VG_CMD=()
while IFS= read -r -d '' tok; do
  VG_CMD+=("$tok")
done < "${VG_ARGV_FILE}"
set +e
"${VG_CMD[@]}" --log-file="${log}" "${TEST_CMD[@]}"
rc=$?
set -e
echo "exit: ${rc}" >> "${meta}"
echo "finished: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${meta}"
# Always succeed at the launcher level; leak policy is enforced post-parse/diff
exit 0
WRAP
chmod +x "${WRAPPER}"

export MEMLEAK_LOG_DIR="${OUT_DIR}/raw"
export MEMLEAK_VG_ARGV_FILE="${VG_ARGV_FILE}"

CTEST_ARGS=(
  --test-dir "${BUILD_DIR}"
  --output-on-failure
  --timeout "${TIMEOUT_PER_TEST}"
  -j "${JOBS}"
  --schedule-random
)

if [[ -n "${CTEST_INCLUDE_REGEX}" ]]; then
  CTEST_ARGS+=(-R "${CTEST_INCLUDE_REGEX}")
fi
if [[ -n "${CTEST_EXCLUDE_REGEX}" ]]; then
  CTEST_ARGS+=(-E "${CTEST_EXCLUDE_REGEX}")
fi
if [[ -n "${CTEST_LABELS}" ]]; then
  # allow comma-separated labels -> multiple -L
  IFS=',' read -r -a labs <<< "${CTEST_LABELS}"
  for lab in "${labs[@]}"; do
    lab_trimmed="$(echo "${lab}" | xargs)"
    [[ -n "${lab_trimmed}" ]] && CTEST_ARGS+=(-L "${lab_trimmed}")
  done
fi

if [[ "${DRY_LIST}" -eq 1 ]]; then
  echo "Would run:"
  ctest "${CTEST_ARGS[@]}" -N
  exit 0
fi

echo "==> memleak run label=${LABEL} tool=${TOOL} build=${BUILD_DIR}"
echo "==> output: ${OUT_DIR}"
echo "==> filters include='${CTEST_INCLUDE_REGEX}' exclude='${CTEST_EXCLUDE_REGEX}' max_tests='${MAX_TESTS}'"
{
  echo "BUILD_DIR=${BUILD_DIR}"
  ls -la "${BUILD_DIR}/bin" 2>&1 || echo "bin/ missing under ${BUILD_DIR}"
  echo "---- find *-test / assertions-in-tests ----"
  find "${BUILD_DIR}" -type f \( -name '*-test' -o -name 'assertions-in-tests' \) 2>/dev/null | head -n 80 || true
  echo "---- valgrind ----"
  command -v valgrind
  valgrind --version || true
} | tee "${OUT_DIR}/bin_ls.txt" || true

# Smoke-test valgrind: must produce a .log or the runner cannot work on this host.
set +e
valgrind --tool=memcheck --error-exitcode=0 --log-file="${OUT_DIR}/raw/_smoke_true.log" /bin/true
smoke_rc=$?
set -e
if [[ ! -f "${OUT_DIR}/raw/_smoke_true.log" ]]; then
  echo "error: valgrind smoke test did not create a log file (rc=${smoke_rc})" >&2
  echo "       valgrind may be broken or blocked on this runner." >&2
  exit 3
fi
echo "==> valgrind smoke ok (rc=${smoke_rc})"

# Optional: capture ctest JSON for ordering/properties (commands often missing on
# modern CMake). Discovery itself does not require this to succeed.
TMP_JSON="${OUT_DIR}/ctest_tests.json"
set +e
# Discovery-only flags: avoid -j/--timeout/--schedule-random which can break --show-only
ctest --test-dir "${BUILD_DIR}" --show-only=json-v1 \
  ${CTEST_INCLUDE_REGEX:+-R "${CTEST_INCLUDE_REGEX}"} \
  ${CTEST_EXCLUDE_REGEX:+-E "${CTEST_EXCLUDE_REGEX}"} \
  > "${TMP_JSON}" 2>"${OUT_DIR}/ctest_show_only.stderr"
show_rc=$?
set -e
echo "ctest --show-only=json-v1 rc=${show_rc} bytes=$(wc -c < "${TMP_JSON}" 2>/dev/null || echo 0)" | tee "${OUT_DIR}/ctest_show_only.meta"

# Primary: Python enumerator (CTestTestfile + bin + JSON).
ENUM_PY="${SCRIPT_DIR}/enumerate_tests.py"
ran_via_enum=0
if command -v python3 >/dev/null && [[ -f "${ENUM_PY}" ]]; then
  set +e
  set -o pipefail
  python3 "${ENUM_PY}" \
    --build-dir "${BUILD_DIR}" \
    --wrapper "${WRAPPER}" \
    --out-script "${OUT_DIR}/run_all.sh" \
    --ctest-json "${TMP_JSON}" \
    --include-regex "${CTEST_INCLUDE_REGEX:-.*}" \
    --exclude-regex "${CTEST_EXCLUDE_REGEX:-}" \
    --max-tests "${MAX_TESTS}" \
    --diagnostics "${OUT_DIR}/enumerate_diagnostics.json" \
    2>"${OUT_DIR}/enumerate_stderr.txt" | tee "${OUT_DIR}/enumerate_stdout.txt"
  enum_rc=${PIPESTATUS[0]}
  set +o pipefail
  set -e
  if [[ "${enum_rc}" -eq 0 && -x "${OUT_DIR}/run_all.sh" ]]; then
    echo "==> running tests via enumerate_tests.py launcher"
    set +e
    bash "${OUT_DIR}/run_all.sh" | tee "${OUT_DIR}/run_all.stdout.txt"
    set -e
    ran_via_enum=1
  else
    echo "warning: enumeration failed (rc=${enum_rc})" | tee -a "${OUT_DIR}/enumerate_stderr.txt" >&2
    sed -n '1,80p' "${OUT_DIR}/enumerate_stderr.txt" >&2 || true
    if [[ -f "${OUT_DIR}/enumerate_diagnostics.json" ]]; then
      sed -n '1,160p' "${OUT_DIR}/enumerate_diagnostics.json" >&2 || true
    fi
  fi
else
  echo "warning: python3 or ${ENUM_PY} missing; using bash bin scan only" >&2
fi

# Secondary: pure bash scan of unit-test-like binaries (no CTest/JSON required).
# This is the failsafe that must work if unit_tests were built.
real_logs=0
for f in "${OUT_DIR}/raw"/*.log; do
  [[ -e "$f" ]] || continue
  base="$(basename "$f")"
  [[ "${base}" == _smoke_* ]] && continue
  real_logs=1
  break
done
if [[ "${real_logs}" -eq 0 ]]; then
  echo "==> bash unit-binary scan fallback (python enum ran=${ran_via_enum})"
  mapfile -t UNIT_BINS < <(
    {
      if [[ -d "${BUILD_DIR}/bin" ]]; then
        find "${BUILD_DIR}/bin" -maxdepth 1 -type f -executable 2>/dev/null
      fi
      find "${BUILD_DIR}" -type f -executable \( -name '*-test' -o -name 'assertions-in-tests' \) 2>/dev/null
    } | awk 'NF' | sort -u
  )
  run_count=0
  for exe in "${UNIT_BINS[@]:-}"; do
    [[ -n "${exe}" && -x "${exe}" ]] || continue
    base="$(basename "${exe}")"
    case "${base}" in
      inkscape|inkview|cmake|ninja|cpack|ctest) continue ;;
      test_*|perf_*|cli_*|render_*) continue ;;
    esac
    if [[ -n "${CTEST_EXCLUDE_REGEX}" ]] && [[ "${base}" =~ ${CTEST_EXCLUDE_REGEX} ]]; then
      continue
    fi
    echo ">> ${base} (${exe})"
    set +e
    "${WRAPPER}" "${exe}"
    set -e
    run_count=$((run_count + 1))
    if [[ "${MAX_TESTS}" -gt 0 && "${run_count}" -ge "${MAX_TESTS}" ]]; then
      break
    fi
  done
  echo "==> bash fallback ran ${run_count} binaries" | tee "${OUT_DIR}/bash_fallback.txt"
fi

# Count non-smoke logs
LOG_COUNT=0
for f in "${OUT_DIR}/raw"/*.log; do
  [[ -e "$f" ]] || continue
  base="$(basename "$f")"
  [[ "${base}" == _smoke_* ]] && continue
  LOG_COUNT=$((LOG_COUNT + 1))
done

if [[ "${LOG_COUNT}" -eq 0 ]]; then
  echo "error: no valgrind test logs produced (smoke log alone is not enough)" >&2
  echo "       diagnostics: ${OUT_DIR}/enumerate_diagnostics.json" >&2
  echo "       bin listing: ${OUT_DIR}/bin_ls.txt" >&2
  echo "       Ensure unit_tests (or tests) were built into ${BUILD_DIR}/bin." >&2
  # Dump quick diagnostics to stdout (shows up in Actions log / summary hooks)
  sed -n '1,200p' "${OUT_DIR}/bin_ls.txt" >&2 || true
  sed -n '1,200p' "${OUT_DIR}/enumerate_diagnostics.json" >&2 || true
  sed -n '1,80p' "${OUT_DIR}/enumerate_stderr.txt" >&2 || true
  exit 3
fi

echo "==> collected ${LOG_COUNT} valgrind test log(s) (excluding smoke)"

# Parse each log, then aggregate (skip smoke)
AGG_JSONL="${OUT_DIR}/${LABEL}.${TOOL}.jsonl"
: > "${AGG_JSONL}"
PARSE_LOGS=()
for log in "${OUT_DIR}/raw"/*.log; do
  [[ -e "${log}" ]] || continue
  tname="$(basename "${log}" .log)"
  [[ "${tname}" == _smoke_* ]] && continue
  PARSE_LOGS+=("${log}")
  part="${OUT_DIR}/logs/${tname}.jsonl"
  ink_flag=()
  if [[ "${INKSCAPE_ONLY}" == "1" ]]; then
    ink_flag+=(--inkscape-only)
  fi
  kinds_arg="${KINDS}"
  if [[ "${TOOL}" == "helgrind" ]]; then
    kinds_arg="helgrind"
  fi
  python3 "${PARSE_PY}" "${log}" \
    --test-name "${tname}" \
    --tool "${TOOL}" \
    --min-bytes "${MIN_BYTES}" \
    --min-blocks "${MIN_BLOCKS}" \
    --kinds "${kinds_arg}" \
    "${ink_flag[@]}" \
    --jsonl "${part}" \
    --summary-md "${OUT_DIR}/logs/${tname}.md" \
    --title "${tname}" >/dev/null || true
  if [[ -s "${part}" ]]; then
    cat "${part}" >> "${AGG_JSONL}"
  fi
done

python3 "${PARSE_PY}" "${PARSE_LOGS[@]}" \
  --tool "${TOOL}" \
  --min-bytes "${MIN_BYTES}" \
  --min-blocks "${MIN_BLOCKS}" \
  --kinds "$( [[ "${TOOL}" == helgrind ]] && echo helgrind || echo "${KINDS}" )" \
  $( [[ "${INKSCAPE_ONLY}" == "1" ]] && echo --inkscape-only ) \
  --jsonl "${OUT_DIR}/${LABEL}.${TOOL}.merged.jsonl" \
  --summary-md "${OUT_DIR}/${LABEL}.${TOOL}.summary.md" \
  --title "Memleak ${LABEL} (${TOOL})" | tee "${OUT_DIR}/${LABEL}.${TOOL}.parse.json"

# Prefer merged for downstream compare
cp -f "${OUT_DIR}/${LABEL}.${TOOL}.merged.jsonl" "${AGG_JSONL}"

# Manifest
cat > "${OUT_DIR}/manifest.json" <<EOF
{
  "label": "${LABEL}",
  "tool": "${TOOL}",
  "kinds": "${KINDS}",
  "min_bytes": ${MIN_BYTES},
  "inkscape_only": ${INKSCAPE_ONLY},
  "build_dir": "${BUILD_DIR}",
  "log_count": ${LOG_COUNT},
  "jsonl": "${AGG_JSONL}",
  "summary_md": "${OUT_DIR}/${LABEL}.${TOOL}.summary.md"
}
EOF

echo "==> wrote ${AGG_JSONL}"
echo "==> done"
