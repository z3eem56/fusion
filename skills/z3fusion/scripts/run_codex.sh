#!/usr/bin/env bash
# run_codex.sh — run one GPT-5.6 Sol panelist (via codex) on a prompt, with web search + bash.
#
# Usage:
#   run_codex.sh <prompt_file> <output_file> [reasoning_effort] [model]
#
# - <prompt_file>   : path to a file containing the FULL panelist prompt (verbatim user task + brief instruction)
# - <output_file>   : where the panelist's final answer is written (clean, just the answer)
# - reasoning_effort: low | medium | high | xhigh   (default: xhigh)
# - model           : optional model override, e.g. gpt-5.6-sol (default: codex's own configured model).
#                      Passed through as `--model <model>` — the verified, documented codex exec flag
#                      ("Override the configured model for this run"), distinct from the
#                      `-c model_reasoning_effort=...` config override below. Omit/empty = old behavior.
#
# Notes:
# - `-o/--output-last-message` writes ONLY the agent's final message — no streaming noise to parse.
# - The panelist runs against a temporary copy of the current repo/workdir, so its file writes do not
#   touch your live checkout.
# - `--dangerously-bypass-approvals-and-sandbox` intentionally gives the panelist the same local tool
#   access as a normal trusted Codex CLI run. This is needed for macOS keychain-backed tools like `gh`.
# - `-c tools.web_search=true` enables the web search tool.
# - The throwaway copy is deleted when the panelist exits.
# - There is no `timeout`/`gtimeout` on stock macOS, so the codex run is wrapped in a self-contained
#   perl timeout helper (FUSION_TIMEOUT, default 300s — see _fusion_lib.sh). On timeout the runner
#   exits 124 so the orchestrator drops GPT-5.6 Sol and degrades the panel gracefully.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/_fusion_lib.sh"

prompt_file="${1:?usage: run_codex.sh <prompt_file> <output_file> [reasoning_effort] [model]}"
output_file="${2:?usage: run_codex.sh <prompt_file> <output_file> [reasoning_effort] [model]}"
effort="${3:-xhigh}"
model="${4:-}"

if ! have codex; then
  echo "[run_codex.sh] codex CLI not installed — skip this panelist." >&2
  exit 127
fi

case "$prompt_file" in
  /*) ;;
  *) prompt_file="$(pwd -P)/$prompt_file" ;;
esac
case "$output_file" in
  /*) ;;
  *) output_file="$(pwd -P)/$output_file" ;;
esac

if [ ! -s "$prompt_file" ]; then
  echo "[run_codex.sh] prompt file is missing or empty: $prompt_file" >&2
  exit 2
fi
mkdir -p "$(dirname "$output_file")"
rm -f "$output_file"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/z3fusion-codex.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
workdir="$scratch/workdir"

source_root="$(pwd -P)"
source_subdir=""
if git_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  source_root="$(cd "$git_root" && pwd -P)"
  current_dir="$(pwd -P)"
  case "$current_dir" in
    "$source_root") source_subdir="" ;;
    "$source_root"/*) source_subdir="${current_dir#"$source_root"/}" ;;
    *) source_subdir="" ;;
  esac
fi

# _stage_workdir — (re)build the throwaway copy this attempt runs against.
# Called once per attempt rather than once per run: attempt 1 has full local tool access and
# may have written all over its copy before failing, so attempt 2 reusing that tree would be
# resuming a failed run's side effects instead of starting clean. Same attempt-isolation rule
# run_gemini.sh applies by giving each agy attempt a fresh workspace.
_stage_workdir() {
  rm -rf "$workdir"
  mkdir -p "$workdir"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a \
      --exclude '.git/index.lock' \
      --exclude '.git/shallow.lock' \
      --exclude '.git/worktrees/*/index.lock' \
      "$source_root"/ "$workdir"/
  else
    cp -R "$source_root"/. "$workdir"/
  fi

  panel_cwd="$workdir"
  if [ -n "$source_subdir" ]; then
    panel_cwd="$workdir/$source_subdir"
  fi
}

if command -v gh >/dev/null 2>&1; then
  if gh auth status --active --hostname github.com >/dev/null 2>&1; then
    echo "[run_codex.sh] gh auth ok in parent environment" >&2
  else
    echo "[run_codex.sh] warning: gh auth is not usable in parent environment" >&2
  fi
fi

