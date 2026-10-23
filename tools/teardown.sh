#!/usr/bin/env bash
# Remove things. Explicit target required.
#   tools/teardown.sh ollama   # deployment + service + PVC (downloaded models are deleted too)
#   tools/teardown.sh llmd     # helm release + namespace
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
  k3s)
    [ -x /usr/local/bin/k3s-uninstall.sh ] || die "k3s is not installed."
    /usr/local/bin/k3s-uninstall.sh
    ;;
  *) die "Usage: tools/teardown.sh [ollama|llmd|k3s]" ;;
esac
echo "Reminder: delete the cloud instance itself when you are done (stopping may still bill)."
