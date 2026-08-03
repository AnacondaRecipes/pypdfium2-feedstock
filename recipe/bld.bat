@echo off
REM win-64 pdfium source build via pypdfium2's sourcebuild-toolchained backend
REM (depot_tools + gclient sync + Google prebuilt clang + local MSVC/Windows SDK).
set DEPOT_TOOLS_WIN_TOOLCHAIN=0

REM pdfium's gn-gen hook (vs_toolchain.py copy_dlls) hard-requires the SDK
REM "Debugging Tools" dbghelp.dll -- only dbghelp.dll is mandatory, and it is
REM copied into out/ for crash-symbolization tooling this build never runs.
REM Self-disables once the worker AMI ships the real feature (SIR-3688).
set "_DBG_DIR=%ProgramFiles(x86)%\Windows Kits\10\Debuggers\x64"
if not exist "%_DBG_DIR%\dbghelp.dll" (
  mkdir "%_DBG_DIR%" 2>nul
  copy /y "%SystemRoot%\System32\dbghelp.dll" "%_DBG_DIR%\" >nul
  if errorlevel 1 exit 1
)

REM ctypesgen auto-selects cl.exe under vs2022 (its -E output is unparseable);
REM force clang. An explicit CPP is used verbatim, so it must include the -E flag.
set CPP=clang -E

REM 1) build pdfium from source (writes data\sourcebuild\{pdfium.dll,bindings.py})
"%PYTHON%" setupsrc\build_toolchained.py
if errorlevel 1 exit 1

REM 2) win keeps all deps vendored (statically linked into pdfium.dll) -- collect
REM their license texts from the synced tree so they ship in the conda package.
"%PYTHON%" "%RECIPE_DIR%\collect_vendored_licenses.py" "%SRC_DIR%\sbuild\toolchained\pdfium\third_party" "%SRC_DIR%\vendored-licenses.txt"
if errorlevel 1 exit 1

REM 3) wrap the built pdfium into the package; ctypesgen (host) regenerates bindings
set PDFIUM_PLATFORM=sourcebuild
"%PYTHON%" -m pip install . -vv --no-deps --no-build-isolation
if errorlevel 1 exit 1
