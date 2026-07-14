#!/bin/bash
set -euo pipefail

# Build PDFium from source in-tree via pypdfium2's *native* sourcebuild backend
# (setupsrc/build_native.py). This self-manages the pdfium checkout (fetching dep
# revisions dynamically from pdfium's DEPS file) and builds with the *system*
# toolchain -- conda's gcc/g++ on Linux (clang on macOS), conda `gn`, and conda
# `ninja` (ninja-base). It deliberately avoids Google's hermetic binary toolchain,
# so the whole DEPS list + patch set is maintained upstream, not in this recipe.
export PDFIUM_PLATFORM="sourcebuild-native"

# pdfium's build archives static libs with `ar -r -c -D` (deterministic mode).
# On macOS, bare `ar` resolves to Apple's /usr/bin/ar, which has no -D flag (GNU
# ar on Linux does, which is why Linux builds cleanly). Shim a bare `ar` pointing
# at conda's llvm-ar (supports -D) ahead of Apple's on PATH.
if [[ "$(uname)" == "Darwin" ]]; then
    _AR_SHIM="${SRC_DIR}/_ar_shim"
    mkdir -p "$_AR_SHIM"
    ln -sf "$(command -v llvm-ar)" "$_AR_SHIM/ar"
    export PATH="$_AR_SHIM:$PATH"
fi

# Vendor pdfium's bundled third-party libs, except libc++ (use the system C++
# stdlib -- libstdc++ with conda gcc). --no-libclang-rt tells pdfium's build not
# to insist on libclang_rt.builtins.a (libgcc is used instead). This mirrors the
# portable-Linux fallback params upstream tests in CI. -j honours the conda build
# CPU allocation. (Deps are vendored for a green baseline; unvendoring specific
# libs to the conda host packages -- for vuln tracking -- is a follow-up.)
export BUILD_PARAMS="--vendor all --no-vendor libc++ --no-libclang-rt -j ${CPU_COUNT:-4}"

$PYTHON -m pip install . -vv --no-deps --no-build-isolation
