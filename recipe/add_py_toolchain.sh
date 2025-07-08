#!/bin/bash
#
# Create a Python toolchain in the current working directory.

set -exuo pipefail

mkdir -p py_toolchain
cp $RECIPE_DIR/py_toolchain.bzl py_toolchain/BUILD
# Platform-aware sed for macOS/Linux compatibility
if [[ "$OSTYPE" == "darwin"* ]]; then
  sed -i '' "s;@@SRC_DIR@@;$SRC_DIR;" py_toolchain/BUILD
else
  sed -i "s;@@SRC_DIR@@;$SRC_DIR;" py_toolchain/BUILD
fi

cat > python.shebang <<EOF
#!/bin/bash
export PYTHONSAFEPATH=1
${PYTHON} "\$@"
EOF
chmod +x python.shebang

cat >> .bazelrc <<EOF
build --extra_toolchains=//py_toolchain:py_toolchain
EOF
