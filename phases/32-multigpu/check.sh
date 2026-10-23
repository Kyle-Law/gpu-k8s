#!/usr/bin/env bash
# Multi-GPU preflight: are all GPUs visible to the host and to Kubernetes, and how are they wired?
# Read-only apart from a short-lived test pod. Safe to re-run.
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"
need_kube

step "Multi-GPU: host view"
print_profile
[ "$GPU_COUNT" -ge 2 ] || die "Only $GPU_COUNT GPU visible; this phase needs 2+. For one GPU use: ./setup.sh --stack llmd"
nvidia-smi --query-gpu=index,name,memory.total,pci.bus_id --format=csv
# NV# = NVLink between the pair (fast tensor parallel); PHB/PIX/SYS = traffic goes over PCIe.
nvidia-smi topo -m
nvidia-smi nvlink --status 2>/dev/null | head -20 || true

step "Multi-GPU: Kubernetes view"
alloc=$(kubectl get node -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null || true)
info "Allocatable nvidia.com/gpu: ${alloc:-none}"
[ "${alloc:-0}" -ge 2 ] 2>/dev/null || die "Kubernetes only sees ${alloc:-0} GPU(s). Re-run phases/20-cluster/06-gpu-plugin.sh and check: kubectl -n nvidia-device-plugin logs ds/nvdp-nvidia-device-plugin"

step "Multi-GPU: one pod holding $GPU_COUNT GPUs"
free_gpu
kubectl delete pod gpu-test-multi -n default --ignore-not-found >/dev/null
kubectl apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: gpu-test-multi
  namespace: default
spec:
  restartPolicy: Never
  runtimeClassName: nvidia
  containers:
  - name: cuda
    image: nvidia/cuda:12.2.2-base-ubuntu22.04
    command: ["sh", "-c", "nvidia-smi -L && nvidia-smi topo -m"]
    resources:
      limits:
        nvidia.com/gpu: ${GPU_COUNT}
YAML
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/gpu-test-multi -n default --timeout=300s
kubectl logs gpu-test-multi -n default
kubectl delete pod gpu-test-multi -n default
