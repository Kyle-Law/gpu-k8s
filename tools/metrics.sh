#!/usr/bin/env bash
# Which LLM / GPU metrics does Prometheus actually have? Tells you which dashboards will fill in.
#   tools/metrics.sh              summary by family (vLLM, llm-d router, GPU) + dashboard readiness
#   tools/metrics.sh <regex>      list matching metric names, e.g.  tools/metrics.sh 'ttft|first_token'
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
need_kube

pod=$(kubectl get pod -n "$MONITORING_NS" -l app.kubernetes.io/name=prometheus -o name 2>/dev/null | head -1)
[ -n "$pod" ] || die "Prometheus not found in namespace $MONITORING_NS. Run: ./setup.sh --only observability"
names=$(kubectl exec -n "$MONITORING_NS" "$pod" -c prometheus -- \
  wget -qO- http://localhost:9090/api/v1/label/__name__/values | jq -r '.data[]')

if [ -n "${1:-}" ]; then
  grep -E "$1" <<<"$names" || echo "(no metric names match '$1')"
  exit 0
fi

count() { grep -cE "$1" <<<"$names" || true; }
vllm=$(count '^vllm:'); epp=$(count '^llm_d_epp_|^inference_'); gpu=$(count '^DCGM_')
step "Metric families in Prometheus"
info "vLLM model server  (vllm:*)         : $vllm"
info "llm-d router       (llm_d_epp_*)    : $epp"
info "GPU                (DCGM_*)         : $gpu"

step "Dashboards"
ready() { if [ "$2" -gt 0 ]; then echo "data available"; else echo "EMPTY - $3"; fi; }
info "gpu-k8s / GPU + vLLM        : GPU $(ready _ "$gpu" "check dcgm-exporter"), vLLM $(ready _ "$vllm" "check PodMonitor / is the model running?")"
info "llm-d / vLLM overview, KV cache : $(ready _ "$vllm" "check PodMonitor / is the model running?")"
info "llm-d / router, saturation, drill-down : $(ready _ "$epp" "router metrics not scraped; see below")"
if [ "$epp" -eq 0 ]; then
  info "Router scrape (best effort) status:"
  info "  kubectl get servicemonitor -n $NAMESPACE"
  info "  Prometheus UI -> Status -> Targets, look for the llm-d-router target and its error (often 401: metrics need auth)"
fi
if [ "$vllm" -gt 0 ] && ! grep -q '^vllm:kv_cache_usage_perc$' <<<"$names"; then
  info "Note: older vLLM metric names detected (legacy profile); some llm-d dashboard panels will stay empty."
fi
