#!/usr/bin/env bash
# Only one stack can hold the single GPU. Swap between them.
#   tools/switch-stack.sh ollama
#   tools/switch-stack.sh llmd
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
need_kube

target="${1:-}"
case "$target" in
  ollama)
    deploy_exists ollama default || die "Ollama is not deployed. Run stacks/ollama.sh first."
    step "Switching to Ollama"
    scale_deploy "$DECODE_DEPLOY" "$NAMESPACE" 0
    kubectl wait --for=delete pod -l llm-d.ai/guide=optimized-baseline -n "$NAMESPACE" --timeout=120s >/dev/null 2>&1 || true
    scale_deploy ollama default 1
    kubectl rollout status deploy/ollama -n default --timeout=300s
    ;;
  llmd)
    deploy_exists "$DECODE_DEPLOY" "$NAMESPACE" || die "llm-d is not deployed. Run stacks/llmd.sh first."
    step "Switching to llm-d"
    scale_deploy ollama default 0
    kubectl wait --for=delete pod -l app=ollama -n default --timeout=90s >/dev/null 2>&1 || true
    scale_deploy "$DECODE_DEPLOY" "$NAMESPACE" 1
    kubectl rollout status deploy/"$DECODE_DEPLOY" -n "$NAMESPACE" --timeout=900s
    ;;
  *) die "Usage: tools/switch-stack.sh [ollama|llmd]" ;;
esac