# Build the arg list as an array (always non-empty — never expand a possibly-empty array
# under `set -u`, which is unbound-variable-under-nounset on the old bash 3.2 that ships as
# /bin/bash on macOS) so the optional --model override can be spliced in cleanly.
# _codex_attempt <n> <budget_seconds> — one clean codex run. Exit status is codex's own,
# or 124 if the budget was hit. Never retries; the driver below owns that decision.
_codex_attempt() {
  local n="$1" budget="$2"
  _stage_workdir

  codex_args=(
    exec
    --skip-git-repo-check
    --ephemeral
    --cd "$panel_cwd"
    --dangerously-bypass-approvals-and-sandbox
    -c tools.web_search=true
    -c "model_reasoning_effort=$effort"
  )
  if [ -n "$model" ]; then
    codex_args+=( --model "$model" )
  fi
  codex_args+=( -o "$output_file" )

  # Clear any partial answer attempt n-1 left behind, so "-s $output_file" below can only
  # ever be true because THIS attempt wrote it.
  rm -f "$output_file"

  _run_with_timeout "$budget" codex "${codex_args[@]}" \
    - < "$prompt_file" \
    > "$scratch/stream.$n.log" 2>&1
}

# _model_note <log> — if codex rejected the requested model outright, say WHICH model and what
# this codex install would have used instead. Without this the orchestrator only sees a raw 400 and
# has to guess whether the panelist is unusable or merely mis-addressed. VERIFIED on codex-cli
# 0.144.1 with ChatGPT-account auth: `gpt-5.6` is rejected there and `gpt-5.6-sol` is the accepted
# slug — the model half of a panel slot must name the runtime slug, not the marketing name.
_model_note() {
  local log="$1" cfg="${CODEX_HOME:-$HOME/.codex}/config.toml" default=""
  grep -qiE 'not supported when using Codex|unknown model|invalid model|model not found|no such model' "$log" 2>/dev/null || return 0
  [ -f "$cfg" ] && default="$(grep -m1 -E '^[[:space:]]*model[[:space:]]*=' "$cfg" 2>/dev/null | cut -d'"' -f2)"
  echo "[run_codex.sh] codex REJECTED the requested model '${model:-<codex default>}'." >&2
  if [ -n "$default" ]; then
    echo "[run_codex.sh] this codex install's own configured model is '$default' — pass that as the" >&2
    echo "[run_codex.sh] slot's model half (e.g. '$default@codex'), or pass an empty model to use it." >&2
  else
    echo "[run_codex.sh] pass an empty model to fall back to codex's own configured default." >&2
  fi
  echo "[run_codex.sh] not retried: an unsupported model is deterministic (see _fusion_lib.sh)." >&2
}

# --- DRIVER — at most FUSION_MAX_ATTEMPTS, retrying only transient failures ---------------
n=1
while : ; do
  budget="$(_attempt_budget "$n")"
  _codex_attempt "$n" "$budget"
  status=$?
  log="$scratch/stream.$n.log"

  # An exit-0 run that wrote nothing is a failure, not a success — classify it as the generic
  # failure (1) so the evidence in the log decides whether it is worth another attempt.
  if [ $status -eq 0 ] && [ ! -s "$output_file" ]; then
    echo "[run_codex.sh] attempt $n: codex exited 0 but wrote no answer." >&2
    status=1
  fi

  if [ $status -eq 0 ]; then
    [ "$n" -gt 1 ] && echo "[run_codex.sh] recovered on attempt $n/$FUSION_MAX_ATTEMPTS." >&2
    break
  fi

  if _should_retry "$status" "$n" "$log"; then
    [ $status -eq 124 ] && echo "[run_codex.sh] attempt $n timed out after ${budget}s." >&2
    _attempt_note run_codex.sh "$n" "$status"
    tail -20 "$log" >&2
    n=$(( n + 1 ))
    continue
  fi

  if [ $status -eq 124 ]; then
    echo "[run_codex.sh] codex timed out after ${budget}s on attempt $n/$FUSION_MAX_ATTEMPTS; tail of log:" >&2
    tail -20 "$log" >&2
    exit 124
  fi
  _model_note "$log"
  echo "[run_codex.sh] codex exited $status on attempt $n/$FUSION_MAX_ATTEMPTS; tail of log:" >&2
  tail -20 "$log" >&2
  exit 1
done
echo "[run_codex.sh] ok -> $output_file"
