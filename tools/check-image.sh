#!/usr/bin/env bash
# Check whether a container image's PyTorch has kernels for THIS machine's GPU, before using it.
#   tools/check-image.sh <image>      (default: $VLLM_IMAGE if set)
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
need_kube

image="${1:-$VLLM_IMAGE}"
[ -n "$image" ] || die "Usage: tools/check-image.sh <image>   e.g. vllm/vllm-openai:v0.8.5.post1"
want_arch="sm_${GPU_CC//./}"

step "Target GPU: $GPU_NAME (compute $GPU_CC -> $want_arch)"
step "Freeing the GPU"
free_gpu

step "Testing: $image   (a first vLLM image pull is ~8-10 GB; can take several minutes)"
kubectl delete pod gpu-image-check -n default --ignore-not-found >/dev/null
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: gpu-image-check
  namespace: default
spec:
  restartPolicy: Never
  runtimeClassName: nvidia
  containers:
  - name: c
    image: ${image}
    command: ["python3", "-c"]
    args:
    - |
      import torch
      print("torch", torch.__version__, "| built for CUDA", torch.version.cuda)
      print("arch_list:", torch.cuda.get_arch_list())
      x = torch.ones(4, device="cuda")
      print("KERNEL TEST OK:", (x * 2).sum().item())
    resources:
      limits:
        nvidia.com/gpu: 1
EOF

phase=""
for _ in $(seq 1 240); do
  phase=$(kubectl get pod gpu-image-check -n default -o jsonpath='{.status.phase}' 2>/dev/null || true)
  if [ "$phase" = "Succeeded" ] || [ "$phase" = "Failed" ]; then break; fi
  sleep 5
done

step "Result (phase: ${phase:-unknown})"
out=$(kubectl logs gpu-image-check -n default 2>&1 | tail -15 || true)
echo "$out"
kubectl delete pod gpu-image-check -n default --ignore-not-found >/dev/null
echo
if echo "$out" | grep -q "KERNEL TEST OK"; then
  echo "OK: this image runs on $GPU_NAME."
else
  echo "FAILED: this image does not run on $GPU_NAME (looking for $want_arch in arch_list)."
  exit 1
fi
