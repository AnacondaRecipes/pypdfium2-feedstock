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
    # clang mode (BUILD_PARAMS below) force-patches pdfium's -fuse-ld to
    # <clang_path>/bin/ld.lld -- the ELF lld name. lld picks its flavor from
    # argv[0], so invoked as "ld.lld" it runs in ELF mode and rejects the Mach-O
    # link (-dead_strip, -framework, -ObjC, -lto_library). Make that path a wrapper
    # that re-execs `ld64.lld` (from the `lld` build dep) so lld selects Mach-O.
    cat > "$BUILD_PREFIX/bin/ld.lld" <<'LDLLD'
#!/bin/bash
# Re-exec as ld64.lld so lld links Mach-O. Also make the shared lib relocatable:
# pdfium's clang-mode link sets no -install_name (it defaults to ./libpdfium.dylib)
# and no headerpad, so conda-build's install_name_tool rpath fixup then fails.
# Inject -install_name @rpath/<name> + -headerpad_max_install_names for .dylib output.
extra=(-headerpad_max_install_names)
prev=""; out=""
for x in "$@"; do
  [ "$prev" = "-o" ] && out="$x"
  prev="$x"
done
case "$out" in
  *.dylib) extra+=(-install_name "@rpath/$(basename "$out")") ;;
esac
exec ld64.lld "$@" "${extra[@]}"
LDLLD
    chmod +x "$BUILD_PREFIX/bin/ld.lld"
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

# Vendor pdfium's bundled third-party libs, EXCEPT the ones listed here, which we
# link from the conda host packages instead (--no-vendor sets pdfium's GN
# use_system_<lib>). Unvendoring makes each a real conda run dep (via run_exports),
# so vulnerability trackers see them -- the point of building them separately.
#   - libc++: use the system C++ stdlib (libstdc++ with conda gcc).
#   - zlib/libpng/lcms2/openjpeg/libtiff: self-contained image/compression libs,
#     low pdfium coupling. (freetype/libjpeg/icu stay vendored for now -- pdfium
#     couples to specific versions / the 12-bit libjpeg path; a later wave.)
# --no-libclang-rt: don't require libclang_rt.builtins.a (use libgcc). -j honours
# the conda build CPU allocation.
_UNVENDOR="libc++ zlib libpng lcms2 openjpeg libtiff"
if [[ "$(uname)" == "Darwin" ]]; then
    # Force clang mode on macOS. Otherwise build_native takes its "gcc" toolchain
    # path (because /usr/bin/gcc exists), which drives GN's gcc_toolchain -- and
    # that emits Linux-only linker flags for the shared lib (-Wl,-soname,
    # -Wl,--whole-archive) that Apple ld rejects. Clang mode uses pdfium's
    # mac-native toolchain, which links dylibs correctly (-install_name/-all_load).
    export BUILD_PARAMS="--compiler clang --clang-path ${BUILD_PREFIX} --vendor all --no-vendor ${_UNVENDOR} --no-libclang-rt -j ${CPU_COUNT:-4}"
else
    export BUILD_PARAMS="--vendor all --no-vendor ${_UNVENDOR} --no-libclang-rt -j ${CPU_COUNT:-4}"
fi

$PYTHON -m pip install . -vv --no-deps --no-build-isolation
