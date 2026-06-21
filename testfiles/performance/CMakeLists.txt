# SPDX-License-Identifier: GPL-2.0-or-later
#
# Wire performance (perf + FlameGraph) counterparts for the existing Inkscape
# test suite.  This file is included only when performance testing is available
# (see CMakeScripts/PerformanceTest.cmake).  It never modifies existing tests.
#
# IMPORTANT: We register perf tests with explicit COMMANDs rather than reading
# the CTest COMMAND property from existing tests.  That property is only
# available in CMake >= 3.29; Inkscape's minimum is 3.24 and many distros
# (e.g. Ubuntu 24.04 / CMake 3.28) still lack it.
#
# Unit-test target names follow add_unit_tests() in UnitTest.cmake:
#   path/foo_bar-test.cpp  ->  path-foo-bar-test

if(NOT INKSCAPE_PERFORMANCE_TESTS_AVAILABLE)
    return()
endif()

set(_PERF_REGISTERED_COUNT 0)

# Helper: register perf_<name> for a built test executable target.
macro(_perf_add_exe_test _perf_name _exe_target)
    set(_perf_labels ${ARGN})
    if(TARGET ${_exe_target})
        add_performance_test(${_perf_name}
            COMMAND $<TARGET_FILE:${_exe_target}>
            LABELS ${_perf_labels}
            DEPENDS ${_exe_target}
        )
        math(EXPR _PERF_REGISTERED_COUNT "${_PERF_REGISTERED_COUNT} + 1")
    elseif(TEST ${_exe_target})
        add_performance_test(${_perf_name}
            COMMAND ${_exe_target}
            LABELS ${_perf_labels}
        )
        math(EXPR _PERF_REGISTERED_COUNT "${_PERF_REGISTERED_COUNT} + 1")
    else()
        message(STATUS "perf: skipping '${_perf_name}' (no target/test '${_exe_target}')")
    endif()
endmacro()

# ---------------------------------------------------------------------------
# Integration tests (gtest binaries that link inkscape_base)
# LPE binaries (test_lpe / test_lpe64) are also tagged live-path-effects here
# so they are not registered a second time below.
# ---------------------------------------------------------------------------
foreach(test_source ${TEST_SOURCES})
    string(REPLACE "-test" "" testname "test_${test_source}")
    string(REPLACE "/" "_" testname "${testname}")
    set(_int_labels integration)
    if(testname STREQUAL "test_lpe" OR testname STREQUAL "test_lpe64")
        list(APPEND _int_labels live-path-effects)
    endif()
    _perf_add_exe_test(${testname} ${testname} ${_int_labels})
endforeach()

# ---------------------------------------------------------------------------
# Unit tests — names must match add_unit_test / add_unit_tests output exactly.
# ---------------------------------------------------------------------------
set(_PERF_UNIT_TESTS
    # add_unit_test(<name> ...) keeps the given name
    assertions-in-tests
    version-test
    css-syntactic-decomposition-test
    mod360-test
    treeify-test
    # add_unit_tests(TEST_SOURCES "foo.cpp") -> basename, _ -> -
    svg-length-test
    svg-stringstream-test
    util-units-test
    # add_unit_tests(TEST_SOURCES "libnrtype/foo.cpp") -> libnrtype-foo
    libnrtype-font-factory-test
    libnrtype-font-instance-test
    # add_unit_tests(TEST_SOURCES "colors/foo.cpp") -> colors-foo
    colors-cms-profile-test
    colors-color-test
    colors-gamut-test
    colors-manager-test
    colors-parser-test
    colors-printer-test
    colors-gradient-averager-test
    colors-spaces-cms-test
    colors-spaces-cmyk-test
    colors-spaces-gray-test
    colors-spaces-hsl-test
    colors-spaces-hsluv-test
    colors-spaces-hsv-test
    colors-spaces-lab-test
    colors-spaces-lch-test
    colors-spaces-linear-rgb-test
    colors-spaces-luv-test
    colors-spaces-named-test
    colors-spaces-okhsl-test
    colors-spaces-okhsv-test
    colors-spaces-oklab-test
    colors-spaces-oklch-test
    colors-spaces-rgb-test
    colors-spaces-xyz-test
    colors-utils-test
)
if(NOT WIN32)
    list(APPEND _PERF_UNIT_TESTS xslt-extension-test)
