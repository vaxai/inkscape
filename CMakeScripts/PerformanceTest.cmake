# SPDX-License-Identifier: GPL-2.0-or-later
#
# Performance testing framework using Linux perf and FlameGraph.
#
# Enabled only when:
#   - BUILD_PERFORMANCE_TESTS is ON (or auto-enabled with debug symbols)
#   - CMAKE_BUILD_TYPE includes debug symbols (Debug, RelWithDebInfo, Strict)
#   - perf is available on the host
#
# Reports are written under ${CMAKE_BINARY_DIR}/performance_reports/
#
# Global CMake variables (cache):
#   BUILD_PERFORMANCE_TESTS          - master switch
#   PERF_TEST_ITERATIONS             - default repeat count for all perf tests
#   PERF_TEST_MAX_TIME               - maximum wall time in seconds (default 15)
#   PERF_TEST_CALL_STACK_MODE        - kernel | userspace | both (default both)
#   PERF_TEST_REPORT_DIR             - output directory for reports
#
# Per-test overrides (set on CTest properties via add_performance_test / helpers):
#   PERF_ITERATIONS                  - override PERF_TEST_ITERATIONS for one test
#   PERF_MAX_TIME                    - override PERF_TEST_MAX_TIME for one test
#   PERF_CALL_STACK_MODE             - override PERF_TEST_CALL_STACK_MODE for one test

# -----------------------------------------------------------------------------
# Build-type / debug-symbol gate
# -----------------------------------------------------------------------------
set(_INKSCAPE_BUILD_TYPES_WITH_DEBUG_SYMBOLS "Debug" "RelWithDebInfo" "Strict")
string(TOUPPER "${CMAKE_BUILD_TYPE}" _INKSCAPE_BUILD_TYPE_UPPER)

set(INKSCAPE_HAS_DEBUG_SYMBOLS OFF)
if(CMAKE_BUILD_TYPE IN_LIST _INKSCAPE_BUILD_TYPES_WITH_DEBUG_SYMBOLS)
    set(INKSCAPE_HAS_DEBUG_SYMBOLS ON)
elseif(_INKSCAPE_BUILD_TYPE_UPPER MATCHES "DEBUG" OR
       CMAKE_CXX_FLAGS_${_INKSCAPE_BUILD_TYPE_UPPER} MATCHES "-g")
    set(INKSCAPE_HAS_DEBUG_SYMBOLS ON)
endif()

# -----------------------------------------------------------------------------
# Options (BUILD_PERFORMANCE_TESTS may already exist as an option() from the
# top-level CMakeLists.txt; we only refine dependent cache variables here.)
# -----------------------------------------------------------------------------
if(NOT DEFINED BUILD_PERFORMANCE_TESTS)
    option(BUILD_PERFORMANCE_TESTS
        "Enable perf/FlameGraph performance tests (requires debug symbols and Linux perf)"
        OFF)
endif()

# If the user left BUILD_PERFORMANCE_TESTS at its default OFF but the build
# clearly has debug symbols, emit a one-time status hint (do not force ON so
# existing caches / CI Release builds stay undisturbed).
if(NOT BUILD_PERFORMANCE_TESTS AND INKSCAPE_HAS_DEBUG_SYMBOLS)
    message(STATUS
        "Debug symbols present (${CMAKE_BUILD_TYPE}); enable performance tests with "
        "-DBUILD_PERFORMANCE_TESTS=ON")
endif()

set(PERF_TEST_ITERATIONS "1" CACHE STRING
    "Default number of times to execute each performance test (helps capture data for fast tests)")
set(PERF_TEST_MAX_TIME "15" CACHE STRING
    "Maximum wall-clock time in seconds allowed for perf record / the workload before it fails (flame-graph post-processing is not counted)")
set(PERF_TEST_POSTPROCESS_TIME "300" CACHE STRING
    "Extra seconds allowed by CTest beyond PERF_TEST_MAX_TIME for perf script + FlameGraph generation")
