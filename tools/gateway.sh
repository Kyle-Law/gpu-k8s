#!/usr/bin/env bash
# Show how to reach everything through the Gateway, or send test requests through it.
#   tools/gateway.sh                 URLs, credentials and curl examples
#   tools/gateway.sh test ["prompt"] real requests through the gateway (from the VM)
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
need_kube

kubectl get httproute llm-gateway -n "$NAMESPACE" >/dev/null 2>&1 \
  || die "Gateway not installed. Run: ./setup.sh --only gateway"
user=$(kubectl get secret llm-gateway-credentials -n "$NAMESPACE" -o jsonpath='{.data.user}' | base64 -d)
pw=$(kubectl get secret llm-gateway-credentials -n "$NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)
host=$(public_host)
has_monitoring=0
kubectl get httproute monitoring-gateway -n "$MONITORING_NS" >/dev/null 2>&1 && has_monitoring=1

code() { curl -s -o /dev/null -m 15 -w '%{http_code}' "$@" || true; }

case "${1:-info}" in
  info)
    step "Gateway"
    info "Plain HTTP on port 80: credentials are NOT encrypted in transit."
    info "Credentials : $user / $pw"
    info "LLM API     : http://$host/llm/v1/...      (also http://$host/v1/...)"
    if [ "$has_monitoring" = 1 ]; then
      info "Grafana     : http://$host/grafana/        (then Grafana's own login; user admin, password via tools/grafana.sh)"
      info "Prometheus  : http://$host/prometheus/"
    else
      info "Grafana/Prometheus: not routed (install observability, then ./setup.sh --only gateway)"
    fi
    info "Try         : curl -u $user:$pw http://$host/llm/v1/models"
    info "Safer from your laptop, over an SSH tunnel:"
    info "  ssh -L 8080:localhost:80 <user>@<vm-ip>   then browse http://localhost:8080/grafana/"
    ;;
  test)
    prompt="${2:-Say hello in five words.}"
    base=http://127.0.0.1
    echo "--- /llm without credentials (expect 401): $(code "$base/llm/v1/models")"
    served=$(curl -s -m 15 -u "$user:$pw" "$base/llm/v1/models" | jq -r '.data[0].id // empty' 2>/dev/null || true)
    echo "--- /llm/v1/models with credentials: ${served:-no answer}"
    if [ -n "$served" ]; then
      payload=$(jq -n --arg m "$served" --arg p "$prompt" \
        '{model:$m, messages:[{role:"user",content:$p}], max_tokens:60, chat_template_kwargs:{enable_thinking:false}}')
      curl -s -m 120 -u "$user:$pw" "$base/llm/v1/chat/completions" -H 'Content-Type: application/json' -d "$payload" \
        | jq -r '.choices[0].message.content // .'
    fi
    if [ "$has_monitoring" = 1 ]; then
      echo "--- /grafana/api/health (expect 200): $(code -u "$user:$pw" "$base/grafana/api/health")"
      echo "--- /prometheus/-/healthy (expect 200): $(code -u "$user:$pw" "$base/prometheus/-/healthy")"
    fi
    ;;
  *) die "Usage: tools/gateway.sh [info|test [prompt]]" ;;
esac
