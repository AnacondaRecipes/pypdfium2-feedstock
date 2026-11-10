@echo off
REM ===========================================================================
REM win pdfium source build via pypdfium2's sourcebuild-toolchained backend
REM (depot_tools + gclient sync + Google prebuilt clang + local MSVC/Windows SDK).
REM No worker-AMI changes required: MinGit is self-provisioned (host-arch matched,
REM see below), and pdfium's debugger-DLL copy (which would otherwise need the SDK
REM "Debugging Tools" feature) is patched out -- dbghelp is not needed for the
REM shipped release lib.
REM ===========================================================================
set DEPOT_TOOLS_WIN_TOOLCHAIN=0

REM gsutil (used by pdfium's test_fonts hook) otherwise unpacks into the checkout,
REM where one file sits ~185 chars below the pdfium dir and trips Windows' 260-char
REM MAX_PATH on longer build paths -- gclient sync then fails and pypdfium2's patch
REM phase is skipped. gsutil.py honours this var; depot_tools uses %TEMP% itself.
if defined TEMP set "DEPOT_TOOLS_GSUTIL_BIN_DIR=%TEMP%\depot_tools_gsutil"

REM depot_tools' bootstrap only accepts a Git-for-Windows-layout git: an ancestor
REM dir named "Git" with cmd\git.exe, or an MSYS2 ucrt64/clang64/clangarm64 tree.
REM Neither conda `git` (Library\bin\git.exe) nor `msys2-git` (Library\usr\bin)
REM matches, so provision MinGit (the GfW portable layout) if absent. The asset must
REM match the host arch: the win-64 build is a `mingw64` tree, the win-arm64 build a
REM `clangarm64` tree, and an x64 git cannot run on Windows Server arm64. The
REM download is SHA-256 pinned (git-for-windows' published checksum for this exact
REM asset) and verified before extraction, so a tampered/MITM'd zip fails the build.
REM (goto-label rather than an if(...) block: the PowerShell below contains parens
REM inside its quoted -Command, which cmd's parenthesized-block parser mishandles.)
set "MINGIT_BASE=https://github.com/git-for-windows/git/releases/download/v2.55.0.windows.3/MinGit-2.55.0.3"
if /I "%target_platform%"=="win-arm64" (
    set "MINGIT_URL=%MINGIT_BASE%-arm64.zip"
    set "MINGIT_SHA=f7748965d5068e81ad93ca1923650db6742d6e22332b1ae7567a841c59f6bde5"
) else (
    set "MINGIT_URL=%MINGIT_BASE%-64-bit.zip"
    set "MINGIT_SHA=f48e2d2dc74a24454adc6d8fd0ac25bf9c2386f19cfb06202b9465aaad4f9f05"
)
REM An extraction drops C:\Git\.pypdfium2-minigit-arch, so a tree this recipe made
REM may be replaced, whereas a foreign one (e.g. baked into the worker image) is
REM never deleted. Reuse a tree only if it actually runs: workers are shared across
REM platforms, so a lone x64 MinGit can be left sitting on an arm64 machine.
if exist "C:\Git\.pypdfium2-minigit-arch" set "MINGIT_OURS=1"
if not exist C:\Git\cmd\git.exe goto mingit_replace
C:\Git\cmd\git.exe --version >nul 2>&1
if not errorlevel 1 goto mingit_ready
if not defined MINGIT_OURS (echo ERROR: C:\Git does not run on this host and was not provisioned by this recipe & exit 1)
:mingit_replace
echo Provisioning MinGit for %target_platform% at C:\Git ...
if defined MINGIT_OURS rmdir /s /q C:\Git
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; $zip=\"$env:TEMP\MinGit.zip\"; Invoke-WebRequest -UseBasicParsing -Uri $env:MINGIT_URL -OutFile $zip; $h=(Get-FileHash -Algorithm SHA256 $zip).Hash.ToLower(); if ($h -ne $env:MINGIT_SHA) { throw \"MinGit SHA-256 mismatch: got $h expected $env:MINGIT_SHA\" }; Expand-Archive -Path $zip -DestinationPath C:\Git -Force"
if errorlevel 1 exit 1
> "C:\Git\.pypdfium2-minigit-arch" echo %target_platform%
:mingit_ready
set PATH=C:\Git\cmd;%PATH%
REM allow `git apply` on the gclient-synced pdfium checkout regardless of owner
git config --global --add safe.directory "*"

REM ctypesgen auto-selects cl.exe under vs2022 (unparseable -E); force clang -E.
set CPP=clang -E

REM vs_toolchain.py finds the local VS only via %ProgramFiles%\Microsoft Visual
REM Studio\<year>\<edition> or an explicit vs<year>_install hint (it never calls
REM vswhere), and the conda vs2022 activation may have located the install under
REM %ProgramFiles(x86)%, which that probe misses -- gn gen then dies in
REM GetVisualStudioVersion(). Pass the located path on through the hint.
if defined VS_YEAR if defined VSINSTALLDIR set "vs%VS_YEAR%_install=%VSINSTALLDIR%"

REM Pass 1: sync the pdfium checkout (then gn gen, which fails on the debugger-DLL
REM copy -- patched out below). depot_tools' gsutil bootstrap occasionally fails to
REM lock its shared cache under gclient's parallel DEPS fetches (a known transient,
REM not a recipe issue). Retry until pypdfium2's patch phase has run (resources.rc),
REM not merely until gn.exe exists: that is fetched before the fail-prone hooks, and
REM dl_pdfium only re-syncs an absent checkout, so a retry drops it first. Real build
REM failures surface later at gn gen / ninja and are NOT retried here.
set _tries=0
:sync_loop
"%PYTHON%" setupsrc\build_toolchained.py
if exist sbuild\toolchained\pdfium\resources.rc goto synced
set /a _tries+=1
if %_tries% GEQ 3 (echo ERROR: pdfium sync/patches did not complete after %_tries% attempts -- see the gclient output above & exit 1)
echo pdfium sync/patches incomplete ^(attempt %_tries%^), retrying from a clean checkout...
rmdir /s /q sbuild\toolchained\pdfium
goto sync_loop
:synced

REM Skip pdfium's debugger-DLL copy. vs_toolchain.py copies dbghelp/dbgcore/etc.
REM from the SDK "Debugging Tools" feature purely as a crash-symbolization aid for
REM pdfium's own tests; the shipped conda package is just pdfium.dll, so removing
REM the copy drops that AMI-only dependency. Applied as a reviewable patch; arm64
REM needs its own, because pypdfium2's arm64_native.patch has already removed the
REM win_clang_x64 block that the win-64 patch's context relies on.
set "SKIP_DBG_PATCH=skip-debugger-dll-copy.patch"
if /I "%target_platform%"=="win-arm64" set "SKIP_DBG_PATCH=skip-debugger-dll-copy-arm64.patch"
pushd sbuild\toolchained\pdfium
if /I "%target_platform%"=="win-arm64" findstr /m /c:"win_clang_x64" build\vs_toolchain.py >nul 2>&1
if /I "%target_platform%"=="win-arm64" if not errorlevel 1 (popd & echo ERROR: build\vs_toolchain.py still contains the win_clang_x64 block, so pypdfium2's arm64_native.patch did not apply & exit 1)
git apply --ignore-whitespace "%RECIPE_DIR%\patches\%SKIP_DBG_PATCH%"
if errorlevel 1 (popd & echo ERROR: %SKIP_DBG_PATCH% failed to apply & exit 1)
popd

REM Pass 2: reuse the synced checkout; `gn gen` (generate the ninja build files from
REM pdfium's GN config) now succeeds, then ninja builds pdfium and packs data\sourcebuild\.
"%PYTHON%" setupsrc\build_toolchained.py
if errorlevel 1 exit 1

REM Wrap the built pdfium into the package. PDFIUM_PLATFORM=sourcebuild tells
REM pypdfium2 to consume the pdfium we just built (data\sourcebuild\pdfium.dll);
REM "toolchained" refers to HOW that pdfium was built (build_toolchained.py above),
REM matching upstream's own sbuild_one.yaml. ctypesgen (host) regenerates bindings.
set PDFIUM_PLATFORM=sourcebuild
"%PYTHON%" -m pip install . -vv --no-deps --no-build-isolation
if errorlevel 1 exit 1