set(PERF_TEST_CALL_STACK_MODE "both" CACHE STRING
    "Call stack capture mode for perf: kernel, userspace, or both")
set_property(CACHE PERF_TEST_CALL_STACK_MODE PROPERTY STRINGS kernel userspace both)

set(PERF_TEST_REPORT_DIR "${CMAKE_BINARY_DIR}/performance_reports" CACHE PATH
    "Directory under the build tree where performance reports and flame graphs are written")

# Paths to FlameGraph tooling (vendored under src/3rdparty/FlameGraph)
set(FLAMEGRAPH_DIR "${CMAKE_SOURCE_DIR}/src/3rdparty/FlameGraph" CACHE PATH
    "Path to the FlameGraph repository")
set(FLAMEGRAPH_SCRIPT "${FLAMEGRAPH_DIR}/flamegraph.pl")
set(STACKCOLLAPSE_PERF_SCRIPT "${FLAMEGRAPH_DIR}/stackcollapse-perf.pl")

# Runner scripts (configured into the build tree so they pick up absolute paths)
set(PERF_RUN_TEST_SCRIPT_IN "${CMAKE_SOURCE_DIR}/testfiles/performance/run_perf_test.sh.in")
set(PERF_RUN_INKSCAPE_SCRIPT_IN "${CMAKE_SOURCE_DIR}/testfiles/performance/run_inkscape_perf.sh.in")
set(PERF_RUN_TEST_SCRIPT "${CMAKE_BINARY_DIR}/testfiles/performance/run_perf_test.sh")
set(PERF_RUN_INKSCAPE_SCRIPT "${CMAKE_BINARY_DIR}/testfiles/performance/run_inkscape_perf.sh")

# -----------------------------------------------------------------------------
# Availability checks
# -----------------------------------------------------------------------------
set(INKSCAPE_PERFORMANCE_TESTS_AVAILABLE OFF)
set(_PERF_DISABLE_REASON "")

if(NOT BUILD_PERFORMANCE_TESTS)
    set(_PERF_DISABLE_REASON "BUILD_PERFORMANCE_TESTS is OFF")
elseif(NOT INKSCAPE_HAS_DEBUG_SYMBOLS)
    set(_PERF_DISABLE_REASON
        "build type '${CMAKE_BUILD_TYPE}' does not include debug symbols (use Debug, RelWithDebInfo, or Strict)")
    message(WARNING
        "BUILD_PERFORMANCE_TESTS=ON but build type '${CMAKE_BUILD_TYPE}' lacks debug symbols; "
        "performance tests disabled. Reconfigure with -DCMAKE_BUILD_TYPE=RelWithDebInfo or Debug.")
elseif(NOT EXISTS "${FLAMEGRAPH_SCRIPT}" OR NOT EXISTS "${STACKCOLLAPSE_PERF_SCRIPT}")
    set(_PERF_DISABLE_REASON
        "FlameGraph scripts not found under ${FLAMEGRAPH_DIR}")
elseif(NOT CMAKE_SYSTEM_NAME STREQUAL "Linux")
    set(_PERF_DISABLE_REASON "perf is only available on Linux (current: ${CMAKE_SYSTEM_NAME})")
else()
    find_program(PERF_EXECUTABLE perf DOC "Linux perf profiler")
    if(NOT PERF_EXECUTABLE)
        set(_PERF_DISABLE_REASON "perf executable not found in PATH")
    else()
        set(INKSCAPE_PERFORMANCE_TESTS_AVAILABLE ON)
    endif()
endif()

if(BUILD_PERFORMANCE_TESTS AND NOT INKSCAPE_PERFORMANCE_TESTS_AVAILABLE)
    message(STATUS "Performance tests requested but unavailable: ${_PERF_DISABLE_REASON}")
endif()

