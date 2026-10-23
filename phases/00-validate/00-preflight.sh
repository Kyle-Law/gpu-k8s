#!/usr/bin/env bash
# Preflight: check the host BEFORE changing anything. Read-only, safe to re-run.
# Fails (exit 1) on blockers; prints warnings for things that are probably fine.
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

fails=0
ok()   { printf '    [ ok ] %s\n' "$*"; }
warn() { printf '    [warn] %s\n' "$*"; }
bad()  { printf '    [FAIL] %s\n' "$*"; fails=$((fails + 1)); }

step "Preflight: host"
. /etc/os-release 2>/dev/null || true
if [ "${ID:-}" = ubuntu ] && [ "${VERSION_ID:-}" = "22.04" ]; then ok "Ubuntu 22.04"
else warn "OS is ${PRETTY_NAME:-unknown}; these scripts are written for Ubuntu 22.04"; fi

if [ "$(uname -m)" = x86_64 ]; then ok "x86_64"; else bad "architecture is $(uname -m); only x86_64 is supported"; fi

if [ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null; then ok "sudo without a password"
else bad "sudo needs a password (or user is not a sudoer); run 'sudo -v' first"; fi

mem_gb=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
if [ "$mem_gb" -ge 16 ]; then ok "RAM: ${mem_gb} GiB"; else warn "RAM: ${mem_gb} GiB (16+ recommended for an 8B model)"; fi

free_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
if [ "$free_gb" -ge 60 ]; then ok "Disk free on /: ${free_gb} GiB"
else warn "Disk free on /: ${free_gb} GiB (60+ recommended: images + model weights)"; fi

step "Preflight: GPU"
if grep -qsi '^0x10de' /sys/bus/pci/devices/*/vendor; then ok "NVIDIA device on the PCI bus"
else bad "no NVIDIA PCI device found. Is this a GPU instance?"; fi
if driver_ok; then ok "driver loaded: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1), ${GPU_COUNT} GPU(s)"
else warn "NVIDIA driver not loaded yet; the host phase will install it (may need a reboot)"; fi

step "Preflight: home directory"
fix_home_ownership
ok "~/.config and ~/.cache are writable"

step "Preflight: network (these hosts are all needed during setup)"
for url in \
  https://github.com \
  https://raw.githubusercontent.com \
  https://get.k3s.io \
  https://nvidia.github.io/k8s-device-plugin/index.yaml \
  https://huggingface.co \
  https://registry-1.docker.io/v2/ \
  https://ghcr.io/v2/ \
  https://registry.k8s.io/v2/ ; do
  if check_url "$url"; then ok "$url"; else bad "cannot reach $url"; fi
done
if [ "$INFERENCE_GATEWAY" = 1 ]; then
  if check_url https://cr.agentgateway.dev/v2/; then ok "https://cr.agentgateway.dev"; else bad "cannot reach https://cr.agentgateway.dev (agentgateway charts)"; fi
fi
if [ "$OBSERVABILITY" = 1 ]; then
  for url in https://prometheus-community.github.io/helm-charts/index.yaml \
             https://nvidia.github.io/dcgm-exporter/helm-charts/index.yaml; do
    if check_url "$url"; then ok "$url"; else bad "cannot reach $url"; fi
  done
fi

echo
if [ "$fails" -gt 0 ]; then die "Preflight found $fails blocker(s). Fix them, then re-run."; fi
info "Preflight passed."
