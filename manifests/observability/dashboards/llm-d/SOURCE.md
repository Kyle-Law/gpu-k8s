# llm-d dashboards

Copied unmodified from the llm-d project (Apache-2.0),
`guides/recipes/observability/grafana/dashboards/` on branch `release-1.0`:
https://github.com/llm-d/llm-d/tree/release-1.0/guides/recipes/observability/grafana/dashboards

They use a Grafana datasource variable (`DS_PROMETHEUS`), so no editing is needed.
Only the ones that apply to a single-GPU vLLM + router setup are included
(batch-gateway, async-processor, SGLang, TPU and prefill/decode-coordinator dashboards are left out).
Re-fetch to update: see the URL above.

| File | Needs |
|---|---|
| llm-d-vllm-overview.json | vLLM metrics (PodMonitor) |
| llm-d-performance-kv-cache.json | vLLM metrics |
| llm-d-failure-saturation-dashboard.json | vLLM + router (EPP) metrics |
| llm-d-diagnostic-drilldown-dashboard.json | vLLM + router (EPP) metrics |
| llm-d-router.json | router (EPP) `llm_d_epp_*` metrics only |

These use current vLLM metric names (e.g. `vllm:kv_cache_usage_perc`); with the `legacy` GPU profile
(vLLM 0.8.5) some panels stay empty. The "GPU + vLLM (gpu-k8s)" dashboard handles both.
