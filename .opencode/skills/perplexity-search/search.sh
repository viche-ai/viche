#!/usr/bin/env bash
set -euo pipefail

# Perplexity Agent API wrapper
# Usage: search.sh search [--mode fast|pro|deep|advanced] [OPTIONS] "query"
#        search.sh fetch [OPTIONS] "url"

SCRIPT_NAME="$(basename "$0")"
API_ENDPOINT="https://api.perplexity.ai/v1/agent"

# ─── Helpers ─────────────────────────────────────────────────────────────────

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed. Please install it and retry."
}

show_help() {
  cat <<EOF
Usage:
  $SCRIPT_NAME search [OPTIONS] "query"
  $SCRIPT_NAME fetch  [OPTIONS] "url"
  $SCRIPT_NAME --help

Subcommands:
  search   Perform a web search via the Perplexity Agent API
  fetch    Fetch and summarise a specific URL

Search options:
  --mode fast|pro|deep|advanced
             Preset to use (default: pro)
               fast     - Quick factual lookups (xai/grok-4, 1 step)
               pro      - Balanced research (openai/gpt-5.1, 3 steps)
               deep     - Complex analysis (openai/gpt-5.2, 10 steps)
               advanced - Institutional research (anthropic/claude-opus-4-6, 10 steps)

Shared options:
  --domains "d1.com,d2.com"
             Comma-separated domain allowlist (max 20)
  --exclude "reddit.com,quora.com"
             Comma-separated domain denylist (prefix '-' added automatically)
  --recency day|week|month|year
             Only return results newer than this window
  --raw      Output raw JSON response instead of formatted text
  --help     Show this help message

Environment:
  PERPLEXITY_API_KEY   Required. Your Perplexity API key.

Examples:
  # Quick search
  $SCRIPT_NAME search "What is Deno 2.0?"

  # Fast mode for a simple fact
  $SCRIPT_NAME search --mode fast "capital of France"

  # Deep research with domain filter, recent results only
  $SCRIPT_NAME search --mode deep --domains "techcrunch.com,wired.com" --recency week "AI regulation 2025"

  # Exclude low-quality domains
  $SCRIPT_NAME search --exclude "reddit.com,quora.com" "best Deno ORM"

  # Fetch and summarise a URL
  $SCRIPT_NAME fetch "https://deno.com/blog/v2"

  # Get raw JSON
  $SCRIPT_NAME search --raw "TypeScript 5.5 features"
EOF
}

# ─── Preflight ────────────────────────────────────────────────────────────────

require_cmd curl
require_cmd jq

# ─── Argument parsing ────────────────────────────────────────────────────────

# Defaults
MODE="pro"
DOMAINS=""
EXCLUDE=""
RECENCY=""
RAW=false
SUBCOMMAND=""
QUERY=""

# No arguments → help
if [[ $# -eq 0 ]]; then
  show_help
  exit 0
fi

# Top-level --help
if [[ "$1" == "--help" || "$1" == "-h" ]]; then
  show_help
  exit 0
fi

# Extract subcommand
SUBCOMMAND="$1"
shift

if [[ "$SUBCOMMAND" != "search" && "$SUBCOMMAND" != "fetch" ]]; then
  die "Unknown subcommand '$SUBCOMMAND'. Use 'search' or 'fetch'. Run '$SCRIPT_NAME --help' for usage."
fi

# Parse remaining flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      show_help
      exit 0
      ;;
    --mode)
      [[ $# -ge 2 ]] || die "--mode requires a value (fast|pro|deep|advanced)"
      MODE="$2"
      shift 2
      ;;
    --mode=*)
      MODE="${1#--mode=}"
      shift
      ;;
    --domains)
      [[ $# -ge 2 ]] || die "--domains requires a value"
      DOMAINS="$2"
      shift 2
      ;;
    --domains=*)
      DOMAINS="${1#--domains=}"
      shift
      ;;
    --exclude)
      [[ $# -ge 2 ]] || die "--exclude requires a value"
      EXCLUDE="$2"
      shift 2
      ;;
    --exclude=*)
      EXCLUDE="${1#--exclude=}"
      shift
      ;;
    --recency)
      [[ $# -ge 2 ]] || die "--recency requires a value (day|week|month|year)"
      RECENCY="$2"
      shift 2
      ;;
    --recency=*)
      RECENCY="${1#--recency=}"
      shift
      ;;
    --raw)
      RAW=true
      shift
      ;;
    --)
      shift
      QUERY="$*"
      break
      ;;
    -*)
      die "Unknown flag '$1'. Run '$SCRIPT_NAME --help' for usage."
      ;;
    *)
      QUERY="$1"
      shift
      # Anything remaining is treated as continuation of the query
      if [[ $# -gt 0 ]]; then
        QUERY="$QUERY $*"
        break
      fi
      ;;
  esac
done

[[ -n "$QUERY" ]] || die "No query/url provided. Run '$SCRIPT_NAME --help' for usage."

# Validate --mode
case "$MODE" in
  fast|pro|deep|advanced) ;;
  *) die "Invalid --mode '$MODE'. Must be one of: fast, pro, deep, advanced" ;;
