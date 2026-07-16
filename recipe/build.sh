#!/bin/bash
set -euo pipefail

# Build PDFium from source in-tree via pypdfium2's *native* sourcebuild backend
# (setupsrc/build_native.py). This self-manages the pdfium checkout (fetching dep
# revisions dynamically from pdfium's DEPS file) and builds with the *system*
# toolchain -- conda's gcc/g++ on Linux (clang on macOS), conda `gn`, and conda
# `ninja` (ninja-base). It deliberately avoids Google's hermetic binary toolchain,
# so the whole DEPS list + patch set is maintained upstream, not in this recipe.
export PDFIUM_PLATFORM="sourcebuild-native"

# Let pdfium's hermetic compiles/links find the unvendored conda libs (zlib,
# libpng, lcms2, openjpeg, libtiff, freetype). pdfium invokes the compiler by
# absolute path, so -I/-L flag injection won't reach it -- but CPATH/LIBRARY_PATH
# are read from the environment by clang/gcc themselves. They rank below pdfium's
# own -I/-L, so only headers/libs it doesn't vendor (the system ones) resolve.
export CPATH="${PREFIX}/include${CPATH:+:$CPATH}"
export LIBRARY_PATH="${PREFIX}/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
# openjpeg and freetype install headers under subdirs (openjpeg-X.Y, freetype2).
for _inc in "${PREFIX}"/include/openjpeg-* "${PREFIX}"/include/freetype2; do
    [ -d "$_inc" ] && export CPATH="${_inc}:${CPATH}"
done

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
# Re-exec as ld64.lld so lld links Mach-O, with fixups for the conda build:
#  * -install_name @rpath + -headerpad so conda's install_name_tool relocation works
#    (pdfium's clang-mode link sets neither, defaulting the id to ./libpdfium.dylib).
#  * -llcms2 -lopenjp2: pdfium's use_system_lcms2/libopenjpeg2 configs auto-link on
#    Linux but don't emit -l flags on macOS (openjpeg 2.x lib is libopenjp2);
#    LIBRARY_PATH supplies -L, same as zlib/libpng/libtiff which already resolve.
#  * bump the link's macOS min version to conda's baseline ($MACOSX_DEPLOYMENT_TARGET,
#    12.1) -- pdfium hardcodes 11.0, and ld64.lld errors linking conda's newer dylibs
#    ("version 12.1.0 ... newer than target minimum of 11.0.0") into an older target.
MINVER="${MACOSX_DEPLOYMENT_TARGET:-12.1}"
extra=(-headerpad_max_install_names)
out=""; prev=""; args=()
while [ $# -gt 0 ]; do
  if [ "$1" = "-platform_version" ]; then
    args+=("$1" "$2" "$MINVER" "$4"); shift 4; continue   # platform, min->MINVER, sdk
  fi
  [ "$prev" = "-o" ] && out="$1"
  prev="$1"; args+=("$1"); shift
done
case "$out" in
  *.dylib) extra+=(-install_name "@rpath/$(basename "$out")" -llcms2 -lopenjp2 -lfreetype) ;;
esac
exec ld64.lld "${args[@]}" "${extra[@]}"
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
#   - zlib/libpng/lcms2/openjpeg/libtiff: self-contained image/compression libs.
#   - freetype: font engine (build_native sets pdf_bundle_freetype=false); high
#     CVE surface, so a valuable one to track. (libjpeg/icu stay vendored for now
#     -- the 12-bit libjpeg path / pdfium's ICU version coupling; a later wave.)
# --no-libclang-rt: don't require libclang_rt.builtins.a (use libgcc). -j honours
# the conda build CPU allocation.
_UNVENDOR="libc++ zlib libpng lcms2 openjpeg libtiff freetype"
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