# -----------------------------------------------------------------------------
# Configure runner scripts and report directory
# -----------------------------------------------------------------------------
if(INKSCAPE_PERFORMANCE_TESTS_AVAILABLE)
    file(MAKE_DIRECTORY "${PERF_TEST_REPORT_DIR}")
    file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/testfiles/performance")

    configure_file(
        "${PERF_RUN_TEST_SCRIPT_IN}"
        "${PERF_RUN_TEST_SCRIPT}"
        @ONLY
    )
    configure_file(
        "${PERF_RUN_INKSCAPE_SCRIPT_IN}"
        "${PERF_RUN_INKSCAPE_SCRIPT}"
        @ONLY
    )

    # Make configured scripts executable at configure time
    file(CHMOD "${PERF_RUN_TEST_SCRIPT}" PERMISSIONS
        OWNER_READ OWNER_WRITE OWNER_EXECUTE
        GROUP_READ GROUP_EXECUTE
        WORLD_READ WORLD_EXECUTE)
    file(CHMOD "${PERF_RUN_INKSCAPE_SCRIPT}" PERMISSIONS
        OWNER_READ OWNER_WRITE OWNER_EXECUTE
        GROUP_READ GROUP_EXECUTE
        WORLD_READ WORLD_EXECUTE)

    # Create the aggregator target early so add_performance_test() / DEPENDS can
    # attach build deps during testfiles/performance/CMakeLists.txt processing.
    # inkscape_performance_finalize() later wires inkscape/tests/unit_tests and
    # the perf_inkscape helper once those targets definitely exist.
    if(NOT TARGET performance_tests)
        # NOTE: test executables live under EXCLUDE_FROM_ALL (tests / unit_tests).
        # Running `ctest -L performance` alone does not build them; use
        # `cmake --build <build> --target performance_tests` or build
        # tests/unit_tests/inkscape first.
        add_custom_target(performance_tests
            COMMAND ${CMAKE_CTEST_COMMAND}
                --output-on-failure
                -L "performance"
            WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
            COMMENT "Running performance tests (perf + FlameGraph); ensure tests/unit_tests/inkscape are built first"
            USES_TERMINAL
        )
    endif()
    set(INKSCAPE_PERFORMANCE_NEEDS_FINALIZE ON)

    message(STATUS "Performance testing enabled:")
    message(STATUS "  perf:            ${PERF_EXECUTABLE}")
    message(STATUS "  FlameGraph dir:  ${FLAMEGRAPH_DIR}")
    message(STATUS "  report dir:      ${PERF_TEST_REPORT_DIR}")
    message(STATUS "  iterations:      ${PERF_TEST_ITERATIONS}")
    message(STATUS "  max time (s):    ${PERF_TEST_MAX_TIME}")
    message(STATUS "  call stacks:     ${PERF_TEST_CALL_STACK_MODE}")
    message(STATUS "  runner:          ${PERF_RUN_TEST_SCRIPT}")
    message(STATUS "  inkscape runner: ${PERF_RUN_INKSCAPE_SCRIPT}")
else()
    set(INKSCAPE_PERFORMANCE_NEEDS_FINALIZE OFF)
endif()

