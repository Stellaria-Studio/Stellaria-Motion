#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
release_dir="${root_dir}/release"
skip_build=0

usage() {
  cat <<EOF
usage: tools/package_dmg.sh [--skip-build]

Creates a macOS drag-to-Applications DMG:
  release/StellariaMotion-<version>-macOS-arm64.dmg

Optional signing and notarization environment:
  STELLARIA_DEVELOPER_ID_APPLICATION  Developer ID Application identity
  STELLARIA_NOTARY_PROFILE            notarytool keychain profile

Without those variables the script still creates a clean DMG, but Gatekeeper
will treat it as an unsigned/ad-hoc developer build on other machines.
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
  "${root_dir}/tools/package_release.sh"
else
  "${root_dir}/tools/package_release.sh" --skip-build
fi

app_path="${release_dir}/Stellaria Motion 0.1.0/Stellaria Motion.app"
info_plist="${app_path}/Contents/Info.plist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${info_plist}")"
volume_name="Stellaria Motion ${version}"
dmg_path="${release_dir}/StellariaMotion-${version}-macOS-arm64.dmg"
staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/stellaria-motion-dmg.XXXXXX")"

cleanup() {
  rm -rf "${staging_dir}"
}
trap cleanup EXIT

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
    echo "DMG resource missing: ${file}" >&2
    exit 1
  fi
done

if [[ -n "${STELLARIA_DEVELOPER_ID_APPLICATION:-}" ]]; then
  codesign --force --deep --options runtime --timestamp \
    --sign "${STELLARIA_DEVELOPER_ID_APPLICATION}" "${app_path}"
else
  codesign --force --deep --sign - "${app_path}" >/dev/null
fi
codesign --verify --deep --strict "${app_path}"

mkdir -p "${staging_dir}/${volume_name}"
ditto --norsrc --noextattr "${app_path}" "${staging_dir}/${volume_name}/Stellaria Motion.app"
ln -s /Applications "${staging_dir}/${volume_name}/Applications"
cp "${root_dir}/LICENSE" "${staging_dir}/${volume_name}/LICENSE"
cp "${root_dir}/NOTICE" "${staging_dir}/${volume_name}/NOTICE"
cp "${root_dir}/README.md" "${staging_dir}/${volume_name}/README.md"
cp "${release_dir}/RELEASE_NOTES.md" "${staging_dir}/${volume_name}/RELEASE_NOTES.md"

rm -f "${dmg_path}"
hdiutil create \
  -volname "${volume_name}" \
  -srcfolder "${staging_dir}/${volume_name}" \
  -ov \
  -format UDZO \
  "${dmg_path}" >/dev/null

if [[ -n "${STELLARIA_DEVELOPER_ID_APPLICATION:-}" ]]; then
  codesign --force --timestamp --sign "${STELLARIA_DEVELOPER_ID_APPLICATION}" "${dmg_path}"
fi

if [[ -n "${STELLARIA_NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "${dmg_path}" \
    --keychain-profile "${STELLARIA_NOTARY_PROFILE}" \
    --wait
  xcrun stapler staple "${dmg_path}"
  spctl --assess --type open --context context:primary-signature --verbose=4 "${dmg_path}"
fi

sha256="$(shasum -a 256 "${dmg_path}" | awk '{print $1}')"
cat <<EOF
Packaged Stellaria Motion DMG
  DMG:    ${dmg_path}
  SHA256: ${sha256}
EOF

if [[ -z "${STELLARIA_DEVELOPER_ID_APPLICATION:-}" || -z "${STELLARIA_NOTARY_PROFILE:-}" ]]; then
  cat <<EOF
Warning: Developer ID signing/notarization was not completed.
Set STELLARIA_DEVELOPER_ID_APPLICATION and STELLARIA_NOTARY_PROFILE to create
a public Gatekeeper-friendly one-click DMG.
EOF
fi
