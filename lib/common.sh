#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables here are used by the scripts that source this file
# Shared settings + helpers. Sourced by every script (never run directly).
[ -n "${_GPUK8S_COMMON_LOADED:-}" ] && return 0
_GPUK8S_COMMON_LOADED=1
set -euo pipefail

GPUK8S_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export GPUK8S_ROOT

# Optional overrides: copy config.env.example to config.env (or pass env vars).
# shellcheck disable=SC1091
if [ -f "$GPUK8S_ROOT/config.env" ]; then source "$GPUK8S_ROOT/config.env"; fi

SUDO=""; if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; fi
export KUBECONFIG="$HOME/.kube/config"

# ---- GPU profile --------------------------------------------------------------
# legacy : compute capability < 7.5 (e.g. V100 = 7.0). Current vLLM/PyTorch images have
#          no kernels for these GPUs, so we pin an older vLLM, fp16 and eager mode.
# modern : compute capability >= 7.5 (T4, A-series, L-series, RTX, H100...). Uses llm-d's
#          own up-to-date vLLM image with default dtype (bf16) and a bigger model.
# Override with GPU_PROFILE=legacy|modern.
driver_ok() { command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; }

detect_gpu() {
  GPU_NAME="unknown"; GPU_CC=""; GPU_VRAM_MIB=0
  if driver_ok; then
    local line
    line=$(nvidia-smi --query-gpu=name,compute_cap,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || true)
    GPU_NAME=$(echo "$line" | cut -d, -f1 | sed 's/^ *//;s/ *$//')
    GPU_CC=$(echo "$line" | cut -d, -f2 | tr -d ' ')
    GPU_VRAM_MIB=$(echo "$line" | cut -d, -f3 | tr -d ' ')
    GPU_VRAM_MIB=${GPU_VRAM_MIB:-0}
  fi
}
detect_gpu

if [ -z "${GPU_PROFILE:-}" ]; then
  if [ -n "$GPU_CC" ] && awk -v cc="$GPU_CC" 'BEGIN{exit !(cc+0 < 7.5)}'; then
    GPU_PROFILE=legacy
  elif [ -z "$GPU_CC" ] && echo "$GPU_NAME" | grep -qiE 'V100|P100|P40|K80'; then
    GPU_PROFILE=legacy
  else
    GPU_PROFILE=modern
  fi
fi
case "$GPU_PROFILE" in legacy|modern) ;; *) echo "ERROR: GPU_PROFILE must be legacy|modern" >&2; exit 1 ;; esac

# ---- settings (env vars / config.env override these defaults) ----------------
: "${STACK:=llmd}"                    # llmd | ollama | none
: "${HF_TOKEN:=}"                     # leave empty for public models (a WRONG token causes 401s)
: "${NAMESPACE:=llm-d-quickstart}"
: "${GUIDE_NAME:=quickstart}"
: "${LLMD_BRANCH:=release-1.0}"
: "${LLMD_DIR:=$HOME/llm-d}"
: "${VLLM_EXTRA_ARGS:=}"              # extra space-separated vLLM flags
: "${OBSERVABILITY:=0}"               # 1 = also install Prometheus + Grafana + DCGM (setup.sh --observability)
: "${MONITORING_NS:=monitoring}"
: "${KPS_CHART_VERSION:=}"            # kube-prometheus-stack chart version (empty = latest)
: "${DCGM_CHART_VERSION:=}"           # dcgm-exporter chart version (empty = latest)

if [ "$GPU_PROFILE" = legacy ]; then
  : "${MODEL:=Qwen/Qwen3-0.6B}"
  : "${OLLAMA_MODEL:=qwen2.5:0.5b}"
  : "${MAX_MODEL_LEN:=4096}"
  : "${GPU_MEM_UTIL:=0.85}"
  # v0.8.5.post1 = torch 2.6 + CUDA 12.4: still ships sm_70 (V100) kernels and supports Qwen3.
  : "${VLLM_IMAGE:=vllm/vllm-openai:v0.8.5.post1}"
else
  : "${MODEL:=Qwen/Qwen3-8B}"
  : "${OLLAMA_MODEL:=qwen3:8b}"
  : "${MAX_MODEL_LEN:=8192}"
  : "${GPU_MEM_UTIL:=0.90}"
  : "${VLLM_IMAGE:=}"                 # empty = keep llm-d's own release image
fi

# Model server pod sizing (requests are what must fit on the node)
: "${MS_CPU_REQ:=2}"
: "${MS_MEM_REQ:=6Gi}"
: "${MS_MEM_LIM:=24Gi}"
: "${MS_SHM:=4Gi}"

DECODE_DEPLOY="optimized-baseline-nvidia-gpu-vllm-decode"
EXIT_REBOOT=10                        # phases/10-host/01-driver.sh exits with this when a reboot is needed

# ---- helpers ------------------------------------------------------------------
step() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need_kube() {
  if ! command -v kubectl >/dev/null 2>&1 || [ ! -f "$KUBECONFIG" ]; then
    die "k3s is not set up yet. Run phases/20-cluster/04-k3s.sh first (or ./setup.sh)."
  fi
}

# An earlier `sudo` command can leave ~/.config or ~/.cache root-owned, which makes helm
# fail with "mkdir ~/.config/helm: permission denied". Hand them back to the current user.
fix_home_ownership() {
  [ "$(id -u)" -ne 0 ] || return 0
  local d
  for d in "$HOME/.config" "$HOME/.cache"; do
    [ -d "$d" ] || continue
    if [ -n "$(find "$d" ! -user "$(id -un)" -print -quit 2>/dev/null)" ]; then
      info "Fixing ownership of $d (some entries were owned by another user)"
      $SUDO chown -R "$(id -u):$(id -g)" "$d"
    fi
  done
}

# check_url <url>  -> 0 if the host answers over HTTPS within 10 s (any HTTP status counts)
check_url() { curl -sS -o /dev/null -m 10 "$1" 2>/dev/null; }

wait_node_ready() { until kubectl get node 2>/dev/null | grep -q " Ready"; do sleep 3; done; }

deploy_exists() { kubectl get deploy "$1" -n "$2" >/dev/null 2>&1; }

# scale_deploy <name> <namespace> <replicas>   (no-op if the deployment doesn't exist)
scale_deploy() {
  if deploy_exists "$1" "$2"; then kubectl scale deploy/"$1" -n "$2" --replicas="$3"; fi
}

# Only one stack can hold the single GPU. A crash-looping pod still reserves it, so scale to 0.
free_gpu() {
  scale_deploy ollama default 0
  scale_deploy "$DECODE_DEPLOY" "$NAMESPACE" 0
  kubectl wait --for=delete pod -l app=ollama -n default --timeout=90s >/dev/null 2>&1 || true
  kubectl wait --for=delete pod -l llm-d.ai/guide=optimized-baseline -n "$NAMESPACE" --timeout=120s >/dev/null 2>&1 || true
}

print_profile() {
  info "GPU: ${GPU_NAME} (compute ${GPU_CC:-?}, ${GPU_VRAM_MIB} MiB)  ->  profile: ${GPU_PROFILE}"
  info "Models: llm-d=${MODEL}  ollama=${OLLAMA_MODEL}"
}
