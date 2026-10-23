#!/usr/bin/env bash
# Runs the setup in phases (see phases/):
#   validate -> host -> cluster -> inference -> [observability] -> verify
# The GPU is auto-detected (see lib/common.sh): V100-class cards get a legacy profile,
# everything newer (A6000, L4, RTX, H100...) gets the modern profile.
#
#   ./setup.sh                          all phases, llm-d stack (default)
#   ./setup.sh --stack ollama           Ollama instead of llm-d
#   ./setup.sh --stack none             stop after the cluster (k3s + GPU plumbing)
#   ./setup.sh --observability          also install Prometheus + Grafana + GPU/vLLM metrics
#   ./setup.sh --only validate          run one phase: validate|host|cluster|inference|observability|verify
#   ./setup.sh --from 06                resume at numbered step 06 (steps 00-07 live in the first 3 phases)
#   ./setup.sh --no-verify              skip the final verify phase
#   ./setup.sh --list                   show what would run, then exit
#
# Every script also runs on its own, e.g.:  bash phases/20-cluster/04-k3s.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
need_value() { if [ "$1" -lt 2 ]; then echo "$2 needs a value" >&2; exit 2; fi; }

FROM=0; LIST=0; ONLY=""; NO_VERIFY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --stack) need_value $# --stack; export STACK="$2"; shift 2 ;;
    --from)  need_value $# --from;  FROM=$((10#$2));   shift 2 ;;
    --only)  need_value $# --only;  ONLY="$2";         shift 2 ;;
    --observability) export OBSERVABILITY=1; shift ;;
    --no-verify) NO_VERIFY=1; shift ;;
    --list)  LIST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"
print_profile
case "$STACK" in llmd|ollama|none) ;; *) die "Unknown stack '$STACK' (use llmd | ollama | none)" ;; esac

phase_dir() {
  case "$1" in
    validate) echo 00-validate ;;     host) echo 10-host ;;           cluster) echo 20-cluster ;;
    inference) echo 30-inference ;;   observability) echo 40-observability ;;   verify) echo 50-verify ;;
    *) die "Unknown phase '$1' (use validate|host|cluster|inference|observability|verify)" ;;
  esac
}
[ -z "$ONLY" ] || phase_dir "$ONLY" >/dev/null

# Does this phase run? (--only wins; otherwise the defaults + flags decide)
phase_enabled() {
  if [ -n "$ONLY" ]; then [ "$ONLY" = "$1" ]; return; fi
  case "$1" in
    inference)     [ "$STACK" != none ] ;;
    observability) [ "$OBSERVABILITY" = 1 ] ;;
    verify)        [ "$NO_VERIFY" = 0 ] ;;
    *) true ;;
  esac
}

# Build the plan: one "phase|script" line per script, in order.
plan=()
for ph in validate host cluster inference observability verify; do
  phase_enabled "$ph" || continue
  dir="$ROOT/phases/$(phase_dir "$ph")"
  case "$ph" in
    inference) [ "$STACK" != none ] || die "--only inference needs --stack llmd|ollama"
               scripts=("$dir/$STACK.sh") ;;
    observability) scripts=("$dir/install.sh") ;;
    verify) scripts=("$dir/verify.sh") ;;
    *) scripts=("$dir"/[0-9][0-9]-*.sh) ;;
  esac
  for f in "${scripts[@]}"; do
    case "$ph" in
      validate|host|cluster) n=$((10#$(basename "$f" | cut -c1-2))); [ "$n" -ge "$FROM" ] || continue ;;
    esac
    plan+=("$ph|$f")
  done
done

if [ "$LIST" -eq 1 ]; then
  echo "Plan (stack=$STACK, observability=$OBSERVABILITY):"
  for item in "${plan[@]}"; do echo "  ${item%%|*}: ${item#*|}" | sed "s#$ROOT/##"; done
  exit 0
fi

for item in "${plan[@]}"; do
  ph="${item%%|*}"; f="${item#*|}"; rel="${f#"$ROOT"/}"
  rc=0; bash "$f" || rc=$?
  if [ "$rc" -eq "$EXIT_REBOOT" ]; then
    echo; echo "Reboot required. After rebooting, run: ./setup.sh"
    exit 0
  elif [ "$rc" -ne 0 ]; then
    case "$ph" in
      validate|host|cluster)
        die "$rel failed (exit $rc). Fix it, then resume with: ./setup.sh --from $(basename "$f" | cut -c1-2)" ;;
      *) die "$rel failed (exit $rc). Fix it, then re-run just this phase: ./setup.sh --only $ph" ;;
    esac
  fi
done

cat <<EOF

=========================================================================
 Done.   Run:  source ~/.bashrc     (enables the 'k' alias + tab completion)
 Useful:
   tools/status.sh                 GPU, pods, endpoints
   tools/test.sh llmd|ollama       send a test prompt
   tools/grafana.sh                Grafana over port-forward (if --observability)
   tools/switch-stack.sh llmd|ollama   swap stacks (only one GPU!)
   tools/teardown.sh ollama|llmd|observability|k3s
   ./setup.sh --only verify        re-run the health checks any time
 Remember to DELETE the cloud instance when finished.
=========================================================================
EOF
