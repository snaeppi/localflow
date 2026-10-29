#!/bin/bash
# Builds the cleanup harness: main.swift plus the app's Rewriter.swift (instrumented by
# instrument.py), Tokenizer.swift and Vocabulary.swift, and the engine (Sources/LocalflowEngine).
#
# usage: bench/rewrite_harness/build.sh [OUTPUT]
#   OUTPUT  default /tmp/rewrite-harness/harness
#   CFLAGS  extra engine flags, e.g. -DLF_SME=0 for NEON only (as on chips before M4)
# then: OUTPUT MODEL CASES OUT.jsonl [REPS]   (see main.swift)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${1:-/tmp/rewrite-harness/harness}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
python3 "$ROOT/bench/rewrite_harness/instrument.py" "$ROOT/Sources/LocalflowApp/Rewriter.swift" "$WORK/Rewriter.swift"
cp "$ROOT/Sources/LocalflowApp/Vocabulary.swift" "$ROOT/Sources/LocalflowApp/Tokenizer.swift" \
  "$ROOT/bench/rewrite_harness/main.swift" "$WORK/"
ENGINE=$ROOT/Sources/LocalflowEngine
mkdir -p "$WORK/module"
printf 'module LocalflowEngine {\n    header "%s/include/LocalflowEngine.h"\n    export *\n}\n' "$ENGINE" > "$WORK/module/module.modulemap"
for f in "$ENGINE"/*.c; do
  clang -O3 -std=c17 -mmacosx-version-min=26.0 -DACCELERATE_NEW_LAPACK ${CFLAGS:-} -I "$ENGINE/include" -c "$f" -o "$WORK/$(basename "$f" .c).o"
done
mkdir -p "$(dirname "$OUT")"
# The app's deployment target (swiftc defaults to the SDK's).
swiftc -swift-version 6 -parse-as-library -O -target arm64-apple-macosx26.0 -I "$WORK/module" \
  "$WORK/main.swift" "$WORK/Rewriter.swift" "$WORK/Tokenizer.swift" "$WORK/Vocabulary.swift" "$WORK"/*.o -framework Accelerate -o "$OUT"
echo "Built $OUT"