esac

# Validate --recency
if [[ -n "$RECENCY" ]]; then
  case "$RECENCY" in
    day|week|month|year) ;;
    *) die "Invalid --recency '$RECENCY'. Must be one of: day, week, month, year" ;;
  esac
fi

# ─── API key check ────────────────────────────────────────────────────────────

if [[ -z "${PERPLEXITY_API_KEY:-}" ]]; then
  die "PERPLEXITY_API_KEY is not set. Export it before running:
  export PERPLEXITY_API_KEY=your_key_here"
fi

# ─── Map mode → preset ───────────────────────────────────────────────────────

mode_to_preset() {
  case "$1" in
    fast)     echo "fast-search" ;;
    pro)      echo "pro-search" ;;
    deep)     echo "deep-research" ;;
    advanced) echo "advanced-deep-research" ;;
  esac
}

PRESET="$(mode_to_preset "$MODE")"

# ─── Build JSON payload ───────────────────────────────────────────────────────

# Build web_search tool filters object
build_web_search_filters() {
  local domains_json="[]"
  local parts=()

  # Allowlist domains
  if [[ -n "$DOMAINS" ]]; then
    local allow_arr
    IFS=',' read -ra allow_arr <<< "$DOMAINS"
    domains_json="$(printf '%s\n' "${allow_arr[@]}" | jq -R . | jq -s .)"
  fi

  # Denylist domains (prefix with -)
  if [[ -n "$EXCLUDE" ]]; then
    local deny_arr
    IFS=',' read -ra deny_arr <<< "$EXCLUDE"
    local deny_json
    deny_json="$(printf '%s\n' "${deny_arr[@]}" | sed 's/^/-/' | jq -R . | jq -s .)"
    # Merge allow + deny arrays
    domains_json="$(echo "[$domains_json, $deny_json]" | jq -s 'add')"
  fi

  # Build filters
  local filters="{}"

  if [[ "$domains_json" != "[]" ]]; then
    filters="$(echo "$filters" | jq --argjson d "$domains_json" '. + {search_domain_filter: $d}')"
  fi

  if [[ -n "$RECENCY" ]]; then
    filters="$(echo "$filters" | jq --arg r "$RECENCY" '. + {search_recency_filter: $r}')"
  fi

  echo "$filters"
}

build_payload() {
  local input="$1"
  local filters
  filters="$(build_web_search_filters)"

  if [[ "$SUBCOMMAND" == "fetch" ]]; then
    # For fetch: use pro-search preset, provide URL in input, include fetch_url tool
    jq -n \
      --arg preset "pro-search" \
      --arg input "Please fetch and summarise the content at this URL: $input" \
      --argjson filters "$filters" \
      '{
        preset: $preset,
        input: $input,
        tools: [
          {type: "web_search", filters: $filters},
          {type: "fetch_url"}
        ]
      }'
  else
    local has_filters
    has_filters="$(echo "$filters" | jq 'keys | length > 0')"

    if [[ "$has_filters" == "true" ]]; then
      jq -n \
        --arg preset "$PRESET" \
        --arg input "$input" \
        --argjson filters "$filters" \
        '{
          preset: $preset,
          input: $input,
          tools: [
            {type: "web_search", filters: $filters},
            {type: "fetch_url"}
          ]
        }'
    else
      jq -n \
        --arg preset "$PRESET" \
        --arg input "$input" \
        '{
          preset: $preset,
          input: $input,
          tools: [
            {type: "web_search"},
            {type: "fetch_url"}
          ]
        }'
    fi
  fi
}

