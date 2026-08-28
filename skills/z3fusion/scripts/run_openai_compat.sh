#!/usr/bin/env bash
# run_openai_compat.sh — generic runner for ANY OpenAI-chat-completions-compatible HTTP
# endpoint. This is what makes "any model, any provider" real: OpenRouter alone proxies
# hundreds of models across every major provider using plain model-slug strings like
# "anthropic/claude-opus-4.8", "deepseek/deepseek-v4-pro", "meta-llama/llama-4-maverick",
# "x-ai/grok-4", "qwen/qwen3.7-max" — no CLI needed for any of them. Also covers local
# no-auth servers (LM Studio, vLLM, llama.cpp server, text-generation-webui, koboldcpp
# OpenAI-compat mode) and every hosted OpenAI-compatible API (Groq, Together, Fireworks,
# DeepSeek, Mistral, xAI, Google's OpenAI-compat endpoint, OpenAI itself, ...).
#
# Usage:
#   run_openai_compat.sh <base_url> <api_key_env_or_empty> <model> <prompt_file> <output_file> [extra_json_or_empty]
#
# - <base_url>             : e.g. https://openrouter.ai/api/v1 (one trailing slash stripped
#                             if present). POSTs go to "<base_url>/chat/completions".
# - <api_key_env_or_empty> : name of an env var holding the bearer token (e.g.
#                             OPENROUTER_API_KEY). Empty string ("") = send NO Authorization
#                             header at all — this is the local no-auth-server case. If this
#                             arg is non-empty but that named env var is unset/empty, exit
#                             127 with "missing API key: set <that env var name>".
# - <model>                : model slug/name exactly as the provider expects it, passed
#                             through verbatim in the request body's "model" field.
# - <prompt_file>          : path to a file containing the FULL panelist prompt.
# - <output_file>          : where the panelist's final answer is written (clean, just the
#                             answer).
# - [extra_json_or_empty]  : EXPERIMENTAL. An optional raw JSON object STRING, shallow-merged
#                             into the request body's top level, verbatim. Intended use:
#                             attaching OpenRouter's own native multi-model fusion plugin as
#                             an advanced opt-in (see
#                             https://openrouter.ai/docs/guides/routing/routers/fusion-router
#                             for the plugin shape) — but that shape cannot be verified
#                             against raw JSON in this environment, so this script has NO
#                             fusion-plugin-specific logic of its own: it just merges
#                             whatever JSON object string is passed in here into the request
#                             body. The robust, verified "any provider" path is the plain
#                             per-model call with this argument left empty; that must work
#                             correctly regardless of the plugin schema being right or wrong.
#
# Exit codes: 127 = missing API key (named env var unset/empty) or curl not present;
#             2 = bad usage or missing prompt file; 124 = timed out; 1 = other failure
#             (failed to build request body, non-2xx HTTP status, curl failure, or empty
#             extracted answer); 0 = success (output_file written, non-empty).
#
# NOTE: like every other z3Fusion runner, none of these endpoints could be functionally
# tested end to end in this environment. The request/response shape follows the documented
# OpenAI chat-completions API that every listed provider advertises compatibility with, but
# exact error-body shapes, rate-limit behavior, etc. are best-effort/unverified here.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/_fusion_lib.sh"

# Attempt policy (FUSION_MAX_ATTEMPTS, default 2). In the parent this does not return: it
# re-runs this script once per attempt with an escalating FUSION_TIMEOUT and exits with the
# final status. This is the runner that needs it most — a hosted provider answering 429/502/503
# is the most common transient panelist failure, and _should_retry reads the HTTP error body
# this script already prints to stderr to tell that apart from a bad key, which never retries.
_drive_attempts run_openai_compat.sh "${BASH_SOURCE[0]}" "$@"

usage="usage: run_openai_compat.sh <base_url> <api_key_env_or_empty> <model> <prompt_file> <output_file> [extra_json_or_empty]"

base_url="${1:?$usage}"
# api_key_env is allowed to be an explicit empty string ("" = no auth header), so this uses
# the no-colon form: it only errors when the argument is truly absent (fewer than 2 args
# given), not when it was passed as "". (The colon form `${2:?...}` would wrongly reject a
# deliberately-empty "" argument as if it were missing.)
api_key_env="${2?$usage}"
model="${3:?$usage}"
prompt_file="${4:?$usage}"
output_file="${5:?$usage}"
extra_json="${6:-}"

base_url="${base_url%/}"

