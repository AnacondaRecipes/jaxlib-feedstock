#!/bin/bash
set -euxo pipefail

export JAX_RELEASE=1

# Workaround a timestamp issue in rattler-build
# https://github.com/prefix-dev/rattler-build/issues/1865
touch -m -t 203510100101 $(find $BUILD_PREFIX/share/bazel/install -type f)

$RECIPE_DIR/add_py_toolchain.sh

if [[ "${target_platform}" == osx-* ]]; then
  export LDFLAGS="${LDFLAGS} -lz -framework CoreFoundation -Xlinker -undefined -Xlinker dynamic_lookup"
  # Remove stdlib=libc++; this is the default and errors on C sources.
  export CXXFLAGS="${CXXFLAGS/-stdlib=libc++} -D_LIBCPP_DISABLE_AVAILABILITY"
else
  export LDFLAGS="${LDFLAGS} -lrt"

  # See https://github.com/llvm/llvm-project/issues/85656
  # Otherwise, this will cause linkage errors with a GCC-built abseil
  export CXXFLAGS="${CXXFLAGS} -fclang-abi-compat=17"
fi
if [[ "${target_platform}" == "linux-64" || "${target_platform}" == "linux-aarch64" ]]; then
    # https://github.com/conda-forge/jaxlib-feedstock/issues/310
    # Explicitly force non-executable stack to fix compatibility with glibc 2.41, due to:
    # xla_extension.so: cannot enable executable stack as shared object requires: Invalid argument
    LDFLAGS+=" -Wl,-z,noexecstack"
fi
export CFLAGS="${CFLAGS} -DNDEBUG -Dabsl_nullable= -Dabsl_nonnull="
export CXXFLAGS="${CXXFLAGS} -DNDEBUG -Dabsl_nullable= -Dabsl_nonnull="

