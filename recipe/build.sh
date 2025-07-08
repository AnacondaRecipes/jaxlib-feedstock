#!/bin/bash

set -euxo pipefail

if [[ "${target_platform}" == osx-* ]]; then
  export LDFLAGS="${LDFLAGS} -lz -framework CoreFoundation -Xlinker -undefined -Xlinker dynamic_lookup"
else
  export LDFLAGS="${LDFLAGS} -lrt"
fi
export CFLAGS="${CFLAGS} -DNDEBUG"
export CXXFLAGS="${CXXFLAGS} -DNDEBUG"

export BUILD_FLAGS="--target_cpu_features default"

#  - if JAX_RELEASE or JAXLIB_RELEASE are set: version looks like "0.4.16"
#  - if JAX_NIGHTLY or JAXLIB_NIGHTLY are set: version looks like "0.4.16.dev20230906"
#  - if none are set: version looks like "0.4.16.dev20230906+ge58560fdc
export JAXLIB_RELEASE=1

if [[ ${cuda_compiler_version} != "None" ]]; then
  export HERMETIC_CUDA_COMPUTE_CAPABILITIES=sm_60,sm_70,sm_75,sm_80,sm_86,sm_89,sm_90,compute_90
  export CUDA_HOME="${BUILD_PREFIX}/targets/x86_64-linux"
  export PATH=$PATH:${BUILD_PREFIX}/nvvm/bin

  # XLA can only cope with a single cuda header include directory, merge both
  rsync -a ${PREFIX}/targets/x86_64-linux/include/ ${BUILD_PREFIX}/targets/x86_64-linux/include/

  # Although XLA supports a non-hermetic build, it still tries to find headers in the hermetic locations.
  # We do this in the BUILD_PREFIX to not have any impact on the resulting jaxlib package.
  # Otherwise, these copied files would be included in the package.
  rm -rf ${BUILD_PREFIX}/targets/x86_64-linux/include/third_party
  mkdir -p ${BUILD_PREFIX}/targets/x86_64-linux/include/third_party/gpus/cuda/extras/CUPTI
  cp -r ${PREFIX}/targets/x86_64-linux/include ${BUILD_PREFIX}/targets/x86_64-linux/include/third_party/gpus/cuda/
  cp -r ${PREFIX}/targets/x86_64-linux/include ${BUILD_PREFIX}/targets/x86_64-linux/include/third_party/gpus/cuda/extras/CUPTI/
  mkdir -p ${BUILD_PREFIX}/targets/x86_64-linux/include/third_party/gpus/cudnn
  cp ${PREFIX}/include/cudnn.h ${BUILD_PREFIX}/targets/x86_64-linux/include/third_party/gpus/cudnn/

  export LOCAL_CUDA_PATH="${BUILD_PREFIX}/targets/x86_64-linux"
  export LOCAL_CUDNN_PATH="${PREFIX}/targets/x86_64-linux"
  export LOCAL_NCCL_PATH="${PREFIX}/targets/x86_64-linux"
  export TF_CUDA_VERSION="${cuda_compiler_version}"
  export TF_CUDNN_VERSION="${cudnn}"
  export TF_NEED_CUDA=1
  export TF_NCCL_VERSION=$(pkg-config nccl --modversion | grep -Po '\d+\.\d+')

  mkdir -p ${BUILD_PREFIX}/targets/x86_64-linux/bin
  ln -s $(which ptxas) ${BUILD_PREFIX}/targets/x86_64-linux/bin/ptxas
  ln -s $(which nvlink) ${BUILD_PREFIX}/targets/x86_64-linux/bin/nvlink
  ln -s $(which fatbinary) ${BUILD_PREFIX}/targets/x86_64-linux/bin/fatbinary

  export BUILD_FLAGS="${BUILD_FLAGS} \
                      --cuda_compute_capabilities=$HERMETIC_CUDA_COMPUTE_CAPABILITIES \
                      --cuda_version=$TF_CUDA_VERSION \
                      --cudnn_version=$TF_CUDNN_VERSION"
fi

if [[ "${target_platform}" == linux-* ]]; then
    export BUILD_FLAGS="${BUILD_FLAGS} --use_clang=false"
fi

source gen-bazel-toolchain

cat >> .bazelrc <<EOF

build --crosstool_top=//bazel_toolchain:toolchain
build --apple_crosstool_top=//bazel_toolchain:toolchain
build --host_crosstool_top=//bazel_toolchain:toolchain
build --logging=6
build --verbose_failures
build --toolchain_resolution_debug
build --define=PREFIX=${PREFIX}
build --define=PROTOBUF_INCLUDE_PATH=${PREFIX}/include
build --local_cpu_resources=${CPU_COUNT}"
EOF

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

# Fix clang naming for v0.6.0 build system
# Create symlinks so build system can find clang with expected names
if [[ ${CC} =~ clang ]]; then
    # Extract clang major version (we know this is clang 14 from conda)
    CLANG_VERSION="14"

    # Create a separate directory for clang symlinks to avoid conflicts with Bazel toolchains
    mkdir -p "${SRC_DIR}/clang-bin"

    # Create symlinks in the separate directory (backup)
    ln -sf "${CC}" "${SRC_DIR}/clang-bin/clang-${CLANG_VERSION}"
    ln -sf "${CXX}" "${SRC_DIR}/clang-bin/clang++-${CLANG_VERSION}"

    # Add our clang-bin directory to the front of PATH
    export PATH="${SRC_DIR}/clang-bin:${PATH}"

    # Also add clang++-14 to BUILD_PREFIX/bin since clang-14 is already there from conda
    # This ensures both are in the same directory as expected by the build system
    ln -sf "${CXX}" "${BUILD_PREFIX}/bin/clang++-${CLANG_VERSION}"

    echo "Created clang symlinks: clang-${CLANG_VERSION} -> ${CC}, clang++-${CLANG_VERSION} -> ${CXX}"
    echo "Added ${SRC_DIR}/clang-bin to PATH"
    echo "Added clang++-${CLANG_VERSION} to ${BUILD_PREFIX}/bin"
fi

${PYTHON} build/build.py build --wheels=jaxlib ${BUILD_FLAGS}
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
