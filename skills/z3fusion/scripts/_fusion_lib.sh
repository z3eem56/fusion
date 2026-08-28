#!/usr/bin/env bash
# _fusion_lib.sh — shared helpers for the z3Fusion panelist runners.
#
# Sourced (not executed) by run_codex.sh and run_gemini.sh:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "$SCRIPT_DIR/_fusion_lib.sh"
#
# Why this exists: macOS has no `timeout`/`gtimeout` (those ship with GNU coreutils,
# not installed here). _run_with_timeout reproduces GNU `timeout` semantics with a
# small self-contained perl fork+alarm wrapper: it sends SIGTERM on the deadline,
# then SIGKILL after a 2s grace, returns the command's real exit status, and returns
# 124 when the command was killed for running over time.

# Default per-panelist budget in seconds; override with FUSION_TIMEOUT.
FUSION_TIMEOUT="${FUSION_TIMEOUT:-300}"

# Python interpreter: Windows installs often expose only `python`, not `python3`.
# Falls back to the literal "python3" so error messages still name the real dependency.
FUSION_PY="${FUSION_PY:-$(command -v python3 || command -v python || echo python3)}"

have() { command -v "$1" >/dev/null 2>&1; }

# _run_with_timeout SECONDS cmd [args...]
# Exit status = the command's own status, or 124 if it was killed for timing out.
_run_with_timeout() {
  local secs="$1"; shift
  perl -e '
    my $secs = shift @ARGV;
    my $pid = fork();
    exit 127 unless defined $pid;
    if ($pid == 0) { exec @ARGV or exit 127; }   # child: become the real command
    local $SIG{ALRM} = sub { kill "TERM", $pid; sleep 2; kill "KILL", $pid; };
    alarm $secs;
    waitpid($pid, 0);
    my $rc = $?;
    alarm 0;
    exit 124 if ($rc & 127);   # killed by a signal (our TERM/KILL) => timed out
    exit($rc >> 8);            # otherwise propagate the command exit code
  ' "$secs" "$@"
}

# ==========================================================================================
# ATTEMPT POLICY — shared by every SYNCHRONOUS runner (codex, ollama, openai-compat).
# ==========================================================================================
# run_gemini.sh had a 2-attempt transient-retry loop from the start; the other runners were
# one-shot, so a single blip (a 502, a connection reset, a cold model load overrunning the
# budget) killed a panelist that a second try would have answered. These helpers give every
# runner the SAME policy, with the same two rules that make it safe:
#
#   1. Only TRANSIENT failures retry. An auth error, an unknown model, or a quota cap cannot
#      be fixed by trying again — retrying those just burns the budget twice and delays the
#      degradation note the orchestrator needs. `_retry_verdict`'s deny-list is checked FIRST
#      so "auth failed after timeout" classifies as deterministic, not transient.
#   2. The budget ESCALATES. Attempt n runs at FUSION_TIMEOUT * FUSION_RETRY_FACTOR^(n-1),
#      because the most common transient failure is "not enough time", and a retry at the
#      same budget would fail the same way.
#
# NOTE — the ceiling here is the HARNESS, not this policy. Claude's Bash tool caps a
# foreground call at 600s, so a synchronous panelist cannot usefully be given a multi-hour
# budget no matter what FUSION_TIMEOUT says: the tool call dies first and the runner never
# gets to report. Multi-hour work needs the DETACHED supervisor (gemini_heavy.sh), which is
# why that file exists and why it is not simply a bigger timeout. See SKILL.md.
#
# Config (env):
#   FUSION_MAX_ATTEMPTS  attempts per panelist. Default 2, clamped 1..3. 1 = old one-shot.
#   FUSION_RETRY_FACTOR  budget multiplier per extra attempt. Default 2, minimum 1.
FUSION_MAX_ATTEMPTS="${FUSION_MAX_ATTEMPTS:-2}"
case "$FUSION_MAX_ATTEMPTS" in 1|2|3) ;; *) FUSION_MAX_ATTEMPTS=2 ;; esac
FUSION_RETRY_FACTOR="${FUSION_RETRY_FACTOR:-2}"
case "$FUSION_RETRY_FACTOR" in ''|*[!0-9]*) FUSION_RETRY_FACTOR=2 ;; esac
[ "$FUSION_RETRY_FACTOR" -lt 1 ] && FUSION_RETRY_FACTOR=1

# _attempt_budget <n> — seconds allowed for attempt <n> (1-based).
_attempt_budget() {
  local n="$1" b="$FUSION_TIMEOUT" i=1
  case "$n" in ''|*[!0-9]*) n=1 ;; esac
  while [ "$i" -lt "$n" ]; do
    b=$(( b * FUSION_RETRY_FACTOR ))
    i=$(( i + 1 ))
  done
  printf '%s' "$b"
}

# _retry_verdict <text...> — "yes" only for evidence that a longer/fresh attempt could fix.
# The deny-list is checked FIRST so "auth failed after timeout" is never retried.
# (run_gemini.sh defines its own identical copy AFTER sourcing this file — that override is
# deliberate and harmless; the classification rules are intentionally the same.)
_retry_verdict() {
  if printf '%s' "$*" | grep -qiE 'not logged in|unauthori[sz]ed|authentication|auth failed|permission denied|invalid api key|forbidden|quota|usage limit|billing|not supported|unknown model|invalid model|model not found|no such model'; then
    printf 'no'
    return
  fi
  if printf '%s' "$*" | grep -qiE 'timeout|timed out|deadline exceeded|temporarily unavailable|service unavailable|overloaded|rate limit|connection (reset|refused|closed)|unexpected eof|\b(429|50[234])\b'; then
    printf 'yes'
    return
  fi
  printf 'no'
}

