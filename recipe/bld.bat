@echo off
setlocal enabledelayedexpansion

REM Build PDFium from source in-tree via pypdfium2's *toolchained* sourcebuild
REM backend (setupsrc/build_toolchained.py). build_native has no MSVC path, so on
REM Windows pypdfium2 uses depot_tools + gclient to fetch Google's hermetic
REM clang/gn/ninja toolchain; the local MSVC install (from the C/C++ compiler
REM dep) supplies the Windows SDK. DEPOT_TOOLS_WIN_TOOLCHAIN=0 is set internally
REM by the backend so it uses the local toolchain rather than Google's internal one.
set PDFIUM_PLATFORM=sourcebuild-toolchained

%PYTHON% -m pip install . -vv --no-deps --no-build-isolation
if errorlevel 1 exit 1
