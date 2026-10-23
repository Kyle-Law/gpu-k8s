#!/usr/bin/env bash
# Single-node k3s + kubeconfig for the current user.
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

step "k3s"
if ! command -v k3s >/dev/null 2>&1; then
  curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644
else
  info "k3s already installed."
fi

mkdir -p "$HOME/.kube"
cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"

info "Waiting for the node to register and become Ready..."
wait_node_ready

if ! $SUDO grep -q nvidia /var/lib/rancher/k3s/agent/etc/containerd/config.toml; then
  info "nvidia runtime not found in containerd config; restarting k3s..."
  $SUDO systemctl restart k3s
  sleep 15
  wait_node_ready
fi

kubectl get node
