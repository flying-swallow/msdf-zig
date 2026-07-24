#!/usr/bin/env bash
# Regenerates the golden fixtures in src/test/fixtures from the C++ msdfgen.
#
# This is a local dev tool, NOT part of `zig build test` and NOT run in CI --
# the committed fixtures are what the test suite reads, so CI needs no C++
# toolchain. Rerun this only when bumping the msdfgen reference version, and
# review the resulting fixture diff carefully: a change here moves the oracle
# itself, so it can mask a regression rather than reveal one.
#
# Usage: MSDFGEN_DIR=/path/to/msdfgen tools/oracle/regenerate.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MSDFGEN_DIR="${MSDFGEN_DIR:-}"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

if [[ -z "$MSDFGEN_DIR" ]]; then
    echo "error: set MSDFGEN_DIR to an msdfgen checkout (tested against v1.13.0)" >&2
    exit 1
fi
if [[ ! -f "$MSDFGEN_DIR/msdfgen.h" ]]; then
    echo "error: $MSDFGEN_DIR does not look like an msdfgen checkout (no msdfgen.h)" >&2
    exit 1
fi

echo "==> Building msdfgen from $MSDFGEN_DIR"
# Skia/SVG/PNG are all irrelevant to the fixtures and only add dependencies.
# MSDFGEN_INSTALL stays OFF, which means msdfgen-config.h is never generated --
# hence the explicit -D flags below, mirroring what CMake puts on the targets
# (CMakeLists.txt:105-137, 149-170). MSDFGEN_USE_CPP11 in particular affects ABI
# via move constructors, so it MUST match how the libraries were built.
cmake -B "$BUILD_DIR" -S "$MSDFGEN_DIR" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DMSDFGEN_USE_VCPKG=OFF \
    -DMSDFGEN_USE_SKIA=OFF \
    -DMSDFGEN_DISABLE_SVG=ON \
    -DMSDFGEN_DISABLE_PNG=ON \
    -DMSDFGEN_BUILD_STANDALONE=OFF \
    -DMSDFGEN_INSTALL=OFF >/dev/null
ninja -C "$BUILD_DIR" >/dev/null

echo "==> Building oracle"
g++ -std=gnu++11 -O2 -o "$BUILD_DIR/oracle" "$REPO_ROOT/tools/oracle/oracle.cpp" \
    -I"$MSDFGEN_DIR" \
    $(pkg-config --cflags freetype2) \
    -DMSDFGEN_PUBLIC= -DMSDFGEN_EXT_PUBLIC= -DMSDFGEN_USE_CPP11 \
    -DMSDFGEN_EXTENSIONS -DMSDFGEN_DISABLE_SVG -DMSDFGEN_DISABLE_PNG \
    -L"$BUILD_DIR" -lmsdfgen-ext -lmsdfgen-core \
    $(pkg-config --libs freetype2)

echo "==> Generating fixtures"
mkdir -p "$REPO_ROOT/src/test/fixtures"
"$BUILD_DIR/oracle" "$REPO_ROOT/example/assets" "$REPO_ROOT/src/test/fixtures"
