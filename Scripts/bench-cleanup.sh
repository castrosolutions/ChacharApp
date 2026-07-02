#!/usr/bin/env bash
# Build and run the Layer 2 cleanup benchmark (chacharapp-bench).
#
# Why xcodebuild (not `swift build`): MLX's Metal kernels (default.metallib) are ONLY compiled by
# Xcode's build system; plain `swift build` skips them and MLX crashes at runtime with
# "Failed to load the default metallib".
#
# Usage: Scripts/bench-cleanup.sh [modelId]
#   modelId   optional Hugging Face MLX model id (default: the cleaner's configured model)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XC_CONFIG="Debug"
DERIVED="$ROOT/.build/xcode"
PRODUCTS="$DERIVED/Build/Products/$XC_CONFIG"
OUT="$ROOT/docs/cleanup-benchmark.md"

echo "Building chacharapp-bench via xcodebuild ($XC_CONFIG)…" >&2
xcodebuild -scheme chacharapp-bench -configuration "$XC_CONFIG" \
    -derivedDataPath "$DERIVED" -destination 'platform=macOS,arch=arm64' \
    -skipMacroValidation -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO build >&2

mkdir -p "$ROOT/docs"
echo "Running benchmark (Markdown report -> $OUT)…" >&2
# The resource bundle mlx-swift_Cmlx.bundle (metallib) sits next to the executable in PRODUCTS, so
# MLX resolves it via Bundle.module; bypass the .app-oriented metallib heuristic in MLXTextCleaner.
CHACHARAPP_SKIP_METALLIB_CHECK=1 "$PRODUCTS/chacharapp-bench" "$@" > "$OUT"

echo "Done. Wrote $OUT" >&2
