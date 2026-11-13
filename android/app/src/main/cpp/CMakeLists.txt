cmake_minimum_required(VERSION 3.22.1)
project(aithra_llama C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(FetchContent)

# llama.cpp is pinned to a release tag and verified by hash.
FetchContent_Declare(
    llama
    URL https://github.com/ggml-org/llama.cpp/archive/refs/tags/b11935.tar.gz
    URL_HASH SHA256=0bfc7af823a4c25fb2d21dfdce40eb878aa76dbbcc16648e679cc56796f6692c
)

set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_APP OFF CACHE BOOL "" FORCE)
set(LLAMA_OPENSSL OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP ON CACHE BOOL "" FORCE)
set(GGML_LLAMAFILE OFF CACHE BOOL "" FORCE)
# Tensor G3 (Cortex-X3/A715/A510) and every Armv9 phone support dotprod, i8mm
# and fp16 arithmetic; ggml's Q4_0 repacked kernels need dotprod/i8mm.
set(GGML_CPU_ARM_ARCH "armv8.2-a+dotprod+i8mm+fp16" CACHE STRING "" FORCE)

FetchContent_MakeAvailable(llama)

add_library(aithra_llama SHARED aithra_llama.cpp)
target_link_libraries(aithra_llama llama ggml android log)
