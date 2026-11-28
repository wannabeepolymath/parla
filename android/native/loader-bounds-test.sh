#!/bin/sh
# Host check of the "parla:" loader bounds in vendor/whisper/src/whisper.cpp (see loader_bounds_test.cpp).
# CPU only, no network. Optional: PARLA_REAL_MODELS=a.bin:b.bin also requires real models to still load;
# PARLA_LEAKS=1 reruns the refusals (PARLA_REPEAT times) under macOS `leaks --atExit`, which fails on any leak.
# If the newest macOS SDK cannot link, pass an older one, e.g. SDKROOT=.../MacOSX26.5.sdk.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-"$here/../app/build/host-whisper"}
mkdir -p "$out/wrap" "$out/cases"
# whisper's own top-level CMakeLists configures bindings that are not vendored; build it as a subproject.
cat > "$out/wrap/CMakeLists.txt" <<EOF
cmake_minimum_required(VERSION 3.22)
project(host_whisper C CXX)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
foreach(f GGML_METAL GGML_BLAS GGML_ACCELERATE GGML_NATIVE GGML_OPENMP WHISPER_BUILD_TESTS WHISPER_BUILD_EXAMPLES WHISPER_BUILD_SERVER WHISPER_CURL)
  set(\${f} OFF CACHE BOOL "" FORCE)
endforeach()
add_subdirectory("$here/vendor/whisper" whisper)
EOF
sysroot=${SDKROOT:+-DCMAKE_OSX_SYSROOT=$SDKROOT}
cmake -S "$out/wrap" -B "$out" -DCMAKE_BUILD_TYPE=Release ${sysroot:-} >/dev/null
cmake --build "$out" --target whisper -j 8 >/dev/null
l="$out/whisper"
c++ -std=c++17 ${SDKROOT:+-isysroot "$SDKROOT"} -I "$here/vendor/whisper/include" -I "$here/vendor/whisper/ggml/include" \
  "$here/loader_bounds_test.cpp" "$l/src/libwhisper.a" "$l/ggml/src/libggml.a" "$l/ggml/src/libggml-cpu.a" "$l/ggml/src/libggml-base.a" \
  -o "$out/loader_bounds_test"
"$out/loader_bounds_test" "$out/cases"
# Leak check (macOS): every refused load, repeated, must release what it allocated.
if [ "${PARLA_LEAKS:-0}" = 1 ]; then
  PARLA_REPEAT=${PARLA_REPEAT:-5} PARLA_REAL_MODELS= MallocStackLogging=1 leaks --atExit -- "$out/loader_bounds_test" "$out/cases"
fi
