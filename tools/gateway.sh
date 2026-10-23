#!/usr/bin/env bash
# Show how to reach the model through the Gateway, or send a test request through it.
#   tools/gateway.sh                 URL, credentials and a curl example
#   tools/gateway.sh test ["prompt"] real request through the gateway (from the VM)
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
need_kube

kubectl get httproute llm-gateway -n "$NAMESPACE" >/dev/null 2>&1 \
  || die "Gateway not installed. Run: ./setup.sh --only gateway"
user=$(kubectl get secret llm-gateway-credentials -n "$NAMESPACE" -o jsonpath='{.data.user}' | base64 -d)
pw=$(kubectl get secret llm-gateway-credentials -n "$NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)
ext=$(kubectl get svc traefik -n kube-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

case "${1:-info}" in
  info)
    step "Gateway"
    info "Public address : http://${ext:-<vm-ip>}/v1   (plain HTTP: credentials are NOT encrypted in transit)"
    info "Credentials    : $user / $pw"
    info "Try (from anywhere your firewall allows):"
    info "  curl -u $user:$pw http://${ext:-<vm-ip>}/v1/models"
    info "Safer from your laptop, over an SSH tunnel:"
    info "  ssh -L 8080:localhost:80 <user>@<vm-ip>   then   curl -u $user:$pw http://localhost:8080/v1/models"
    ;;
  test)
    prompt="${2:-Say hello in five words.}"
    payload=$(jq -n --arg m "$MODEL" --arg p "$prompt" \
      '{model:$m, messages:[{role:"user",content:$p}], max_tokens:60, chat_template_kwargs:{enable_thinking:false}}')
    echo "--- without credentials (expect 401):"
    curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1/v1/models
    echo "--- with credentials:"
    curl -s -u "$user:$pw" http://127.0.0.1/v1/chat/completions -H 'Content-Type: application/json' -d "$payload" \
      | jq -r '.choices[0].message.content // .'
    ;;
  *) die "Usage: tools/gateway.sh [info|test [prompt]]" ;;
esac
