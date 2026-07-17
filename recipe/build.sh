#!/bin/bash
set -euo pipefail

# Build PDFium from source in-tree via pypdfium2's *native* sourcebuild backend
# (setupsrc/build_native.py). This self-manages the pdfium checkout (fetching dep
# revisions dynamically from pdfium's DEPS file) and builds with the *system*
# toolchain -- conda's gcc/g++ on Linux (clang on macOS), conda `gn`, and conda
# `ninja` (ninja-base). It deliberately avoids Google's hermetic binary toolchain,
# so the whole DEPS list + patch set is maintained upstream, not in this recipe.
export PDFIUM_PLATFORM="sourcebuild-native"

# --- macOS SDK discovery + find_sdk redirect --------------------------------
# pdfium's build/mac/find_sdk.py demands a minimum macOS SDK and looks ONLY under
# $DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs (i.e. Xcode.app), which on
# the PBP worker has only an 11.3-named SDK -- even though CommandLineTools actually
# holds real MacOSX14.5.sdk / 15.2.sdk. Diagnostic first (crash-proofed: it runs in a
# subshell with pipefail off so `find|head` SIGPIPE etc. can't fail the build), then
# a fake DEVELOPER_DIR that mirrors the real one but exposes the real 14.5 SDK so
# find_sdk accepts it and pdfium builds against genuine 14.5 headers.
if [[ "$(uname)" == "Darwin" ]]; then
    ( set +e +o pipefail
      echo "===== macOS SDK DIAGNOSTIC ====="
      echo "-- xcode-select -p --"; xcode-select -p
      echo "-- CONDA_BUILD_SYSROOT --"; echo "${CONDA_BUILD_SYSROOT:-<unset>}"
      echo "-- CommandLineTools SDKs --"; ls -l /Library/Developer/CommandLineTools/SDKs/
      echo "-- Xcode.app SDKs --"; ls -l "$(xcode-select -p)/Platforms/MacOSX.platform/Developer/SDKs/"
      echo "-- xcodebuild -showsdks --"; xcodebuild -showsdks 2>&1 | grep -i macos
      echo "-- xcrun sdk --"; xcrun --show-sdk-version; xcrun --show-sdk-path
      echo "===== END SDK DIAGNOSTIC ====="
    ) 2>&1 || true

    # Pick the newest real CommandLineTools SDK (14.5/15.2 if present), else the sysroot.
    _CLT_SDK=""
    for _cand in MacOSX15.2 MacOSX14.5 MacOSX13.3 MacOSX12.3; do
        _p="/Library/Developer/CommandLineTools/SDKs/${_cand}.sdk"
        [ -d "$_p" ] && { _CLT_SDK="$_p"; break; }
    done
    [ -n "$_CLT_SDK" ] || _CLT_SDK="${CONDA_BUILD_SYSROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX12.1.sdk}"

    _REAL_DEV="$(xcode-select -p 2>/dev/null || echo /Applications/Xcode.app/Contents/Developer)"
    _FAKE_DEV="${SRC_DIR}/_fake_dev"
    mkdir -p "$_FAKE_DEV/Platforms/MacOSX.platform/Developer/SDKs"
    # mirror the real developer dir top-level entries so DEVELOPER_DIR tool lookups still work
    for _e in "$_REAL_DEV"/*; do
        [ "$(basename "$_e")" = "Platforms" ] && continue
        ln -sf "$_e" "$_FAKE_DEV/$(basename "$_e")"
    done
    _SDKS="$_FAKE_DEV/Platforms/MacOSX.platform/Developer/SDKs"
    for _s in "$_REAL_DEV"/Platforms/MacOSX.platform/Developer/SDKs/*; do
        [ -e "$_s" ] && ln -sf "$_s" "$_SDKS/$(basename "$_s")"
    done
    # expose the real newest CLT SDK under its own name so find_sdk.py's ">=min" passes
    ln -sf "$_CLT_SDK" "$_SDKS/$(basename "$_CLT_SDK")"
    export DEVELOPER_DIR="$_FAKE_DEV"
    echo "Redirected DEVELOPER_DIR=$DEVELOPER_DIR (exposing real SDK $_CLT_SDK)"
fi
# ---------------------------------------------------------------------------

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

# Linux only: pdfium's system-freetype config (freetype_from_pkgconfig) also runs
# pkg_config("gio_config") for gio-2.0/gio-unix-2.0. pdfium doesn't use gio
# (use_glib=false), but `gn gen` errors if pkg-config can't resolve them. Provide
# empty stub .pc files so the query succeeds without pulling glib into the deps.
if [[ "$(uname)" != "Darwin" ]]; then
    _STUB_PC="${SRC_DIR}/_stub_pc"
    mkdir -p "$_STUB_PC"
    for _p in gio-2.0 gio-unix-2.0; do
        printf 'Name: %s\nVersion: 2.0\nDescription: stub for pdfium gn gen\nLibs:\nCflags:\n' \
            "$_p" > "$_STUB_PC/${_p}.pc"
    done
    export PKG_CONFIG_PATH="${_STUB_PC}${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
fi

# macOS toolchain shims (we force clang mode below -- see BUILD_PARAMS):
#   1. `ar` -> llvm-ar: pdfium archives static libs with `ar -r -c -D`, and Apple's
#      /usr/bin/ar has no -D flag (GNU ar on Linux does, which is why Linux is clean).
#   2. ld.lld wrapper: re-exec as ld64.lld (Mach-O flavor) + relocation/version fixups.
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
    export PATH="$_SHIM:$PATH"   # put the ar shim ahead of Apple's /usr/bin/ar
fi

# Vendor pdfium's bundled third-party libs, EXCEPT the ones listed here, which we
# link from the conda host packages instead (--no-vendor sets pdfium's GN
# use_system_<lib>). Unvendoring makes each a real conda run dep (via run_exports),
# so vulnerability trackers see them -- the point of building them separately.
#   - libc++: use the system C++ stdlib (libstdc++ with conda gcc).
#   - zlib/lcms2/openjpeg: self-contained codec/compression libs pdfium links.
#   - freetype: font engine (build_native sets pdf_bundle_freetype=false); high
#     CVE surface, so a valuable one to track.
# Only the four above are *tracked* (also in host: -> run via run_exports). libpng
# and libtiff are also --no-vendor'd but NOT put in host: they are XFA-only codecs
# and pdf_enable_xfa=false here, so pdfium never compiles/links them -- but their
# vendored third_party/*/BUILD.gn reference third_party/zlib/BUILD.gn, which breaks
# `gn gen` once zlib is unvendored. Passing --no-vendor gates their vendored BUILD.gn
# out (use_system_*), fixing gn gen, while omitting them from host keeps them off the
# dependency graph (no false run dep -- verified: not in DT_NEEDED). (libjpeg/icu
# stay fully vendored -- 12-bit libjpeg path / ICU version coupling.)
# --no-libclang-rt: don't require libclang_rt.builtins.a (use libgcc). -j honours
# the conda build CPU allocation.
_UNVENDOR="libc++ zlib lcms2 openjpeg freetype libpng libtiff"
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