if [[ "${cuda_compiler_version:-None}" != "None" ]]; then
    if [[ ${cuda_compiler_version} == 12* ]]; then
        export HERMETIC_CUDA_COMPUTE_CAPABILITIES=sm_60,sm_70,sm_75,sm_80,sm_86,sm_89,sm_90,sm_100,sm_120,compute_120
    else
        export HERMETIC_CUDA_COMPUTE_CAPABILITIES=sm_75,sm_80,sm_86,sm_89,sm_90,sm_100,sm_110,sm_120,compute_120
    fi
    if [[ "${target_platform}" == "linux-64" ]]; then
        export CUDA_ARCH="x86_64-linux"
    elif [[ "${target_platform}" == "linux-aarch64" ]]; then
	export CUDA_ARCH="sbsa-linux"
    else
	echo "Unknown architecture for CUDA"
	exit 1
    fi
    export CUDA_HOME="${BUILD_PREFIX}/targets/${CUDA_ARCH}"
    export TF_CUDA_PATHS="${BUILD_PREFIX}/targets/${CUDA_ARCH},${PREFIX}/targets/${CUDA_ARCH}"
    # Needed for some nvcc binaries
    export PATH=$PATH:${BUILD_PREFIX}/nvvm/bin
    # XLA can only cope with a single cuda header include directory, merge both
    rsync -a ${PREFIX}/targets/${CUDA_ARCH}/include/ ${BUILD_PREFIX}/targets/${CUDA_ARCH}/include/

    # Although XLA supports a non-hermetic build, it still tries to find headers in the hermetic locations.
    # We do this in the BUILD_PREFIX to not have any impact on the resulting jaxlib package.
    # Otherwise, these copied files would be included in the package.
    rm -rf ${BUILD_PREFIX}/targets/${CUDA_ARCH}/include/third_party
    mkdir -p ${BUILD_PREFIX}/targets/${CUDA_ARCH}/include/third_party/gpus/cuda/extras/CUPTI
    cp -r ${PREFIX}/targets/${CUDA_ARCH}/include ${BUILD_PREFIX}/targets/${CUDA_ARCH}/include/third_party/gpus/cuda/
    cp -r ${PREFIX}/targets/${CUDA_ARCH}/include ${BUILD_PREFIX}/targets/${CUDA_ARCH}/include/third_party/gpus/cuda/extras/CUPTI/
    mkdir -p ${BUILD_PREFIX}/targets/${CUDA_ARCH}/include/third_party/gpus/cudnn
    cp ${PREFIX}/include/cudnn*.h ${BUILD_PREFIX}/targets/${CUDA_ARCH}/include/third_party/gpus/cudnn/
    mkdir -p ${BUILD_PREFIX}/targets/${CUDA_ARCH}/include/third_party/nccl
    cp ${PREFIX}/include/nccl*.h ${BUILD_PREFIX}/targets/${CUDA_ARCH}/include/third_party/nccl/
    # Work around clang CUDA host compilation colliding with libstdc++'s
    # __attribute__((__noinline__)) usage via host_defines.h macro expansion.
    # Patch both build and host CUDA include trees used by this build.
    for CUDA_INCLUDE_ROOT in "${BUILD_PREFIX}/targets/${CUDA_ARCH}/include" "${PREFIX}/targets/${CUDA_ARCH}/include"; do
      while IFS= read -r CUDA_HOST_DEFINES; do
        sed -i 's/#if defined(__CUDACC__) || defined(__CUDA_ARCH__) || defined(__CUDA_LIBDEVICE__)/#if (defined(__CUDACC__) || defined(__CUDA_ARCH__) || defined(__CUDA_LIBDEVICE__)) \&\& !defined(__clang__)/' "${CUDA_HOST_DEFINES}"
        sed -i 's/#if (defined(__CUDACC__) \&\& !defined(__clang__)) || defined(__CUDA_ARCH__) || defined(__CUDA_LIBDEVICE__)/#if (defined(__CUDACC__) || defined(__CUDA_ARCH__) || defined(__CUDA_LIBDEVICE__)) \&\& !defined(__clang__)/' "${CUDA_HOST_DEFINES}"
      done < <(find "${CUDA_INCLUDE_ROOT}" -path '*/crt/host_defines.h' -print)

      # Work around clang + CUDA 12 CUB placement-new resolution in device code.
      while IFS= read -r CUDA_CUB_BLOCK_LOAD; do
        sed -i 's|new (\&dst_items\[i\]) T(block_src_it\[warp_offset + tid + (i \* CUB_PTX_WARP_THREADS)\]);|detail::uninitialized_copy_single(\&dst_items[i], block_src_it[warp_offset + tid + (i * CUB_PTX_WARP_THREADS)]);|' "${CUDA_CUB_BLOCK_LOAD}"
        sed -i 's|new (\&dst_items\[i\]) T(block_src_it\[src_pos\]);|detail::uninitialized_copy_single(\&dst_items[i], block_src_it[src_pos]);|' "${CUDA_CUB_BLOCK_LOAD}"
      done < <(find "${CUDA_INCLUDE_ROOT}" -path '*/cub/block/block_load.cuh' -print)
    done
    export LOCAL_CUDA_PATH="${BUILD_PREFIX}/targets/${CUDA_ARCH}"
    export LOCAL_CUDNN_PATH="${PREFIX}/targets/${CUDA_ARCH}"
    export LOCAL_NCCL_PATH="${PREFIX}/targets/${CUDA_ARCH}"
    mkdir -p ${BUILD_PREFIX}/targets/${CUDA_ARCH}/bin
    test -f ${BUILD_PREFIX}/targets/${CUDA_ARCH}/bin/ptxas || ln -s $(which ptxas) ${BUILD_PREFIX}/targets/${CUDA_ARCH}/bin/ptxas
    test -f ${BUILD_PREFIX}/targets/${CUDA_ARCH}/bin/nvlink || ln -s $(which nvlink) ${BUILD_PREFIX}/targets/${CUDA_ARCH}/bin/nvlink
    test -f ${BUILD_PREFIX}/targets/${CUDA_ARCH}/bin/fatbinary || ln -s $(which fatbinary) ${BUILD_PREFIX}/targets/${CUDA_ARCH}/bin/fatbinary

    # rules_ml_toolchain expects an nvml redist directory for local CUDA builds.
    # Conda packages only provide the NVML stub library, so expose the target root
    # under the expected name to satisfy the repository rule on clean builds.
    if [[ ! -e "${LOCAL_CUDA_PATH}/nvml" ]]; then
      ln -s . "${LOCAL_CUDA_PATH}/nvml"
    fi
    export TF_CUDA_VERSION="${cuda_compiler_version}"
    # Detect installed cuDNN version from $PREFIX (matches conda-forge approach).
    # The recipe's CBC no longer pins `cudnn`, so the env var is unset; querying
    # conda's package list gives the actual major.minor.patch (e.g., 9.17.0).
    export TF_CUDNN_VERSION=$(conda list -p $PREFIX ^cudnn$ | awk '$1 == "cudnn" {split($2, a, "."); print a[1]"."a[2]"."a[3]}')
    if [[ "${target_platform}" == "linux-aarch64" ]]; then
        export TF_CUDA_PATHS="${CUDA_HOME}/targets/sbsa-linux,${TF_CUDA_PATHS}"
    fi
    export TF_NEED_CUDA=1
    export TF_NCCL_VERSION=$(pkg-config nccl --modversion | grep -Po '\d+\.\d+')
    export CUDA_COMPILER_MAJOR_VERSION=$(echo "$cuda_compiler_version" | cut -d '.' -f 1)
    CUDA_ARGS="--wheels=jaxlib,jax-cuda-plugin,jax-cuda-pjrt \
               --cuda_compute_capabilities=$HERMETIC_CUDA_COMPUTE_CAPABILITIES \
               --cuda_major_version=${CUDA_COMPILER_MAJOR_VERSION} \
               --cuda_version=$TF_CUDA_VERSION \
               --cudnn_version=$TF_CUDNN_VERSION \
               --build_cuda_with_clang"
