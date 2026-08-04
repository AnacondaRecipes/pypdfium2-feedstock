@echo off
REM ===========================================================================
REM win-64 pdfium source build via pypdfium2 sourcebuild-toolchained backend
REM (depot_tools + gclient sync + Google prebuilt clang + local MSVC/Windows SDK).
REM No worker-AMI changes required: MinGit is self-provisioned, and pdfium's
REM debugger-DLL copy (which would otherwise need the SDK "Debugging Tools"
REM feature) is patched out -- dbghelp is not needed for the shipped release lib.
REM ===========================================================================
set DEPOT_TOOLS_WIN_TOOLCHAIN=0

REM depot_tools bootstrap needs a Git-for-Windows-layout git; provision MinGit.
if not exist C:\Git\cmd\git.exe (
  echo Provisioning MinGit at C:\Git ...
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/git-for-windows/git/releases/download/v2.55.0.windows.3/MinGit-2.55.0.3-64-bit.zip' -OutFile \"$env:TEMP\MinGit.zip\"; Expand-Archive -Path \"$env:TEMP\MinGit.zip\" -DestinationPath C:\Git -Force"
  if errorlevel 1 exit 1
)
set PATH=C:\Git\cmd;%PATH%

REM ctypesgen auto-selects cl.exe under vs2022 (unparseable -E); force clang -E.
set CPP=clang -E

REM Pass 1: sync the pdfium checkout (+ first gn gen). gclient's gsutil DEPS hooks
REM can flake transiently (lockfile error), leaving the checkout without gn; each
REM re-run resumes the sync, so retry until gn is present. Once the checkout has
REM gn, sync is complete and gn gen will have failed only on the dbghelp step,
REM which the patch below removes.
set _tries=0
:sync_loop
"%PYTHON%" setupsrc\build_toolchained.py
if exist sbuild\toolchained\pdfium\buildtools\win\gn.exe goto synced
set /a _tries+=1
if %_tries% GEQ 4 (echo ERROR: gclient sync did not complete after %_tries% attempts & exit 1)
echo pdfium sync incomplete ^(attempt %_tries%^), retrying...
goto sync_loop
:synced

REM Patch out the _CopyDebugger CALL (keeps CopyDlls' release-CRT copy intact).
REM dbghelp is only a crash-symbolization aid for pdfium's own tests; the shipped
REM package contains only pdfium.dll, so this removes the SDK-feature dependency.
"%PYTHON%" -c "import pathlib,re; p=pathlib.Path(r'sbuild/toolchained/pdfium/build/vs_toolchain.py'); s=p.read_text(); n,c=re.subn(r'(?<!def )_CopyDebugger\(target_dir, target_cpu\)','pass  # _CopyDebugger disabled (dbghelp not needed for shipped release lib)',s); assert c>=1,'patch site not found'; p.write_text(n); print('patched _CopyDebugger call(s):',c)"
if errorlevel 1 exit 1

REM Pass 2: reuse the synced checkout (skips gclient), re-run gn gen (now clean)
REM + ninja build, then pack data\sourcebuild\.
"%PYTHON%" setupsrc\build_toolchained.py
if errorlevel 1 exit 1

REM Wrap the built pdfium into the package; ctypesgen (host) regenerates bindings.
set PDFIUM_PLATFORM=sourcebuild
"%PYTHON%" -m pip install . -vv --no-deps --no-build-isolation
if errorlevel 1 exit 1