# ─── API call ─────────────────────────────────────────────────────────────────

call_api() {
  local payload="$1"
  local response
  local http_code

  # Capture both body and HTTP status code
  local tmp_body
  tmp_body="$(mktemp)"

  http_code="$(curl -s -w "%{http_code}" -o "$tmp_body" \
    -X POST "$API_ENDPOINT" \
    -H "Authorization: Bearer $PERPLEXITY_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$payload")" || {
    rm -f "$tmp_body"
    die "Network error: curl failed. Check your internet connection."
  }

  response="$(cat "$tmp_body")"
  rm -f "$tmp_body"

  # Handle HTTP errors
  case "$http_code" in
    200|201) ;;
    401) die "Authentication failed (HTTP 401). Check your PERPLEXITY_API_KEY." ;;
    403) die "Forbidden (HTTP 403). Your API key may not have access to this endpoint." ;;
    429) die "Rate limit exceeded (HTTP 429). Please wait before retrying." ;;
    500|502|503) die "Perplexity API server error (HTTP $http_code). Try again later." ;;
    *)
      local err_msg
      err_msg="$(echo "$response" | jq -r '.error.message // .message // "Unknown error"' 2>/dev/null || echo "Unknown error")"
      die "API error (HTTP $http_code): $err_msg"
      ;;
  esac

  # Check response-level error
  local api_status
  api_status="$(echo "$response" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")"

  if [[ "$api_status" == "failed" ]]; then
    local api_error
    api_error="$(echo "$response" | jq -r '.error.message // .error // "Unknown API error"' 2>/dev/null || echo "Unknown API error")"
    die "API returned failure: $api_error"
  fi

  echo "$response"
}

# ─── Output formatting ────────────────────────────────────────────────────────

format_response() {
  local response="$1"

  # Extract answer text from message-type output items
  local answer
  answer="$(echo "$response" | jq -r '
    .output[]
    | select(.type == "message")
    | .content[]
    | select(.type == "output_text")
    | .text
  ' 2>/dev/null | head -c 100000)"

  # Fallback: try any content text
  if [[ -z "$answer" ]]; then
    answer="$(echo "$response" | jq -r '
      .output[]?
      | .content[]?
      | .text // empty
    ' 2>/dev/null | head -c 100000)"
  fi

  # Extract sources from search_results items
  local sources
  sources="$(echo "$response" | jq -r '
    .output[]
    | select(.type == "search_results")
    | .results[]
    | .url
  ' 2>/dev/null | sort -u)"

  # Extract cost
  local cost
  cost="$(echo "$response" | jq -r '.usage.cost.total_cost // empty' 2>/dev/null)"

  # Print answer
  if [[ -n "$answer" ]]; then
    echo "$answer"
  else
    echo "(No answer text found in response)"
  fi

  # Print sources
  if [[ -n "$sources" ]]; then
    echo ""
    echo "Sources:"
    local i=1
    while IFS= read -r url; do
      echo "  $i. $url"
      ((i++))
    done <<< "$sources"
  fi

  # Print cost
  if [[ -n "$cost" ]]; then
    echo ""
    printf "Cost: \$%.5f\n" "$cost"
  fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

PAYLOAD="$(build_payload "$QUERY")"

RESPONSE="$(call_api "$PAYLOAD")"

if [[ "$RAW" == "true" ]]; then
  echo "$RESPONSE" | jq .
else
  format_response "$RESPONSE"
fi
