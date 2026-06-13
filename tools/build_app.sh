#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${STELLARIA_MOTION_BUILD_DIR:-${root_dir}/build-app}"
generator="${STELLARIA_MOTION_GENERATOR:-Ninja}"
open_app=0
clean=0
run_tests=1

usage() {
  cat <<EOF
usage: tools/build_app.sh [--open] [--clean] [--no-tests]

Builds Stellaria Motion.app, MotionKernels.metallib, the Chrome native host,
and core tests in one command.

Environment:
  STELLARIA_MOTION_BUILD_DIR   Build directory. Default: ./build-app
  STELLARIA_MOTION_GENERATOR   CMake generator. Default: Ninja
  CMAKE_MAKE_PROGRAM           Optional path to ninja/make.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --open)
      open_app=1
      shift
      ;;
    --clean)
      clean=1
      shift
      ;;
    --no-tests)
      run_tests=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

detect_ninja() {
  if [[ -n "${CMAKE_MAKE_PROGRAM:-}" && -x "${CMAKE_MAKE_PROGRAM}" ]]; then
    printf '%s\n' "${CMAKE_MAKE_PROGRAM}"
    return 0
  fi

  if command -v ninja >/dev/null 2>&1; then
    command -v ninja
    return 0
  fi

  local clion_ninja="/Applications/CLion.app/Contents/bin/ninja/mac/aarch64/ninja"
  if [[ -x "${clion_ninja}" ]]; then
    printf '%s\n' "${clion_ninja}"
    return 0
  fi

  return 1
}

if [[ "${clean}" -eq 1 ]]; then
  rm -rf "${build_dir}"
fi

cmake_args=(-S "${root_dir}" -B "${build_dir}" -DSTELLARIA_MOTION_BUILD_APP=ON -DSTELLARIA_MOTION_BUILD_TESTS=ON)

if [[ "${generator}" == "Ninja" ]]; then
  if ninja_path="$(detect_ninja)"; then
    cmake_args+=(-G Ninja -DCMAKE_MAKE_PROGRAM="${ninja_path}")
  else
    echo "Ninja not found; falling back to Unix Makefiles." >&2
    cmake_args+=(-G "Unix Makefiles")
  fi
else
  cmake_args+=(-G "${generator}")
fi

cmake "${cmake_args[@]}"
cmake --build "${build_dir}" --target StellariaMotionApp

if [[ "${run_tests}" -eq 1 ]]; then
  cmake --build "${build_dir}" --target MotionCoreTests
  cmake --build "${build_dir}" --target MotionOfflineProcessorSmoke
  ctest --test-dir "${build_dir}" --output-on-failure
fi

app_path="${build_dir}/StellariaMotionApp.app"
metallib_path="${app_path}/Contents/Resources/MotionKernels.metallib"
native_host_path="${app_path}/Contents/MacOS/StellariaMotionNativeHost"

if [[ ! -d "${app_path}" ]]; then
  echo "App bundle missing: ${app_path}" >&2
  exit 1
fi

if [[ ! -f "${metallib_path}" ]]; then
  echo "Bundled metallib missing: ${metallib_path}" >&2
  exit 1
fi

if [[ ! -x "${native_host_path}" ]]; then
  echo "Bundled native host missing: ${native_host_path}" >&2
  exit 1
fi

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "${app_path}" >/dev/null
fi

cat <<EOF
Built Stellaria Motion.app
  App:        ${app_path}
  Metallib:   ${metallib_path}
  NativeHost: ${native_host_path}
EOF

if [[ "${open_app}" -eq 1 ]]; then
  open "${app_path}"
fi
