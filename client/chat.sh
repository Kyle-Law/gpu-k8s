#!/usr/bin/env bash
# One chat request. Everything is adjustable by flag or environment variable.
#   client/chat.sh "Explain Kubernetes in one sentence."
#   client/chat.sh -t 0.2 -n 300 "Write a haiku about GPUs"
#   client/chat.sh --stream "Tell me a short story"
#   client/chat.sh --think "How many r's are in strawberry?"
#   client/chat.sh -s "You are a pirate." "Say hello"
# Flags:  -m MODEL  -t TEMP  -n MAX_TOKENS  -s SYSTEM  --stream  --think  --raw
# Env:    MODEL TEMP MAX_TOKENS SYSTEM STREAM=1 THINK=1   (flags win)
# Qwen3 "thinks" before answering, which costs many tokens; it is OFF unless you pass --think.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

TEMP="${TEMP:-0.7}"; MAX_TOKENS="${MAX_TOKENS:-256}"; SYSTEM="${SYSTEM:-}"
STREAM="${STREAM:-0}"; THINK="${THINK:-0}"; RAW=0
while [ $# -gt 0 ]; do
  case "$1" in
    -m) MODEL="$2"; shift 2 ;;
    -t) TEMP="$2"; shift 2 ;;
    -n) MAX_TOKENS="$2"; shift 2 ;;
    -s) SYSTEM="$2"; shift 2 ;;
    --stream) STREAM=1; shift ;;
    --think)  THINK=1; shift ;;
    --raw)    RAW=1; shift ;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --) shift; break ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *) break ;;
  esac
done
PROMPT="${*:-How are you today?}"
model=$(llm_model)

payload=$(jq -n --arg m "$model" --arg p "$PROMPT" --arg s "$SYSTEM" \
  --argjson t "$TEMP" --argjson n "$MAX_TOKENS" --argjson stream "$([ "$STREAM" = 1 ] && echo true || echo false)" \
  --argjson think "$([ "$THINK" = 1 ] && echo true || echo false)" '
  {model:$m, temperature:$t, max_tokens:$n, stream:$stream,
   chat_template_kwargs:{enable_thinking:$think},
   messages: ((if $s == "" then [] else [{role:"system",content:$s}] end) + [{role:"user",content:$p}])}
  + (if $stream then {stream_options:{include_usage:true}} else {} end)')

echo "model=$model temp=$TEMP max_tokens=$MAX_TOKENS think=$THINK stream=$STREAM" >&2

if [ "$STREAM" = 1 ]; then
  start=$(now); first=""
  llm_curl -N "$LLM_BASE/v1/chat/completions" -H 'Content-Type: application/json' -d "$payload" |
  while IFS= read -r line; do
    case "$line" in
      "data: [DONE]") break ;;
      "data: "*)
        chunk=${line#data: }
        if [ "$RAW" = 1 ]; then echo "$chunk"; continue; fi
        # reasoning (if any) in grey, answer in normal colour
        piece=$(jq -j '.choices[0].delta | ((.reasoning_content // .reasoning // empty) | "\u001b[90m" + . + "\u001b[0m"), (.content // empty)' <<<"$chunk" 2>/dev/null || true)
        if [ -n "$piece" ] && [ -z "$first" ]; then first=$(now); printf '[ttft %.2fs] ' "$(echo "$first - $start" | bc)" >&2; fi
        printf '%s' "$piece"
        usage=$(jq -r 'select(.usage != null) | .usage | "\(.prompt_tokens) prompt + \(.completion_tokens) completion tokens"' <<<"$chunk" 2>/dev/null || true)
        [ -z "$usage" ] || echo "$usage" > "${TMPDIR:-/tmp}/llm-usage.$$"
        ;;
      *) : ;;
    esac
  done
  echo
  if [ -f "${TMPDIR:-/tmp}/llm-usage.$$" ]; then echo "usage: $(cat "${TMPDIR:-/tmp}/llm-usage.$$")  total $(printf '%.2f' "$(echo "$(now) - $start" | bc)")s" >&2; rm -f "${TMPDIR:-/tmp}/llm-usage.$$"; fi
else
  tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
  secs=$(llm_curl -o "$tmp" -w '%{time_total}' "$LLM_BASE/v1/chat/completions" -H 'Content-Type: application/json' -d "$payload")
  if [ "$RAW" = 1 ] || ! jq -e '.choices' "$tmp" >/dev/null 2>&1; then jq . "$tmp" 2>/dev/null || cat "$tmp"; exit 0; fi
  jq -r '.choices[0].message | ((.reasoning_content // .reasoning // empty) | "\u001b[90m" + . + "\u001b[0m\n"), (.content // "")' "$tmp"
  jq -r --arg s "$secs" '.usage | "usage: \(.prompt_tokens) prompt + \(.completion_tokens) completion tokens in \($s)s  (\((.completion_tokens / ($s|tonumber)) * 10 | round / 10) tok/s)"' "$tmp" >&2
fi
