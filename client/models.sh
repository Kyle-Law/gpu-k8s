#!/usr/bin/env bash
# List the models the endpoint serves, and check that auth works.
#   client/models.sh
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

code=$(curl -s -o /dev/null -m 15 -w '%{http_code}' "$LLM_BASE/v1/models" || true)
echo "without credentials : HTTP $code   (401 = gateway is protecting the endpoint)"
out=$(llm_curl -w '\n%{http_code}' "$LLM_BASE/v1/models")
code=${out##*$'\n'}; body=${out%$'\n'*}
echo "with credentials    : HTTP $code"
[ "$code" = 200 ] || { echo "$body"; exit 1; }
jq -r '.data[] | "  model: \(.id)   max_model_len: \(.max_model_len // "?")"' <<<"$body"
