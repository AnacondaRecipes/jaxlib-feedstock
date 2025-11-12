:: https://docs.jax.dev/en/latest/developer.html#building-jaxlib-from-source
:: https://docs.jax.dev/en/latest/developer.html#additional-notes-for-building-jaxlib-from-source-on-windows

:: Note: TF_SYSTEM_LIBS variable doesn't work on Windows
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
set ML_WHEEL_TYPE=release

:: Necessary variables to make conda-build working
set BAZEL_VS="%VSINSTALLDIR%"
set BAZEL_VC="%VSINSTALLDIR%/VC"
set BAZEL_LLVM=%BUILD_PREFIX:\=/%/Library/

:: Variables for passing to the Bazel build environment
set CLANG_COMPILER_PATH=%BUILD_PREFIX:\=/%/Library/bin/clang.exe
set CLANG_CL_PATH=%BUILD_PREFIX:\=/%/Library/bin/clang-cl.exe

:: Use ".bazelrc.user" file for customization
:: Ref: https://github.com/jax-ml/jax/blob/main/.bazelrc#L526

:: Set up Python toolchain to make sure we are using
:: the Python executable from the conda-build environment
call %RECIPE_DIR%\add_py_toolchain.bat

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
echo build --repo_env=BAZEL_USE_CPP_ONLY_TOOLCHAIN=1 >> .bazelrc.userls

:: Set wheel version string (seems to be required alongside JAXLIB_RELEASE env variable)
:: * `0.7.2.dev0+selfbuilt` (local build, default build rule behavior): `--repo_env=ML_WHEEL_TYPE=snapshot`
:: * `0.7.2` (release): `--repo_env=ML_WHEEL_TYPE=release`
:: * `0.7.2rc1` (release candidate): `--repo_env=ML_WHEEL_TYPE=release --repo_env=ML_WHEEL_VERSION_SUFFIX=rc1`
:: * `0.7.2.dev20250128+3e75e20c7` (nightly build): `--repo_env=ML_WHEEL_TYPE=custom --repo_env=ML_WHEEL_BUILD_DATE=20250128 --repo_env=ML_WHEEL_GIT_HASH=$(git rev-parse HEAD)`
:: Ref: https://github.com/jax-ml/jax/commit/d424f5b5b38b75b6577d2c30532abbb693353742
echo build --repo_env=ML_WHEEL_TYPE=%ML_WHEEL_TYPE% >> .bazelrc.user
echo build --repo_env=JAXLIB_RELEASE=%JAXLIB_RELEASE% >> .bazelrc.user

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

:: Manually copy wheel with correct pattern (build.py is using wrong pattern)
if not exist dist mkdir dist
copy /Y bazel-bin\jaxlib\tools\dist\jaxlib-*.whl dist\
if %ERRORLEVEL% NEQ 0 exit %ERRORLEVEL%

:: Clean up
bazel clean --expunge
bazel shutdown

:: Install generated wheels
%PYTHON% -m pip install --find-links=dist jaxlib --no-build-isolation --no-deps -vv
if %ERRORLEVEL% NEQ 0 exit %ERRORLEVEL%

:: Copy DLL files to the conda bin dir
for /r "%PREFIX%\Lib\site-packages\jaxlib" %%i in (*.dll) do (
    echo Copying %%~nxi
    copy /Y "%%i" "%LIBRARY_BIN%\"
)
