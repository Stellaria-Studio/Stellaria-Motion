#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${STELLARIA_MOTION_BUILD_DIR:-${root_dir}/build-app}"
release_dir="${root_dir}/release"
skip_build=0

usage() {
  cat <<EOF
usage: tools/package_release.sh [--skip-build]

Builds a clean, drag-and-run macOS arm64 release package:
  release/StellariaMotion-<version>-macOS-arm64.zip

The package includes the app bundle plus LICENSE, NOTICE, README, and release
notes. It strips Finder resource forks and verifies the runtime resources that
make the app usable without the source checkout.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)
      skip_build=1
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

if [[ "${skip_build}" -eq 0 ]]; then
  "${root_dir}/tools/build_app.sh" --no-tests
fi

app_path="${build_dir}/StellariaMotionApp.app"
info_plist="${app_path}/Contents/Info.plist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${info_plist}")"
package_name="Stellaria Motion ${version}"
stage_dir="${release_dir}/${package_name}"
zip_path="${release_dir}/StellariaMotion-${version}-macOS-arm64.zip"

required_files=(
  "${app_path}/Contents/MacOS/StellariaMotionApp"
  "${app_path}/Contents/MacOS/StellariaMotionNativeHost"
  "${app_path}/Contents/Resources/MotionKernels.metallib"
  "${app_path}/Contents/Resources/StellariaMotion.icns"
  "${app_path}/Contents/Resources/tools/bilibili_cache_client.py"
  "${app_path}/Contents/Resources/Models/RIFE-SP4/rife_sp4_a1p.sp4"
  "${app_path}/Contents/Resources/Models/RIFE-safetensors/flownet.safetensors"
)

for file in "${required_files[@]}"; do
  if [[ ! -e "${file}" ]]; then
    echo "release resource missing: ${file}" >&2
    exit 1
  fi
done

rm -rf "${stage_dir}" "${zip_path}"
mkdir -p "${stage_dir}"
ditto --norsrc --noextattr "${app_path}" "${stage_dir}/Stellaria Motion.app"
cp "${root_dir}/LICENSE" "${stage_dir}/LICENSE"
cp "${root_dir}/NOTICE" "${stage_dir}/NOTICE"
cp "${root_dir}/README.md" "${stage_dir}/README.md"
cp "${release_dir}/RELEASE_NOTES.md" "${stage_dir}/RELEASE_NOTES.md"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "${stage_dir}/Stellaria Motion.app" >/dev/null
  codesign --verify --deep --strict "${stage_dir}/Stellaria Motion.app"
fi

(
  cd "${release_dir}"
  ditto -c -k --norsrc --noextattr "${package_name}" "${zip_path}"
)

sha256="$(shasum -a 256 "${zip_path}" | awk '{print $1}')"
cat <<EOF
Packaged Stellaria Motion release
  App:    ${stage_dir}/Stellaria Motion.app
  Zip:    ${zip_path}
  SHA256: ${sha256}
EOF
