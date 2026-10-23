# gpu-k8s: k3s + NVIDIA GPU + inference on a single GPU

Fresh Ubuntu 22.04 VM with one NVIDIA GPU -> k3s, GPU support, and either llm-d
(router + vLLM) or Ollama. Every script is idempotent and runs on its own.

## Prerequisites

- Ubuntu 22.04 VM (cloud or bare metal) with one NVIDIA GPU
- A user with `sudo` and outbound internet access (apt, GitHub, Hugging Face, container registries)
- Enough VRAM for the model: a 24 GB card (e.g. L4) runs the modern default (`Qwen3-8B`); the legacy default (`Qwen3-0.6B`) fits easily on a V100

## Quick start

```bash
git clone https://github.com/Kyle-Law/gpu-k8s.git && cd gpu-k8s
./setup.sh                  # validate -> host -> cluster -> llm-d -> verify
./setup.sh --stack ollama   # same, but Ollama instead
./setup.sh --stack none     # stop after the cluster (k3s + GPU plumbing)
./setup.sh --stack llmd-multi   # llm-d across 2+ GPUs on one node (see "Multiple GPUs")
./setup.sh --observability  # also install Prometheus + Grafana + GPU/vLLM metrics
./setup.sh --gateway        # also serve /llm, /grafana, /prometheus on one address (basic auth)
```

Pick **one** of these; they are alternatives, not a sequence.

If the NVIDIA driver is missing, step 01 installs it and asks you to reboot.
Reboot, then run `./setup.sh` again. Afterwards: `source ~/.bashrc`.

## GPU profiles (auto-detected)

The GPU's compute capability decides the profile (`nvidia-smi --query-gpu=compute_cap`):

| | `legacy` (cc < 7.5, e.g. Tesla V100) | `modern` (cc >= 7.5, e.g. RTX A6000, L4, RTX, H100) |
|---|---|---|
| vLLM image | pinned `vllm/vllm-openai:v0.8.5.post1` | llm-d's own current image |
| dtype / mode | fp16, `--enforce-eager`, V0 engine | default (bf16), normal mode |
| llm-d model | `Qwen/Qwen3-0.6B` | `Qwen/Qwen3-8B` |
| Ollama model | `qwen2.5:0.5b` | `qwen3:8b` |
| context / VRAM use | 4096 / 0.85 | 8192 / 0.90 |

Why legacy exists: current vLLM images bundle PyTorch builds without Volta (sm_70)
kernels and crash with `no kernel image is available for execution on the device`.
Force a profile with `GPU_PROFILE=legacy|modern`.

## Phases

`setup.sh` runs these phases in order (gateway and observability are opt-in). Each phase is a directory under `phases/` and every
script in it also runs on its own.

