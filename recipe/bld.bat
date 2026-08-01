@echo off
REM ===========================================================================
REM win-64 pdfium source build via pypdfium2 sourcebuild-toolchained backend
REM (depot_tools + gclient sync + Google prebuilt clang + local MSVC/Windows SDK).
REM
REM AMI PREREQUISITES (not conda-expressible; must exist on the win-64 worker):
REM   1. MinGit (Git-for-Windows) at C:\Git -- depot_tools bootstrap rejects conda
REM      git; it requires an ancestor dir named "Git" with cmd\git.exe.
REM   2. Windows SDK 10.0.26100 "Debugging Tools for Windows" feature -- pdfium's
REM      vs_toolchain.py copies Debuggers\x64\dbghelp.dll during gn gen.
REM ===========================================================================
set DEPOT_TOOLS_WIN_TOOLCHAIN=0
REM depot_tools needs a Git-for-Windows-layout git ahead of conda git on PATH
set PATH=C:\Git\cmd;%PATH%
REM ctypesgen auto-selects cl.exe under vs2022 (its -E output is unparseable);
REM force clang. An explicit CPP is used verbatim, so it must include the -E flag.
set CPP=clang -E
REM 1) build pdfium from source (writes data\sourcebuild\{pdfium.dll,bindings.py})
"%PYTHON%" setupsrc\build_toolchained.py
if errorlevel 1 exit 1
REM 2) wrap the built pdfium into the package; ctypesgen (host) regenerates bindings
set PDFIUM_PLATFORM=sourcebuild
"%PYTHON%" -m pip install . -vv --no-deps --no-build-isolation
if errorlevel 1 exit 1
