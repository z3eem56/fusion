#!/usr/bin/env bash
# run_ollama.sh — run one panelist against a fully local Ollama model. Zero API key.
#
# Usage:
#   run_ollama.sh <model> <prompt_file> <output_file>
#
# - <model>       : an Ollama model tag, e.g. llama3.1, qwen3, deepseek-r1 (must already be
#                   pulled locally — this script does not `ollama pull` on your behalf).
# - <prompt_file> : path to a file containing the FULL panelist prompt.
# - <output_file> : where the panelist's final answer is written (clean, just the answer).
#
# Two independent paths, same anti-empty-guard discipline as run_gemini.sh:
#
#   Path A (preferred): the `ollama` CLI is on PATH — run `ollama run <model>` with the
#                        prompt piped in on stdin (non-interactive, no TTY assumed), capture
#                        stdout to a scratch file, then strip ANSI escapes / control bytes the
#                        same defensive way run_gemini.sh does. NOTE: exact stdout-cleanliness
#                        of `ollama run` in non-interactive/piped mode is best-effort/unverified
#                        in this environment — progress/spinner control sequences are stripped
#                        defensively on the assumption they may appear, not because they are
#                        confirmed to appear.
#   Path B (fallback) : used if the CLI is absent, OR Path A produced empty output after
#                        stripping. POSTs to the local Ollama server's OpenAI-less native API
#                        (http://localhost:11434/api/chat, stream:false) via an inline python3
#                        heredoc (no jq dependency, mirroring run_gemini.sh / agy_transcript.py's
#                        python3-based JSON handling), after confirming the server is up via
#                        GET http://localhost:11434/api/tags.
#
# Anti-empty guard: if output_file is still empty after both paths, exit 1 — never exit 0 with
# an empty file (matches run_gemini.sh's convention exactly).
#
# Exit codes: 127 = neither the `ollama` CLI nor a local Ollama server is reachable;
#             2 = bad usage or missing prompt file; 124 = timed out; 1 = other failure or
#             empty output; 0 = success (output_file written, non-empty).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/_fusion_lib.sh"

# Attempt policy (FUSION_MAX_ATTEMPTS, default 2). In the parent this does not return: it
# re-runs this script once per attempt with an escalating FUSION_TIMEOUT and exits with the
# final status. A cold model load overrunning the budget is the transient case this covers.
_drive_attempts run_ollama.sh "${BASH_SOURCE[0]}" "$@"

model="${1:?usage: run_ollama.sh <model> <prompt_file> <output_file>}"
prompt_file="${2:?usage: run_ollama.sh <model> <prompt_file> <output_file>}"
output_file="${3:?usage: run_ollama.sh <model> <prompt_file> <output_file>}"

OLLAMA_HOST_URL="${OLLAMA_HOST_URL:-http://localhost:11434}"

