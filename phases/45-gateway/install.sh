#!/usr/bin/env bash
# Gateway API in front of the model, using k3s's bundled Traefik as the controller.
#   1. Gateway API CRDs (standard channel, version Traefik documents support for)
#   2. Traefik: turn on its Gateway provider and let routes from any namespace attach
#   3. HTTPRoutes, all behind one basic-auth Middleware, with the path prefix stripped:
#        /llm  (and /v1)  -> llm-d router
#        /grafana         -> Grafana        (only if observability is installed)
#        /prometheus      -> Prometheus     (only if observability is installed)
# Idempotent. The credentials are generated once and kept in a Secret.
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"
need_kube

kubectl get deploy traefik -n kube-system >/dev/null 2>&1 \
  || die "Traefik is not running in kube-system (was k3s installed with --disable traefik?)."

step "Gateway API: CRDs"
# Recent k3s ships the Gateway API CRDs itself (via its Helm-managed traefik-crd chart).
# Applying our own copy then fails with server-side-apply conflicts, so only install them
# when they are missing.
if kubectl get crd gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io >/dev/null 2>&1; then
  have=$(kubectl get crd gateways.gateway.networking.k8s.io \
    -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}' 2>/dev/null || true)
  info "Gateway API CRDs already present (bundle ${have:-unknown}); leaving them alone."
  [ "$have" = "$GATEWAY_API_VERSION" ] || info "(Traefik 3.7 documents support for $GATEWAY_API_VERSION; a nearby version is normally fine.)"
else
  info "Installing Gateway API CRDs $GATEWAY_API_VERSION (standard channel)"
  kubectl apply --server-side -f \
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
fi

step "Gateway API: enable Traefik's Gateway provider"
# k3s merges a HelmChartConfig named after its bundled chart into the chart's values.
# The default Gateway ('traefik-gateway', listener 'web' on :80) only accepts routes from
# its own namespace, so allow all namespaces: our HTTPRoute lives next to the model.
kubectl apply -f - <<'YAML'
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    providers:
      kubernetesGateway:
        enabled: true
    gateway:
      listeners:
        web:
          namespacePolicy:
            from: All
YAML

info "Waiting for the k3s helm-controller to redeploy Traefik with the Gateway provider..."
for _ in $(seq 1 60); do
  kubectl get gateway traefik-gateway -n kube-system >/dev/null 2>&1 && break
  sleep 5
done
kubectl get gateway traefik-gateway -n kube-system >/dev/null 2>&1 \
  || die "Gateway 'traefik-gateway' never appeared. Check: kubectl -n kube-system get helmchart,job,pod | grep traefik"
kubectl rollout status deploy/traefik -n kube-system --timeout=180s
kubectl wait --for=condition=Programmed gateway/traefik-gateway -n kube-system --timeout=180s

step "Gateway API: credentials + route to the llm-d router (namespace $NAMESPACE)"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
if ! kubectl get secret llm-gateway-credentials -n "$NAMESPACE" >/dev/null 2>&1; then
  pw=$(openssl rand -hex 16)
  hash=$(printf '%s' "$pw" | openssl passwd -apr1 -stdin)
  kubectl create secret generic llm-gateway-auth -n "$NAMESPACE" \
    --from-literal=users="${GATEWAY_USER}:${hash}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret generic llm-gateway-credentials -n "$NAMESPACE" \
    --from-literal=user="$GATEWAY_USER" --from-literal=password="$pw"
  info "Generated credentials for user '$GATEWAY_USER' (show them with: tools/gateway.sh)"
else
  info "Credentials already exist; keeping them."
fi

# Every path is served with its prefix stripped (/llm/v1/models -> /v1/models), so the
# backends keep serving from "/". /v1 is also routed unchanged for plain OpenAI-style clients.
kubectl apply -n "$NAMESPACE" -f - <<YAML
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: llm-gateway-auth
spec:
  basicAuth:
    secret: llm-gateway-auth
    removeHeader: true      # do not forward the credentials to the backend
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: llm-gateway
spec:
  parentRefs:
    - name: traefik-gateway
      namespace: kube-system
      sectionName: web
  rules:
    - matches:
        - path: {type: PathPrefix, value: /llm}
      filters:
        - type: ExtensionRef
          extensionRef: {group: traefik.io, kind: Middleware, name: llm-gateway-auth}
        - type: URLRewrite
          urlRewrite:
            path: {type: ReplacePrefixMatch, replacePrefixMatch: /}
      backendRefs:
        - name: ${GUIDE_NAME}-epp
          port: 80
    - matches:
        - path: {type: PathPrefix, value: /v1}
      filters:
        - type: ExtensionRef
          extensionRef: {group: traefik.io, kind: Middleware, name: llm-gateway-auth}
      backendRefs:
        - name: ${GUIDE_NAME}-epp
          port: 80
YAML

routes=("$NAMESPACE/llm-gateway")

step "Gateway API: /grafana and /prometheus (namespace $MONITORING_NS)"
if kubectl get svc kps-grafana kps-kube-prometheus-stack-prometheus -n "$MONITORING_NS" >/dev/null 2>&1; then
  # Middleware and route must live in the backend's namespace (no ReferenceGrant needed), and
  # a Middleware can only read a Secret from its own namespace: reuse the same credentials.
  users=$(kubectl get secret llm-gateway-auth -n "$NAMESPACE" -o jsonpath='{.data.users}' | base64 -d)
  kubectl create secret generic llm-gateway-auth -n "$MONITORING_NS" \
    --from-literal=users="$users" --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -n "$MONITORING_NS" -f - <<YAML
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: llm-gateway-auth
spec:
  basicAuth:
    secret: llm-gateway-auth
    removeHeader: true      # also keeps these credentials away from Grafana's own login
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: monitoring-gateway
spec:
  parentRefs:
    - name: traefik-gateway
      namespace: kube-system
      sectionName: web
  rules:
    - matches:
        - path: {type: PathPrefix, value: /grafana}
      filters:
        - type: ExtensionRef
          extensionRef: {group: traefik.io, kind: Middleware, name: llm-gateway-auth}
        - type: URLRewrite
          urlRewrite:
            path: {type: ReplacePrefixMatch, replacePrefixMatch: /}
      backendRefs:
        - name: kps-grafana
          port: 80
    - matches:
        - path: {type: PathPrefix, value: /prometheus}
      filters:
        - type: ExtensionRef
          extensionRef: {group: traefik.io, kind: Middleware, name: llm-gateway-auth}
        - type: URLRewrite
          urlRewrite:
            path: {type: ReplacePrefixMatch, replacePrefixMatch: /}
      backendRefs:
        - name: kps-kube-prometheus-stack-prometheus
          port: 9090
YAML
  routes+=("$MONITORING_NS/monitoring-gateway")
else
  info "Grafana/Prometheus not installed; skipping. Run ./setup.sh --only observability, which adds these routes."
fi

# An HTTPRoute reports Accepted per parent Gateway (status.parents[]), not at the top level,
# so `kubectl wait --for=condition=Accepted` can never succeed.
for r in "${routes[@]}"; do
  kubectl wait httproute/"${r#*/}" -n "${r%%/*}" --timeout=60s \
    --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True \
    || info "HTTPRoute ${r#*/} not Accepted yet; inspect: kubectl describe httproute ${r#*/} -n ${r%%/*}"
done

bash "$GPUK8S_ROOT/tools/gateway.sh"
