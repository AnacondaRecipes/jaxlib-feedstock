:: Note: TF_SYSTEM_LIBS variable won't work on Windows
:: Ref: https://github.com/tensorflow/tensorflow/blob/master/.bazelrc#L476
:: Therefore, for any of the packages that rely on xla (tensorflow and jaxlib),
:: we've made the decision to just use the vendored dependencies on Windows.

@echo on
setlocal EnableDelayedExpansion

:: if JAX_RELEASE or JAXLIB_RELEASE are set: version looks like "0.7.2"
:: if JAX_NIGHTLY or JAXLIB_NIGHTLY are set: version looks like "0.7.2.devX"
:: if none are set: version looks like "0.7.2.devX+Y" or "0.7.2.dev0+selfbuilt"
:: where X is the build number, Y is the git hash
:: This is required to get '%SP_DIR~\jaxlib-{{ version }}.dist-info' directory name correctly
set JAXLIB_RELEASE=1

:: Set wheel version string (seems to be required alongside JAXLIB_RELEASE env variable)
:: * `0.7.2.dev0+selfbuilt` (local build, default build rule behavior): `--repo_env=ML_WHEEL_TYPE=snapshot`
:: * `0.7.2` (release): `--repo_env=ML_WHEEL_TYPE=release`
:: * `0.7.2rc1` (release candidate): `--repo_env=ML_WHEEL_TYPE=release --repo_env=ML_WHEEL_VERSION_SUFFIX=rc1`
:: * `0.7.2.dev20250128+3e75e20c7` (nightly build): `--repo_env=ML_WHEEL_TYPE=custom --repo_env=ML_WHEEL_BUILD_DATE=20250128 --repo_env=ML_WHEEL_GIT_HASH=$(git rev-parse HEAD)`
:: Ref: https://github.com/jax-ml/jax/commit/d424f5b5b38b75b6577d2c30532abbb693353742
set ML_WHEEL_TYPE=release

:: Necessary variables to make conda-build working
set BAZEL_VS="%VSINSTALLDIR%"
set BAZEL_VC="%VSINSTALLDIR%/VC"
set BAZEL_LLVM=%BUILD_PREFIX:\=/%/Library/
set CLANG_COMPILER_PATH=%BUILD_PREFIX:\=/%/Library/bin/clang.exe

:: Converted from build.sh
echo build --logging=6 >> .bazelrc.user
echo build --verbose_failures >> .bazelrc.user
echo build --toolchain_resolution_debug >> .bazelrc.user
echo build --define=PREFIX=%PREFIX:\=/% >> .bazelrc.user
echo build --define=PROTOBUF_INCLUDE_PATH=%PREFIX:\=/%/include >> .bazelrc.user
echo build --local_resources=cpu=%CPU_COUNT% >> .bazelrc.user
echo build --repo_env=GRPC_BAZEL_DIR=%PREFIX:\=/%/share/bazel/grpc/bazel >> .bazelrc.user

:: _m_prefetchw is declared in both Clang and Windows SDK
:: This can be removed after Clang 21 is released
echo build --copt=-D__PRFCHWINTRIN_H >> .bazelrc.user

:: Build and install jaxlib
:: --wheels=jaxlib
::      to explicitly build jaxlib wheels only
:: --use_clang=true
::to use the clang as recommended by the upstream
:: --clang_path=%CLANG_COMPILER_PATH%
::      to use the clang from the conda-build environment
:: --python_version=%PY_VER% is
::      not directly required and 99.99% of the time hermetic builds use the conda-build environment python version,
::      but we just want to make sure it is always the same as conda-build environment python version.
::      Therefore, this is here for just a bit of extra caution.
:: --bazel_options=--config=win_clang
::      to use the win_clang config defined in JAX .bazelrc file
::      'win_clang' config allows the build system to use 'clang-cl.exe' instead of 'cl.exe'.
:: --bazel_options="--experimental_ui_max_stdouterr_bytes=8000000"
::      to increase the size of the buffer for stderr output
::      If this number is too small, the errors will be truncated.
%PYTHON% build/build.py build ^
    --verbose ^
    --wheels=jaxlib ^
    --use_clang=true ^
    --clang_path=%CLANG_COMPILER_PATH% ^
    --python_version=%PY_VER% ^
    --bazel_options=--config=win_clang ^
    --bazel_options="--experimental_ui_max_stdouterr_bytes=8000000"
if %ERRORLEVEL% NEQ 0 exit %ERRORLEVEL%

if not exist dist mkdir dist
copy /Y bazel-bin\jaxlib\tools\dist\jaxlib-*.whl dist\
if %ERRORLEVEL% NEQ 0 exit %ERRORLEVEL%

:: Clean up Bazel artifacts
bazel clean --expunge
bazel shutdown

:: Install generated wheels
%PYTHON% -m pip install --find-links=dist jaxlib -vv --no-build-isolation --no-deps
if %ERRORLEVEL% NEQ 0 exit %ERRORLEVEL%

:: Copy DLL files to the conda bin dir
:: Necessary to eliminate overlinking errors when --error-overlinking is passed to conda-build
for /r "%PREFIX%\Lib\site-packages\jaxlib" %%i in (*.dll) do (
    echo Copying %%~nxi
    copy /Y "%%i" "%LIBRARY_BIN%\"
)
