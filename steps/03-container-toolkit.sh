#!/usr/bin/env bash
# NVIDIA container toolkit. Must be installed BEFORE k3s so k3s auto-detects the nvidia runtime.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

step "NVIDIA container toolkit"
if dpkg -s nvidia-container-toolkit >/dev/null 2>&1; then
  info "Already installed."
  exit 0
fi

curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | $SUDO gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | $SUDO tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
$SUDO apt-get update
$SUDO apt-get install -y nvidia-container-toolkit
