#!/bin/bash
# Builds the per-pass timers: lf_pass on the engine (Sources/LocalflowEngine) with SME and NEON only
# (as on chips before M4), and with LLAMA set, llama_pass against that llama.cpp build.
#
# usage: bench/pass_latency/build.sh [OUTPUT_DIR]   (default /tmp/pass-latency)
#   LLAMA  a llama.cpp checkout and build directory, e.g. LLAMA=llama.cpp:build (static libraries,
#          cmake -DBUILD_SHARED_LIBS=OFF, KleidiAI's included if built; see bench/README.md)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${1:-/tmp/pass-latency}
ENGINE=$ROOT/Sources/LocalflowEngine
mkdir -p "$OUT"
for variant in sme neon; do
  flags=""; [ $variant = neon ] && flags="-DLF_SME=0"
  clang -O3 -std=c17 -mmacosx-version-min=26.0 -DACCELERATE_NEW_LAPACK $flags -I "$ENGINE/include" \
    "$ENGINE"/*.c "$ROOT/bench/pass_latency/lf_pass.c" -framework Accelerate -o "$OUT/lf_pass-$variant"
  echo "Built $OUT/lf_pass-$variant"
done
if [ -n "${LLAMA:-}" ]; then
  src=${LLAMA%%:*}; build=$src/${LLAMA#*:}
  shopt -s nullglob
  clang -O2 -I "$src/include" -I "$src/ggml/include" "$ROOT/bench/pass_latency/llama_pass.c" \
    "$build/src/libllama.a" "$build"/ggml/src/libggml.a "$build"/ggml/src/libggml-*.a "$build"/ggml/src/ggml-*/libggml-*.a \
    "$build"/_deps/*/libkleidiai.a -lc++ -framework Accelerate -framework Metal -framework MetalKit -framework Foundation -o "$OUT/llama_pass-$(basename "$build")"
  echo "Built $OUT/llama_pass-$(basename "$build")"
fi
