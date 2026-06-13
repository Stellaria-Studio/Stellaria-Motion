#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
model_dir="${STELLARIA_MOTION_MODEL_DIR:-${root_dir}/Models/RIFE-safetensors}"
repo_base="https://huggingface.co/TensorForger/RIFE-safetensors/resolve/main"

mkdir -p "${model_dir}"

download() {
  local file="$1"
  local url="${repo_base}/${file}?download=true"
  local dst="${model_dir}/${file}"
  if [[ -f "${dst}" ]]; then
    echo "exists ${dst}"
    return
  fi
  echo "downloading ${file}"
  curl -L --fail --retry 3 --retry-delay 2 "${url}" -o "${dst}"
}

download "flownet.safetensors"
download "interpolation_model.py"
download "requirements.txt"
download "LICENSE"

cat > "${model_dir}/README.stellaria-motion.md" <<EOF
# RIFE assets for Stellaria Motion

Downloaded from:
https://huggingface.co/TensorForger/RIFE-safetensors

These assets are used as the reference RIFE v4 frame-interpolation model source
for later Core ML / MPSGraph / Metal-kernel conversion. The product runtime must
not depend on Python or PyTorch.
EOF

echo "Model assets ready: ${model_dir}"