case "$prompt_file" in
  /*) ;;
  *) prompt_file="$(pwd -P)/$prompt_file" ;;
esac
case "$output_file" in
  /*) ;;
  *) output_file="$(pwd -P)/$output_file" ;;
esac

if [ ! -s "$prompt_file" ]; then
  echo "[run_ollama.sh] prompt file is missing or empty: $prompt_file" >&2
  exit 2
fi
mkdir -p "$(dirname "$output_file")"
rm -f "$output_file"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/z3fusion-ollama.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

server_up() {
  have curl && curl -s -m 5 -o /dev/null -w '%{http_code}' "$OLLAMA_HOST_URL/api/tags" 2>/dev/null | grep -q '^2'
}

cli_present=0
have ollama && cli_present=1

if [ "$cli_present" -eq 0 ] && ! server_up; then
  echo "[run_ollama.sh] ollama not found - install from https://ollama.com and pull a model, or start the local server" >&2
  exit 127
fi

# --- Path A: `ollama run <model>` via the CLI, prompt piped on stdin -------------------
if [ "$cli_present" -eq 1 ]; then
  raw_out="$scratch/raw.out"
  : > "$raw_out"
  _run_with_timeout "$FUSION_TIMEOUT" ollama run "$model" < "$prompt_file" \
    > "$raw_out" 2> "$scratch/stderr.log"
  status=$?
  if [ $status -eq 124 ]; then
    echo "[run_ollama.sh] ollama run timed out after ${FUSION_TIMEOUT}s; tail of log:" >&2
    tail -20 "$scratch/stderr.log" >&2
    exit 124
  fi
  # Defensive strip: ANSI escapes, carriage returns, and other stray control bytes that
  # spinner/progress output could leak into stdout (see note above — unverified, defensive).
  sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' -e 's/\r//g' "$raw_out" \
    | LC_ALL=C tr -d '\000-\010\013-\037\177' > "$output_file"

  if [ -s "$output_file" ]; then
    echo "[run_ollama.sh] ok (path A: ollama CLI) -> $output_file"
    exit 0
  fi
  echo "[run_ollama.sh] path A (ollama CLI) produced empty output — falling back to local server API." >&2
  [ -s "$scratch/stderr.log" ] && tail -10 "$scratch/stderr.log" >&2
fi

# --- Path B: local Ollama server REST API (http://localhost:11434/api/chat) -----------
# NOTE: if we get here with cli_present==1, the CLI *was* found (Path A just came back
# empty, e.g. model not pulled) — that is an anti-empty-guard failure (exit 1), not a
# "nothing available at all" failure (exit 127). The 127 case is only reachable when the
# CLI is absent, which the earlier guard already confirmed against server_up.
if ! server_up; then
  if [ "$cli_present" -eq 1 ]; then
    echo "[run_ollama.sh] ollama CLI produced no answer and no local server is reachable at $OLLAMA_HOST_URL." >&2
    exit 1
  fi
  echo "[run_ollama.sh] ollama not found - install from https://ollama.com and pull a model, or start the local server" >&2
  exit 127
fi

body_file="$scratch/body.json"
resp_file="$scratch/resp.json"

MODEL="$model" "$FUSION_PY" - "$prompt_file" > "$body_file" <<'PYEOF'
import json
import os
import sys

prompt_path = sys.argv[1]
with open(prompt_path, "r", encoding="utf-8", errors="replace") as f:
    prompt = f.read()

body = {
    "model": os.environ["MODEL"],
    "stream": False,
    "messages": [{"role": "user", "content": prompt}],
}
sys.stdout.write(json.dumps(body))
PYEOF

if have curl; then
  _run_with_timeout "$FUSION_TIMEOUT" curl -s -m "$FUSION_TIMEOUT" \
    -X POST "$OLLAMA_HOST_URL/api/chat" \
    -H 'Content-Type: application/json' \
    --data-binary "@$body_file" \
    -o "$resp_file"
  status=$?
  if [ $status -eq 124 ]; then
    echo "[run_ollama.sh] local server request timed out after ${FUSION_TIMEOUT}s" >&2
    exit 124
  fi
  if [ $status -ne 0 ]; then
    echo "[run_ollama.sh] curl to $OLLAMA_HOST_URL/api/chat failed (status $status)" >&2
    [ -s "$resp_file" ] && tail -20 "$resp_file" >&2
    exit 1
  fi
else
  echo "[run_ollama.sh] curl not found - cannot reach local Ollama server API" >&2
  exit 127
fi

"$FUSION_PY" - "$resp_file" > "$output_file" <<'PYEOF'
import json
import sys

# LLM answers routinely contain non-ASCII glyphs (em-dashes, smart quotes, math symbols).
# On Windows, Python defaults stdout to cp1252 when redirected to a file, which raises
# UnicodeEncodeError mid-write and leaves output_file empty/truncated. Force UTF-8
# (mirrors agy_transcript.py's identical guard).
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

resp_path = sys.argv[1]
try:
    with open(resp_path, "r", encoding="utf-8", errors="replace") as f:
        data = json.load(f)
    content = (data.get("message") or {}).get("content", "")
except Exception:
    content = ""
if content:
    sys.stdout.write(content)
PYEOF

# --- Anti-empty guard -------------------------------------------------------------------
if [ ! -s "$output_file" ]; then
  echo "[run_ollama.sh] ollama produced no answer (path A + path B both empty)." >&2
  [ -s "$resp_file" ] && { echo "[run_ollama.sh] server response tail:" >&2; tail -20 "$resp_file" >&2; }
  exit 1
fi
echo "[run_ollama.sh] ok (path B: local server API) -> $output_file"
