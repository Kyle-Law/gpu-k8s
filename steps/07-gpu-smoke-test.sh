#!/usr/bin/env bash
# Run nvidia-smi inside a pod that requests one GPU.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
need_kube

step "GPU smoke test pod"
free_gpu
kubectl delete pod gpu-test -n default --ignore-not-found >/dev/null
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: gpu-test
  namespace: default
spec:
  restartPolicy: Never
  runtimeClassName: nvidia
  containers:
  - name: cuda
    image: nvidia/cuda:12.2.2-base-ubuntu22.04
    command: ["nvidia-smi"]
    resources:
      limits:
        nvidia.com/gpu: 1
EOF
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/gpu-test -n default --timeout=300s
kubectl logs gpu-test -n default
kubectl delete pod gpu-test -n default
