#!/usr/bin/env bash
# preflight.sh — pre-run, NON-BLOCKING sanity check the orchestrator shows before fanning out.
#
# Usage:
#   preflight.sh <slug> <prompt_file>
#
# Prints: a rough token/call estimate (so a heavy question doesn't surprise you) and a Codex
# cap reminder. It NEVER blocks — it only informs. Always exits 0.

set -uo pipefail

slug="${1:?usage: preflight.sh <slug> <prompt_file>}"
prompt_file="${2:?usage: preflight.sh <slug> <prompt_file>}"

case "$slug" in
  claude-gpt5.6-gemini3.1pro) n=3 ;;
  claude-gpt5.6|claude-gemini3.1pro|claude-claude)  n=2 ;;
  *)                           n=2 ;;
esac

words=0
[ -f "$prompt_file" ] && words="$(wc -w < "$prompt_file" | tr -d ' ')"
# ~1.3 tokens/word, very rough; output usually dwarfs input on deep questions.
in_tokens=$(( words * 4 / 3 ))

echo "preflight (informational — not a gate):"
echo "  panel        : $slug  ($n panelists + 1 Opus judge pass)"
echo "  prompt size  : ~${words} words (~${in_tokens} input tokens) sent to EACH of $n panelists"
echo "  note         : each panelist also generates a full answer, and the judge reads all $n;"
echo "                 real token cost is several× the input. Heavy deep-research questions are slow."
echo "  per-panelist timeout : ${FUSION_TIMEOUT:-300}s (override with FUSION_TIMEOUT)"
echo "  attempts/panelist    : ${FUSION_MAX_ATTEMPTS:-2} — attempt 2 runs at $(( ${FUSION_TIMEOUT:-300} * ${FUSION_RETRY_FACTOR:-2} ))s and fires ONLY on a"
echo "                 transient failure (timeout / 429 / 5xx / connection reset). Auth, quota,"
echo "                 unknown-model and missing-CLI failures never retry. FUSION_MAX_ATTEMPTS=1 = one-shot."
echo "                 The Bash tool caps a call at 600s, so a multi-hour panelist needs the detached"
echo "                 supervisor (Z3F_GEMINI_HEAVY=1, agy only) — not a bigger FUSION_TIMEOUT."

if command -v codex >/dev/null 2>&1; then
  echo "  codex (GPT-5.6 Sol) : installed — quota isn't readable non-interactively; if a run fails on"
  echo "                    cap, check '/status' inside codex. Panel degrades gracefully if it does."
else
  echo "  codex (GPT-5.6 Sol) : NOT installed — GPT-5.6 Sol panelist will be skipped."
fi

exit 0
