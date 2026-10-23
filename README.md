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
./setup.sh --gateway        # also expose the model via the Gateway API, behind basic auth
./setup.sh --observability  # also install Prometheus + Grafana + GPU/vLLM metrics
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
| `gateway` | *Opt-in.* Exposes the model through the Gateway API (k3s's Traefik as the controller) behind basic auth | `phases/35-gateway/` |
| `observability` | *Opt-in.* Prometheus, Grafana, DCGM GPU exporter, vLLM + router scraping, dashboard | `phases/40-observability/` |
| `verify` | End-to-end checks: node, GPU, a real completion, metrics flowing | `phases/50-verify/` |

```bash
./setup.sh --list                    # show the plan
./setup.sh --only validate           # run one phase (validate|host|cluster|inference|gateway|observability|verify)
./setup.sh --from 06                 # resume at numbered step 06 (steps 00-07 are in validate/host/cluster)
./setup.sh --only verify             # re-run the health checks any time
```

## Layout

```
setup.sh                   runner (--stack, --gateway, --observability, --only, --from, --no-verify, --list)
config.env.example         copy to config.env to override defaults
lib/common.sh              shared settings, GPU detection, helpers
phases/
  00-validate/00-preflight.sh
  10-host/                 01-driver  02-base-tools  03-container-toolkit
  20-cluster/              04-k3s  05-shell-helpers  06-gpu-plugin  07-gpu-smoke-test
  30-inference/            llmd.sh  ollama.sh      (pick one; they share the single GPU)
  35-gateway/              install.sh
  40-observability/        install.sh
  50-verify/               verify.sh
manifests/
  ollama.yaml              Ollama PVC + Deployment + Service
  observability/           kube-prometheus-stack values, vLLM PodMonitor, Grafana dashboard
tools/
  status.sh                GPU, profile, pods, endpoints
  test.sh                  send a test prompt (llmd | ollama)
  switch-stack.sh          swap which stack holds the GPU
  gateway.sh               gateway URL + credentials, or a test request through it
  grafana.sh               port-forward Grafana / Prometheus
  check-image.sh           does an image's PyTorch support this GPU?
  teardown.sh              remove ollama | llmd | gateway | observability | k3s
```

## Gateway API

```bash
./setup.sh --gateway           # as part of a full run
./setup.sh --only gateway      # add it to a cluster that is already up
tools/gateway.sh               # URL + generated credentials
tools/gateway.sh test          # request through the gateway: 401 without credentials, answer with them
```

k3s's bundled Traefik doubles as the Gateway API controller, so there is nothing extra to run.
The phase installs the Gateway API CRDs (`GATEWAY_API_VERSION`, default v1.6.3, the version Traefik
3.7 documents support for), turns on Traefik's Gateway provider through a `HelmChartConfig`, and
creates an `HTTPRoute` that sends `/v1/*` to the llm-d router. A Traefik `Middleware` (attached with an
`ExtensionRef` filter) requires basic auth; the password is generated once and kept in a Secret.

- It listens on the VM's port 80 as **plain HTTP**, so the password is not encrypted in transit.
  For anything beyond a throwaway VM, use an SSH tunnel or add a TLS listener.
- Whether the internet can reach port 80 depends on your cloud firewall.
- `tools/teardown.sh gateway` removes the route and puts Traefik back to the k3s defaults.
- Only the llm-d stack is routed (the route targets the llm-d router service).

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
| Dashboard "GPU + vLLM (gpu-k8s)" | all of the above, auto-imported |

Ollama has no Prometheus endpoint, so with `--stack ollama` only the GPU and cluster panels fill in.
Remove it again with `tools/teardown.sh observability`.

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

Only one stack can hold the single GPU at a time. Delete the cloud instance when
finished (stopping may still bill).

## Cleanup

```bash
tools/teardown.sh ollama    # or: llmd | observability | k3s
```

## Notes

- `config.env` is git-ignored; copy `config.env.example` to create yours.
- `HF_TOKEN` is only needed for gated models. Leave it empty otherwise, since a wrong token causes 401s.
