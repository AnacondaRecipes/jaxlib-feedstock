#!/bin/bash

set -euxo pipefail

# Set up Python toolchain for bazel
$RECIPE_DIR/add_py_toolchain.sh

if [[ "${target_platform}" == osx-* ]]; then
  export LDFLAGS="${LDFLAGS} -lz -framework CoreFoundation -Xlinker -undefined -Xlinker dynamic_lookup"
else
  export LDFLAGS="${LDFLAGS} -lrt"
fi
export CFLAGS="${CFLAGS} -DNDEBUG"
export CXXFLAGS="${CXXFLAGS} -DNDEBUG"

export BUILD_FLAGS="--target_cpu_features=default"
export WHEELS="jaxlib"

#  - if JAX_RELEASE or JAXLIB_RELEASE are set: version looks like "0.4.16"
#  - if JAX_NIGHTLY or JAXLIB_NIGHTLY are set: version looks like "0.4.16.dev20230906"
#  - if none are set: version looks like "0.4.16.dev20230906+ge58560fdc
export JAXLIB_RELEASE=1

if [[ ${cuda_compiler_version} != "None" ]] && [[ "${target_platform}" == linux-* ]]; then
  export HERMETIC_CUDA_COMPUTE_CAPABILITIES=sm_60,sm_70,sm_75,sm_80,sm_86,sm_89,sm_90,compute_90
  export CUDA_HOME="${BUILD_PREFIX}/targets/x86_64-linux"
  export PATH=$PATH:${BUILD_PREFIX}/nvvm/bin

  # XLA can only cope with a single cuda header include directory, merge both
  if [[ -d "${PREFIX}/targets/x86_64-linux/include/" ]]; then
  rsync -a ${PREFIX}/targets/x86_64-linux/include/ ${BUILD_PREFIX}/targets/x86_64-linux/include/
  fi

  # Although XLA supports a non-hermetic build, it still tries to find headers in the hermetic locations.
  # We do this in the BUILD_PREFIX to not have any impact on the resulting jaxlib package.
  # Otherwise, these copied files would be included in the package.
  if [[ -d "${PREFIX}/targets/x86_64-linux/include" ]]; then
  rm -rf ${BUILD_PREFIX}/targets/x86_64-linux/include/third_party
  mkdir -p ${BUILD_PREFIX}/targets/x86_64-linux/include/third_party/gpus/cuda/extras/CUPTI
  cp -r ${PREFIX}/targets/x86_64-linux/include ${BUILD_PREFIX}/targets/x86_64-linux/include/third_party/gpus/cuda/
  cp -r ${PREFIX}/targets/x86_64-linux/include ${BUILD_PREFIX}/targets/x86_64-linux/include/third_party/gpus/cuda/extras/CUPTI/
  fi
  if [[ -f "${PREFIX}/include/cudnn.h" ]]; then
  mkdir -p ${BUILD_PREFIX}/targets/x86_64-linux/include/third_party/gpus/cudnn
  cp ${PREFIX}/include/cudnn.h ${BUILD_PREFIX}/targets/x86_64-linux/include/third_party/gpus/cudnn/
  fi

  export LOCAL_CUDA_PATH="${BUILD_PREFIX}/targets/x86_64-linux"
  export LOCAL_CUDNN_PATH="${PREFIX}/targets/x86_64-linux"
  export LOCAL_NCCL_PATH="${PREFIX}/targets/x86_64-linux"
  export TF_CUDA_VERSION="${cuda_compiler_version}"
  export TF_CUDNN_VERSION="${cudnn}"
  export TF_NEED_CUDA=1
  export TF_NCCL_VERSION=$(pkg-config nccl --modversion | grep -Po '\d+\.\d+')

  mkdir -p ${BUILD_PREFIX}/targets/x86_64-linux/bin
  if command -v ptxas &> /dev/null; then
  ln -s $(which ptxas) ${BUILD_PREFIX}/targets/x86_64-linux/bin/ptxas
  fi
  if command -v nvlink &> /dev/null; then
  ln -s $(which nvlink) ${BUILD_PREFIX}/targets/x86_64-linux/bin/nvlink
  fi
  if command -v fatbinary &> /dev/null; then
  ln -s $(which fatbinary) ${BUILD_PREFIX}/targets/x86_64-linux/bin/fatbinary
  fi

  # For JAX 0.6.1+, CUDA is enabled via --wheels parameter
  export WHEELS="jaxlib,jax-cuda-plugin"
  export BUILD_FLAGS="${BUILD_FLAGS} \
                      --cuda_compute_capabilities=$HERMETIC_CUDA_COMPUTE_CAPABILITIES \
                      --cuda_version=$TF_CUDA_VERSION \
                      --cudnn_version=$TF_CUDNN_VERSION"