# -----------------------------------------------------------------------------
# Finalize: attach build deps that may not have existed at include time, and
# create perf_inkscape once the inkscape target is known.  Call from
# testfiles/CMakeLists.txt after tests/unit_tests exist.
# -----------------------------------------------------------------------------
function(inkscape_performance_finalize)
    if(NOT INKSCAPE_PERFORMANCE_TESTS_AVAILABLE)
        return()
    endif()

    if(NOT TARGET performance_tests)
        add_custom_target(performance_tests
            COMMAND ${CMAKE_CTEST_COMMAND}
                --output-on-failure
                -L "performance"
            WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
            COMMENT "Running performance tests (perf + FlameGraph)"
            USES_TERMINAL
        )
    endif()

    if(TARGET inkscape)
        add_dependencies(performance_tests inkscape)
    endif()
    if(TARGET tests)
        add_dependencies(performance_tests tests)
    endif()
    if(TARGET unit_tests)
        add_dependencies(performance_tests unit_tests)
    endif()

    if(TARGET inkscape AND NOT TARGET perf_inkscape)
        add_custom_target(perf_inkscape
            COMMAND ${PERF_RUN_INKSCAPE_SCRIPT}
                --report-dir "${PERF_TEST_REPORT_DIR}"
                --call-stack-mode "${PERF_TEST_CALL_STACK_MODE}"
                --max-time "${PERF_TEST_MAX_TIME}"
                --inkscape "$<TARGET_FILE:inkscape>"
            WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
            COMMENT "Run Inkscape under perf and generate a flame graph"
            USES_TERMINAL
        )
        add_dependencies(perf_inkscape inkscape)
    endif()
endfunction()

# -----------------------------------------------------------------------------
# Helper: map PERF_TEST_CALL_STACK_MODE to perf record flags
# -----------------------------------------------------------------------------
function(_perf_call_stack_flags mode out_var)
    if(mode STREQUAL "kernel")
        set(${out_var} "--call-graph=dwarf" "-e" "cycles:k" PARENT_SCOPE)
    elseif(mode STREQUAL "userspace")
        set(${out_var} "--call-graph=dwarf" "-e" "cycles:u" PARENT_SCOPE)
    else()
        # both (default)
        set(${out_var} "--call-graph=dwarf" "-e" "cycles" PARENT_SCOPE)
    endif()
endfunction()

