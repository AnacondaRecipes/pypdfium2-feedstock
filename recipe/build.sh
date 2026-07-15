#!/bin/bash
set -euo pipefail

# Build PDFium from source in-tree via pypdfium2's *native* sourcebuild backend
# (setupsrc/build_native.py). This self-manages the pdfium checkout (fetching dep
# revisions dynamically from pdfium's DEPS file) and builds with the *system*
# toolchain -- conda's gcc/g++ on Linux (clang on macOS), conda `gn`, and conda
# `ninja` (ninja-base). It deliberately avoids Google's hermetic binary toolchain,
# so the whole DEPS list + patch set is maintained upstream, not in this recipe.
export PDFIUM_PLATFORM="sourcebuild-native"

# macOS toolchain shims. build_native takes its "gcc" toolchain path on macOS
# (because /usr/bin/gcc exists), driving conda's clang via GN's gcc_toolchain --
# which is Linux-shaped in two spots that break on Apple tools:
#   1. archives static libs with `ar -r -c -D`; Apple's /usr/bin/ar has no -D
#      (GNU ar on Linux does, which is why Linux builds clean). Shim `ar` -> llvm-ar.
#   2. links the shared lib with `-Wl,-soname,libpdfium.dylib`; macOS ld has no
#      -soname (it uses -install_name). Shim conda's $CC/$CXX drivers to rewrite
#      `-Wl,-soname,X` -> `-Wl,-install_name,@rpath/X`.
if [[ "$(uname)" == "Darwin" ]]; then
    _SHIM="${SRC_DIR}/_shim"
    mkdir -p "$_SHIM"
    ln -sf "$(command -v llvm-ar)" "$_SHIM/ar"
    # Shim every clang/clang++ driver the toolchain might invoke (bare names plus
    # the conda arm64-apple-darwin*-clang[++] wrappers -- gcc_solink_wrapper.py
    # calls the driver by its toolchain name, which is the darwin-prefixed one).
    for _name in clang clang++ "$CC" "$CXX" \
                 arm64-apple-darwin20.0.0-clang arm64-apple-darwin20.0.0-clang++; do
        [ -n "$_name" ] || continue
        _real="$(command -v "$_name" 2>/dev/null)" || continue
        case "$_real" in "$_SHIM"/*) continue ;; esac   # don't shim our own shim
        cat > "$_SHIM/$(basename "$_name")" <<SHIM
#!/bin/bash
a=()
for x in "\$@"; do
  case "\$x" in
    -Wl,-soname,*) a+=("-Wl,-install_name,@rpath/\${x#-Wl,-soname,}") ;;
    -Wl,-soname=*) a+=("-Wl,-install_name,@rpath/\${x#-Wl,-soname=}") ;;
    *) a+=("\$x") ;;
  esac
done
exec "$_real" "\${a[@]}"
SHIM
        chmod +x "$_SHIM/$(basename "$_name")"
    done
    export PATH="$_SHIM:$PATH"
fi

# Vendor pdfium's bundled third-party libs, except libc++ (use the system C++
# stdlib -- libstdc++ with conda gcc). --no-libclang-rt tells pdfium's build not
# to insist on libclang_rt.builtins.a (libgcc is used instead). This mirrors the
# portable-Linux fallback params upstream tests in CI. -j honours the conda build
# CPU allocation. (Deps are vendored for a green baseline; unvendoring specific
# libs to the conda host packages -- for vuln tracking -- is a follow-up.)
export BUILD_PARAMS="--vendor all --no-vendor libc++ --no-libclang-rt -j ${CPU_COUNT:-4}"

$PYTHON -m pip install . -vv --no-deps --no-build-isolation