fi

# Note: --nouse_clang argument is no longer supported in JAX 0.6.1
# Removed the conditional that was adding --nouse_clang for Linux platforms
# JAX 0.6.1 requires clang to be available - now installed as build dependency

# Override ALL compiler variables to use clang for bazel toolchain generation
# This ensures the bazel toolchain uses clang instead of GCC to match JAX's --config=clang
export CC="${BUILD_PREFIX}/bin/clang"
export CXX="${BUILD_PREFIX}/bin/clang++"
export CC_FOR_BUILD="${BUILD_PREFIX}/bin/clang"
export CXX_FOR_BUILD="${BUILD_PREFIX}/bin/clang++"
# Critical: Also override GCC/GXX variables that gen-bazel-toolchain uses
export GCC="${BUILD_PREFIX}/bin/clang"
export GXX="${BUILD_PREFIX}/bin/clang++"

# Regenerate bazel toolchain with clang settings
source gen-bazel-toolchain

cat >> .bazelrc <<EOF

build --crosstool_top=//bazel_toolchain:toolchain
build --platforms=//bazel_toolchain:target_platform
build --host_platform=//bazel_toolchain:build_platform
build --extra_toolchains=//bazel_toolchain:cc_cf_toolchain
build --extra_toolchains=//bazel_toolchain:cc_cf_host_toolchain
build --logging=6
build --verbose_failures
build --toolchain_resolution_debug
build --define=PREFIX=${PREFIX}
build --define=PROTOBUF_INCLUDE_PATH=${PREFIX}/include
build --local_cpu_resources=${CPU_COUNT}
build --copt=-isystem${BUILD_PREFIX}/lib/clang/17/include
build --features=-strict_header_checking
EOF

# Never use the Apple toolchain - critical fix for macOS ARM64
if [[ "$OSTYPE" == "darwin"* ]]; then
  sed -i '' '/local_config_apple/d' .bazelrc
else
  sed -i '/local_config_apple/d' .bazelrc
fi

if [[ "${target_platform}" == "osx-arm64" ]]; then
  echo "build --cpu=darwin_arm64" >> .bazelrc
fi

# Unvendor from XLA using TF_SYSTEM_LIBS. You can find the list of supported libraries at:
# https://github.com/openxla/xla/blob/main/third_party/tsl/third_party/systemlibs/syslibs_configure.bzl#L11
# TODO: RE2 fails with: external/xla/xla/hlo/parser/hlo_lexer.cc:244:8: error: no matching function for call to 'Consume'
  # if (!RE2::Consume(&consumable, *payload_pattern))
# Removed com_googlesource_code_re2
# Removed com_google_protobuf: Upstream discourages dynamically linking with protobuf https://github.com/conda-forge/jaxlib-feedstock/issues/89
export TF_SYSTEM_LIBS="
  absl_py,
  astor_archive,
  astunparse_archive,
  boringssl,
  com_github_googlecloudplatform_google_cloud_cpp,
  com_github_grpc_grpc,
  com_google_absl,
  curl,
  cython,
  dill_archive,
  double_conversion,
  flatbuffers,
  functools32_archive,
  gast_archive,
  gif,
  hwloc,
  icu,
  jsoncpp_git,
  libjpeg_turbo,
  nasm,
  nsync,
  org_sqlite,
  pasta,
  png,
  pybind11,
  six_archive,
  snappy,
  tblib_archive,
  termcolor_archive,
  typing_extensions_archive,
  wrapt,
  zlib"

bazel clean --expunge

echo "Building...."
${PYTHON} build/build.py build --wheels=${WHEELS} ${BUILD_FLAGS}
echo "Building done."

# Clean up to speedup postprocessing
echo "Issuing bazel clean..."
pushd build
bazel clean --expunge
popd

echo "Issuing bazel shutdown..."
bazel shutdown

echo "Installing jaxlib wheel..."
${PYTHON} -m pip install dist/jaxlib-*.whl --no-build-isolation --no-deps
