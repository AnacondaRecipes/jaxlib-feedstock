:: https://docs.jax.dev/en/latest/developer.html#building-jaxlib-from-source
:: https://docs.jax.dev/en/latest/developer.html#additional-notes-for-building-jaxlib-from-source-on-windows

@echo on
setlocal EnableDelayedExpansion

set BAZEL_VS="%VSINSTALLDIR%"
set BAZEL_VC="%VSINSTALLDIR%/VC"
set CLANG_COMPILER_PATH=%BUILD_PREFIX:\=/%/Library/bin/clang.exe
set BAZEL_LLVM=%BUILD_PREFIX:\=/%/Library/

@REM   - if JAX_RELEASE or JAXLIB_RELEASE are set: version looks like "0.4.16"
@REM   - if JAX_NIGHTLY or JAXLIB_NIGHTLY are set: version looks like "0.4.16.dev20230906"
@REM   - if none are set: version looks like "0.4.16.dev20230906+ge58560fdc
set JAXLIB_RELEASE=1

@REM Note: TF_SYSTEM_LIBS don't work on windows per https://github.com/openxla/xla/blob/edf18ce242f234fbd20d1fbf4e9c96dfa5be2847/.bazelrc#L383

:: Needed for XLA to pull in dependencies.
echo common --experimental_repo_remote_exec > .bazelrc

:: Make sure to pass clang environment vars into the bazel build.
if defined CFLAGS (
  for /f "tokens=1* delims= " %%a in ("!CFLAGS!") do (
    echo build --copt=%%a >> .bazelrc
    echo build --host_copt=%%a >> .bazelrc
    set "LIST=%%b"
    :recurse1
    if defined LIST (
      for /f "tokens=1* delims= " %%d in ("!LIST!") do (
        echo build --copt=%%d >> .bazelrc
        echo build --host_copt=%%d >> .bazelrc
        set "LIST=%%e"
      )
      goto recurse1
    )
  )
)
if defined CXXFLAGS (
  for /f "tokens=1* delims= " %%a in ("!CXXFLAGS!") do (
    echo build --cxxopt=%%a >> .bazelrc
    echo build --host_cxxopt=%%a >> .bazelrc
    set "LIST=%%b"
    :recurse2
    if defined LIST (
      for /f "tokens=1* delims= " %%d in ("!LIST!") do (
        echo build --cxxopt=%%d >> .bazelrc
        echo build --host_cxxopt=%%d >> .bazelrc
        set "LIST=%%e"
      )
      goto recurse2
    )
  )
)
if defined LDFLAGS (
  for /f "tokens=1* delims= " %%a in ("!LDFLAGS!") do (
    echo build --linkopt=%%a >> .bazelrc
    set "LIST=%%b"
    :recurse3
    if defined LIST (
      for /f "tokens=1* delims= " %%d in ("!LIST!") do (
        echo build --linkopt=%%d >> .bazelrc
        set "LIST=%%e"
      )
      goto recurse3
    )
  )
)

:: Set min C++ standard in a format MSVC understands.
echo build --cxxopt=/std:c++17 >> .bazelrc
echo build --host_cxxopt=/std:c++17 >> .bazelrc
echo build --cxxopt=/Zc:__cplusplus >> .bazelrc
echo build --host_cxxopt=/Zc:__cplusplus >> .bazelrc

:: Force winsock2.h to be included before any windows.h gets pulled in to avoid redefinition conflicts.
echo build --copt=/FIwinsock2.h >> .bazelrc
echo build --cxxopt=/FIwinsock2.h >> .bazelrc

echo build --logging=6 >> .bazelrc
echo build --verbose_failures >> .bazelrc
echo build --toolchain_resolution_debug >> .bazelrc
echo build --define=PREFIX=%PREFIX:\=/% >> .bazelrc
echo build --define=PROTOBUF_INCLUDE_PATH=%PREFIX:\=/%/include >> .bazelrc
::echo build --local_resources=cpu=%CPU_COUNT% >> .bazelrc
echo build --local_resources=cpu=8 >> .bazelrc
echo build --repo_env=GRPC_BAZEL_DIR=%PREFIX:\=/%/share/bazel/grpc/bazel >> .bazelrc

:: TODO: The upstream docs say CUDA on Windows is not officially supported but their build docs say otherwise. IDK
::       which is right.
%PYTHON% build/build.py build ^
  --verbose ^
  --wheels=jaxlib ^
  --use_clang=true ^
  --clang_path=%CLANG_COMPILER_PATH% ^
  --disable_mkl_dnn ^
  --bazel_options="--config=win_clang"
if %ERRORLEVEL% NEQ 0 exit %ERRORLEVEL%

bazel clean --expunge
bazel shutdown

%PYTHON% -m pip install --find-links=dist jaxlib --no-build-isolation --no-deps -vv
if %ERRORLEVEL% NEQ 0 exit %ERRORLEVEL%

copy %PREFIX%\Lib\site-packages\jaxlib\mlir\_mlir_libs\*.dll %LIBRARY_BIN%\
