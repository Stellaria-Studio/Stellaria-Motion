#!/usr/bin/env bash
set -euo pipefail

browser="chrome"

usage() {
  cat >&2 <<EOF
usage: $0 [--browser chrome] <extension-id[,extension-id...]> <native-host-binary>

Installs the native messaging host manifest for the Stellaria Motion browser
agent for Google Chrome. Load Sources/BrowserAgent/extension as an unpacked extension first, then
copy its extension id into this command.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --browser)
      browser="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -lt 2 ]]; then
  usage
  exit 2
fi

extension_ids="$1"
host_binary="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"

allowed_origins_json() {
  local first=1
  IFS=',' read -r -a ids <<< "${extension_ids}"
  for id in "${ids[@]}"; do
    id="${id//[[:space:]]/}"
    [[ -n "${id}" ]] || continue
    if [[ "${first}" -eq 0 ]]; then
      printf ',\n'
    fi
    printf '    "chrome-extension://%s/"' "${id}"
    first=0
  done
}

install_manifest() {
  local manifest_dir="$1"
  local manifest_path="${manifest_dir}/studio.stellaria.motion.json"
  mkdir -p "${manifest_dir}"
  cat > "${manifest_path}" <<EOF
{
  "name": "studio.stellaria.motion",
  "description": "Stellaria Motion Native Messaging Host",
  "path": "${host_binary}",
  "type": "stdio",
  "allowed_origins": [
$(allowed_origins_json)
  ]
}
EOF
  echo "Installed ${manifest_path}"
}

case "${browser}" in
  chrome)
    install_manifest "${HOME}/Library/Application Support/Google/Chrome/NativeMessagingHosts"
    ;;
  *)
    echo "unsupported browser: ${browser}; Stellaria Motion browser VFI is maintained for Google Chrome only" >&2
    usage
    exit 2
    ;;
esac
