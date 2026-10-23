#!/usr/bin/env bash
# llm-d in GATEWAY mode, next to the standalone router, so you can compare the two.
#
#   standalone (/llm):  Traefik -> quickstart-epp Service -> Envoy sidecar -> EPP picks pod -> vLLM
#   gateway    (/pool): Traefik -> agentgateway Gateway -> HTTPRoute whose backendRef is the
#                       InferencePool -> agentgateway asks the EPP (ext_proc) -> vLLM
#
# agentgateway is a Gateway API controller that implements the Inference Extension (Traefik does
# not), so here an HTTPRoute really uses `kind: InferencePool` as its backend. Both modes share
# the same vLLM pod(s); each has its own EPP. Follows llm-d's agentgateway guide
# (docs/infrastructure/gateway/agentgateway.md) and its gateway-mode router chart. Idempotent.
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"
need_kube

AGW_NS=agentgateway-system
IGW_GATEWAY=llm-d-inference-gateway
IGW_RELEASE="${GUIDE_NAME}-gw"          # its InferencePool and HTTPRoute get this name too

deploy_exists "$DECODE_DEPLOY" "$NAMESPACE" \
  || die "llm-d is not deployed. Run: ./setup.sh --only inference --stack llmd"
[ -f "$LLMD_DIR/guides/env.sh" ] \
  || die "llm-d repo not found at $LLMD_DIR (phases/30-inference/llmd.sh clones it)."
kubectl get crd inferencepools.inference.networking.k8s.io >/dev/null 2>&1 \
  || die "InferencePool CRD missing (phases/30-inference/llmd.sh installs it)."

step "agentgateway $AGENTGATEWAY_VERSION (Gateway API controller with Inference Extension support)"
fix_home_ownership
helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --namespace "$AGW_NS" --create-namespace --version "$AGENTGATEWAY_VERSION" --wait
helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --namespace "$AGW_NS" --version "$AGENTGATEWAY_VERSION" \
  --set inferenceExtension.enabled=true --wait --timeout 5m
kubectl wait --for=condition=Accepted gatewayclass/agentgateway --timeout=120s

step "Gateway '$IGW_GATEWAY' (class agentgateway, ClusterIP only)"
# llm-d's agentgateway recipe, plus the AgentgatewayParameters trick from its OpenShift variant:
# keep the data-plane Service ClusterIP. Otherwise it is a LoadBalancer, which on k3s would grab
# a host port on the public IP with no authentication. We reach it through Traefik instead.
kubectl apply -n "$NAMESPACE" -f - <<YAML
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayParameters
metadata:
  name: agentgateway-params
spec:
  service:
    spec:
      type: ClusterIP
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${IGW_GATEWAY}
spec:
  gatewayClassName: agentgateway
  infrastructure:
    parametersRef:
      group: agentgateway.dev
      kind: AgentgatewayParameters
      name: agentgateway-params
  listeners:
    - name: default
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All
YAML
kubectl wait --for=condition=Programmed gateway/"$IGW_GATEWAY" -n "$NAMESPACE" --timeout=180s

step "llm-d router, gateway mode (release '$IGW_RELEASE': EPP + InferencePool + HTTPRoute)"
# Subshell: llm-d's env.sh exports its own versions (e.g. GATEWAY_API_VERSION) that must not leak.
(
  export REPO_ROOT="$LLMD_DIR"
  cd "$LLMD_DIR"
  # shellcheck disable=SC1091
  source guides/env.sh
  helm upgrade -i "$IGW_RELEASE" "$ROUTER_GATEWAY_CHART" \
    -f guides/recipes/router/base.values.yaml \
    -f guides/optimized-baseline/router/optimized-baseline.values.yaml \
    -f "$GPUK8S_ROOT/manifests/inference-gateway/router-gateway.values.yaml" \
    --set provider.name=agentgateway \
    --set httpRoute.create=true \
    --set httpRoute.inferenceGatewayName="$IGW_GATEWAY" \
    -n "$NAMESPACE" --version "$ROUTER_CHART_VERSION" --wait --timeout 10m
)

info "HTTPRoute '$IGW_RELEASE' -> backendRef: $(kubectl get httproute "$IGW_RELEASE" -n "$NAMESPACE" \
  -o jsonpath='{.spec.rules[0].backendRefs[0].kind}/{.spec.rules[0].backendRefs[0].name}')"
# ResolvedRefs=True is the proof: agentgateway accepted an InferencePool as a backend.
kubectl wait httproute/"$IGW_RELEASE" -n "$NAMESPACE" --timeout=120s \
  --for=jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}'=True \
  || info "Not resolved yet; inspect: kubectl describe httproute $IGW_RELEASE -n $NAMESPACE"
kubectl get httproute "$IGW_RELEASE" -n "$NAMESPACE" \
  -o jsonpath='{range .status.parents[0].conditions[*]}    {.type}={.status} ({.reason}){"\n"}{end}'

step "Expose it at /pool through Traefik (same basic auth as /llm)"
svc=$(kubectl get svc -n "$NAMESPACE" -l gateway.networking.k8s.io/gateway-name="$IGW_GATEWAY" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
svc="${svc:-$IGW_GATEWAY}"
if kubectl get middleware.traefik.io llm-gateway-auth -n "$NAMESPACE" >/dev/null 2>&1; then
  kubectl apply -n "$NAMESPACE" -f - <<YAML
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: pool-gateway
spec:
  parentRefs:
    - name: traefik-gateway
      namespace: kube-system
      sectionName: web
  rules:
    - matches:
        - path: {type: PathPrefix, value: /pool}
      filters:
        - type: ExtensionRef
          extensionRef: {group: traefik.io, kind: Middleware, name: llm-gateway-auth}
        - type: URLRewrite
          urlRewrite:
            path: {type: ReplacePrefixMatch, replacePrefixMatch: /}
      backendRefs:
        - name: ${svc}
          port: 80
YAML
  kubectl wait httproute/pool-gateway -n "$NAMESPACE" --timeout=60s \
    --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True \
    || info "pool-gateway not Accepted yet; inspect: kubectl describe httproute pool-gateway -n $NAMESPACE"
  info "Gateway mode : http://$(public_host)/pool/v1/...   (compare with standalone at /llm/v1/...)"
  info "Test         : tools/gateway.sh test     or from your laptop: LLM_PATH=pool client/chat.sh \"hi\""
else
  info "The Traefik gateway phase is not installed, so /pool is not exposed. From the VM:"
  info "  kubectl port-forward -n $NAMESPACE svc/$svc 8080:80   then  curl localhost:8080/v1/models"
fi
