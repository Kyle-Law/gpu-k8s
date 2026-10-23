#!/usr/bin/env bash
# Install the NVIDIA driver if it is missing.
# Exit code 10 means "reboot required": reboot, then re-run ./setup.sh.
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

step "NVIDIA driver"
if driver_ok; then
  nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv
  exit 0
fi

info "No working driver found. Installing nvidia-driver-535-server..."
$SUDO apt-get update
$SUDO apt-get install -y nvidia-driver-535-server
echo
echo ">>> Driver installed. REBOOT now ('reboot'), then re-run ./setup.sh <<<"
exit "$EXIT_REBOOT"
