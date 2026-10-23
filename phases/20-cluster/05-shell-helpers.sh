#!/usr/bin/env bash
# kubectl alias `k` + tab completion in ~/.bashrc (idempotent).
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

step "Shell helpers (alias k + autocomplete)"
if grep -q "# --- kubectl helpers ---" "$HOME/.bashrc" 2>/dev/null; then
  info "Already in ~/.bashrc."
else
  cat >> "$HOME/.bashrc" <<'EOF'

# --- kubectl helpers ---
export KUBECONFIG="$HOME/.kube/config"
source <(kubectl completion bash)
alias k=kubectl
complete -o default -F __start_kubectl k
# --- end kubectl helpers ---
EOF
  info "Added. Run: source ~/.bashrc"
fi
