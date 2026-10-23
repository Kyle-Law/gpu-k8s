#!/usr/bin/env bash
# Verify the finished deployment end to end. Read-only apart from one test prompt.
# Exit 1 if anything required is broken.
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"
need_kube

fails=0
ok()   { printf '    [ ok ] %s\n' "$*"; }
warn() { printf '    [warn] %s\n' "$*"; }
bad()  { printf '    [FAIL] %s\n' "$*"; fails=$((fails + 1)); }

# prom_count <promql> -> number of series, or "" if Prometheus can't be queried
prom_count() {
  local pod
  pod=$(kubectl get pod -n "$MONITORING_NS" -l app.kubernetes.io/name=prometheus -o name 2>/dev/null | head -1)
  [ -n "$pod" ] || return 0
  kubectl exec -n "$MONITORING_NS" "$pod" -c prometheus -- \
    wget -qO- --post-data="query=count($1)" http://localhost:9090/api/v1/query 2>/dev/null \
    | jq -r '.data.result[0].value[1] // "0"' 2>/dev/null || true
}

step "Verify: cluster + GPU"
if kubectl get node 2>/dev/null | grep -q ' Ready'; then ok "node Ready"; else bad "node not Ready"; fi
gpus=$(kubectl get node -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null || true)
if [ "${gpus:-0}" -ge 1 ] 2>/dev/null; then ok "allocatable GPUs: $gpus"; else bad "no allocatable nvidia.com/gpu"; fi

step "Verify: inference"
ran_any=0
llmd_ready=$(kubectl get deploy "$DECODE_DEPLOY" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
ollama_ready=$(kubectl get deploy ollama -n default -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
if [ "${llmd_ready:-0}" -ge 1 ]; then
  ran_any=1
  if bash "$GPUK8S_ROOT/tools/test.sh" llmd >/dev/null 2>&1; then ok "llm-d answers a completion ($MODEL)"
  else bad "llm-d is Ready but the test prompt failed (tools/test.sh llmd)"; fi
fi
if [ "${ollama_ready:-0}" -ge 1 ]; then
  ran_any=1
  if bash "$GPUK8S_ROOT/tools/test.sh" ollama >/dev/null 2>&1; then ok "Ollama answers a chat ($OLLAMA_MODEL)"
  else bad "Ollama is Ready but the test prompt failed (tools/test.sh ollama)"; fi
fi
if [ "$ran_any" = 0 ]; then
  if [ "$STACK" = none ]; then info "no inference stack deployed (STACK=none)"; else bad "no inference stack is Ready"; fi
fi

if kubectl get ns "$MONITORING_NS" >/dev/null 2>&1; then
  step "Verify: observability"
  not_ready=$(kubectl get pods -n "$MONITORING_NS" --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed"' | wc -l)
  if [ "$not_ready" -eq 0 ]; then ok "all pods in $MONITORING_NS are Running"; else bad "$not_ready pod(s) in $MONITORING_NS not Running"; fi
  n=$(prom_count DCGM_FI_DEV_GPU_UTIL)
  if [ "${n:-0}" -ge 1 ] 2>/dev/null; then ok "Prometheus has GPU metrics (DCGM)"; else bad "no DCGM_FI_DEV_GPU_UTIL in Prometheus yet (kubectl -n $MONITORING_NS get po -l app.kubernetes.io/name=dcgm-exporter)"; fi
  if [ "${llmd_ready:-0}" -ge 1 ]; then
    n=$(prom_count 'vllm:num_requests_running')
    if [ "${n:-0}" -ge 1 ] 2>/dev/null; then ok "Prometheus has vLLM metrics"; else bad "no vllm:* metrics in Prometheus (check the PodMonitor: kubectl get podmonitor -n $NAMESPACE)"; fi
    n=$(prom_count 'up{job=~".*epp.*"} == 1')
    if [ "${n:-0}" -ge 1 ] 2>/dev/null; then ok "Prometheus scrapes the llm-d router"; else warn "llm-d router metrics not scraped (best effort; may need auth)"; fi
  fi
fi

echo
if [ "$fails" -gt 0 ]; then die "Verify found $fails problem(s)."; fi
info "Everything checked is healthy."
