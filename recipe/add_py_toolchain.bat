@echo off

REM Create Python toolchain
if not exist py_toolchain mkdir py_toolchain
copy "%RECIPE_DIR%\py_toolchain_win.bzl" py_toolchain\BUILD

REM Replace @@SRC_DIR@@ manually (requires enabling delayed expansion if SRC_DIR has special chars)
setlocal enabledelayedexpansion
set "BAZEL_SRC_DIR=%SRC_DIR:\=/%"
powershell -Command "(Get-Content py_toolchain\BUILD) -replace '@@SRC_DIR@@', '%BAZEL_SRC_DIR%' | Set-Content py_toolchain\BUILD"
endlocal

REM Create Python wrapper
echo @echo off > python.bat
echo set PYTHONSAFEPATH=1 >> python.bat
echo "%PYTHON%" %%* >> python.bat

REM Add to .bazelrc.user
echo build --extra_toolchains=//py_toolchain:py_toolchain >> .bazelrc.user
