#!/usr/bin/env bash
# llm-d router (standalone mode) + a vLLM model server sized for ONE GPU.
# The model server flags depend on the GPU profile (see lib/common.sh).
# For 2+ GPUs see phases/32-multigpu/.
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"
source "$GPUK8S_ROOT/lib/llmd.sh"
need_kube

step "llm-d: settings"
print_profile
if [ "$GPU_PROFILE" = legacy ]; then
  info "legacy profile: image=$VLLM_IMAGE, fp16, eager mode, max-model-len=$MAX_MODEL_LEN"
else
  info "modern profile: llm-d's own vLLM image, default dtype (bf16), max-model-len=$MAX_MODEL_LEN, gpu-mem-util=$GPU_MEM_UTIL"
fi

llmd_install_router

step "llm-d: model server overlay ($MODEL)"
llmd_vllm_args
llmd_deploy_modelserver single-gpu 1 1

llmd_wait_ready

step "llm-d: test"
bash "$GPUK8S_ROOT/tools/test.sh" llmd