fi

source gen-bazel-toolchain

# pkgs/main's bazel-toolchain 0.4.1 doesn't declare the conda_target_platform /
# conda_build_platform constraints that conda-forge's >=0.5.8 emits.
# Our patched XLA protobuf BUILD references @//bazel_toolchain:conda_target_platform
# in a config_setting select(). Append the missing constraints so bazel can parse
# them; since we don't cross-compile here (build_platform == target_platform),
# the select() correctly falls through to the BUILD_PREFIX branch by default.
cat >> bazel_toolchain/BUILD <<'BAZEL_EOF'

constraint_setting(name = "conda_platform")
constraint_value(name = "conda_target_platform", constraint_setting = ":conda_platform")
constraint_value(name = "conda_build_platform", constraint_setting = ":conda_platform")
BAZEL_EOF

# Use line-by-line echo with unquoted vars so bash expands them at write time.
# Heredoc + conda-build text-file prefix substitution interacts badly: heredoc
# writes real paths but conda-build later rewrites them back to literal
# $BUILD_PREFIX/$PREFIX placeholders, which bazel reads as literals (proven by
# `bazel info` showing --define=BUILD_PREFIX=\$BUILD_PREFIX). Append per line.
echo "" >> .bazelrc
echo "build --crosstool_top=//bazel_toolchain:toolchain" >> .bazelrc
echo "build --platforms=//bazel_toolchain:target_platform" >> .bazelrc
echo "build --host_platform=//bazel_toolchain:build_platform" >> .bazelrc
echo "build --extra_toolchains=//bazel_toolchain:cc_cf_toolchain" >> .bazelrc
echo "build --extra_toolchains=//bazel_toolchain:cc_cf_host_toolchain" >> .bazelrc
echo "build --logging=6" >> .bazelrc
echo "build --verbose_failures" >> .bazelrc
echo "build --toolchain_resolution_debug" >> .bazelrc
echo "build --define=with_cross_compiler_support=true" >> .bazelrc
echo "build --per_file_copt=external/xla/xla/backends/profiler/gpu/nvtx_utils.*@-include,string" >> .bazelrc
echo "build --host_per_file_copt=external/xla/xla/backends/profiler/gpu/nvtx_utils.*@-include,string" >> .bazelrc
echo "build:build_cuda_with_nvcc --action_env=CONDA_USE_NVCC=1" >> .bazelrc