endif()

foreach(_ut ${_PERF_UNIT_TESTS})
    _perf_add_exe_test(${_ut} ${_ut} unit)
endforeach()

# ---------------------------------------------------------------------------
# Rendering tests (bash + inkscape, same as rendering_tests/CMakeLists.txt)
# ---------------------------------------------------------------------------
set(_PERF_RENDERING_CASES
    test-empty
    test-dont-crash
    test-use
    solid-color-test
    selector-important-002
    selector-important-003
    multi-style
    style-parsing
    test-peppercarrot-text
    text-flow
    test-powerstroke-join
    symbol-svg2-geometry-properties
    symbol-svg2-ref
    text-svg-glyph-custom
)
if(${CMAKE_SIZEOF_VOID_P} EQUAL 8)
    list(APPEND _PERF_RENDERING_CASES text-gzipped-svg-glyph)
endif()

set(_RENDER_TEST_SH "${CMAKE_SOURCE_DIR}/testfiles/rendering_tests/test.sh")
set(_RENDER_WORKDIR "${CMAKE_BINARY_DIR}/testfiles/rendering_tests")
foreach(_case ${_PERF_RENDERING_CASES})
    set(_rname "render_${_case}")
    set(_r_labels rendering)
    if(_case STREQUAL "test-powerstroke-join")
        list(APPEND _r_labels live-path-effects)
    endif()
    if(TARGET inkscape)
        add_performance_test(${_rname}
            COMMAND bash ${_RENDER_TEST_SH}
                    ${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/inkscape
                    ${CMAKE_SOURCE_DIR}/testfiles/rendering_tests/${_case}
            LABELS ${_r_labels}
            WORKING_DIRECTORY ${_RENDER_WORKDIR}
            DEPENDS inkscape
        )
        math(EXPR _PERF_REGISTERED_COUNT "${_PERF_REGISTERED_COUNT} + 1")
    endif()
endforeach()

# ---------------------------------------------------------------------------
# CLI tests – representative subset
# ---------------------------------------------------------------------------
if(TARGET inkscape)
    add_performance_test(cli_version_build
        COMMAND $<TARGET_FILE:inkscape> --version --export-png-use-dithering=false
        LABELS cli
        DEPENDS inkscape
        ENVIRONMENT "${CMAKE_CTEST_ENV}"
    )
    add_performance_test(cli_version_known_build
        COMMAND $<TARGET_FILE:inkscape> --version --export-png-use-dithering=false
        LABELS cli
        DEPENDS inkscape
        ENVIRONMENT "${CMAKE_CTEST_ENV}"
    )
    math(EXPR _PERF_REGISTERED_COUNT "${_PERF_REGISTERED_COUNT} + 2")
endif()

# ---------------------------------------------------------------------------
# Smoke / ad-hoc (idempotent if re-run; distinct name from cli_version_*)
# ---------------------------------------------------------------------------
if(TARGET inkscape)
    add_performance_test(inkscape-version
        COMMAND $<TARGET_FILE:inkscape> --version
        LABELS cli smoke
        DEPENDS inkscape
        ENVIRONMENT "${CMAKE_CTEST_ENV}"
    )
    math(EXPR _PERF_REGISTERED_COUNT "${_PERF_REGISTERED_COUNT} + 1")
endif()

message(STATUS "Registered ${_PERF_REGISTERED_COUNT} performance tests (integration, unit, rendering, cli, smoke)")
