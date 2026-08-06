@echo off
REM ===========================================================================
REM win-64 pdfium source build via pypdfium2's sourcebuild-toolchained backend
REM (depot_tools + gclient sync + Google prebuilt clang + local MSVC/Windows SDK).
REM No worker-AMI changes required: MinGit is self-provisioned, and pdfium's
REM debugger-DLL copy (which would otherwise need the SDK "Debugging Tools"
REM feature) is patched out -- dbghelp is not needed for the shipped release lib.
REM ===========================================================================
set DEPOT_TOOLS_WIN_TOOLCHAIN=0

REM depot_tools' bootstrap only accepts a Git-for-Windows-layout git: an ancestor
REM dir named "Git" with cmd\git.exe, or an MSYS2 ucrt64/clang64/clangarm64 tree.
REM Neither conda `git` (Library\bin\git.exe) nor `msys2-git` (Library\usr\bin)
REM matches, so provision MinGit (the GfW portable layout) if absent. The download
REM is SHA-256 pinned (git-for-windows' published checksum for this exact asset) and
REM verified before extraction, so a tampered/MITM'd zip fails the build.
REM (goto-label rather than an if(...) block: the PowerShell below contains parens
REM inside its quoted -Command, which cmd's parenthesized-block parser mishandles.)
if exist C:\Git\cmd\git.exe goto mingit_ready
echo Provisioning MinGit at C:\Git ...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; $zip=\"$env:TEMP\MinGit.zip\"; $sha='f48e2d2dc74a24454adc6d8fd0ac25bf9c2386f19cfb06202b9465aaad4f9f05'; Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/git-for-windows/git/releases/download/v2.55.0.windows.3/MinGit-2.55.0.3-64-bit.zip' -OutFile $zip; $h=(Get-FileHash -Algorithm SHA256 $zip).Hash.ToLower(); if ($h -ne $sha) { throw \"MinGit SHA-256 mismatch: got $h expected $sha\" }; Expand-Archive -Path $zip -DestinationPath C:\Git -Force"
if errorlevel 1 exit 1
:mingit_ready
set PATH=C:\Git\cmd;%PATH%
REM allow `git apply` on the gclient-synced pdfium checkout regardless of owner
git config --global --add safe.directory "*"

REM ctypesgen auto-selects cl.exe under vs2022 (unparseable -E); force clang -E.
set CPP=clang -E

REM Pass 1: sync the pdfium checkout (then gn gen, which fails on the debugger-DLL
REM copy -- patched out below). depot_tools' gsutil bootstrap occasionally fails to
REM lock its shared cache under gclient's parallel DEPS fetches (a known transient,
REM not a recipe issue); a re-run resumes the checkout. Retry only until pdfium's gn
REM binary is present (i.e. the sync completed) -- real build failures surface later
REM at gn gen / ninja and are NOT retried here.
set _tries=0
:sync_loop
"%PYTHON%" setupsrc\build_toolchained.py
if exist sbuild\toolchained\pdfium\buildtools\win\gn.exe goto synced
set /a _tries+=1
if %_tries% GEQ 4 (echo ERROR: pdfium sync did not complete after %_tries% attempts & exit 1)
echo pdfium sync incomplete ^(attempt %_tries%^), retrying...
goto sync_loop
:synced

REM Skip pdfium's debugger-DLL copy. vs_toolchain.py copies dbghelp/dbgcore/etc.
REM from the SDK "Debugging Tools" feature purely as a crash-symbolization aid for
REM pdfium's own tests; the shipped conda package is just pdfium.dll, so removing
REM the copy drops that AMI-only dependency. Applied as a reviewable patch.
pushd sbuild\toolchained\pdfium
git apply --ignore-whitespace "%RECIPE_DIR%\patches\skip-debugger-dll-copy.patch"
if errorlevel 1 (popd & echo ERROR: skip-debugger-dll-copy.patch failed to apply & exit 1)
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