# IMPORTANT: defines and repo_envs that contain $PREFIX or $BUILD_PREFIX paths
# go directly on the bazel command line (via build/build.py --bazel_options),
# NOT into .bazelrc. conda-build's text-file prefix substitution clobbers those
# paths in .bazelrc; passing them via the command line bypasses that.

# Use a fixed number instead of CPU_COUNT on linux-aarch64
if [[ "${target_platform}" == "linux-aarch64" ]]; then
  echo "build --local_resources=cpu=8" >> .bazelrc
else
  echo "build --local_resources=cpu=${CPU_COUNT}" >> .bazelrc
fi

if [[ "${target_platform}" == "osx-arm64" || "${target_platform}" != "${build_platform}" ]]; then
  echo "build --cpu=${TARGET_CPU}" >> .bazelrc
fi

# For debugging
# CUSTOM_BAZEL_OPTIONS="${CUSTOM_BAZEL_OPTIONS} --bazel_options=--subcommands"

# Force static linkage with protobuf to avoid definition collisions,
# see https://github.com/conda-forge/jaxlib-feedstock/issues/89
# We have modified the system_lib BUILD here to link to libprotobuf.a from
# the libprotobuf-static host package; com_google_protobuf MUST be in
# TF_SYSTEM_LIBS so bazel uses the patched system_lib BUILD (which references
# $(BUILD_PREFIX)/lib/libprotobuf.a) instead of the vendored protobuf source.
export TF_SYSTEM_LIBS="
  boringssl,
  com_github_googlecloudplatform_google_cloud_cpp,
  com_github_grpc_grpc,
  com_google_absl,
  com_googlesource_code_re2,
  com_google_protobuf,
  flatbuffers,
  zlib
"

# # Anaconda XLA unvendoring
# export TF_SYSTEM_LIBS="
#   ${TF_SYSTEM_LIBS},
#   absl_py,
#   astor_archive,
#   astunparse_archive,
#   curl,
#   cython,
#   dill_archive,
#   double_conversion,
#   functools32_archive,
#   gast_archive,
#   gif,
#   hwloc,
#   icu,
#   jsoncpp_git,
#   libjpeg_turbo,
#   nasm,
#   nsync,
#   org_sqlite,
#   pasta,
#   png,
#   pybind11,
#   six_archive,
#   snappy,
#   tblib_archive,
#   termcolor_archive,
#   typing_extensions_archive,
#   wrapt
# "

if [[ "${target_platform}" == "osx-64" ]]; then
    export TF_SYSTEM_LIBS="${TF_SYSTEM_LIBS},onednn"
fi

# Mark as a release build.
# Pass paths-with-prefix via --bazel_options (build.py argv) instead of
# .bazelrc — otherwise conda-build's prefix substitution on text files
# replaces the real path with the literal "$BUILD_PREFIX" / "$PREFIX"
# placeholder and bazel reads them as undefined make-variables.
EXTRA="--bazel_options=--repo_env=ML_WHEEL_TYPE=release"
EXTRA="${EXTRA} --bazel_options=--define=BUILD_PREFIX=${BUILD_PREFIX}"
EXTRA="${EXTRA} --bazel_options=--define=PREFIX=${PREFIX}"
EXTRA="${EXTRA} --bazel_options=--define=PROTOBUF_INCLUDE_PATH=${PREFIX}/include"
EXTRA="${EXTRA} --bazel_options=--repo_env=GRPC_BAZEL_DIR=${PREFIX}/share/bazel/grpc/bazel"
EXTRA="${EXTRA} --bazel_options=--repo_env=PROTOBUF_BAZEL_DIR=${PREFIX}/share/bazel/protobuf/bazel"
# protoc-generated .pb.h files include "google/protobuf/runtime_version.h"
# (and friends). Those headers ship with libprotobuf at $PREFIX/include/.
# bazel's cc_toolchain CXXFLAGS sed didn't propagate -isystem $PREFIX/include
# to every action (verified by grepping the actual clang invocation), so add
# them explicitly via copt + host_copt for both target and exec configs.
EXTRA="${EXTRA} --bazel_options=--copt=-I${PREFIX}/include"
EXTRA="${EXTRA} --bazel_options=--host_copt=-I${PREFIX}/include"
EXTRA="${EXTRA} ${CUDA_ARGS:-}"

