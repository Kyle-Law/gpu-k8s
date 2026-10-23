#!/usr/bin/env bash
# Observability: Prometheus + Grafana (kube-prometheus-stack), NVIDIA DCGM exporter for GPU
# metrics, vLLM + llm-d router scrape configs, and a ready-made Grafana dashboard.
# Idempotent. Works before or after the inference stack exists (monitors just start matching).
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"
need_kube
OBS="$GPUK8S_ROOT/manifests/observability"

step "Observability: Helm repos"
fix_home_ownership
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo add gpu-helm-charts https://nvidia.github.io/dcgm-exporter/helm-charts --force-update
helm repo update prometheus-community gpu-helm-charts

step "Observability: Prometheus + Grafana (release 'kps', namespace $MONITORING_NS)"
helm upgrade -i kps prometheus-community/kube-prometheus-stack \
  --namespace "$MONITORING_NS" --create-namespace \
  ${KPS_CHART_VERSION:+--version "$KPS_CHART_VERSION"} \
  -f "$OBS/kps-values.yaml" \
  --set prometheus.prometheusSpec.externalUrl="http://$(public_host)/prometheus" \
  --wait --timeout 10m

step "Observability: DCGM exporter (GPU utilisation, VRAM, power, temperature)"
# Runs under the nvidia RuntimeClass so it can see the GPU without *requesting* it, which
# means it does not compete with the model server for the single GPU.
helm upgrade -i dcgm gpu-helm-charts/dcgm-exporter \
  --namespace "$MONITORING_NS" \
  ${DCGM_CHART_VERSION:+--version "$DCGM_CHART_VERSION"} \
  --set runtimeClassName=nvidia \
  --set serviceMonitor.enabled=true \
  --set serviceMonitor.interval=15s \
  --wait --timeout 5m

step "Observability: vLLM scrape config + dashboard"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n "$NAMESPACE" -f "$OBS/vllm-podmonitor.yaml"

# dashboards/<folder>/*.json  ->  one ConfigMap each, shown in a Grafana folder named <folder>
for f in "$OBS"/dashboards/*/*.json; do
  folder=$(basename "$(dirname "$f")")
  name="dashboard-$(basename "$f" .json)"
  kubectl create configmap "$name" -n "$MONITORING_NS" --from-file="$(basename "$f")=$f" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl label configmap "$name" -n "$MONITORING_NS" grafana_dashboard=1 --overwrite
  kubectl annotate configmap "$name" -n "$MONITORING_NS" grafana_folder="$folder" --overwrite
done

step "Observability: llm-d router (EPP) metrics (best effort)"
# Scrape config is derived from the live Service, so it follows whatever labels/port name
# the llm-d chart used. EPP metrics may need auth; the service-account token is sent.
if svc_json=$(kubectl get svc "${GUIDE_NAME}-epp" -n "$NAMESPACE" -o json 2>/dev/null); then
  port_name=$(jq -r '.spec.ports[] | select(.port==9090) | .name // empty' <<<"$svc_json")
  if [ -n "$port_name" ]; then
    jq -n --argjson svc "$svc_json" --arg port "$port_name" --arg ns "$NAMESPACE" '{
      apiVersion: "monitoring.coreos.com/v1", kind: "ServiceMonitor",
      metadata: {name: "llm-d-router", namespace: $ns},
      spec: {selector: {matchLabels: $svc.metadata.labels},
             endpoints: [{port: $port, path: "/metrics", interval: "15s",
                          bearerTokenFile: "/var/run/secrets/kubernetes.io/serviceaccount/token"}]}}' \
      | kubectl apply -f -
  else
    info "Service ${GUIDE_NAME}-epp has no port 9090; skipping router metrics."
  fi
else
  info "llm-d router not deployed yet; skipping router metrics (re-run this script after the stack is up)."
fi

# If the gateway is already installed, add the /grafana and /prometheus routes now.
if kubectl get httproute llm-gateway -n "$NAMESPACE" >/dev/null 2>&1; then
  step "Observability: adding /grafana and /prometheus to the gateway"
  bash "$GPUK8S_ROOT/phases/45-gateway/install.sh"
fi

cat <<EOF

    Grafana / Prometheus are ClusterIP only (not exposed to the internet). From the VM:
      tools/grafana.sh               # prints the admin password + port-forwards Grafana to :3000
      tools/grafana.sh prometheus    # Prometheus UI on :9090
    From your laptop:  ssh -L 3000:localhost:3000 <user>@<vm-ip>   then open http://localhost:3000
    Dashboards: folder "gpu-k8s" ("GPU + vLLM") and folder "llm-d" (vLLM overview, KV cache, saturation, drill-down, router).  Ollama has no Prometheus endpoint, so only GPU panels fill for it.
EOF
