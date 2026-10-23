#!/usr/bin/env bash
# Quick health overview: GPU, node, pods, endpoints.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

step "GPU"
print_profile
nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv

need_kube
step "Node + allocatable GPUs"
kubectl get node
kubectl get node -o jsonpath='{range .items[*]}{.metadata.name}{"  nvidia.com/gpu="}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}'

step "Pods: default"
kubectl get po -n default
step "Pods: $NAMESPACE"
kubectl get po -n "$NAMESPACE" 2>/dev/null || info "(namespace not present)"

step "Endpoints (inside the VM)"
if ip=$(kubectl get svc ollama -n default -o jsonpath='{.spec.clusterIP}' 2>/dev/null) && [ -n "$ip" ]; then
  info "Ollama : http://$ip:11434"
fi
if ip=$(kubectl get svc "${GUIDE_NAME}-epp" -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null) && [ -n "$ip" ]; then
  info "llm-d  : http://$ip/v1/completions"
fi
