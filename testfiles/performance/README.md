# Inkscape Performance Testing (perf + FlameGraph)

This directory provides an **additive** performance-testing framework on top of
Inkscape's existing CTest suite.  It does **not** modify or replace normal tests.

## Requirements

- Linux host with `perf` installed (`linux-tools-common` / `linux-tools-$(uname -r)`)
- A build that includes **debug symbols** (`Debug`, `RelWithDebInfo`, or `Strict`)
- Vendored FlameGraph scripts at `src/3rdparty/FlameGraph/`
- CMake option `BUILD_PERFORMANCE_TESTS=ON` (auto-suggested when debug symbols are present)

## Configure

```bash
cmake -S . -B build \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DBUILD_PERFORMANCE_TESTS=ON \
  -DPERF_TEST_ITERATIONS=5 \
  -DPERF_TEST_MAX_TIME=15 \
  -DPERF_TEST_CALL_STACK_MODE=both
cmake --build build
```

### CMake options

| Option | Default | Description |
|--------|---------|-------------|
| `BUILD_PERFORMANCE_TESTS` | OFF (ON when debug symbols present, if set before configure) | Master switch |
| `PERF_TEST_ITERATIONS` | `1` | Global default number of times each perf test runs its command inside one `perf record` session |
| `PERF_TEST_MAX_TIME` | `15` | Maximum wall time in seconds; tests exceeding this fail |
| `PERF_TEST_CALL_STACK_MODE` | `both` | `kernel`, `userspace`, or `both` |
| `PERF_TEST_REPORT_DIR` | `${CMAKE_BINARY_DIR}/performance_reports` | Where perf data and SVGs are written |
| `FLAMEGRAPH_DIR` | `src/3rdparty/FlameGraph` | Path to FlameGraph repository |
| `PERF_CLI_TESTS_EXTRA` | _(empty)_ | Extra `cli_*_build` CTest names to profile |

## Running performance tests

```bash
# All performance tests
cmake --build build --target performance_tests
# or
ctest --test-dir build -L performance --output-on-failure

# Single perf test
ctest --test-dir build -R '^perf_test_lpe$' --output-on-failure

# Override iterations / mode at configure time, then re-run
cmake -B build -DPERF_TEST_ITERATIONS=20 -DPERF_TEST_CALL_STACK_MODE=userspace
ctest --test-dir build -L performance
```

## Profiling Inkscape interactively

Configured script (in the build tree):

```bash
build/testfiles/performance/run_inkscape_perf.sh -- -V
build/testfiles/performance/run_inkscape_perf.sh --iterations 3 --call-stack-mode userspace -- \
    --actions="file-open:share/examples/car.svgz;export-do;quit-now"
```

Or via CMake target:

```bash
cmake --build build --target perf_inkscape
```

## Output layout

Reports are written under `build/performance_reports/` (configurable).  Each run
produces **unique** timestamped files so repeated profiling never overwrites prior data:

```
build/performance_reports/
  test_lpe-20260621T143015Z-12345.perf.data
  test_lpe-20260621T143015Z-12345.perf.script
  test_lpe-20260621T143015Z-12345.folded
  test_lpe-20260621T143015Z-12345.svg          # flame graph
  test_lpe-20260621T143015Z-12345.meta.txt     # run metadata
  test_lpe-latest.svg                          # symlink to most recent SVG
```

## Per-test overrides

From CMake, when registering or extending perf tests:

```cmake
add_performance_test(my-heavy-path
    COMMAND $<TARGET_FILE:inkscape> --actions="..."
    ITERATIONS 10
    MAX_TIME 60
    CALL_STACK_MODE userspace
    LABELS integration
    DEPENDS inkscape
)

add_performance_test_for_existing(test_lpe
    ITERATIONS 20
    MAX_TIME 30
)

add_unit_test_with_perf(my-unit-test TEST_SOURCE my-unit-test.cpp
    PERF_ITERATIONS 50
    PERF_CALL_STACK_MODE userspace
)
```

## Call stack modes

| Mode | `perf` events | Use when |
|------|---------------|----------|
| `kernel` | `cycles:k` + dwarf call graphs | Kernel / syscall heavy paths |
| `userspace` | `cycles:u` + dwarf call graphs | Clean application flame graphs |
| `both` | `cycles` + dwarf call graphs | Full system view (default) |

## Notes

- Performance tests are labelled `performance` plus their category (`integration`,
  `unit`, `rendering`, `cli`, `live-path-effects`).
- Very fast tests may yield sparse profiles; raise `PERF_TEST_ITERATIONS` (global)
  or pass `ITERATIONS` per test so enough CPU samples accumulate.
- Existing CTest entries (`test_*`, `cli_*`, `render_*`, unit tests) are **never**
  modified; only additional `perf_*` tests are registered.
