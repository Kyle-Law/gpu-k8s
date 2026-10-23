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
./setup.sh                  # driver -> k3s -> GPU plugin -> llm-d
./setup.sh --stack ollama   # same, but Ollama instead
./setup.sh --stack none     # k3s + GPU plumbing only
```

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

## Layout

```
setup.sh                  runner (--stack, --from NN, --list)
config.env.example        copy to config.env to override defaults
lib/common.sh             shared settings, GPU detection, helpers
steps/                    run in order; each is standalone
  01-driver.sh            NVIDIA driver (exit 10 = reboot needed)
  02-base-tools.sh        curl, gpg, jq, git, bash-completion
  03-container-toolkit.sh NVIDIA container toolkit (before k3s!)
  04-k3s.sh               k3s + kubeconfig
  05-shell-helpers.sh     alias k + kubectl autocomplete
  06-gpu-plugin.sh        RuntimeClass, device plugin, GPU node label
  07-gpu-smoke-test.sh    nvidia-smi inside a pod
stacks/                   pick one (they share the single GPU)
  llmd.sh                 llm-d router + vLLM
  ollama.sh               Ollama (llama.cpp)
manifests/ollama.yaml     Ollama PVC + Deployment + Service
tools/
  status.sh               GPU, profile, pods, endpoints
  test.sh                 send a test prompt (llmd | ollama)
  switch-stack.sh         swap which stack holds the GPU
  check-image.sh          does an image's PyTorch support this GPU?
  teardown.sh             remove ollama | llmd | k3s
```

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
bash steps/06-gpu-plugin.sh       # re-run a single step
./setup.sh --from 06              # resume from a step
```

Only one stack can hold the single GPU at a time. Delete the cloud instance when
finished (stopping may still bill).

## Cleanup

```bash
tools/teardown.sh ollama    # or: llmd | k3s
```

## Notes

- `config.env` is git-ignored; copy `config.env.example` to create yours.
- `HF_TOKEN` is only needed for gated models. Leave it empty otherwise, since a wrong token causes 401s.
