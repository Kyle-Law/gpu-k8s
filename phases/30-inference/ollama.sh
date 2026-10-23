#!/usr/bin/env bash
# Ollama (llama.cpp): simplest way to serve a model on a single GPU.
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"
need_kube

step "Ollama: deploy"
print_profile
free_gpu
kubectl apply -n default -f "$GPUK8S_ROOT/manifests/ollama.yaml"
kubectl rollout status deploy/ollama -n default --timeout=300s

step "Ollama: pull '$OLLAMA_MODEL'"
kubectl exec -n default deploy/ollama -- ollama pull "$OLLAMA_MODEL"

step "Ollama: test"
bash "$GPUK8S_ROOT/tools/test.sh" ollama