if [[ "${target_platform}" == "osx-arm64" || "${target_platform}" != "${build_platform}" ]]; then
    EXTRA="${EXTRA} --target_cpu ${TARGET_CPU}"
fi

# Never use the Apple toolchain
sed -i '/local_config_apple/d' .bazelrc
if [[ "${target_platform}" == linux-* ]]; then
    EXTRA="${EXTRA} --clang_path $CC"
    # Defensive: enable glibc extensions for transitively-vendored deps that
    # rely on them (e.g., pthread_setname_np, etc.). (vkhomits, jaxlib-feedstock#25)
    EXTRA="${EXTRA} --bazel_options=--copt=-D_GNU_SOURCE"

    # Remove incompatible argument from bazelrc
    sed -i '/Qunused-arguments/d' .bazelrc
    # Don't override our toolchain for CUDA
    sed -i '/TF_NVCC_CLANG/{N;d}' .bazelrc
    # Keep using our toolchain
    sed -i '/--crosstool_top=@local_config_cuda/d' .bazelrc
fi

# ------------- DEBUG OUTPUT (PKG-10582) -------------
echo "===== DEBUG: env before bazel build ====="
echo "BUILD_PREFIX=$BUILD_PREFIX"
echo "PREFIX=$PREFIX"
echo "TF_SYSTEM_LIBS=$TF_SYSTEM_LIBS"
echo "PROTOBUF_BAZEL_DIR=${PROTOBUF_BAZEL_DIR:-<unset>}"
echo "GRPC_BAZEL_DIR=${GRPC_BAZEL_DIR:-<unset>}"
echo "===== DEBUG: ls libprotobuf-static .a files in BUILD_PREFIX/lib ====="
ls -la "$BUILD_PREFIX/lib/" 2>&1 | grep -E "libprotobuf|libutf8|libprotoc" | head -10 || true
echo "===== DEBUG: ls libprotobuf-static .a files in PREFIX/lib ====="
ls -la "$PREFIX/lib/" 2>&1 | grep -E "libprotobuf|libutf8|libprotoc" | head -10 || true
echo "===== DEBUG: protobuf-bazel-rules layout ====="
ls -la "$PREFIX/share/bazel/protobuf/bazel/" 2>&1 | head -10 || true
echo "===== DEBUG: tail of .bazelrc ====="
tail -40 .bazelrc 2>&1
echo "===== DEBUG: end ====="

${PYTHON} build/build.py build \
    --target_cpu_features default \
    --python_version $PY_VER \
    ${EXTRA} || BAZEL_BUILD_RC=$?

# If bazel build failed, dump the offending BUILD file so we can see what's at line 119.
if [[ -n "${BAZEL_BUILD_RC:-}" ]]; then
  echo "===== DEBUG: bazel build failed (rc=$BAZEL_BUILD_RC); dumping protobuf BUILD ====="
  PROTOBUF_BUILD=$(find ~/.cache/bazel -path '*/external/com_google_protobuf/BUILD' 2>/dev/null | head -1)
  if [[ -n "$PROTOBUF_BUILD" ]]; then
    echo "Path: $PROTOBUF_BUILD"
    echo "----- First 130 lines (line 119 is the failing genrule) -----"
    sed -n '1,130p' "$PROTOBUF_BUILD"
    echo "----- BUILD_PREFIX references in file -----"
    grep -n "BUILD_PREFIX" "$PROTOBUF_BUILD" || echo "(none)"
  else
    echo "Could not find external/com_google_protobuf/BUILD in bazel cache"
  fi
  echo "===== DEBUG: bazel info defines (if bazel still alive) ====="
  ./bazel-7.4.1-linux-x86_64 info --noenable_bzlmod 2>&1 | grep -i "define\|prefix" | head -10 || true
  exit $BAZEL_BUILD_RC
fi

# Clean up to speedup postprocessing
pushd build
bazel clean --expunge
popd

