cmake_minimum_required(VERSION 3.22)
project(famasock_android C)
get_filename_component(ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../.." ABSOLUTE)
if(ANDROID_ABI STREQUAL "arm64-v8a")
    set(RUST_TARGET aarch64-linux-android)
elseif(ANDROID_ABI STREQUAL "x86_64")
    set(RUST_TARGET x86_64-linux-android)
else()
    message(FATAL_ERROR "Unsupported ABI: ${ANDROID_ABI}")
endif()
find_program(CARGO cargo REQUIRED)
set(RUST_DIR "${ROOT}/target/android/${ANDROID_ABI}")
set(RUST_LIB "${RUST_DIR}/${RUST_TARGET}/release/libfamasock.a")
file(GLOB_RECURSE RUST_SOURCES CONFIGURE_DEPENDS "${ROOT}/crates/famasock/src/*.rs")
string(TOUPPER "${RUST_TARGET}" TARGET_ENV)
string(REPLACE "-" "_" TARGET_ENV "${TARGET_ENV}")
add_custom_command(OUTPUT "${RUST_LIB}"
    COMMAND ${CMAKE_COMMAND} -E env
        "CARGO_TARGET_DIR=${RUST_DIR}"
        "CARGO_TARGET_${TARGET_ENV}_LINKER=${CMAKE_C_COMPILER}"
        "CC_${RUST_TARGET}=${CMAKE_C_COMPILER}"
        "CFLAGS_${RUST_TARGET}=--target=${CMAKE_C_COMPILER_TARGET} --sysroot=${CMAKE_SYSROOT}"
        "AR_${RUST_TARGET}=${CMAKE_AR}"
        ${CARGO} build --manifest-path "${ROOT}/Cargo.toml" -p famasock --lib
        --locked --release --target ${RUST_TARGET}
    DEPENDS ${RUST_SOURCES} "${ROOT}/Cargo.lock" "${ROOT}/Cargo.toml" "${ROOT}/crates/famasock/Cargo.toml"
    WORKING_DIRECTORY "${ROOT}" VERBATIM)
add_custom_target(rust_core DEPENDS "${RUST_LIB}")
add_library(famasock_jni SHARED bridge.c)
add_dependencies(famasock_jni rust_core)
target_include_directories(famasock_jni PRIVATE "${ROOT}/apps/ios/Shared")
target_compile_options(famasock_jni PRIVATE -Wall -Wextra -Werror)
target_link_options(famasock_jni PRIVATE "-Wl,-z,max-page-size=16384")
target_link_libraries(famasock_jni PRIVATE "${RUST_LIB}" android log dl m)
