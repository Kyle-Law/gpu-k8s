#!/usr/bin/env bash
# llm-d router + vLLM on 2+ GPUs of one node (selected with: ./setup.sh --stack llmd-multi).
#   MULTIGPU_MODE=tp        (default) ONE replica split over all GPUs with tensor parallelism:
#                           lets a model that is too big for one card run (2 x V100 16 GB -> Qwen3-8B fp16)
#   MULTIGPU_MODE=replicas  one replica PER GPU; the llm-d router balances between them
#                           (2 x V100 16 GB -> 2 x Qwen3-4B): more throughput, not a bigger model
# Same Deployment name, namespace and labels as the single-GPU stack, so tools/test.sh,
# tools/teardown.sh, the gateway, observability and verify all work unchanged.
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"
source "$GPUK8S_ROOT/lib/llmd.sh"
need_kube

step "llm-d (multi-GPU): settings"
print_profile
[ "$GPU_COUNT" -ge 2 ] || die "Only $GPU_COUNT GPU visible; this phase needs 2+. For one GPU use: ./setup.sh --stack llmd"
gpus_per_pod=$TP_SIZE
need=$((REPLICAS * gpus_per_pod))
[ "$need" -le "$GPU_COUNT" ] || die "REPLICAS=$REPLICAS x TP_SIZE=$TP_SIZE needs $need GPUs, the node has $GPU_COUNT"
info "mode=$MULTIGPU_MODE: $REPLICAS replica(s) x $gpus_per_pod GPU(s), model=$MODEL, max-model-len=$MAX_MODEL_LEN"
if [ "$GPU_PROFILE" = legacy ]; then
  info "legacy profile: image=$VLLM_IMAGE, fp16, eager mode"
fi

llmd_install_router

step "llm-d (multi-GPU): model server overlay ($MODEL)"
flags=()
[ "$gpus_per_pod" -le 1 ] || flags+=("--tensor-parallel-size=${gpus_per_pod}")
llmd_vllm_args ${flags[@]+"${flags[@]}"}
llmd_deploy_modelserver multi-gpu "$REPLICAS" "$gpus_per_pod"

llmd_wait_ready

step "llm-d (multi-GPU): GPU memory in use (every GPU should hold weights)"
nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv

step "llm-d (multi-GPU): test"
bash "$GPUK8S_ROOT/tools/test.sh" llmd