case "$prompt_file" in
  /*) ;;
  *) prompt_file="$(pwd -P)/$prompt_file" ;;
esac
case "$output_file" in
  /*) ;;
  *) output_file="$(pwd -P)/$output_file" ;;
esac

if [ ! -s "$prompt_file" ]; then
  echo "[run_openai_compat.sh] prompt file is missing or empty: $prompt_file" >&2
  exit 2
fi
mkdir -p "$(dirname "$output_file")"
rm -f "$output_file"

if ! have curl; then
  echo "[run_openai_compat.sh] curl not found - cannot reach $base_url" >&2
  exit 127
fi

# Indirect expansion under `set -u`: use ${!api_key_env:-} (with the :- default), never the
# bare ${!api_key_env} — the bare form aborts the whole script via nounset when the named
# var is unset, before we get a chance to print our own clear "missing API key" message.
api_key_value=""
if [ -n "$api_key_env" ]; then
  api_key_value="${!api_key_env:-}"
  if [ -z "$api_key_value" ]; then
    echo "[run_openai_compat.sh] missing API key: set $api_key_env" >&2
    exit 127
  fi
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/z3fusion-openai-compat.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

body_file="$scratch/body.json"
resp_file="$scratch/resp.json"
http_code_file="$scratch/http_code.txt"
curl_err_file="$scratch/curl_stderr.log"

# --- Build the request body via an inline python3 heredoc (no jq dependency) --------------
MODEL="$model" EXTRA_JSON="$extra_json" "$FUSION_PY" - "$prompt_file" > "$body_file" 2>"$scratch/body_build.log" <<'PYEOF'
import json
import os
import sys

prompt_path = sys.argv[1]
with open(prompt_path, "r", encoding="utf-8", errors="replace") as f:
    prompt = f.read()

body = {
    "model": os.environ["MODEL"],
    "messages": [{"role": "user", "content": prompt}],
}

extra_raw = os.environ.get("EXTRA_JSON", "")
if extra_raw.strip():
    try:
        extra = json.loads(extra_raw)
    except Exception as e:
        sys.stderr.write("extra_json is not valid JSON - ignoring: %s\n" % e)
        extra = None
    if isinstance(extra, dict):
        # Shallow merge, verbatim, per contract — no fusion-plugin-specific logic here.
        body.update(extra)
    elif extra is not None:
        sys.stderr.write("extra_json is not a JSON object - ignoring\n")

sys.stdout.write(json.dumps(body))
PYEOF
build_status=$?
if [ "$build_status" -ne 0 ] || [ ! -s "$body_file" ]; then
  echo "[run_openai_compat.sh] failed to build request body" >&2
  [ -s "$scratch/body_build.log" ] && tail -20 "$scratch/body_build.log" >&2
  exit 1
fi
[ -s "$scratch/body_build.log" ] && tail -20 "$scratch/body_build.log" >&2

# --- POST to <base_url>/chat/completions, wrapped in the shared timeout helper -----------
# Build curl's arg list as an array that always has at least its base flags (never a
# strictly-empty array before optional elements are spliced in) — same discipline as
# run_codex.sh's codex_args, since expanding a genuinely empty array under `set -u` is
# unbound-variable-under-nounset on the old bash 3.2 that ships as /bin/bash on macOS.
curl_args=(
  -s -m "$FUSION_TIMEOUT"
  -X POST "$base_url/chat/completions"
  -H 'Content-Type: application/json'
)
if [ -n "$api_key_value" ]; then
  curl_args+=( -H "Authorization: Bearer $api_key_value" )
fi
curl_args+=( --data-binary "@$body_file" -o "$resp_file" -w '%{http_code}' )

_run_with_timeout "$FUSION_TIMEOUT" curl "${curl_args[@]}" \
  > "$http_code_file" 2> "$curl_err_file"
status=$?

if [ "$status" -eq 124 ]; then
  echo "[run_openai_compat.sh] request to $base_url/chat/completions timed out after ${FUSION_TIMEOUT}s" >&2
  exit 124
fi
if [ "$status" -ne 0 ]; then
  echo "[run_openai_compat.sh] curl failed (status $status) posting to $base_url/chat/completions" >&2
  [ -s "$curl_err_file" ] && tail -20 "$curl_err_file" >&2
  [ -s "$resp_file" ] && { echo "[run_openai_compat.sh] response body tail:" >&2; tail -40 "$resp_file" >&2; }
  exit 1
fi

http_code="$(cat "$http_code_file" 2>/dev/null)"
case "$http_code" in
  2??) ;;
  *)
    echo "[run_openai_compat.sh] non-2xx HTTP status ($http_code) from $base_url/chat/completions" >&2
    [ -s "$resp_file" ] && tail -40 "$resp_file" >&2
    exit 1
    ;;
esac

# --- Extract choices[0].message.content (shared helper from _fusion_lib.sh) --------------
_extract_openai_content "$resp_file" "$output_file"

# --- Anti-empty guard ---------------------------------------------------------------------
if [ ! -s "$output_file" ]; then
  echo "[run_openai_compat.sh] empty answer extracted from response at $base_url/chat/completions" >&2
  [ -s "$resp_file" ] && { echo "[run_openai_compat.sh] response body tail:" >&2; tail -40 "$resp_file" >&2; }
  exit 1
fi
echo "[run_openai_compat.sh] ok -> $output_file"
