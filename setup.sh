#!/usr/bin/env bash
# Runs every numbered script in steps/, then the chosen stack in stacks/.
# The GPU is auto-detected (see lib/common.sh): V100-class cards get a legacy profile,
# everything newer (A6000, L4, RTX, H100...) gets the modern profile.
#
#   ./setup.sh                    steps 01-07 + llm-d stack (default)
#   ./setup.sh --stack ollama     steps 01-07 + Ollama instead
#   ./setup.sh --stack none       steps 01-07 only (k3s + GPU plumbing)
#   ./setup.sh --from 06          resume at step 06 (skips earlier steps)
#   ./setup.sh --list             show what would run, then exit
#
# Each script also runs on its own, e.g.:  bash steps/04-k3s.sh   bash stacks/llmd.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
need_value() { if [ "$1" -lt 2 ]; then echo "$2 needs a value" >&2; exit 2; fi; }

FROM=1; LIST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --stack) need_value $# --stack; export STACK="$2"; shift 2 ;;
    --from)  need_value $# --from;  FROM=$((10#$2));   shift 2 ;;
    --list)  LIST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"
print_profile
case "$STACK" in llmd|ollama|none) ;; *) die "Unknown stack '$STACK' (use llmd | ollama | none)" ;; esac

steps=()
for f in "$ROOT"/steps/*.sh; do
  n=$((10#$(basename "$f" | cut -c1-2)))
  if [ "$n" -ge "$FROM" ]; then steps+=("$f"); fi
done

if [ "$LIST" -eq 1 ]; then
  echo "Steps:"; for f in "${steps[@]}"; do echo "  steps/$(basename "$f")"; done
  if [ "$STACK" = none ]; then echo "Stack: none"; else echo "Stack: stacks/$STACK.sh"; fi
  exit 0
fi

for f in "${steps[@]}"; do
  rc=0; bash "$f" || rc=$?
  nn=$(basename "$f" | cut -c1-2)
  if [ "$rc" -eq "$EXIT_REBOOT" ]; then
    echo; echo "Reboot required. After rebooting, run: ./setup.sh"
    exit 0
  elif [ "$rc" -ne 0 ]; then
    die "steps/$(basename "$f") failed (exit $rc). Fix it, then resume with: ./setup.sh --from $nn"
  fi
done

if [ "$STACK" != none ]; then
  rc=0; bash "$ROOT/stacks/$STACK.sh" || rc=$?
  [ "$rc" -eq 0 ] || die "stacks/$STACK.sh failed (exit $rc). Fix it, then re-run just: bash stacks/$STACK.sh"
fi

cat <<EOF

=========================================================================
 Done.   Run:  source ~/.bashrc     (enables the 'k' alias + tab completion)
 Useful:
   tools/status.sh                 GPU, pods, endpoints
   tools/test.sh llmd|ollama       send a test prompt
   tools/switch-stack.sh llmd|ollama   swap stacks (only one GPU!)
   tools/teardown.sh ollama|llmd|k3s
 Remember to DELETE the cloud instance when finished.
=========================================================================
EOF
