#!/usr/bin/env bash
# Send a test prompt.   Usage: tools/test.sh [llmd|ollama] ["your prompt"]
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
need_kube

target="${1:-$STACK}"
prompt="${2:-How are you today?}"

case "$target" in
  ollama)
    ip=$(kubectl get svc ollama -n default -o jsonpath='{.spec.clusterIP}')
    payload=$(jq -n --arg m "$OLLAMA_MODEL" --arg p "$prompt" \
      '{model:$m, messages:[{role:"user", content:$p}], stream:false}')
    info "POST http://$ip:11434/api/chat  (first call includes model load time)"
    curl -s -m 120 "http://$ip:11434/api/chat" -d "$payload" | jq -r .message.content
    echo "--- ollama ps (PROCESSOR should say 100% GPU) ---"
    kubectl exec -n default deploy/ollama -- ollama ps
    ;;
  llmd)
    ip=$(kubectl get svc "${GUIDE_NAME}-epp" -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}')
    payload=$(jq -n --arg m "$MODEL" --arg p "$prompt" '{model:$m, prompt:$p, max_tokens:40}')
    info "POST http://$ip/v1/completions"
    ok=0
    for _ in $(seq 1 24); do
      out=$(curl -s -m 60 "http://$ip/v1/completions" -H "Content-Type: application/json" -d "$payload" || true)
      if echo "$out" | grep -q '"choices"'; then echo "$out" | jq .; ok=1; break; fi
      sleep 5
    done
    [ "$ok" = 1 ] || die "No completion. Check: kubectl -n $NAMESPACE logs deploy/${GUIDE_NAME}-epp -c epp --tail=50"
    ;;
  *) die "Usage: tools/test.sh [llmd|ollama] [prompt]" ;;
esac
