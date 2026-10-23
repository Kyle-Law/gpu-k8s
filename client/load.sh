#!/usr/bin/env bash
# Fire N concurrent chat requests and report total throughput.
#   client/load.sh                      16 requests, all at once
#   client/load.sh 32 "Write a poem"    32 requests with your prompt
#   CONCURRENCY=8 MAX_TOKENS=200 client/load.sh 64
# Watch the Grafana dashboards (http://<vm-ip>/grafana/) while it runs.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

N="${1:-16}"; PROMPT="${2:-Write a short story about a robot learning to paint.}"
CONCURRENCY="${CONCURRENCY:-$N}"; MAX_TOKENS="${MAX_TOKENS:-128}"
model=$(llm_model)
out=$(mktemp -d); trap 'rm -rf "$out"' EXIT

one() { # one <i>
  local payload
  payload=$(jq -n --arg m "$model" --arg p "$PROMPT (variation $1)" --argjson n "$MAX_TOKENS" \
    '{model:$m, max_tokens:$n, ignore_eos:true, chat_template_kwargs:{enable_thinking:false},
      messages:[{role:"user",content:$p}]}')
  llm_curl -o "$out/$1.json" -w '%{http_code} %{time_total}\n' "$LLM_BASE/v1/chat/completions" \
    -H 'Content-Type: application/json' -d "$payload" > "$out/$1.stat" 2>/dev/null || echo "000 0" > "$out/$1.stat"
}
export -f one llm_curl; export model PROMPT MAX_TOKENS out LLM_BASE LLM_USER LLM_PASSWORD LLM_TIMEOUT

echo "model=$model requests=$N concurrency=$CONCURRENCY max_tokens=$MAX_TOKENS" >&2
start=$(now)
seq "$N" | xargs -P "$CONCURRENCY" -I{} bash -c 'one {}'
wall=$(printf '%.2f' "$(echo "$(now) - $start" | bc)")

ok=$(cat "$out"/*.stat | awk '$1==200' | wc -l | tr -d ' ')
tokens=$(for f in "$out"/*.json; do jq -r '.usage.completion_tokens // 0' "$f" 2>/dev/null || echo 0; done | paste -sd+ - | bc)
lat=$(cat "$out"/*.stat | awk '$1==200 {print $2}' | sort -n)
p50=$(echo "$lat" | awk '{a[NR]=$1} END {if (NR) print a[int((NR+1)/2)]}')
p95=$(echo "$lat" | awk '{a[NR]=$1} END {if (NR) print a[int(NR*0.95+0.999)]}')
echo "succeeded : $ok / $N"
echo "wall time : ${wall}s"
echo "tokens    : $tokens generated  ->  $(echo "scale=1; $tokens / $wall" | bc) tok/s overall"
echo "latency   : p50 ${p50:-?}s   p95 ${p95:-?}s   (per request, includes queueing)"
