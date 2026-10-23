#!/usr/bin/env bash
# Remove things. Explicit target required.
#   tools/teardown.sh ollama   # deployment + service + PVC (downloaded models are deleted too)
#   tools/teardown.sh llmd     # helm release + namespace
#   tools/teardown.sh observability   # Prometheus, Grafana, DCGM exporter (+ stored metrics)
#   tools/teardown.sh k3s      # uninstall k3s entirely
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

target="${1:-}"
case "$target" in
  ollama)
    need_kube
    kubectl delete -f "$GPUK8S_ROOT/manifests/ollama.yaml" --ignore-not-found
    ;;
  llmd)
    need_kube
    helm uninstall "$GUIDE_NAME" -n "$NAMESPACE" || true
    kubectl delete namespace "$NAMESPACE" --ignore-not-found
    ;;
  observability)
    need_kube
    helm uninstall dcgm -n "$MONITORING_NS" || true
    helm uninstall kps -n "$MONITORING_NS" || true
    kubectl delete namespace "$MONITORING_NS" --ignore-not-found   # also removes Prometheus data (PVC)
    kubectl delete configmap -n "$MONITORING_NS" -l grafana_dashboard=1 --ignore-not-found 2>/dev/null || true
    echo "Note: the Prometheus Operator CRDs are left in place (they are cluster-wide and harmless)."
    ;;
  k3s)
    [ -x /usr/local/bin/k3s-uninstall.sh ] || die "k3s is not installed."
    /usr/local/bin/k3s-uninstall.sh
    ;;
  *) die "Usage: tools/teardown.sh [ollama|llmd|observability|k3s]" ;;
esac
echo "Reminder: delete the cloud instance itself when you are done (stopping may still bill)."
