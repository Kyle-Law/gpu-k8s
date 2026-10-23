#!/usr/bin/env bash
# RuntimeClass `nvidia` + NVIDIA device plugin, then wait until the GPU is allocatable.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
need_kube

step "RuntimeClass + NVIDIA device plugin"
kubectl apply -f - <<'EOF'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: nvidia
EOF

if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin >/dev/null 2>&1 || true
helm repo update
helm upgrade -i nvdp nvdp/nvidia-device-plugin \
  --namespace nvidia-device-plugin --create-namespace \
  --set runtimeClassName=nvidia

# The plugin only schedules onto labelled GPU nodes (normally done by Node Feature Discovery).
kubectl label node --all nvidia.com/gpu.present=true --overwrite

info "Waiting for the GPU to show up as allocatable..."
gpus=""
for _ in $(seq 1 60); do
  gpus=$(kubectl get node -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null || true)
  [ -n "$gpus" ] && break
  sleep 5
done
[ -n "$gpus" ] || die "GPU never became allocatable. Check: kubectl -n nvidia-device-plugin get po,logs"
info "Allocatable GPUs: $gpus"
