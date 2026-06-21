# SPDX-License-Identifier: GPL-2.0-or-later
#
# Setup for unit tests.
add_custom_target(unit_tests)

function(make_target_unit_testable target_name)
    target_compile_definitions(${target_name} PRIVATE "-D_GLIBCXX_ASSERTIONS")
    target_compile_options(${target_name} PRIVATE "-fno-omit-frame-pointer" "-UNDEBUG")
    if(TESTS_WITH_ASAN)
        target_compile_options(${target_name} PRIVATE "-fsanitize=address")
        target_link_options(${target_name} PRIVATE "-fsanitize=address")
    endif()
endfunction()

# Add a unit test as follows:
# add_unit_test(name-of-my-test TEST_SOURCE foo-test.cpp [SOURCES foo.cpp ...] [EXTRA_LIBS ...])
function(add_unit_test test_name)
    set(SINGL_VALUE_ARGS TEST_SOURCE)
    set(MULTI_VALUE_ARGS SOURCES EXTRA_LIBS ENVIRONMENT)
    cmake_parse_arguments(ARG "UNUSED_OPTIONS" "${SINGL_VALUE_ARGS}" "${MULTI_VALUE_ARGS}" ${ARGN})
    foreach(source_file ${ARG_SOURCES})
        if(EXISTS "${CMAKE_SOURCE_DIR}/src/${source_file}")
            list(APPEND test_sources "${CMAKE_SOURCE_DIR}/src/${source_file}")
        else()
            if (EXISTS "${CMAKE_SOURCE_DIR}/testfiles/src/${source_file}")
                list(APPEND test_sources "${CMAKE_SOURCE_DIR}/testfiles/src/${source_file}")
            else()
                message(FATAL_ERROR "Test source '${source_file}' can not be found.")
            endif()
        endif()
    endforeach()

    if(EXISTS "${CMAKE_SOURCE_DIR}/testfiles/src/${test_name}.cpp")
        list(APPEND test_sources "${CMAKE_SOURCE_DIR}/testfiles/src/${test_name}.cpp")
    else()
        if (ARG_TEST_SOURCE)
            if (EXISTS "${CMAKE_SOURCE_DIR}/testfiles/src/${ARG_TEST_SOURCE}")
                list(APPEND test_sources "${CMAKE_SOURCE_DIR}/testfiles/src/${ARG_TEST_SOURCE}")
            else()
                message(FATAL_ERROR "'${CMAKE_SOURCE_DIR}/testfiles/src/${ARG_TEST_SOURCE}' not found")
            endif()
        else()
            message(FATAL_ERROR "'${CMAKE_SOURCE_DIR}/testfiles/src/${test_name}.cpp' not found")
        endif()
    endif()

    add_executable(${test_name} ${test_sources})
    target_include_directories(${test_name} SYSTEM PRIVATE ${GTEST_INCLUDE_DIRS})
    set_target_properties(${test_name} PROPERTIES LINKER_LANGUAGE CXX)

    make_target_unit_testable(${test_name})

    target_link_libraries(${test_name} GTest::gtest GTest::gmock GTest::gmock_main ${ARG_EXTRA_LIBS})
    add_test(NAME ${test_name} COMMAND ${test_name})
    add_dependencies(unit_tests ${test_name} ${ARG_EXTRA_LIBS})

    foreach(arg_env ${ARG_ENVIRONMENT})
        set_property(TEST ${test_name} APPEND PROPERTY ENVIRONMENT "${arg_env}")
    endforeach()

    # Optional per-test performance counterpart (only when perf framework is active).
    # Developers can pass PERF_ITERATIONS / PERF_MAX_TIME / PERF_CALL_STACK_MODE
    # through ENVIRONMENT is not used; instead honour optional args:
    #   PERF_ITERATIONS, PERF_MAX_TIME, PERF_CALL_STACK_MODE as extra oneValueArgs
    # are handled below if the caller provided them via ARGN already parsed above.
endfunction(add_unit_test)

# Extended unit-test helper that also registers a perf_ counterpart when the
# performance framework is available.  Existing add_unit_test() is unchanged.
# Usage:
#   add_unit_test_with_perf(my-test TEST_SOURCE my-test.cpp
#       [PERF_ITERATIONS 10] [PERF_MAX_TIME 30] [PERF_CALL_STACK_MODE userspace]
#       ...)
function(add_unit_test_with_perf test_name)
    set(SINGL_VALUE_ARGS TEST_SOURCE PERF_ITERATIONS PERF_MAX_TIME PERF_CALL_STACK_MODE)
    set(MULTI_VALUE_ARGS SOURCES EXTRA_LIBS ENVIRONMENT)
    cmake_parse_arguments(ARG "UNUSED_OPTIONS" "${SINGL_VALUE_ARGS}" "${MULTI_VALUE_ARGS}" ${ARGN})

    # Delegate to the normal unit-test registration first.
    set(_unit_args "")
    if(ARG_TEST_SOURCE)
        list(APPEND _unit_args TEST_SOURCE "${ARG_TEST_SOURCE}")
    endif()
    if(ARG_SOURCES)
        list(APPEND _unit_args SOURCES ${ARG_SOURCES})
    endif()
    if(ARG_EXTRA_LIBS)
        list(APPEND _unit_args EXTRA_LIBS ${ARG_EXTRA_LIBS})
    endif()
    if(ARG_ENVIRONMENT)
        list(APPEND _unit_args ENVIRONMENT ${ARG_ENVIRONMENT})
    endif()
    add_unit_test(${test_name} ${_unit_args})

    if(NOT INKSCAPE_PERFORMANCE_TESTS_AVAILABLE)
        return()
    endif()

    set(_perf_args LABELS unit)
    if(ARG_PERF_ITERATIONS)
        list(APPEND _perf_args ITERATIONS "${ARG_PERF_ITERATIONS}")
    endif()
    if(ARG_PERF_MAX_TIME)
        list(APPEND _perf_args MAX_TIME "${ARG_PERF_MAX_TIME}")
    endif()
    if(ARG_PERF_CALL_STACK_MODE)
        list(APPEND _perf_args CALL_STACK_MODE "${ARG_PERF_CALL_STACK_MODE}")
    endif()
    add_performance_test_for_existing(${test_name} ${_perf_args})
endfunction(add_unit_test_with_perf)

function(add_unit_tests)
    set(MULTI_VALUE_ARGS "TEST_SOURCES" "SOURCES" "EXTRA_LIBS" "ENVIRONMENT")
    cmake_parse_arguments(ARG "UNUSED_OPTIONS" "" "${MULTI_VALUE_ARGS}" ${ARGN})

    foreach(testsource ${ARG_TEST_SOURCES})
        # Build a testname from the testsource filename
        string(REPLACE "/" "-" testname "${testsource}")
        get_filename_component(testname "${testname}" NAME_WE)
        string(REPLACE "_" "-" testname "${testname}")
        add_unit_test(${testname} TEST_SOURCE "${testsource}"
                                  ENVIRONMENT "${ARG_ENVIRONMENT}"
                                  SOURCES ${ARG_SOURCES}
                                  EXTRA_LIBS ${ARG_EXTRA_LIBS})
    endforeach()

endfunction(add_unit_tests)
