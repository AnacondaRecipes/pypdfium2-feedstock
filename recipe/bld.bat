@echo off
REM ===========================================================================
REM win-64 pdfium source build via pypdfium2 sourcebuild-toolchained backend
REM (depot_tools + gclient sync + Google prebuilt clang + local MSVC/Windows SDK).
REM
REM AMI PREREQUISITE (not conda-expressible; must exist on the win-64 worker):
REM   Windows SDK 10.0.26100 "Debugging Tools for Windows" feature -- pdfium's
REM   vs_toolchain.py copies Debuggers\x64\dbghelp.dll during gn gen.
REM MinGit is self-provisioned below (depot_tools rejects conda git, which lacks
REM the Git-for-Windows layout its bootstrap looks for).
REM ===========================================================================
set DEPOT_TOOLS_WIN_TOOLCHAIN=0

REM depot_tools bootstrap needs a Git-for-Windows-layout git (an ancestor dir named
REM "Git" with cmd\git.exe); conda git does not qualify. Provision MinGit at C:\Git
REM if the worker doesn't already have one.
if not exist C:\Git\cmd\git.exe (
  echo Provisioning MinGit at C:\Git ...
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/git-for-windows/git/releases/download/v2.55.0.windows.3/MinGit-2.55.0.3-64-bit.zip' -OutFile \"$env:TEMP\MinGit.zip\"; Expand-Archive -Path \"$env:TEMP\MinGit.zip\" -DestinationPath C:\Git -Force"
  if errorlevel 1 exit 1
)
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
