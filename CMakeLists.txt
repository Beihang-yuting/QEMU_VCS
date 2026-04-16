cmake_minimum_required(VERSION 3.16)
project(cosim-platform C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

add_compile_options(-Wall -Wextra -Werror -g)

add_subdirectory(bridge)

enable_testing()
add_subdirectory(tests/unit)
add_subdirectory(tests/integration)
