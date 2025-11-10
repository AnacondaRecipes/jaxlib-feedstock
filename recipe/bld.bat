:: https://docs.jax.dev/en/latest/developer.html#building-jaxlib-from-source
:: https://docs.jax.dev/en/latest/developer.html#additional-notes-for-building-jaxlib-from-source-on-windows

:: Note: TF_SYSTEM_LIBS variable doesn't work on Windows
:: Ref: https://github.com/tensorflow/tensorflow/blob/master/.bazelrc#L476
:: Therefore, for any of the packages that rely on xla (tensorflow and jaxlib),
:: we've made the decision to just use the vendored dependencies on Windows.

@echo on
setlocal EnableDelayedExpansion

:: Necessary variables to make conda-build working
set BAZEL_VS="%VSINSTALLDIR%"
set BAZEL_VC="%VSINSTALLDIR%/VC"
set BAZEL_LLVM=%BUILD_PREFIX:\=/%/Library/

:: Variables for passing to the Bazel build environment
set CLANG_COMPILER_PATH=%BUILD_PREFIX:\=/%/Library/bin/clang.exe
set CLANG_CL_PATH=%BUILD_PREFIX:\=/%/Library/bin/clang-cl.exe

:: Use ".bazelrc.user" file for customization
:: Ref: https://github.com/jax-ml/jax/blob/main/.bazelrc#L526

:: Needed for XLA to pull in dependencies
echo common --experimental_repo_remote_exec >> .bazelrc.user

:: Set min C++ standard in a format MSVC understands.
echo build --cxxopt=/std:c++17 >> .bazelrc.user
echo build --host_cxxopt=/std:c++17 >> .bazelrc.user
echo build --cxxopt=/Zc:__cplusplus >> .bazelrc.user
echo build --host_cxxopt=/Zc:__cplusplus >> .bazelrc.user

:: TODO: Do we need to include 'winsock2.h'?

:: Variables from build.sh
echo build --logging=6 >> .bazelrc.user
echo build --verbose_failures >> .bazelrc.user
echo build --toolchain_resolution_debug >> .bazelrc.user
echo build --define=PREFIX=%PREFIX:\=/% >> .bazelrc.user
echo build --define=PROTOBUF_INCLUDE_PATH=%PREFIX:\=/%/include >> .bazelrc.user
echo build --local_resources=cpu=%CPU_COUNT% >> .bazelrc.user
echo build --repo_env=GRPC_BAZEL_DIR=%PREFIX:\=/%/share/bazel/grpc/bazel >> .bazelrc.user

:: Make sure Bazel uses clang
:: "win_clang" config should be able to take care of this, but sometimes it fails
echo build --action_env=CC=%CLANG_CL_PATH% >> .bazelrc.user
echo build --action_env=CXX=%CLANG_CL_PATH% >> .bazelrc.user
echo build --repo_env=CC=%CLANG_CL_PATH% >> .bazelrc.user
echo build --repo_env=CXX=%CLANG_CL_PATH% >> .bazelrc.user
echo build --repo_env=BAZEL_USE_CPP_ONLY_TOOLCHAIN=1 >> .bazelrc.user

:: _m_prefetchw is declared in both Clang and Windows SDK
:: This can be removed with Clang 21
echo build --copt=-D__PRFCHWINTRIN_H >> .bazelrc.user

:: Prevent leaking Windows macros that conflict with stdlib
echo build --copt=-DNOMINMAX >> .bazelrc.user
echo build --copt=-DWIN32_LEAN_AND_MEAN >> .bazelrc.user
echo build --copt=-DNOGDI >> .bazelrc.user

:: TODO: Do we need to add '--disable_mkl_dnn' to the build parameters?

:: Build and install jaxlib
%PYTHON% build/build.py build ^
  --verbose ^
  --wheels=jaxlib ^
  --use_clang=true ^
  --clang_path=%CLANG_COMPILER_PATH% ^
  --python_version=%PY_VER% ^
  --bazel_options="--config=win_clang" ^
  --bazel_options="--experimental_ui_max_stdouterr_bytes=8000000"
if %ERRORLEVEL% NEQ 0 exit %ERRORLEVEL%

bazel clean --expunge
bazel shutdown

:: Install generated wheels
%PYTHON% -m pip install --find-links=dist jaxlib --no-build-isolation --no-deps -vv
if %ERRORLEVEL% NEQ 0 exit %ERRORLEVEL%
