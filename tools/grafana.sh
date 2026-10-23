#!/usr/bin/env bash
# Reach Grafana (default) or Prometheus from the VM. Not exposed publicly: use an SSH tunnel.
#   tools/grafana.sh               Grafana    -> http://localhost:3000   (prints the admin password)
#   tools/grafana.sh prometheus    Prometheus -> http://localhost:9090
# From your laptop first:  ssh -L 3000:localhost:3000 -L 9090:localhost:9090 <user>@<vm-ip>
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
need_kube

case "${1:-grafana}" in
  grafana)
    pw=$(kubectl get secret kps-grafana -n "$MONITORING_NS" -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d) \
      || die "Grafana not installed. Run: ./setup.sh --only observability"
    info "Grafana: http://localhost:3000   user: admin   password: $pw"
    exec kubectl port-forward -n "$MONITORING_NS" svc/kps-grafana 3000:80
    ;;
  prometheus)
    info "Prometheus: http://localhost:9090"
    exec kubectl port-forward -n "$MONITORING_NS" svc/kps-kube-prometheus-stack-prometheus 9090:9090
    ;;
  *) die "Usage: tools/grafana.sh [grafana|prometheus]" ;;
esac