pushd $SP_DIR
$PYTHON -m pip install $SRC_DIR/dist/jaxlib-*.whl --no-build-isolation --no-deps -vv

# Add INSTALLER file and remove RECORD, workaround for
# https://github.com/conda-forge/jaxlib-feedstock/issues/293
JAXLIB_DIST_INFO_DIR="${SP_DIR}/jaxlib-${PKG_VERSION}.dist-info"
echo "conda" > "${JAXLIB_DIST_INFO_DIR}/INSTALLER"
rm -f "${JAXLIB_DIST_INFO_DIR}/RECORD"

if [[ "${cuda_compiler_version:-None}" != "None" ]]; then
  $PYTHON -m pip install $SRC_DIR/dist/jax_cuda*_plugin*.whl --no-build-isolation --no-deps -vv
  $PYTHON -m pip install $SRC_DIR/dist/jax_cuda*_pjrt*.whl --no-build-isolation --no-deps -vv

  # Add INSTALLER file and remove RECORD, workaround for
  # https://github.com/conda-forge/jaxlib-feedstock/issues/293
  JAX_CUDA_PJRT_DIST_INFO_DIR="${SP_DIR}/jax_cuda${CUDA_COMPILER_MAJOR_VERSION}_pjrt-${PKG_VERSION}.dist-info"
  echo "conda" > "${JAX_CUDA_PJRT_DIST_INFO_DIR}/INSTALLER"
  rm -f "${JAX_CUDA_PJRT_DIST_INFO_DIR}/RECORD"
  JAX_CUDA_PLUGIN_DIST_INFO_DIR="${SP_DIR}/jax_cuda${CUDA_COMPILER_MAJOR_VERSION}_plugin-${PKG_VERSION}.dist-info"
  echo "conda" > "${JAX_CUDA_PLUGIN_DIST_INFO_DIR}/INSTALLER"
  rm -f "${JAX_CUDA_PLUGIN_DIST_INFO_DIR}/RECORD"

  # Regression test for https://github.com/conda-forge/jaxlib-feedstock/issues/320
  if [[ "${target_platform}" == linux-* ]]; then
    # Scan all .so files in both plugin directories and error if any FLAGS_* symbols are present.
    declare -a PLUGIN_DIRS=(
      "${SP_DIR}/jax_plugins/xla_cuda${CUDA_COMPILER_MAJOR_VERSION}"
      "${SP_DIR}/jax_cuda${CUDA_COMPILER_MAJOR_VERSION}_plugin"
    )
    echo "Scanning CUDA plugin directories for .so files and FLAGS_* symbols:"
    for DIR in "${PLUGIN_DIRS[@]}"; do
      if [[ -d "${DIR}" ]]; then
        echo " - ${DIR}"
        mapfile -t SO_FILES < <(find "${DIR}" -type f -name '*.so' -print | sort)
        if (( ${#SO_FILES[@]} == 0 )); then
          echo "   (no .so files found)"
          continue
        fi
        echo "   .so files:"
        for SO in "${SO_FILES[@]}"; do
          echo "     * ${SO}"
        done
        # Prefer nm -s as requested; fall back to plain nm if -s is unsupported to avoid hard failure.
        # Fail the build if any symbol starting with FLAGS_ is present.
        for SO in "${SO_FILES[@]}"; do
          SYMBOLS_OUTPUT=$(nm -s "${SO}" 2>/dev/null || nm "${SO}")
          if echo "${SYMBOLS_OUTPUT}" | grep -E '(^|[^A-Za-z0-9_])FLAGS_[A-Za-z0-9_]+' >/dev/null; then
            echo "Error: Unexpected FLAGS_* symbols found in ${SO}:" >&2
            echo "----------------------------------------" >&2
            echo "${SYMBOLS_OUTPUT}" | grep -E '(^|[^A-Za-z0-9_])FLAGS_[A-Za-z0-9_]+' >&2 || true
            echo "----------------------------------------" >&2
            exit 1
          fi
        done
      else
        echo "Warning: ${DIR} not found; skipping" >&2
      fi
    done
    echo "No FLAGS_* symbols found in the CUDA plugin directory, the test was successul"
  fi
fi

popd