# -----------------------------------------------------------------------------
# add_performance_test(<name>
#     COMMAND <cmd> [args...]
#     [ITERATIONS <n>]
#     [MAX_TIME <seconds>]
#     [CALL_STACK_MODE kernel|userspace|both]
#     [LABELS <label1> ...]
#     [WORKING_DIRECTORY <dir>]
#     [ENVIRONMENT <var=val> ...]
#     [DEPENDS <target1> ...]
# )
#
# Registers a CTest named perf_<name> that runs COMMAND under perf, repeats
# it ITERATIONS times, and writes a timestamped flame graph SVG so repeated
# runs never overwrite earlier reports.
# -----------------------------------------------------------------------------
function(add_performance_test perf_name)
    if(NOT INKSCAPE_PERFORMANCE_TESTS_AVAILABLE)
        return()
    endif()

    set(options "")
    set(oneValueArgs ITERATIONS MAX_TIME CALL_STACK_MODE WORKING_DIRECTORY)
    set(multiValueArgs COMMAND LABELS ENVIRONMENT DEPENDS)
    cmake_parse_arguments(ARG "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

    if(NOT ARG_COMMAND)
        message(FATAL_ERROR "add_performance_test(${perf_name}): COMMAND is required")
    endif()

    if(ARG_ITERATIONS)
        set(_iterations "${ARG_ITERATIONS}")
    else()
        set(_iterations "${PERF_TEST_ITERATIONS}")
    endif()

    if(ARG_MAX_TIME)
        set(_max_time "${ARG_MAX_TIME}")
    else()
        set(_max_time "${PERF_TEST_MAX_TIME}")
    endif()

    if(ARG_CALL_STACK_MODE)
        set(_call_stack_mode "${ARG_CALL_STACK_MODE}")
    else()
        set(_call_stack_mode "${PERF_TEST_CALL_STACK_MODE}")
    endif()

    if(ARG_WORKING_DIRECTORY)
        set(_workdir "${ARG_WORKING_DIRECTORY}")
    else()
        set(_workdir "${CMAKE_BINARY_DIR}")
    endif()

    # Sanitize name for use in filenames (replace non-alnum with underscore)
    string(REGEX REPLACE "[^A-Za-z0-9_.-]" "_" _safe_name "${perf_name}")

    set(_ctest_name "perf_${_safe_name}")

    set(_labels performance)
    if(ARG_LABELS)
        list(APPEND _labels ${ARG_LABELS})
    endif()

    # PERF_TEST_MAX_TIME limits only the measured workload (perf record).
    # CTest TIMEOUT must also cover perf script + stackcollapse + flamegraph.pl,
    # which can exceed the workload limit on slow/low-RAM VMs.
    math(EXPR _ctest_timeout "${_max_time} + ${PERF_TEST_POSTPROCESS_TIME}")

    # Idempotent: if this perf test was already registered (e.g. integration + LPE
    # both mention the same binary), only append extra labels.
    if(TEST ${_ctest_name})
        set_property(TEST ${_ctest_name} APPEND PROPERTY LABELS ${_labels})
        return()
    endif()

    # Build the perf runner invocation. The runner handles:
    #   - perf record / perf script
    #   - stackcollapse-perf.pl + flamegraph.pl
    #   - unique timestamped output filenames
    #   - iteration loop and max-time enforcement
    add_test(
        NAME ${_ctest_name}
        COMMAND bash "${PERF_RUN_TEST_SCRIPT}"
            --test-name "${_safe_name}"
            --report-dir "${PERF_TEST_REPORT_DIR}"
            --iterations "${_iterations}"
            --max-time "${_max_time}"
            --call-stack-mode "${_call_stack_mode}"
            --workdir "${_workdir}"
            --
            ${ARG_COMMAND}
        WORKING_DIRECTORY "${_workdir}"
    )

    set_tests_properties(${_ctest_name} PROPERTIES
        LABELS "${_labels}"
        TIMEOUT "${_ctest_timeout}"
        RUN_SERIAL TRUE   # perf benefits from dedicated CPU; avoid noisy neighbors
    )

    if(ARG_ENVIRONMENT)
        set_property(TEST ${_ctest_name} APPEND PROPERTY ENVIRONMENT ${ARG_ENVIRONMENT})
    endif()

    # Propagate standard Inkscape test environment when available
    if(DEFINED CMAKE_CTEST_ENV)
        set_property(TEST ${_ctest_name} APPEND PROPERTY ENVIRONMENT ${CMAKE_CTEST_ENV})
    endif()
    if(DEFINED INKSCAPE_TEST_PROFILE_DIR_ENV)
        set_property(TEST ${_ctest_name} APPEND PROPERTY
            ENVIRONMENT "${INKSCAPE_TEST_PROFILE_DIR_ENV}/${_ctest_name}")
    endif()

    if(ARG_DEPENDS AND TARGET performance_tests)
        foreach(_dep ${ARG_DEPENDS})
            if(TARGET ${_dep})
                add_dependencies(performance_tests ${_dep})
            endif()
        endforeach()
    endif()
endfunction()

# -----------------------------------------------------------------------------
# add_performance_test_for_existing(<existing_test_name>
#     [ITERATIONS <n>]
#     [MAX_TIME <seconds>]
#     [CALL_STACK_MODE kernel|userspace|both]
#     [LABELS <label1> ...]
# )
#
# Wraps an already-registered CTest in a perf_<name> performance counterpart.
# The original test is left untouched; only a new perf_ test is added.
#
# NOTE: Prefer passing COMMAND explicitly.  Reading the CTest COMMAND property
# requires CMake >= 3.29; on older CMake (e.g. 3.28 on Ubuntu 24.04) it is
# always empty and we fall back to the executable/target name when possible.
# -----------------------------------------------------------------------------
function(add_performance_test_for_existing existing_test_name)
    if(NOT INKSCAPE_PERFORMANCE_TESTS_AVAILABLE)
        return()
    endif()

    set(options "")
    set(oneValueArgs ITERATIONS MAX_TIME CALL_STACK_MODE WORKING_DIRECTORY)
    set(multiValueArgs LABELS ENVIRONMENT COMMAND)
    cmake_parse_arguments(ARG "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

    set(_cmd ${ARG_COMMAND})
    set(_workdir "${ARG_WORKING_DIRECTORY}")
    set(_env ${ARG_ENVIRONMENT})

    # Optional: try CTest properties when caller did not supply COMMAND
    # (works on CMake >= 3.29 only).
    if(NOT _cmd AND TEST ${existing_test_name})
        get_property(_cmd TEST ${existing_test_name} PROPERTY COMMAND)
        if(NOT _workdir)
            get_property(_workdir TEST ${existing_test_name} PROPERTY WORKING_DIRECTORY)
        endif()
        if(NOT _env)
            get_property(_env TEST ${existing_test_name} PROPERTY ENVIRONMENT)
        endif()
    endif()

    # Fallback: executable target or bare name (common for gtest binaries)
    if(NOT _cmd)
        if(TARGET ${existing_test_name})
            set(_cmd "$<TARGET_FILE:${existing_test_name}>")
        elseif(TEST ${existing_test_name})
            set(_cmd "${existing_test_name}")
        else()
            message(WARNING
                "add_performance_test_for_existing: cannot derive COMMAND for '${existing_test_name}'; skipping")
            return()
        endif()
    endif()

    set(_extra_args "")
    if(ARG_ITERATIONS)
        list(APPEND _extra_args ITERATIONS "${ARG_ITERATIONS}")
    endif()
    if(ARG_MAX_TIME)
        list(APPEND _extra_args MAX_TIME "${ARG_MAX_TIME}")
    endif()
    if(ARG_CALL_STACK_MODE)
        list(APPEND _extra_args CALL_STACK_MODE "${ARG_CALL_STACK_MODE}")
    endif()
    if(ARG_LABELS)
        list(APPEND _extra_args LABELS ${ARG_LABELS})
    endif()
    if(_workdir)
        list(APPEND _extra_args WORKING_DIRECTORY "${_workdir}")
    endif()
    if(_env)
        list(APPEND _extra_args ENVIRONMENT ${_env})
    endif()
    if(TARGET ${existing_test_name})
        list(APPEND _extra_args DEPENDS ${existing_test_name})
    endif()

    add_performance_test("${existing_test_name}"
        COMMAND ${_cmd}
        ${_extra_args}
    )
endfunction()

# -----------------------------------------------------------------------------
# enable_performance_tests_for_category(<category>
#     TESTS <test1> <test2> ...
#     [ITERATIONS <n>]
#     [MAX_TIME <seconds>]
#     [CALL_STACK_MODE kernel|userspace|both]
# )
#
# Bulk-register performance counterparts for a category of tests
# (integration, cli, rendering, unit, live-path-effects, ...).
# -----------------------------------------------------------------------------
function(enable_performance_tests_for_category category)
    if(NOT INKSCAPE_PERFORMANCE_TESTS_AVAILABLE)
        return()
    endif()

    set(options "")
    set(oneValueArgs ITERATIONS MAX_TIME CALL_STACK_MODE)
    set(multiValueArgs TESTS)
    cmake_parse_arguments(ARG "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

    if(NOT ARG_TESTS)
        return()
    endif()

    set(_extra_args LABELS "${category}")
    if(ARG_ITERATIONS)
        list(APPEND _extra_args ITERATIONS "${ARG_ITERATIONS}")
    endif()
    if(ARG_MAX_TIME)
        list(APPEND _extra_args MAX_TIME "${ARG_MAX_TIME}")
    endif()
    if(ARG_CALL_STACK_MODE)
        list(APPEND _extra_args CALL_STACK_MODE "${ARG_CALL_STACK_MODE}")
    endif()

    foreach(_t ${ARG_TESTS})
        add_performance_test_for_existing("${_t}" ${_extra_args})
    endforeach()
endfunction()