# _should_retry <exit_code> <attempt_n> <evidence_file>
# Returns 0 (retry) only when another attempt remains AND the failure looks transient.
#
# Exit codes are authoritative where they are unambiguous, and only the generic failure (1)
# is classified from the runner's own captured output:
#   124 timed out          -> transient by construction; a longer budget is exactly the fix.
#   127 CLI/API absent     -> NEVER. A missing binary does not appear on a second try; this is
#                             the graceful-degradation signal and must reach the caller fast.
#   2   bad usage          -> NEVER. Deterministic by definition.
#   1   other failure      -> read the evidence: a 502 retries, a bad API key does not.
_should_retry() {
  local rc="$1" n="$2" ev_file="$3"
  [ "$n" -lt "$FUSION_MAX_ATTEMPTS" ] || return 1
  case "$rc" in
    124) return 0 ;;
    127|2|0) return 1 ;;
  esac
  local ev=""
  [ -f "$ev_file" ] && ev="$(tail -c 4000 "$ev_file" 2>/dev/null)"
  [ "$(_retry_verdict "$ev")" = "yes" ]
}

# _attempt_note <runner_tag> <n> <rc> — one line to stderr when a retry is about to happen,
# so a degraded-but-recovered panelist is visible in the transcript rather than silent.
_attempt_note() {
  echo "[$1] attempt $2 failed transiently (exit $3) — retrying at $(_attempt_budget $(( $2 + 1 )))s (attempt $(( $2 + 1 ))/$FUSION_MAX_ATTEMPTS)." >&2
}

# _drive_attempts <tag> <script_path> [args...]
# Attempt loop for runners whose body has MANY exit points (run_ollama.sh's two paths,
# run_openai_compat.sh's build/post/http/extract stages). Refactoring those bodies into a
# retryable function would mean turning every `exit` into a `return` and re-deriving each
# status — a large edit to working code for no behavioral gain. Instead the script re-executes
# ITSELF once per attempt as a child, with FUSION_ATTEMPT set so the child skips this branch
# and runs its body completely unchanged. Every existing exit code keeps its exact meaning,
# because it is still the same code path producing it.
#
# Call it immediately after sourcing this file, before the body:
#     _drive_attempts run_ollama.sh "${BASH_SOURCE[0]}" "$@"
#
# In the PARENT this never returns — it exits with the final attempt's status. In the CHILD
# (FUSION_ATTEMPT already set) it returns 0 immediately and the body runs as normal.
#
# Child stderr is collected to a file and echoed when the attempt ends, so a failure's own
# words are available to _should_retry. That trades live streaming for classifiable evidence;
# a panelist is a bounded batch run, so nothing is watching it stream anyway.
_drive_attempts() {
  local tag="$1" script="$2"; shift 2

  # Child process: the body is what runs. Fall through.
  [ -n "${FUSION_ATTEMPT:-}" ] && return 0

  # Explicitly configured one-shot: run the body in THIS process, no subprocess at all, so
  # FUSION_MAX_ATTEMPTS=1 is byte-for-byte the pre-attempt-policy behavior.
  if [ "$FUSION_MAX_ATTEMPTS" -le 1 ]; then
    FUSION_ATTEMPT=1
    export FUSION_ATTEMPT
    return 0
  fi

  local n=1 rc err
  err="$(mktemp "${TMPDIR:-/tmp}/z3fusion-attempt.XXXXXX")" || return 0
  while : ; do
    FUSION_ATTEMPT="$n" FUSION_TIMEOUT="$(_attempt_budget "$n")" \
      bash "$script" "$@" 2> "$err"
    rc=$?
    [ -s "$err" ] && cat "$err" >&2

    if [ "$rc" -eq 0 ]; then
      [ "$n" -gt 1 ] && echo "[$tag] recovered on attempt $n/$FUSION_MAX_ATTEMPTS." >&2
      rm -f "$err"
      exit 0
    fi
    if _should_retry "$rc" "$n" "$err"; then
      _attempt_note "$tag" "$n" "$rc"
      n=$(( n + 1 ))
      continue
    fi
    rm -f "$err"
    exit "$rc"
  done
}

# _extract_openai_content JSON_FILE OUTPUT_FILE
# Reads an OpenAI-chat-completions-shaped JSON response (choices[0].message.content),
# falling back to a bare Ollama-native shape (message.content) when there's no "choices"
# array, and writes just that text to OUTPUT_FILE. Missing/unreadable/malformed JSON, or a
# response matching neither shape, is NOT an error here: OUTPUT_FILE is simply left empty.
# The caller does the anti-empty guard (same convention as every existing runner), not this
# helper.
_extract_openai_content() {
  local json_file="$1" output_file="$2"
  "$FUSION_PY" -c '
import json
import sys

json_file, output_file = sys.argv[1], sys.argv[2]
data = None
try:
    with open(json_file, "r", encoding="utf-8", errors="replace") as f:
        data = json.load(f)
except Exception:
    data = None

text = ""
if isinstance(data, dict):
    try:
        text = data["choices"][0]["message"]["content"] or ""
    except (KeyError, IndexError, TypeError):
        try:
            text = data["message"]["content"] or ""
        except (KeyError, TypeError):
            text = ""

# Some providers return content as a list of parts ({"type": "text", "text": ...})
# instead of a plain string — flatten the text parts.
if isinstance(text, list):
    text = "".join(
        p.get("text", "") for p in text
        if isinstance(p, dict) and isinstance(p.get("text", ""), str)
    )

with open(output_file, "w", encoding="utf-8") as f:
    f.write(text if isinstance(text, str) else "")
' "$json_file" "$output_file"
}
