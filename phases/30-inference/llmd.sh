#!/usr/bin/env bash
# llm-d router (standalone mode) + a vLLM model server sized for ONE GPU.
# The model server flags depend on the GPU profile (see lib/common.sh).
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"
need_kube

step "llm-d: settings"
print_profile
if [ "$GPU_PROFILE" = legacy ]; then
  info "legacy profile: image=$VLLM_IMAGE, fp16, eager mode, max-model-len=$MAX_MODEL_LEN"
else
  info "modern profile: llm-d's own vLLM image, default dtype (bf16), max-model-len=$MAX_MODEL_LEN, gpu-mem-util=$GPU_MEM_UTIL"
fi

step "llm-d: repo, CRDs, namespace, secret"
free_gpu
export REPO_ROOT="$LLMD_DIR"
if [ ! -d "$REPO_ROOT/.git" ]; then
  git clone https://github.com/llm-d/llm-d.git "$REPO_ROOT"
fi
cd "$REPO_ROOT" || die "Cannot enter $REPO_ROOT"
git checkout "$LLMD_BRANCH"
# shellcheck disable=SC1091
source guides/env.sh
info "GAIE_URL=${GAIE_URL:?env.sh did not set GAIE_URL}  ROUTER_CHART_VERSION=${ROUTER_CHART_VERSION:?not set}"

kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api-inference-extension/${GAIE_URL}/v1-manifests.yaml"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
# Empty token is fine for public models; a WRONG token causes 401s.
kubectl create secret generic llm-d-hf-token \
  --from-literal="HF_TOKEN=${HF_TOKEN}" \
  --namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

step "llm-d: router (standalone)"
fix_home_ownership
helm upgrade -i "$GUIDE_NAME" "$ROUTER_STANDALONE_CHART" \
  -f guides/recipes/router/base.values.yaml \
  -f guides/optimized-baseline/router/optimized-baseline.values.yaml \
  -n "$NAMESPACE" --version "$ROUTER_CHART_VERSION"

# The router defaults request 8 CPU / 16Gi in total: more than a small VM has.
# (Re-applied after every helm upgrade, since upgrade resets it.)
kubectl set resources deploy/"${GUIDE_NAME}-epp" -n "$NAMESPACE" -c envoy-proxy \
  --requests=cpu=250m,memory=256Mi --limits=memory=1Gi
kubectl set resources deploy/"${GUIDE_NAME}-epp" -n "$NAMESPACE" -c epp \
  --requests=cpu=500m,memory=512Mi --limits=memory=2Gi

step "llm-d: model server overlay ($MODEL)"
overlay="guides/optimized-baseline/modelserver/gpu/vllm/single-gpu"
mkdir -p "$overlay"
cat > "$overlay/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../base
patches:
  - path: patch-single-gpu.yaml
EOF

# vLLM args. The base uses --tensor-parallel-size=2 etc. (for 2 GPUs); we replace them all.
args=("$MODEL"
      "--disable-access-log-for-endpoints=/health,/metrics,/v1/models"
      "--max-model-len=${MAX_MODEL_LEN}"
      "--gpu-memory-utilization=${GPU_MEM_UTIL}")
if [ "$GPU_PROFILE" = legacy ]; then
  args+=("--dtype=half" "--enforce-eager")          # V100: no bf16; skip compile paths
else
  case "$MODEL" in
    *Qwen3*|*qwen3*) args+=("--enable-auto-tool-choice" "--tool-call-parser=hermes" "--reasoning-parser=qwen3") ;;
  esac
  args+=("--shutdown-timeout=45")                    # flag exists in current vLLM only
fi
# shellcheck disable=SC2206  # intentional word splitting of the extra-args string
extra=(${VLLM_EXTRA_ARGS})
args+=("${extra[@]}")

{
  cat <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DECODE_DEPLOY}
spec:
  replicas: 1
  template:
    spec:
      runtimeClassName: nvidia
      containers:
        - name: modelserver
EOF
  if [ -n "$VLLM_IMAGE" ]; then echo "          image: ${VLLM_IMAGE}"; fi
  echo "          args:"
  for a in "${args[@]}"; do printf '            - "%s"\n' "$a"; done
  if [ "$GPU_PROFILE" = legacy ]; then
    cat <<'EOF'
          env:
            - name: VLLM_USE_V1
              value: "0"
EOF
  fi
  cat <<EOF
          resources:
            limits:
              memory: ${MS_MEM_LIM}
              nvidia.com/gpu: 1
            requests:
              cpu: "${MS_CPU_REQ}"
              memory: ${MS_MEM_REQ}
              nvidia.com/gpu: 1
      volumes:
        - name: shm
          emptyDir:
            medium: Memory
            sizeLimit: ${MS_SHM}
EOF
} > "$overlay/patch-single-gpu.yaml"
info "vLLM args: ${args[*]}"

# Recreate cleanly: a rolling update would need a 2nd GPU for the surge pod.
kubectl delete deploy/"$DECODE_DEPLOY" -n "$NAMESPACE" --ignore-not-found
kubectl apply -n "$NAMESPACE" -k "$overlay"

step "llm-d: waiting for pods (first start pulls the vLLM image + model weights; 10+ min)"
sleep 20
kubectl get po -n "$NAMESPACE"
for p in $(kubectl get po -n "$NAMESPACE" --field-selector=status.phase=Pending -o name); do
  echo "--- $p is Pending; scheduler events: ---"
  kubectl describe -n "$NAMESPACE" "$p" | sed -n '/^Events:/,$p'
done
if ! kubectl rollout status deploy/"$DECODE_DEPLOY" -n "$NAMESPACE" --timeout=2400s; then
  echo "!!! model server not ready. Logs / events:"
  kubectl logs -n "$NAMESPACE" deploy/"$DECODE_DEPLOY" --tail=60 || true
  kubectl describe po -n "$NAMESPACE" -l llm-d.ai/guide=optimized-baseline | sed -n '/^Events:/,$p'
  exit 1
fi

step "llm-d: test"
bash "$GPUK8S_ROOT/tools/test.sh" llmd
