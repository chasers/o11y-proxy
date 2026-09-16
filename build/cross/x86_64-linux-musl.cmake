# Cross-compile toolchain for Burrito's musl targets. Referenced from mix.exs via
# Burrito's `nif_env` (CMAKE_TOOLCHAIN_FILE), which adbc's Makefile honours.
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER   "${CMAKE_CURRENT_LIST_DIR}/cc-x86_64-linux-musl")
set(CMAKE_CXX_COMPILER "${CMAKE_CURRENT_LIST_DIR}/cxx-x86_64-linux-musl")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM BEFORE)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
