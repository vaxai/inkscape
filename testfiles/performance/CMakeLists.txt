# SPDX-License-Identifier: GPL-2.0-or-later
#
# Wire performance (perf + FlameGraph) counterparts for the existing Inkscape
# test suite.  This file is included only when performance testing is available
# (see CMakeScripts/PerformanceTest.cmake).  It never modifies existing tests.

if(NOT INKSCAPE_PERFORMANCE_TESTS_AVAILABLE)
    return()
endif()

# ---------------------------------------------------------------------------
# Integration tests (gtest binaries that link inkscape_base)
# ---------------------------------------------------------------------------
set(_PERF_INTEGRATION_TESTS)
foreach(test_source ${TEST_SOURCES})
    string(REPLACE "-test" "" testname "test_${test_source}")
    string(REPLACE "/" "_" testname "${testname}")
    list(APPEND _PERF_INTEGRATION_TESTS "${testname}")
endforeach()

enable_performance_tests_for_category(integration
    TESTS ${_PERF_INTEGRATION_TESTS}
)

# ---------------------------------------------------------------------------
# Unit tests (registered via add_unit_test / add_unit_tests)
# Collect known unit test names explicitly; they are independent of
# inkscape_base and therefore cheap to profile in isolation.
# ---------------------------------------------------------------------------
set(_PERF_UNIT_TESTS
    assertions-in-tests
    version-test
    svg-length-test
    svg-stringstream-test
    util-units-test
    font-factory-test
    font-instance-test
    cms-profile-test
    color-test
    gamut-test
    manager-test
    parser-test
    printer-test
    gradient-averager-test
    spaces-cms-test
    spaces-cmyk-test
    spaces-gray-test
    spaces-hsl-test
    spaces-hsluv-test
    spaces-hsv-test
    spaces-lab-test
    spaces-lch-test
    spaces-linear-rgb-test
    spaces-luv-test
    spaces-named-test
    spaces-okhsl-test
    spaces-okhsv-test
    spaces-oklab-test
    spaces-oklch-test
    spaces-rgb-test
    spaces-xyz-test
    utils-test
    css-syntactic-decomposition-test
    mod360-test
    treeify-test
)
if(NOT WIN32)
    list(APPEND _PERF_UNIT_TESTS xslt-extension-test)
endif()

enable_performance_tests_for_category(unit
    TESTS ${_PERF_UNIT_TESTS}
)

# ---------------------------------------------------------------------------
# Rendering tests
# ---------------------------------------------------------------------------
set(_PERF_RENDERING_TESTS
    render_test-empty
    render_test-dont-crash
    render_test-use
    render_solid-color-test
    render_selector-important-002
    render_selector-important-003
    render_multi-style
    render_style-parsing
    render_test-peppercarrot-text
    render_text-flow
    render_test-powerstroke-join
    render_symbol-svg2-geometry-properties
    render_symbol-svg2-ref
    render_text-svg-glyph-custom
)
if(${CMAKE_SIZEOF_VOID_P} EQUAL 8)
    list(APPEND _PERF_RENDERING_TESTS render_text-gzipped-svg-glyph)
endif()

enable_performance_tests_for_category(rendering
    TESTS ${_PERF_RENDERING_TESTS}
)

# ---------------------------------------------------------------------------
# CLI tests – only the main run fixture (not _check / _clean / _ref companions)
# We register a representative subset plus a helper that profiles any existing
# cli_*_build test.  Full enumeration of every CLI fixture would dominate the
# report directory; developers can add specific ones with add_performance_test
# or set PERF_CLI_TESTS_EXTRA.
# ---------------------------------------------------------------------------
set(_PERF_CLI_TESTS
    cli_version_build
    cli_version_known_build
)
# Allow developers to extend the CLI perf set without editing this file:
#   cmake -DPERF_CLI_TESTS_EXTRA="cli_foo_build;cli_bar_build" ...
if(DEFINED PERF_CLI_TESTS_EXTRA)
    list(APPEND _PERF_CLI_TESTS ${PERF_CLI_TESTS_EXTRA})
endif()

enable_performance_tests_for_category(cli
    TESTS ${_PERF_CLI_TESTS}
)

# ---------------------------------------------------------------------------
# Live path effects (LPE) – integration LPE test plus rendering LPE tests
# ---------------------------------------------------------------------------
set(_PERF_LPE_TESTS
    test_lpe
    render_test-powerstroke-join
)
if(${CMAKE_SIZEOF_VOID_P} EQUAL 8)
    list(APPEND _PERF_LPE_TESTS test_lpe64)
endif()

enable_performance_tests_for_category(live-path-effects
    TESTS ${_PERF_LPE_TESTS}
)

# ---------------------------------------------------------------------------
# Direct add_performance_test examples / ad-hoc perf targets
# ---------------------------------------------------------------------------

# Profile inkscape --version (fast; relies on PERF_TEST_ITERATIONS for samples)
if(TARGET inkscape)
    add_performance_test(inkscape-version
        COMMAND $<TARGET_FILE:inkscape> --version
        LABELS cli smoke
        DEPENDS inkscape
        ENVIRONMENT "${CMAKE_CTEST_ENV}"
    )
endif()

message(STATUS "Registered performance tests for categories: integration, unit, rendering, cli, live-path-effects")
