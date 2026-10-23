#!/usr/bin/env bash
# Shared settings + helpers for the client scripts. Sourced, never run directly.
# Settings come from the environment or client/client.env (git-ignored):
#   LLM_HOST      VM address, e.g. 209.137.198.116              (required)
#   LLM_USER      gateway user (default: llm)
#   LLM_PASSWORD  gateway password; prompted for (hidden) if unset
#   LLM_PATH      gateway path: llm (standalone router, default) or pool (Gateway mode)
#   LLM_BASE      override the whole base URL (default: http://$LLM_HOST/$LLM_PATH)
#   MODEL         model name (default: whatever the server reports)
set -euo pipefail
CLIENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
if [ -f "$CLIENT_DIR/client.env" ]; then source "$CLIENT_DIR/client.env"; fi

: "${LLM_USER:=llm}"
: "${LLM_TIMEOUT:=300}"
if [ -z "${LLM_BASE:-}" ]; then
  [ -n "${LLM_HOST:-}" ] || { echo "Set LLM_HOST (see client/client.env.example)" >&2; exit 2; }
  LLM_BASE="http://${LLM_HOST}/${LLM_PATH:-llm}"
fi
LLM_BASE="${LLM_BASE%/}"

command -v jq >/dev/null 2>&1 || { echo "jq is required: brew install jq" >&2; exit 2; }

if [ -z "${LLM_PASSWORD:-}" ]; then
  if [ -t 0 ]; then
    printf 'Password for %s@%s: ' "$LLM_USER" "${LLM_HOST:-$LLM_BASE}" >&2
    read -rs LLM_PASSWORD; echo >&2
  else
    echo "LLM_PASSWORD is not set and there is no terminal to ask on." >&2; exit 2
  fi
fi

# llm_curl <curl args...>   curl with basic auth. Credentials go through a curl config on a
# pipe, so they never appear in `ps` or in shell history.
llm_curl() {
  curl -sS --max-time "$LLM_TIMEOUT" -K <(printf 'user = "%s:%s"\n' "$LLM_USER" "$LLM_PASSWORD") "$@"
}

# llm_model -> $MODEL, or the first model the server lists
llm_model() {
  if [ -n "${MODEL:-}" ]; then echo "$MODEL"; return; fi
  local m
  m=$(llm_curl "$LLM_BASE/v1/models" | jq -r '.data[0].id // empty') || true
  [ -n "$m" ] || { echo "Could not list models at $LLM_BASE/v1/models (wrong password? model still loading?)" >&2; exit 1; }
  echo "$m"
}

# now -> seconds since epoch with decimals (macOS `date` has no %N)
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