| Phase | What it does | Scripts |
|---|---|---|
| `validate` | Read-only preflight: OS, sudo, disk/RAM, NVIDIA PCI device, `~/.config` ownership, reachability of every host the setup downloads from | `phases/00-validate/` |
| `host` | NVIDIA driver (exit 10 = reboot needed), base tools, container toolkit | `phases/10-host/` |
| `cluster` | k3s, shell helpers, RuntimeClass + device plugin, GPU smoke test | `phases/20-cluster/` |
| `inference` | The model server: llm-d (router + vLLM) **or** Ollama | `phases/30-inference/` |
| `multigpu` | *Alternative to `inference`, for 2+ GPUs* (`--stack llmd-multi`): topology check, then llm-d with tensor parallelism or one replica per GPU | `phases/32-multigpu/` |
| `observability` | *Opt-in.* Prometheus, Grafana, DCGM GPU exporter, vLLM + router scraping, dashboard | `phases/40-observability/` |
| `inference-gateway` | *Opt-in.* llm-d in **Gateway mode** next to the standalone router: agentgateway + an `HTTPRoute` whose backend is the `InferencePool`, served at `/pool` | `phases/47-inference-gateway/` |
| `gateway` | *Opt-in.* One public address for the model, Grafana and Prometheus through the Gateway API (k3s's Traefik), behind basic auth | `phases/45-gateway/` |
| `verify` | End-to-end checks: node, GPU, a real completion, metrics flowing | `phases/50-verify/` |

```bash
./setup.sh --list                    # show the plan
./setup.sh --only validate           # run one phase (validate|host|cluster|inference|observability|gateway|inference-gateway|verify)
./setup.sh --from 06                 # resume at numbered step 06 (steps 00-07 are in validate/host/cluster)
./setup.sh --only verify             # re-run the health checks any time
```

## Layout

```
setup.sh                   runner (--stack, --gateway, --observability, --only, --from, --no-verify, --list)
config.env.example         copy to config.env to override defaults
lib/common.sh              shared settings, GPU detection, helpers
lib/llmd.sh                llm-d router + model-server steps shared by the 1-GPU and multi-GPU phases
phases/
  00-validate/00-preflight.sh
  10-host/                 01-driver  02-base-tools  03-container-toolkit
  20-cluster/              04-k3s  05-shell-helpers  06-gpu-plugin  07-gpu-smoke-test
  30-inference/            llmd.sh  ollama.sh      (pick one; they share the single GPU)
  32-multigpu/             check.sh  llmd.sh       (2+ GPUs: --stack llmd-multi)
  40-observability/        install.sh
  45-gateway/              install.sh
  47-inference-gateway/    install.sh
  50-verify/               verify.sh
client/                    run on your laptop: models.sh  chat.sh  load.sh  (env.sh = shared helpers)
manifests/
  ollama.yaml              Ollama PVC + Deployment + Service
  inference-gateway/       gateway-mode router overrides
  observability/           kube-prometheus-stack values, vLLM PodMonitor, Grafana dashboard
tools/
  status.sh                GPU, profile, pods, endpoints
  test.sh                  send a test prompt (llmd | ollama)
  switch-stack.sh          swap which stack holds the GPU
  gateway.sh               gateway URL + credentials, or a test request through it
  grafana.sh               port-forward Grafana / Prometheus
  metrics.sh               which LLM/GPU metrics Prometheus has; which dashboards will fill in
  check-image.sh           does an image's PyTorch support this GPU?
  teardown.sh              remove ollama | llmd | gateway | inference-gateway | observability | k3s
```

## Gateway API

```bash
./setup.sh --observability --gateway   # as part of a full run
./setup.sh --only gateway              # add it to a cluster that is already up
tools/gateway.sh                       # URLs + generated credentials
tools/gateway.sh test                  # requests through the gateway: 401 without credentials, answers with them
```

One address, three paths. Every path asks for the same basic-auth login (user `llm`, generated password):

| URL | Goes to |
|---|---|
| `http://<vm-ip>/llm/...` (also `/v1/...`) | the llm-d router, e.g. `/llm/v1/models`, `/llm/v1/chat/completions` |
| `http://<vm-ip>/grafana/` | Grafana (then Grafana's own login: user `admin`, password from `tools/grafana.sh`) |
| `http://<vm-ip>/prometheus/` | Prometheus |

k3s's bundled Traefik doubles as the Gateway API controller, so there is nothing extra to run. The
phase turns on Traefik's Gateway provider through a `HelmChartConfig` (k3s already ships the Gateway API
CRDs; they are only installed if missing, `GATEWAY_API_VERSION`) and creates `HTTPRoute`s with a Traefik
`Middleware` attached through an `ExtensionRef` filter. The path prefix is stripped before forwarding
(`/grafana/x` reaches Grafana as `/x`), so the backends keep serving from `/`. Grafana is told its public
path through `root_url` and Prometheus through `externalUrl`, so their links and redirects stay correct;
port-forwards (`tools/grafana.sh`) still work at the root.

- It listens on the VM's port 80 as **plain HTTP**, so passwords are not encrypted in transit.
  For anything beyond a throwaway VM, use an SSH tunnel or add a TLS listener.
- Whether the internet can reach port 80 depends on your cloud firewall.
- Set `PUBLIC_HOST` (a DNS name) if you do not want the VM's IP baked into Prometheus's external URL.
- If you install observability after the gateway, the `/grafana` and `/prometheus` routes are added automatically.
- `tools/teardown.sh gateway` removes the routes and puts Traefik back to the k3s defaults.

## Client scripts (run these on your laptop)

`client/` talks to the gateway from macOS or Linux. It needs only `bash`, `curl` and `jq` (`brew install jq`).

```bash
cp client/client.env.example client/client.env     # git-ignored; set LLM_HOST=<vm-ip>
client/models.sh                                   # checks auth (401 without, 200 with) and lists the model
client/chat.sh "Explain Kubernetes in one sentence."
client/chat.sh -t 0.2 -n 300 -s "You are terse." "Why is the sky blue?"
client/chat.sh --stream "Tell me a short story"    # tokens as they arrive + time to first token
client/chat.sh --think "How many r's in strawberry?"   # show Qwen3's reasoning (grey)
client/load.sh 32 "Write a poem"                   # 32 concurrent requests -> tok/s, p50/p95
```

The password is asked for (hidden) unless `LLM_PASSWORD` is set in your shell; it is never written to a file
or shown in `ps`. `-t` temperature, `-n` max tokens, `-s` system prompt, `-m` model (default: whatever the
server reports), `--raw` prints the JSON. Qwen3 thinking is off unless you pass `--think`, since it spends
many tokens. Run `client/load.sh` with the Grafana dashboards open to watch queues and the KV cache fill.

## Gateway mode (InferencePool as the HTTPRoute backend)

```bash
./setup.sh --only inference-gateway     # needs the llm-d stack; uses the gateway phase's auth if present
tools/gateway.sh test                   # now also answers through /pool
LLM_PATH=pool client/chat.sh "hi"       # from your laptop
```

The default install runs llm-d's router in **standalone** mode: the `quickstart-epp` pod carries its own Envoy,
and Traefik simply forwards `/llm` to that Service. This phase adds llm-d's **Gateway mode** beside it, so you can
compare the two on the same vLLM pod(s):

```
/llm   Traefik -> quickstart-epp Service -> Envoy sidecar -> EPP picks a pod -> vLLM
/pool  Traefik -> agentgateway Gateway -> HTTPRoute (backendRef: kind InferencePool) -> EPP (ext_proc) -> vLLM
```

Traefik cannot use an `InferencePool` as a backend, so the phase installs **agentgateway** (`AGENTGATEWAY_VERSION`,
default v1.1.0, the version llm-d release-1.0 documents) with Inference Extension support, a `Gateway`
named `llm-d-inference-gateway`, and llm-d's gateway-mode router chart as release `quickstart-gw` (its own EPP,
`InferencePool` and `HTTPRoute`). The agentgateway Service is kept `ClusterIP` with `AgentgatewayParameters`
(the same trick llm-d's OpenShift recipe uses), so it is only reachable through Traefik's authenticated `/pool`.
On one GPU both paths hit the same pod; the difference starts to matter with
`--stack llmd-multi` and `MULTIGPU_MODE=replicas`. Remove it with `tools/teardown.sh inference-gateway`.

## Observability

```bash
./setup.sh --observability          # as part of a full run
./setup.sh --only observability     # add it to a cluster that is already up
tools/grafana.sh                    # prints the admin password, port-forwards Grafana to :3000
```

Grafana and Prometheus are `ClusterIP` only, so nothing is exposed to the internet. From your
laptop, tunnel in: `ssh -L 3000:localhost:3000 <user>@<vm-ip>` and open http://localhost:3000.

What gets installed (namespace `monitoring`):

| Piece | Gives you |
|---|---|
| kube-prometheus-stack (`kps`) | Prometheus (10 Gi, 3 d retention), Grafana, node-exporter, kube-state-metrics |
| DCGM exporter (`dcgm`) | GPU utilisation, VRAM, power, temperature. Runs under the `nvidia` RuntimeClass without requesting the GPU, so it does not compete with the model server |
| `PodMonitor` for vLLM | queue depth, KV-cache usage, tokens/s, TTFT, inter-token and end-to-end latency, prefix-cache hit rate |
| `ServiceMonitor` for the llm-d router | routing metrics (best effort; the endpoint may require auth) |
| Dashboards (auto-imported, in two Grafana folders) | **gpu-k8s**: "GPU + vLLM" (GPU, queue, throughput, latency; handles old and new vLLM metric names). **llm-d**: the project's own vLLM overview, KV-cache performance, failure & saturation, diagnostic drill-down and router dashboards (copied from llm-d `release-1.0`, see `manifests/observability/dashboards/llm-d/SOURCE.md`) |

`tools/metrics.sh` shows which metric families Prometheus actually has and so which dashboards will fill in
(`tools/metrics.sh 'ttft|first_token'` lists matching metric names). The llm-d router dashboards need the
best-effort router scrape; the llm-d dashboards expect current vLLM metric names, so with the `legacy`
GPU profile (vLLM 0.8.5) some of their panels stay empty.

Ollama has no Prometheus endpoint, so with `--stack ollama` only the GPU and cluster panels fill in.
Remove it again with `tools/teardown.sh observability`.

## Multiple GPUs

For a node with 2+ GPUs (developed against 2 x Tesla V100-SXM2-16GB):

```bash
./setup.sh --stack llmd-multi                          # MULTIGPU_MODE=tp (default)
MULTIGPU_MODE=replicas ./setup.sh --stack llmd-multi
```

| `MULTIGPU_MODE` | Layout | 2 x V100 16 GB default model | Use it for |
|---|---|---|---|
| `tp` | **one** vLLM replica, `--tensor-parallel-size` = GPU count | `Qwen/Qwen3-8B` (fp16, ~16 GB: does not fit one card) | running a model bigger than one GPU |
| `replicas` | **one replica per GPU**; the llm-d router picks between them | `Qwen/Qwen3-4B` (~8 GB per card) | more throughput, and seeing llm-d's routing do something |

`phases/32-multigpu/check.sh` runs first: it prints the GPU interconnect (`nvidia-smi topo -m`; `NV#`
means NVLink, which tensor parallel wants), confirms Kubernetes advertises every GPU, and starts a pod
holding all of them. `llmd.sh` then reuses the single-GPU stack's Deployment name, namespace and labels,
so `tools/test.sh`, the gateway, observability (DCGM shows both GPUs) and `verify` work unchanged.

- Put `STACK=llmd-multi` (and `MULTIGPU_MODE`) in `config.env` so `tools/` agree with how you deployed.
- `TP_SIZE` / `REPLICAS` override the layout, as long as `TP_SIZE x REPLICAS` fits in the GPU count.
- Tensor parallel hangs at start-up? Try `VLLM_EXTRA_ARGS=--disable-custom-all-reduce`.
- V100s have no bf16 and no current-vLLM kernels, so the `legacy` profile (pinned vLLM, fp16, eager) still applies.
- Not tested on real hardware yet: the manifests were rendered and checked, but a first run on the 2-GPU box may need tuning.

## Configuration

Environment variables (or `config.env`) override the defaults. See `config.env.example`
for the full list. Examples:

```bash
MODEL=Qwen/Qwen3-0.6B ./setup.sh                 # quick smoke test with a tiny model
MODEL=Qwen/Qwen3-14B MAX_MODEL_LEN=16384 ./setup.sh   # bigger model on a 48 GB card
./setup.sh --stack ollama
```

## Day-to-day

```bash
tools/status.sh
tools/test.sh llmd "Explain Kubernetes in one sentence."
tools/switch-stack.sh ollama      # frees the GPU from llm-d, starts Ollama
bash phases/20-cluster/06-gpu-plugin.sh   # re-run a single step
./setup.sh --from 06              # resume from a step
```

Only one stack can hold the GPU(s) at a time. Delete the cloud instance when
finished (stopping may still bill).

## Cleanup

```bash
tools/teardown.sh ollama    # or: llmd | observability | k3s
```

## Notes

- `config.env` is git-ignored; copy `config.env.example` to create yours.
- `HF_TOKEN` is only needed for gated models. Leave it empty otherwise, since a wrong token causes 401s.
