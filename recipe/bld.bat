:: https://docs.jax.dev/en/latest/developer.html#building-jaxlib-from-source
:: https://docs.jax.dev/en/latest/developer.html#additional-notes-for-building-jaxlib-from-source-on-windows

@echo on
setlocal EnableDelayedExpansion

set BAZEL_VS="%VSINSTALLDIR%"
set BAZEL_VC="%VSINSTALLDIR%/VC"
set BAZEL_LLVM=%BUILD_PREFIX:\=/%/Library/

set CLANG_COMPILER_PATH=%BUILD_PREFIX:\=/%/Library/bin/clang.exe
set CLANG_CL_PATH=%BUILD_PREFIX:\=/%/Library/bin/clang-cl.exe

@REM   - if JAX_RELEASE or JAXLIB_RELEASE are set: version looks like "0.4.16"
@REM   - if JAX_NIGHTLY or JAXLIB_NIGHTLY are set: version looks like "0.4.16.dev20230906"
@REM   - if none are set: version looks like "0.4.16.dev20230906+ge58560fdc
set JAXLIB_RELEASE=1

@REM Note: TF_SYSTEM_LIBS don't work on windows per https://github.com/openxla/xla/blob/edf18ce242f234fbd20d1fbf4e9c96dfa5be2847/.bazelrc#L383

:: Needed for XLA to pull in dependencies.
echo common --experimental_repo_remote_exec >> .bazelrc.user

@REM :: Make sure to pass clang environment vars into the bazel build.
@REM if defined CFLAGS (
@REM   for /f "tokens=1* delims= " %%a in ("!CFLAGS!") do (
@REM     echo build --copt=%%a >> .bazelrc.user
@REM     echo build --host_copt=%%a >> .bazelrc.user
@REM     set "LIST=%%b"
@REM     :recurse1
@REM     if defined LIST (
@REM       for /f "tokens=1* delims= " %%d in ("!LIST!") do (
@REM         echo build --copt=%%d >> .bazelrc.user
@REM         echo build --host_copt=%%d >> .bazelrc.user
@REM         set "LIST=%%e"
@REM       )
@REM       goto recurse1
@REM     )
@REM   )
@REM )
@REM if defined CXXFLAGS (
@REM   for /f "tokens=1* delims= " %%a in ("!CXXFLAGS!") do (
@REM     echo build --cxxopt=%%a >> .bazelrc.user
@REM     echo build --host_cxxopt=%%a >> .bazelrc.user
@REM     set "LIST=%%b"
@REM     :recurse2
@REM     if defined LIST (
@REM       for /f "tokens=1* delims= " %%d in ("!LIST!") do (
@REM         echo build --cxxopt=%%d >> .bazelrc.user
@REM         echo build --host_cxxopt=%%d >> .bazelrc.user
@REM         set "LIST=%%e"
@REM       )
@REM       goto recurse2
@REM     )
@REM   )
@REM )
@REM if defined LDFLAGS (
@REM   for /f "tokens=1* delims= " %%a in ("!LDFLAGS!") do (
@REM     echo build --linkopt=%%a >> .bazelrc.user
@REM     set "LIST=%%b"
@REM     :recurse3
@REM     if defined LIST (
@REM       for /f "tokens=1* delims= " %%d in ("!LIST!") do (
@REM         echo build --linkopt=%%d >> .bazelrc.user
@REM         set "LIST=%%e"
@REM       )
@REM       goto recurse3
@REM     )
@REM   )
@REM )

:: Set min C++ standard in a format MSVC understands.
echo build --cxxopt=/std:c++17 >> .bazelrc.user
echo build --host_cxxopt=/std:c++17 >> .bazelrc.user
echo build --cxxopt=/Zc:__cplusplus >> .bazelrc.user
echo build --host_cxxopt=/Zc:__cplusplus >> .bazelrc.user

:: Force winsock2.h to be included before any windows.h gets pulled in to avoid redefinition conflicts.
echo build --copt=/FIwinsock2.h >> .bazelrc.user
echo build --cxxopt=/FIwinsock2.h >> .bazelrc.user

echo build --logging=6 >> .bazelrc.user
echo build --verbose_failures >> .bazelrc.user
echo build --toolchain_resolution_debug >> .bazelrc.user
echo build --define=PREFIX=%PREFIX:\=/% >> .bazelrc.user
echo build --define=PROTOBUF_INCLUDE_PATH=%PREFIX:\=/%/include >> .bazelrc.user
echo build --local_resources=cpu=%CPU_COUNT% >> .bazelrc.user
echo build --repo_env=GRPC_BAZEL_DIR=%PREFIX:\=/%/share/bazel/grpc/bazel >> .bazelrc.user

:: Make sure Bazel uses clang
echo build --action_env=CC=%CLANG_CL_PATH% >> .bazelrc.user
echo build --action_env=CXX=%CLANG_CL_PATH% >> .bazelrc.user
echo build --repo_env=CC=%CLANG_CL_PATH% >> .bazelrc.user
echo build --repo_env=CXX=%CLANG_CL_PATH% >> .bazelrc.user
echo build --repo_env=BAZEL_USE_CPP_ONLY_TOOLCHAIN=1 >> .bazelrc.user

:: Prevent leaking Windows macros that conflict with stdlib
echo build --copt=-DNOMINMAX >> .bazelrc.user
echo build --copt=-DWIN32_LEAN_AND_MEAN >> .bazelrc.user
echo build --copt=-UOPTIONAL >> .bazelrc.user

:: Debugging bazel & clang-cl
@REM clang-cl /?
@REM where clang-cl
@REM bazel info execution_root
@REM bazel query --output=build //jax/tools/toolchains:x64_windows-clang-cl

:: TODO: The upstream docs say CUDA on Windows is not officially supported but their build docs say otherwise. IDK
::       which is right.
%PYTHON% build/build.py build ^
  --verbose ^
  --wheels=jaxlib ^
  --use_clang=true ^
  --clang_path=%CLANG_COMPILER_PATH% ^
  --disable_mkl_dnn ^
  --python_version=%PY_VER% ^
  --bazel_options="--config=win_clang" ^
  --bazel_options="--experimental_ui_max_stdouterr_bytes=8000000"
if %ERRORLEVEL% NEQ 0 exit %ERRORLEVEL%

bazel clean --expunge
bazel shutdown

%PYTHON% -m pip install --find-links=dist jaxlib --no-build-isolation --no-deps -vv
if %ERRORLEVEL% NEQ 0 exit %ERRORLEVEL%

copy %PREFIX%\Lib\site-packages\jaxlib\mlir\_mlir_libs\*.dll %LIBRARY_BIN%\