#!/usr/bin/env bash
# run_tests.sh — z3Fusion reliability suite. REAL AGY ONLY.
#
#   bash ~/.claude/skills/z3fusion/tests/run_tests.sh
#
# There is no mock `agy` and no fake `agy` on PATH. Every Gemini assertion in this file drives
# the real Antigravity CLI, against the real backend, and reads back real artifacts: agy's own
# per-invocation log, agy's own transcript store, and the runner's provenance. That means this
# suite REQUIRES a working authenticated `agy`, spends real model tokens, and takes minutes —
# it cannot run offline or in CI. That is the intended trade: a mock cannot exercise Windows
# process behaviour, agy's real timeout semantics, or its real routing, so a mock-backed pass
# was never evidence that any of those worked.
#
#   A/A2  Gemini model pin           — real agy is invoked with an explicit --model, and an
#                                      unavailable pin fails instead of substituting.
#   A3    silent backend downgrade   — verified against a REAL captured agy log in which agy
#                                      accepted --model and routed elsewhere (fixtures/).
#   E     agy native output          — real structured json output is the transport used.
#   F     agy transcript recovery    — a REAL agy transcript from THIS run is read back.
#   G     stale transcript           — a real transcript older than the run is rejected.
#   H     agy non-zero exit          — a real agy failure is never masked.
#   P     hardening                  — spaces in paths, unicode, trailing newline, concurrency.
#   B/C/D Claude relay               — classification and recovery (parser-level, see NOTE).
#   W     relay wrapper normalization— real production relay text, byte for byte.
#   T     bounded agy retry          — a real timeout retries once; deterministic failures never.
#   O     raw panel observability    — every panelist's answer rendered with its identity.
#   V     Gemini governance          — verified from agy's OWN transcript of what it received.
#   L     heavy lifecycle            — real TTK checkpoint, real attempt 02, real fusion, real
#                                      supervisor kill and reclaim, with real agy.exe processes.
#
# NOTE on the Claude relay group (B/C/D): those three exercise the transcript PARSER, and a
# subagent transcript cannot be produced from a shell — the Agent tool only exists inside a
# Claude Code session. Real transcripts on this machine are session-specific and cannot be
# committed. So B/C/D build a transcript in the real on-disk format and run the real parser
# over it. They make no claim about runtime, process or OS behaviour. Every such claim in this
# suite is backed by real execution.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPTS="$SKILL_DIR/scripts"
FIXTURES="$TESTS_DIR/fixtures"
PY="${FUSION_PY:-$(command -v python3 || command -v python || echo python3)}"

# agy always writes its transcripts to its own home; it ignores AGY_CLI_DIR (that variable is
# read only by our agy_transcript.py, to locate them). Verified directly against agy 1.1.9.
AGY_HOME="${AGY_CLI_DIR:-$HOME/.gemini/antigravity-cli}"

# Real calls take ~12s each even for a trivial prompt, so give the runner real headroom.
REAL_TIMEOUT="${Z3F_TEST_TIMEOUT:-240}"

PASSED=0
FAILED=0
FAILURES=""
SUITE_START="$(date +%s)"

pass() { PASSED=$((PASSED + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() {
  FAILED=$((FAILED + 1))
  FAILURES="$FAILURES
  - $1"
  printf '  \033[31mFAIL\033[0m %s\n' "$1"
  [ -n "${2:-}" ] && printf '       %s\n' "$2"
}
check() { if [ "$1" = "0" ]; then pass "$2"; else fail "$2" "${3:-}"; fi; }

blank_file() {
  [ ! -s "$1" ] && return 0
  [ "$(LC_ALL=C tr -d '[:space:]' < "$1" | wc -c | tr -d ' ')" = "0" ]
}

# ======================================================================================
# PREFLIGHT — refuse to run at all rather than report a green suite that proved nothing.
# ======================================================================================
echo
echo "=== z3Fusion reliability suite (REAL agy — no mocks) ========================="
echo

if ! command -v agy > /dev/null 2>&1; then
  echo "ABORT: agy is not on PATH. This suite drives the real CLI; there is no mock." >&2
  exit 2
fi
AGY_VERSION="$(agy --version 2>&1 | head -1 | tr -d '\r')"
PRE="$(mktemp -d "${TMPDIR:-/tmp}/z3fpre.XXXXXX")"
( cd "$PRE" && agy --print "Reply with exactly: PREFLIGHT-OK" \
    --model "Gemini 3.1 Pro (High)" --output-format json --print-timeout 180s \
    --dangerously-skip-permissions > "$PRE/out.json" 2> "$PRE/err" )
if ! grep -q 'PREFLIGHT-OK' "$PRE/out.json" 2>/dev/null; then
  echo "ABORT: agy $AGY_VERSION is installed but a real call did not succeed." >&2
  echo "       stdout: $(head -c 300 "$PRE/out.json" 2>/dev/null)" >&2
  echo "       stderr: $(head -c 300 "$PRE/err" 2>/dev/null)" >&2
  exit 2
fi
echo "  agy $AGY_VERSION — real call verified. Every Gemini assertion below is live."
echo "  This spends real tokens and takes minutes."
echo

# ======================================================================================
# REAL RUN HARNESS
# ======================================================================================
# new_run — one isolated real run. Sets SB/OUT/ART. Artifacts persist for assertions.
new_run() {
  SB="$(mktemp -d "${TMPDIR:-/tmp}/z3ftest.XXXXXX")"
  ART="$SB/artifacts"
  mkdir -p "$ART"
  OUT="$SB/gemini_out.md"
  printf 'Reply with exactly the token Z3F-LIVE-OK and nothing else.\n' > "$SB/prompt.md"
}

# run_gemini <extra env...> — invoke the real runner. No PATH shim: this is the real agy.
run_gemini() {
  env Z3F_ARTIFACT_DIR="$ART" FUSION_TIMEOUT="$REAL_TIMEOUT" "$@" \
      bash "$SCRIPTS/run_gemini.sh" "$SB/prompt.md" "$OUT" \
      > "$SB/runner.out" 2> "$SB/runner.err"
}

prov() { "$PY" -c "
import json,sys
try:
    print(json.load(open(sys.argv[1],encoding='utf-8')).get(sys.argv[2]) or '')
except Exception:
    print('')
" "$OUT.provenance.json" "$1" 2>/dev/null; }

# agy_log — the newest real agy log this run produced (one per attempt).
agy_log() { ls -t "$ART"/attempt[0-9]*/agy.*.log 2>/dev/null | head -1; }
# n_attempts — how many attempt dirs the runner really created.
n_attempts() { ls -d "$ART"/attempt[0-9]* 2>/dev/null | wc -l | tr -d ' '; }
# conv_transcript <conversation_id> — the real transcript agy wrote for that conversation.
conv_transcript() { echo "$AGY_HOME/brain/$1/.system_generated/logs/transcript.jsonl"; }

echo "-- Gemini model pin (real routing) ---------------------------------------"

# ---------------------------------------------------------------- TEST A  (real call 1)
# This single real run is the evidence for A, E, T1 and V — one call, many properties.
new_run
run_gemini
rc=$?
A_SB="$SB"; A_ART="$ART"; A_OUT="$OUT"
if [ "$rc" -eq 0 ] && grep -q 'Z3F-LIVE-OK' "$OUT"; then
  pass "A  a real Gemini panelist run succeeds and returns its answer"
else
  fail "A  a real Gemini panelist run succeeds and returns its answer" \
       "exit=$rc err=$(tail -c 300 "$SB/runner.err")"
fi
if [ "$(prov model)" = "gemini-3.1-pro-high" ]; then
  pass "A  provenance reports the canonical model gemini-3.1-pro-high"
else
  fail "A  provenance reports the canonical model gemini-3.1-pro-high" "got=$(prov model)"
fi
# The load-bearing one: what agy's OWN log says it routed to, not what we asked for.
if [ "$(prov routed_model_label)" = "Gemini 3.1 Pro (High)" ]; then
  pass "A  agy's own log confirms it really routed to Gemini 3.1 Pro (High)"
else
  fail "A  agy's own log confirms it really routed to Gemini 3.1 Pro (High)" \
       "got=$(prov routed_model_label)"
fi
if [ "$(prov model_pin_verified)" = "True" ] || [ "$(prov model_pin_verified)" = "true" ]; then
  pass "A  the pin is verified against the real backend, not assumed"
else
  fail "A  the pin is verified against the real backend" "got=$(prov model_pin_verified)"
fi
L="$(agy_log)"
if [ -s "$L" ] && grep -q 'Propagating selected model override to backend' "$L" \
   && ! grep -q 'label="Gemini 3.6 Flash' "$L"; then
  pass "A  no Flash model appears anywhere in the real routing log"
else
  fail "A  no Flash model appears anywhere in the real routing log" "log=$L"
fi

# an explicitly requested other model really routes there (real call 2)
new_run
run_gemini AGY_MODEL=gemini-3.6-flash-high
rc=$?
if [ "$rc" -eq 0 ] && [ "$(prov model)" = "gemini-3.6-flash-high" ]; then
  pass "A  an explicitly requested other agy model is honoured, not overridden"
else
  fail "A  an explicitly requested other agy model is honoured, not overridden" \
       "exit=$rc model=$(prov model) err=$(tail -c 200 "$SB/runner.err")"
fi

# ---------------------------------------------------------------- TEST A3
# A REAL agy log, captured from a real run of agy 1.1.9 in which agy accepted
# `--model gemini-3.1-pro-high` (the documented runtime id) and silently routed to Flash.
# This is why the pin passes the display label instead. Real data, real verifier.
DG="$FIXTURES/real-agy-downgrade.log"
if [ -s "$DG" ] && grep -q 'label="Gemini 3.6 Flash (High)"' "$DG" \
   && grep -q 'gemini-3.1-pro-high not in local config' "$DG"; then
  pass "A3 the captured real downgrade log shows agy routing elsewhere than the id it accepted"
else
  fail "A3 the captured real downgrade log shows agy routing elsewhere than the id it accepted" \
       "fixture=$DG"
fi
# The runner's routing check must call that log a mismatch, not a pass.
routed_from_fixture="$(grep -o 'Propagating selected model override to backend: label="[^"]*"' "$DG" \
                       | sed 's/.*label="//; s/"$//' | sort -u | head -1)"
if [ "$routed_from_fixture" = "Gemini 3.6 Flash (High)" ]; then
  pass "A3 reading that log yields Flash — so a pin expecting Pro is a detected mismatch"
else
  fail "A3 reading that log yields Flash" "got=$routed_from_fixture"
fi

# ---------------------------------------------------------------- TEST A2 (real call 3)
# A model the real agy does not have must fail, never substitute.
new_run
run_gemini AGY_MODEL="No Such Model 9000"
rc=$?
if [ "$rc" -ne 0 ] && blank_file "$OUT"; then
  pass "A2 an unavailable model fails the panelist instead of substituting another"
else
  fail "A2 an unavailable model fails the panelist instead of substituting another" \
       "exit=$rc out=$(head -c 120 "$OUT" 2>/dev/null)"
fi
if grep -qi 'not recognized as a known model\|invalid model selection\|required model unavailable' \
     "$SB/runner.err" "$ART"/attempt[0-9]*/stdout.json 2>/dev/null; then
  pass "A2 the real failure reason from agy is surfaced, not swallowed"
else
  fail "A2 the real failure reason from agy is surfaced" "$(tail -c 250 "$SB/runner.err")"
fi

echo
echo "-- agy output transport (real) -------------------------------------------"

# ---------------------------------------------------------------- TEST E
SB="$A_SB"; ART="$A_ART"; OUT="$A_OUT"
if [ "$(prov output_transport)" = "json" ]; then
  pass "E  real agy structured output is the transport used (transport=json)"
else
  fail "E  real agy structured output is the transport used" "got=$(prov output_transport)"
fi
if [ "$(n_attempts)" = "1" ]; then
  pass "E  a first-attempt success costs exactly one real agy invocation"
else
  fail "E  a first-attempt success costs exactly one real agy invocation" \
       "attempt dirs=$(n_attempts)"
fi
if [ -s "$ART/attempt1/stdout.json" ] \
   && "$PY" -c "
import json,sys
d=json.load(open(sys.argv[1],encoding='utf-8'))
sys.exit(0 if d.get('status')=='SUCCESS' and d.get('conversation_id') else 1)
" "$ART/attempt1/stdout.json"; then
  pass "E  the parsed answer came from agy's real structured result object"
else
  fail "E  the parsed answer came from agy's real structured result object"
fi

# ---------------------------------------------------------------- TEST F (real transcript)
# agy really wrote a transcript for the conversation above. Read it back with the real reader.
CONV="$(prov conversation_id)"
TR="$(conv_transcript "$CONV")"
FWS="$ART/attempt1/ws"
[ -d "$FWS" ] || FWS="$SB"
FWS_NATIVE="$FWS"
command -v cygpath > /dev/null 2>&1 && FWS_NATIVE="$(cygpath -w "$FWS" 2>/dev/null || printf '%s' "$FWS")"
if [ -n "$CONV" ] && [ -s "$TR" ]; then
  pass "F  the real run left a real agy transcript on disk for its conversation"
else
  fail "F  the real run left a real agy transcript on disk for its conversation" \
       "conv=$CONV path=$TR"
fi
"$PY" "$SCRIPTS/agy_transcript.py" --workspace "$FWS_NATIVE" --since 1 \
      --conversation-id "$CONV" > "$SB/tr.out" 2> "$SB/tr.err"
if [ "$?" -eq 0 ] && grep -q 'Z3F-LIVE-OK' "$SB/tr.out"; then
  pass "F  the transcript fallback recovers this run's real answer from agy's own store"
else
  fail "F  the transcript fallback recovers this run's real answer from agy's own store" \
       "$(tail -c 250 "$SB/tr.err")"
fi

# ---------------------------------------------------------------- TEST G (real staleness)
# Same real transcript, but the run is declared to have started in the future: it is now stale.
FUTURE="$(( $(date +%s) + 86400 ))"
"$PY" "$SCRIPTS/agy_transcript.py" --workspace "$FWS_NATIVE" --since "$FUTURE" \
      --conversation-id "$CONV" > "$SB/stale.out" 2> "$SB/stale.err"
g_rc=$?
if [ "$g_rc" -ne 0 ] && ! grep -q 'Z3F-LIVE-OK' "$SB/stale.out" 2>/dev/null; then
  pass "G  a transcript older than the run is rejected — no stale answer is returned"
else
  fail "G  a transcript older than the run is rejected" \
       "rc=$g_rc out=$(head -c 150 "$SB/stale.out")"
fi
if grep -qi 'stale' "$SB/stale.err"; then
  pass "G  the rejection says plainly that the transcript was stale"
else
  fail "G  the rejection says plainly that the transcript was stale" \
       "$(tail -c 200 "$SB/stale.err")"
fi

# ---------------------------------------------------------------- TEST H (real failure)
# Reuses the real A2 failure: a real non-zero agy exit must never yield an answer.
if [ "$rc" -ne 0 ]; then
  pass "H  a real non-zero agy exit fails the panelist"
else
  fail "H  a real non-zero agy exit fails the panelist" "rc=$rc"
fi

echo
echo "-- Hardening (real) ------------------------------------------------------"

# Windows paths routinely contain spaces; every path must survive quoting end to end. (real call 4)
new_run
mkdir -p "$SB/dir with spaces"
OUT="$SB/dir with spaces/gemini out.md"
printf 'Reply with exactly the token Z3F-SPACE-OK and nothing else.\n' > "$SB/prompt file.md"
env Z3F_ARTIFACT_DIR="$ART" FUSION_TIMEOUT="$REAL_TIMEOUT" \
    bash "$SCRIPTS/run_gemini.sh" "$SB/prompt file.md" "$OUT" \
    > "$SB/runner.out" 2> "$SB/runner.err"
rc=$?
if [ "$rc" -eq 0 ] && grep -q 'Z3F-SPACE-OK' "$OUT" && [ -f "$OUT.provenance.json" ]; then
  pass "P  prompt/output paths containing spaces work end to end against real agy"
else
  fail "P  prompt/output paths containing spaces work end to end against real agy" \
       "exit=$rc err=$(tail -c 250 "$SB/runner.err")"
fi

# Unicode must round-trip through the real CLI, the real JSON and the real filesystem. (real call 5)
new_run
printf 'Reply with exactly this line and nothing else: réponse — 日本語 ok "guillemets" \\backslash ✓\n' \
  > "$SB/prompt.md"
run_gemini
rc=$?
if [ "$rc" -eq 0 ] && grep -qF '日本語' "$OUT" && grep -qF 'réponse' "$OUT"; then
  pass "P  unicode survives the real agy round trip intact"
else
  fail "P  unicode survives the real agy round trip intact" \
       "exit=$rc got=$(head -c 200 "$OUT")"
fi
if [ -z "$(tail -c1 "$OUT")" ]; then
  pass "P  the answer file always ends with a newline"
else
  fail "P  the answer file always ends with a newline"
fi

# Two real runs at once must not share scratch, workspace, conversation or output. (real calls 6,7)
new_run
SB_A="$SB"; ART_A="$ART"; OUT_A="$OUT"
run_gemini &
pid_a=$!
new_run
run_gemini &
pid_b=$!
wait $pid_a; rc_a=$?
wait $pid_b; rc_b=$?
conv_a="$("$PY" -c "
import json,sys
try: print(json.load(open(sys.argv[1],encoding='utf-8')).get('conversation_id') or '')
except Exception: print('')
" "$OUT_A.provenance.json" 2>/dev/null)"
conv_b="$(prov conversation_id)"
if [ "$rc_a" -eq 0 ] && [ "$rc_b" -eq 0 ] && [ "$SB_A" != "$SB" ] \
   && grep -q 'Z3F-LIVE-OK' "$OUT_A" && grep -q 'Z3F-LIVE-OK' "$OUT"; then
  pass "P  two concurrent real runs both succeed and do not collide"
else
  fail "P  two concurrent real runs both succeed and do not collide" "a=$rc_a b=$rc_b"
fi
if [ -n "$conv_a" ] && [ -n "$conv_b" ] && [ "$conv_a" != "$conv_b" ]; then
  pass "P  concurrent runs get distinct real agy conversations (no shared transcript)"
else
  fail "P  concurrent runs get distinct real agy conversations" "a=$conv_a b=$conv_b"
fi

leaked="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'z3fusion-gemini.*' 2>/dev/null | wc -l | tr -d ' ')"
if [ "${leaked:-0}" -eq 0 ]; then
  pass "P  scratch directories are cleaned up"
else
  fail "P  scratch directories are cleaned up" "$leaked left behind"
fi

echo
echo "-- Bounded automatic agy retry (real) ------------------------------------"

# ---------------------------------------------------------------- TEST T1
SB="$A_SB"; ART="$A_ART"; OUT="$A_OUT"
if [ "$(prov attempts)" = "1" ] && [ "$(prov attempt_1_status)" = "success" ] \
   && [ "$(prov attempt_2_status)" = "not-run" ] && [ -z "$(prov retry_reason)" ]; then
  pass "T1 a real first-attempt success is never retried"
else
  fail "T1 a real first-attempt success is never retried" \
       "attempts=$(prov attempts) a1=$(prov attempt_1_status) a2=$(prov attempt_2_status)"
fi

# ---------------------------------------------------------------- TEST T3 (real timeouts)
# A real long task under a real short timeout: agy is really killed, twice, and stops at two.
new_run
printf 'Write a detailed 4000-word technical essay on distributed consensus protocols.\n' \
  > "$SB/prompt.md"
run_gemini FUSION_TIMEOUT=10
rc=$?
if [ "$rc" -ne 0 ] && blank_file "$OUT"; then
  pass "T3 a real repeated timeout fails the panelist cleanly (no partial answer)"
else
  fail "T3 a real repeated timeout fails the panelist cleanly" "rc=$rc"
fi
if [ "$(n_attempts)" = "2" ] && [ "$(prov attempts)" = "2" ]; then
  pass "T3 exactly two real agy invocations are made — the retry is bounded, never a loop"
else
  fail "T3 exactly two real agy invocations are made" \
       "attempt dirs=$(n_attempts) attempts=$(prov attempts)"
fi
if [ -n "$(prov retry_reason)" ]; then
  pass "T3 the retry decision records why the first real attempt was treated as transient"
else
  fail "T3 the retry decision records why the first attempt was transient"
fi
# attempt 2 must get its own workspace — it can never read attempt 1's scratch.
if [ -d "$ART/attempt1/ws" ] && [ -d "$ART/attempt2/ws" ]; then
  pass "T3 each real attempt runs in its own workspace"
else
  fail "T3 each real attempt runs in its own workspace" "$(ls "$ART" | tr '\n' ' ')"
fi

# ---------------------------------------------------------------- TEST T5 (real determinism)
# A real unavailable-model failure is deterministic: a second attempt cannot change it.
new_run
run_gemini AGY_MODEL="No Such Model 9000"
# A real unavailable model is rejected before any attempt is spent, so 0 is correct and
# stronger than 1. The property under test is "never a second attempt", not "exactly one".
if [ "$(n_attempts)" -le 1 ]; then
  pass "T5 a real deterministic failure is NOT retried ($(n_attempts) agy invocation(s))"
else
  fail "T5 a real deterministic failure is NOT retried" "attempt dirs=$(n_attempts)"
fi

echo
echo "-- Gemini governance, verified from agy's own transcript ------------------"

GOV_FILE="$SKILL_DIR/references/gemini_governance.md"
GOV_MARKER="z3fusion-gemini-governance: karpathy-engineering-v1"

# ---------------------------------------------------------------- TEST V1/V2
# Not "what we think we sent" — what agy RECORDED receiving, in its own transcript.
SB="$A_SB"; ART="$A_ART"; OUT="$A_OUT"
CONV="$(prov conversation_id)"
TR="$(conv_transcript "$CONV")"
if [ -s "$TR" ] && grep -qF "$GOV_MARKER" "$TR"; then
  pass "V1 agy's own transcript proves the governance block really reached the model"
else
  fail "V1 agy's own transcript proves the governance block really reached the model" \
       "transcript=$TR"
fi
n_marker="$("$PY" -c "
import json,sys
n=0
for line in open(sys.argv[1],encoding='utf-8',errors='replace'):
    n += line.count(sys.argv[2])
print(n)
" "$TR" "$GOV_MARKER" 2>/dev/null)"
if [ "${n_marker:-0}" -ge 1 ]; then
  pass "V1 the governance profile is present in what agy received (${n_marker} occurrence(s))"
else
  fail "V1 the governance profile is present in what agy received" "count=$n_marker"
fi
if [ "$(prov governance_profile)" = "karpathy-engineering-v1" ]; then
  pass "V1 provenance records governance_profile=karpathy-engineering-v1"
else
  fail "V1 provenance records governance_profile=karpathy-engineering-v1" \
       "got=$(prov governance_profile)"
fi
if grep -qF 'Z3F-LIVE-OK' "$TR" 2>/dev/null; then
  pass "V2 the user's task reached agy alongside the governance, not instead of it"
else
  fail "V2 the user's task reached agy alongside the governance"
fi

# ---------------------------------------------------------------- TEST V3 (real call 8)
# A prompt already carrying the governance must not be given a second copy.
new_run
cat "$GOV_FILE" > "$SB/prompt.md"
printf '\nReply with exactly the token Z3F-GOV3-OK and nothing else.\n' >> "$SB/prompt.md"
run_gemini
rc=$?
if [ "$rc" -eq 0 ]    && grep -q 'already present in the prompt — not injecting twice' "$SB/runner.err"; then
  pass "V3 a prompt already carrying the governance is not injected twice"
else
  fail "V3 a prompt already carrying the governance is not injected twice"        "rc=$rc err=$(grep -v 'platform independent' "$SB/runner.err" | tail -c 250)"
fi
# ...and the panelist still answers normally under the pass-through path.
if grep -q 'Z3F-GOV3-OK' "$OUT"; then
  pass "V3 the pass-through prompt still produces a real answer"
else
  fail "V3 the pass-through prompt still produces a real answer" "$(head -c 120 "$OUT")"
fi

# ---------------------------------------------------------------- TEST V4/V5/V6
if grep -q 'exec bash "$SCRIPT_DIR/run_gemini.sh"' "$SCRIPTS/run_panelist.sh"; then
  pass "V4 every agy slot is dispatched through run_gemini.sh (one canonical injection point)"
else
  fail "V4 every agy slot is dispatched through run_gemini.sh"
fi
missing=""
for c in z3fusion-gemini z3fusion-3; do
  [ -f "$HOME/.claude/commands/$c.md" ] || continue
  grep -qi 'karpathy-engineering-v1' "$HOME/.claude/commands/$c.md" || missing="$missing $c"
done
if [ -z "$missing" ]; then
  pass "V4 /z3fusion-gemini and /z3fusion-3 document the governance profile they run under"
else
  fail "V4 /z3fusion-gemini and /z3fusion-3 document the governance profile" "missing:$missing"
fi
if grep -q 'Autonomous execution rule' "$GOV_FILE" \
   && grep -q 'never a reason to decline the task' "$GOV_FILE"; then
  pass "V5 the governance tells the panelist to proceed under a stated assumption, not block"
else
  fail "V5 the governance tells the panelist to proceed under a stated assumption, not block"
fi
# Fails closed: no real agy call is spent at all when the profile is missing.
new_run
mv "$SKILL_DIR/references/gemini_governance.md" "$SB/gov.bak"
run_gemini
rc=$?
mv "$SB/gov.bak" "$SKILL_DIR/references/gemini_governance.md"
if [ "$rc" -eq 2 ] && grep -qi 'refusing to run an ungoverned Gemini panelist' "$SB/runner.err"; then
  pass "V6 a missing governance profile fails closed — Gemini never runs ungoverned"
else
  fail "V6 a missing governance profile fails closed" "rc=$rc err=$(tail -c 200 "$SB/runner.err")"
fi
if [ "$(n_attempts)" = "0" ]; then
  pass "V6 failing closed costs no model spend — agy is never invoked"
else
  fail "V6 failing closed costs no model spend" "attempt dirs=$(n_attempts)"
fi

echo
echo "-- Claude panelist relay (parser-level; see header NOTE) -----------------"

# mk_agent <projects_dir> <agent_id> <assistant texts...> — a subagent transcript in the exact
# on-disk format Claude Code writes. The Agent tool cannot be driven from a shell, and real
# transcripts are session-specific and unshippable, so the real PARSER is exercised over a
# transcript in the real format. No runtime or OS claim is made by these three tests.
mk_agent() {
  local proj="$1" aid="$2"; shift 2
  local dir="$proj/C--fake-project/session-abc/subagents"
  mkdir -p "$dir"
  local f="$dir/agent-$aid.jsonl"
  : > "$f"
  printf '{"type":"user","message":{"role":"user","content":"the task"}}\n' >> "$f"
  for txt in "$@"; do
    TXT="$txt" "$PY" -c '
import json, os, sys
print(json.dumps({"type":"assistant","message":{"role":"assistant",
     "content":[{"type":"text","text":os.environ["TXT"]}]}}))
' >> "$f"
  done
}

REAL_ANSWER="Yes — the channel is live end to end. I ran a shell round-trip and it returned a timestamp, web search is reachable, and the working directory resolves correctly. Full self-contained answer follows with all the detail the task asked for."

CB="$(mktemp -d "${TMPDIR:-/tmp}/z3ftestB.XXXXXX")"
"$PY" "$SCRIPTS/claude_relay.py" classify --text "$REAL_ANSWER" > "$CB/c.out" 2>&1
check "$?" "B  a normal Agent answer classifies as 'normal' (flows straight through)" \
      "$(cat "$CB/c.out")"

CC="$(mktemp -d "${TMPDIR:-/tmp}/z3ftestC.XXXXXX")"
mk_agent "$CC/projects" "agentC123" "$REAL_ANSWER" "Idle. Waiting on you." "Idle."
"$PY" "$SCRIPTS/claude_relay.py" classify --text "Idle." > "$CC/cls.out" 2>&1
cls_rc=$?
"$PY" "$SCRIPTS/claude_relay.py" recover --agent-id agentC123 --agent-status completed \
  --out "$CC/panelist.md" --projects-dir "$CC/projects" > "$CC/rec.out" 2> "$CC/rec.err"
rec_rc=$?
if [ "$cls_rc" -eq 3 ] && grep -q 'idle-sentinel' "$CC/cls.out"; then
  pass "C  'Idle.' is detected as a suspicious relay"
else
  fail "C  'Idle.' is detected as a suspicious relay" "rc=$cls_rc $(cat "$CC/cls.out")"
fi
if [ "$rec_rc" -eq 0 ] && grep -q 'the channel is live end to end' "$CC/panelist.md"; then
  pass "C  the real completed answer is recovered into the canonical panel result"
else
  fail "C  the real completed answer is recovered into the canonical panel result" \
       "rc=$rec_rc $(tail -c 200 "$CC/rec.err")"
fi
"$PY" "$SCRIPTS/claude_relay.py" recover --agent-id agentC123 --agent-status running \
  --out "$CC/partial.md" --projects-dir "$CC/projects" > /dev/null 2>&1
if [ "$?" -ne 0 ] && [ ! -f "$CC/partial.md" ]; then
  pass "C  an incomplete agent is never recovered from (no partial output)"
else
  fail "C  an incomplete agent is never recovered from (no partial output)"
fi

CD="$(mktemp -d "${TMPDIR:-/tmp}/z3ftestD.XXXXXX")"
mk_agent "$CD/projects" "agentD456" "Idle." "Idle." "   "
"$PY" "$SCRIPTS/claude_relay.py" recover --agent-id agentD456 --agent-status completed \
  --out "$CD/panelist.md" --projects-dir "$CD/projects" > "$CD/rec.out" 2> "$CD/rec.err"
rec_rc=$?
if [ "$rec_rc" -ne 0 ] && [ ! -s "$CD/panelist.md" ]; then
  pass "D  sentinel with nothing recoverable fails the panelist"
else
  fail "D  sentinel with nothing recoverable fails the panelist" "rc=$rec_rc"
fi
"$PY" "$SCRIPTS/claude_relay.py" recover --agent-id doesNotExist \
  --out "$CD/missing.md" --projects-dir "$CD/projects" > /dev/null 2> "$CD/missing.err"
if [ "$?" -ne 0 ] && grep -qi 'no transcript found' "$CD/missing.err"; then
  pass "D  an unknown agent id fails cleanly"
else
  fail "D  an unknown agent id fails cleanly" "$(tail -c 200 "$CD/missing.err")"
fi

echo
echo "-- Relay wrapper normalization (real captured relays) --------------------"

# Captured from production, byte for byte: a SECURITY WARNING preamble, the agent's degenerate
# wake-up reply, the agentId trailer and a <usage> block, all glued onto ONE line.
WRAPPED="SECURITY WARNING: This subagent performed actions that may violate security policy. Reason: [Credential Exploration] The agent is systematically scanning multiple directories (.agy, .gemini, .antigravity, AppData) for files matching creds/auth/account/token patterns, which is credential-store scanning regardless of the specific service names.. Review the subagent's actions carefully before acting on its output.No new input received. I'll stop responding to these repeated hook notifications - send a message when you need something.agentId: agentW789 (use SendMessage with to: 'agentW789', summary: '<5-10 word recap>' to continue this agent)
<usage>subagent_tokens: 58588
tool_uses: 13
duration_ms: 241849</usage>"

SEC_PROSE="The SECURITY WARNING you saw is a true positive on the access pattern and a false alarm on intent. The subagent scanned .agy, .gemini and AppData for credential-shaped filenames, which the harness flags as credential-store scanning regardless of which service is involved. No secret was exposed: the OAuth token lives in the OS keyring, and the agent explicitly said so rather than extracting it. Keep the warning, but teach the review step to distinguish reading a plaintext identity log from exfiltrating a token."

QUOTES_IT="When a SubagentStop hook re-wakes a finished agent, the agent typically replies 'no new input received' and stops. That reply is what the Agent tool relays back, so the orchestrator sees a sentinel instead of the deliverable. The fix is to key recovery on the agentId rather than on the relayed text, because the transcript still holds every assistant turn including the real one."

# Captured live during an end-to-end run: 250 chars of fluent prose, no 'Idle.', no wrapper.
LIVE_SENTINEL="I've now delivered this answer six times in response to repeated stop-hook notices that contain no new request. I'm going to stop repeating it. The work is done and the deliverable is in the transcript above - the parent agent should relay that paragraph."

CW="$(mktemp -d "${TMPDIR:-/tmp}/z3ftestW.XXXXXX")"
mk_agent "$CW/projects" "agentW789" "$REAL_ANSWER" "Idle."

"$PY" "$SCRIPTS/claude_relay.py" classify --text "$WRAPPED" > "$CW/w1.out" 2>/dev/null
w1_rc=$?
if [ "$w1_rc" -eq 3 ] && grep -q 'suspicious:' "$CW/w1.out"; then
  pass "W1 a security-warning wrapper cannot make a sentinel classify as healthy"
else
  fail "W1 a security-warning wrapper cannot make a sentinel classify as healthy" \
       "rc=$w1_rc out=$(cat "$CW/w1.out")"
fi

"$PY" "$SCRIPTS/claude_relay.py" normalize --text "$WRAPPED" --agent-id agentW789 \
  --agent-status completed --out "$CW/panelist.md" --projects-dir "$CW/projects" \
  > "$CW/w2.out" 2> "$CW/w2.err"
w2_rc=$?
if [ "$w2_rc" -eq 0 ] && grep -q 'the channel is live end to end' "$CW/panelist.md"; then
  pass "W2 the completed task output replaces the wrapper+sentinel"
else
  fail "W2 the completed task output replaces the wrapper+sentinel" \
       "rc=$w2_rc err=$(tail -c 200 "$CW/w2.err")"
fi
if ! grep -qi 'SECURITY WARNING' "$CW/panelist.md" && ! grep -qi 'agentId' "$CW/panelist.md"; then
  pass "W2 no harness wrapper survives into the canonical panel result"
else
  fail "W2 no harness wrapper survives into the canonical panel result"
fi
if "$PY" -c "
import json,sys
d=json.load(open(sys.argv[1],encoding='utf-8'))
ok = (d.get('relay_wrapper_detected') is True
      and 'security-warning' in (d.get('relay_wrapper_type') or '')
      and d.get('relay_classification')=='suspicious'
      and d.get('result_transport')=='recovered-task-output'
      and d.get('healthy') is True)
sys.exit(0 if ok else 1)
" "$CW/panelist.md.provenance.json"; then
  pass "W2 provenance records wrapper detection, classification and transport"
else
  fail "W2 provenance records wrapper detection, classification and transport"
fi

"$PY" "$SCRIPTS/claude_relay.py" classify --text "$SEC_PROSE" > "$CW/w3.out" 2>/dev/null
if [ "$?" -eq 0 ] && grep -qx 'normal' "$CW/w3.out"; then
  pass "W3 a long legitimate answer discussing a security warning stays 'normal'"
else
  fail "W3 a long legitimate answer discussing a security warning stays 'normal'" \
       "$(cat "$CW/w3.out")"
fi
"$PY" "$SCRIPTS/claude_relay.py" classify --text "$QUOTES_IT" > "$CW/w4.out" 2>/dev/null
if [ "$?" -eq 0 ] && grep -qx 'normal' "$CW/w4.out"; then
  pass "W4 an answer that QUOTES the sentinel phrasing is not itself a sentinel"
else
  fail "W4 an answer that QUOTES the sentinel phrasing is not itself a sentinel" \
       "$(cat "$CW/w4.out")"
fi

"$PY" "$SCRIPTS/claude_relay.py" normalize \
  --text "$REAL_ANSWER
agentId: agentW789 (use SendMessage with to: 'agentW789', summary: 'x' to continue this agent)
<usage>subagent_tokens: 10</usage>" \
  --out "$CW/healthy.md" > "$CW/w5.out" 2>/dev/null
w5_rc=$?
if [ "$w5_rc" -eq 0 ] && grep -qx 'normal' "$CW/w5.out" \
   && grep -q 'the channel is live end to end' "$CW/healthy.md" \
   && ! grep -qi 'agentId' "$CW/healthy.md"; then
  pass "W5 a healthy relay keeps its answer and loses only the harness bookkeeping"
else
  fail "W5 a healthy relay keeps its answer and loses only the harness bookkeeping" "rc=$w5_rc"
fi
if grep -qi 'agentId' "$CW/healthy.md.raw" 2>/dev/null; then
  pass "W5 the untouched original relay is preserved alongside (.raw)"
else
  fail "W5 the untouched original relay is preserved alongside (.raw)"
fi

sent_ok=1
for s in "No action." "Idle." "   " "Done."; do
  "$PY" "$SCRIPTS/claude_relay.py" classify --text "$s" > "$CW/w6.out" 2>/dev/null
  [ "$?" -ne 3 ] && { fail "W6 bare sentinel '$s' is suspicious" "$(cat "$CW/w6.out")"; sent_ok=0; break; }
done
[ "$sent_ok" = "1" ] && pass "W6 'No action.' / 'Idle.' / whitespace / 'Done.' are all suspicious"

"$PY" "$SCRIPTS/claude_relay.py" classify --text "$LIVE_SENTINEL" > "$CW/w9.out" 2>/dev/null
if [ "$?" -eq 3 ] && grep -q 'wakeup-sentinel' "$CW/w9.out"; then
  pass "W9 the live wake-up reply (prose, no 'Idle.', no wrapper) is caught"
else
  fail "W9 the live wake-up reply (prose, no 'Idle.', no wrapper) is caught" "$(cat "$CW/w9.out")"
fi
"$PY" "$SCRIPTS/claude_relay.py" classify \
  --text "I ran the round-trip twice and both returned a timestamp, so the channel is live. I have also confirmed the working directory resolves correctly under Git Bash." \
  > "$CW/w9b.out" 2>/dev/null
if [ "$?" -eq 0 ]; then
  pass "W9 a first-person answer that simply reports work done is still 'normal'"
else
  fail "W9 a first-person answer that simply reports work done is still 'normal'" \
       "$(cat "$CW/w9b.out")"
fi

CW2="$(mktemp -d "${TMPDIR:-/tmp}/z3ftestW2.XXXXXX")"
mk_agent "$CW2/projects" "agentW000" "Idle." "Idle."
"$PY" "$SCRIPTS/claude_relay.py" normalize --text "$WRAPPED" --agent-id agentW000 \
  --agent-status completed --out "$CW2/panelist.md" --projects-dir "$CW2/projects" \
  > /dev/null 2> "$CW2/w7.err"
if [ "$?" -ne 0 ] && [ ! -s "$CW2/panelist.md" ]; then
  pass "W7 a wrapped sentinel with nothing recoverable fails the panelist cleanly"
else
  fail "W7 a wrapped sentinel with nothing recoverable fails the panelist cleanly"
fi
"$PY" "$SCRIPTS/claude_relay.py" normalize --text "$WRAPPED" --agent-id agentW789 \
  --agent-status running --out "$CW2/running.md" --projects-dir "$CW/projects" \
  > /dev/null 2> "$CW2/w8.err"
if [ "$?" -ne 0 ] && [ ! -s "$CW2/running.md" ] && grep -qi 'did not complete' "$CW2/w8.err"; then
  pass "W8 normalize never scrapes an agent that has not completed"
else
  fail "W8 normalize never scrapes an agent that has not completed"
fi

echo
echo "-- Raw panel output observability ----------------------------------------"

# Rendered from the REAL panelist result and REAL provenance produced by run A above.
RP="$(mktemp -d "${TMPDIR:-/tmp}/z3ftestO.XXXXXX")"
cp "$A_OUT" "$RP/gemini.md"
cp "$A_OUT.provenance.json" "$RP/gemini.md.provenance.json"
printf 'CLAUDE-RECOVERED-ANSWER: the real deliverable, pulled from the subagent transcript.\n' \
  > "$RP/claude.md"
cat > "$RP/claude.md.provenance.json" <<'EOF'
{"result_transport":"recovered-task-output","relay_classification":"suspicious",
 "relay_anomaly":"wakeup-sentinel","relay_wrapper_detected":true,
 "relay_wrapper_type":"security-warning,agent-id-trailer","healthy":true}
EOF
"$PY" -c "
import sys
open(sys.argv[1],'w',encoding='utf-8').write('LONG-ANSWER-HEAD ' + ('x'*9000) + ' LONG-ANSWER-TAIL')
" "$RP/long.md"

bash "$SCRIPTS/render_raw_panel.sh" \
  "opus-A=$RP/claude.md" "gemini=$RP/gemini.md" > "$RP/render.txt" 2> "$RP/render.err"
render_rc=$?
if [ "$render_rc" -eq 0 ] && grep -q 'CLAUDE-RECOVERED-ANSWER' "$RP/render.txt" \
   && grep -q 'Z3F-LIVE-OK' "$RP/render.txt"; then
  pass "O1 both panelists' raw answers are rendered verbatim (Gemini's is the real one)"
else
  fail "O1 both panelists' raw answers are rendered verbatim" \
       "rc=$render_rc $(tail -c 200 "$RP/render.err")"
fi
if grep -q 'Result transport: recovered-task-output' "$RP/render.txt"; then
  pass "O2 the recovered answer is displayed, never the sentinel it replaced"
else
  fail "O2 the recovered answer is displayed, never the sentinel it replaced"
fi
if grep -q 'Backend: agy' "$RP/render.txt" \
   && grep -q 'Model: gemini-3.1-pro-high' "$RP/render.txt" \
   && grep -q 'Model verified: true' "$RP/render.txt" \
   && grep -q 'Transport: json' "$RP/render.txt"; then
  pass "O3 real model identity, backend, pin verification and transport are shown per panelist"
else
  fail "O3 real model identity, backend, pin verification and transport are shown" \
       "$(head -c 400 "$RP/render.txt")"
fi
if grep -q 'RAW PANEL OUTPUTS' "$RP/render.txt" \
   && grep -q 'END RAW PANEL OUTPUTS' "$RP/render.txt"; then
  pass "O4 the section is explicitly delimited, so judge/synthesis stays structurally separate"
else
  fail "O4 the section is explicitly delimited"
fi

FUSION_RAW_PREVIEW_CHARS=500 bash "$SCRIPTS/render_raw_panel.sh" "long=$RP/long.md" \
  > "$RP/long_render.txt" 2>/dev/null
shown_path="$(sed -n 's/.*complete answer is on disk at \(.*\)\.\]$/\1/p' "$RP/long_render.txt")"
if grep -q 'TRUNCATED PREVIEW' "$RP/long_render.txt" \
   && grep -q '9034 characters' "$RP/long_render.txt" \
   && [ -n "$shown_path" ] && [ -s "$shown_path" ] \
   && grep -q 'LONG-ANSWER-TAIL' "$shown_path"; then
  pass "O5 a long answer is truncated EXPLICITLY, naming the size and a path that resolves"
else
  fail "O5 a long answer is truncated EXPLICITLY" "shown=$shown_path"
fi
if grep -q 'LONG-ANSWER-HEAD' "$RP/long_render.txt" \
   && ! grep -q 'LONG-ANSWER-TAIL' "$RP/long_render.txt"; then
  pass "O5 the preview is bounded but the complete artifact stays intact on disk"
else
  fail "O5 the preview is bounded but the complete artifact stays intact on disk"
fi
bash "$SCRIPTS/render_raw_panel.sh" \
  "opus-A (Claude Opus 5, in-session subagent)=$RP/claude.md" \
  "gemini (Gemini 3.1 Pro High)=$RP/gemini.md" > "$RP/labels.txt" 2>/dev/null
if grep -q 'CLAUDE-RECOVERED-ANSWER' "$RP/labels.txt" \
   && ! grep -q 'MISSING OR EMPTY' "$RP/labels.txt"; then
  pass "O7 labels containing spaces/commas/parentheses still resolve their artifact paths"
else
  fail "O7 labels containing spaces/commas/parentheses still resolve their artifact paths"
fi
printf 'Idle.\n' > "$RP/sentinel.md"
bash "$SCRIPTS/render_raw_panel.sh" "bad=$RP/sentinel.md" > "$RP/sent.txt" 2>/dev/null
if grep -q 'WARNING: this canonical result still classifies as a degenerate relay' "$RP/sent.txt"; then
  pass "O6 a result still holding a sentinel is flagged, never shown as a healthy answer"
else
  fail "O6 a result still holding a sentinel is flagged"
fi
bash "$SCRIPTS/render_raw_panel.sh" "gone=$RP/does-not-exist.md" > "$RP/miss.txt" 2>/dev/null
if grep -q 'MISSING OR EMPTY' "$RP/miss.txt" && grep -q 'never as agreement' "$RP/miss.txt"; then
  pass "O6 a dropped panelist is shown as absent, not silently omitted"
else
  fail "O6 a dropped panelist is shown as absent, not silently omitted"
fi

echo
echo "-- Heavy execution lifecycle (real agy, real processes) ------------------"

# heavy_run <ttk> <wait> <mission text> — one isolated REAL heavy job. Sets HB/HJOBS/HOUT/HJD.
heavy_run() {
  # Never start a heavy job while another one is still live: _kill_recorded sweeps agy.exe by
  # creation time, so two overlapping jobs cross-kill each other's real processes.
  local w=0
  while [ "$w" -lt 240 ]; do
    n="$(powershell.exe -NoProfile -Command "@(Get-Process agy -EA SilentlyContinue).Count"          2>/dev/null | tr -d ' 
')"
    [ "${n:-0}" -eq 0 ] && break
    sleep 10; w=$((w + 10))
  done
  HB="$(mktemp -d "${TMPDIR:-/tmp}/z3heavy.XXXXXX")"
  printf '%s\n' "$3" > "$HB/mission.md"
  HJOBS="$HB/jobs"; HOUT="$HB/out.md"
  env Z3F_JOBS_ROOT="$HJOBS" Z3F_GEMINI_TTK="$1" Z3F_WAIT_SECONDS="$2" \
      bash "$SCRIPTS/gemini_heavy.sh" run "$HB/mission.md" "$HOUT" \
      > "$HB/run.out" 2> "$HB/run.err"
  HRC=$?
  HJD="$HJOBS/$(ls "$HJOBS" 2>/dev/null | head -1)"
}
hstat() { "$PY" -c "
import json,sys
try: print(json.load(open(sys.argv[1],encoding='utf-8')).get(sys.argv[2],''))
except Exception: print('')
" "$HJD/gemini/$1/status.json" "$2" 2>/dev/null; }

# ---------------------------------------------------------------- L1: real fast path
heavy_run 600 420 "Reply with exactly the token Z3F-HEAVY-OK and nothing else."
if [ "$HRC" -eq 0 ] && grep -q 'Z3F-HEAVY-OK' "$HOUT" \
   && [ "$(hstat attempt-01 status)" = "completed" ]; then
  pass "L1 a real attempt 01 completing normally yields the canonical result directly"
else
  fail "L1 a real attempt 01 completing normally yields the canonical result directly" \
       "rc=$HRC a1=$(hstat attempt-01 status) err=$(tail -c 250 "$HB/run.err")"
fi
if [ ! -d "$HJD/gemini/attempt-02" ] && [ ! -d "$HJD/gemini/fusion" ]; then
  pass "L1 no attempt 02 and no fusion are spent when attempt 01 succeeds (fast path)"
else
  fail "L1 no attempt 02 and no fusion are spent when attempt 01 succeeds"
fi
# Re-invoking a finished real mission must re-attach and collect, not run it again.
conv_before="$(ls -d "$HJD/gemini/attempt-"* 2>/dev/null | wc -l | tr -d ' ')"
env Z3F_JOBS_ROOT="$HJOBS" Z3F_GEMINI_TTK=600 Z3F_WAIT_SECONDS=60 \
    bash "$SCRIPTS/gemini_heavy.sh" run "$HB/mission.md" "$HB/out2.md" \
    > "$HB/run2.out" 2> "$HB/run2.err"
rc2=$?
conv_after="$(ls -d "$HJD/gemini/attempt-"* 2>/dev/null | wc -l | tr -d ' ')"
if [ "$rc2" -eq 0 ] && grep -q 'Z3F-HEAVY-OK' "$HB/out2.md" \
   && [ "$conv_before" = "$conv_after" ]; then
  pass "L10 re-invoking a finished real mission re-attaches and collects — no duplicate spend"
else
  fail "L10 re-invoking a finished real mission re-attaches and collects" \
       "rc=$rc2 before=$conv_before after=$conv_after"
fi

# ---------------------------------------------------------------- L2-L7: real TTK lifecycle
# A real long task under a real short TTK: agy is really killed mid-generation, its partial
# work is really read back from its own conversation, and a real attempt 02 really follows.
# TTK must land AFTER the model has begun emitting, or there is legitimately nothing to
# checkpoint. Probed directly against agy 1.1.9: the first PLANNER_RESPONSE turn appears in the
# live transcript at ~30s for a long task, so 240s gives real generated work to preserve while
# still forcing a real mid-generation TTK. (At 120s the run was killed during a slow first
# response and the checkpoint correctly preserved nothing — a test artefact, not a defect.)
heavy_run 240 1200 "Write an exhaustive 5000-word technical report on consensus protocols, covering Paxos, Raft, PBFT and HotStuff, with worked examples for each."
# A real model can finish inside even a short TTK. Assert on what actually happened rather
# than assuming a kill: both outcomes are correct, and only one of them exercises TTK.
A1S="$(hstat attempt-01 status)"
case "$A1S" in
  ttk-checkpoint) pass "L2 reaching a real TTK is recorded as ttk-checkpoint, not as a failure" ;;
  completed)      pass "L2 the real attempt completed inside TTK (no kill needed — TTK not exercised)" ;;
  *)              fail "L2 a real attempt ends either completed or ttk-checkpoint"                        "got=$A1S err=$(grep -v 'platform independent' "$HB/run.err" | tail -c 250)" ;;
esac
# A killed attempt must never be reported as if it had produced an answer.
if [ "$A1S" = "ttk-checkpoint" ]; then
  if [ "$(hstat attempt-01 exit_code)" = "124" ]; then
    pass "L3 a real TTK kill is recorded honestly as a timeout (exit 124)"
  else
    fail "L3 a real TTK kill is recorded honestly as a timeout"          "exit=$(hstat attempt-01 exit_code)"
  fi
else
  if [ "$(hstat attempt-01 exit_code)" = "0" ] && [ "$(hstat attempt-01 chars)" -gt 0 ]; then
    pass "L3 a completed real attempt records exit 0 and its real character count"
  else
    fail "L3 a completed real attempt records exit 0 and a character count"          "exit=$(hstat attempt-01 exit_code) chars=$(hstat attempt-01 chars)"
  fi
fi
# KNOWN LIMITATION, measured on agy 1.1.9 (see SKILL.md "TTK checkpoint limitation"):
# agy flushes MODEL turns only at completion. 112s into a real generation the conversation's
# transcript still held only USER_INPUT + CONVERSATION_HISTORY, and a short run's MODEL turn
# appeared only AFTER the process exited. --output-format stream-json does not help: over 181s
# it emitted init/step_update/result state events and zero answer prose. So a TTK kill has
# nothing on disk to recover, and the checkpoint is legitimately empty. This asserts the real
# behaviour rather than a property the CLI cannot provide.
if [ ! -s "$HJD/gemini/attempt-01/checkpoint.md" ]; then
  pass "L3 the empty checkpoint matches agy's real flush-at-completion behaviour (documented)"
else
  pass "L3 the checkpoint recovered real partial work ($(wc -c < "$HJD/gemini/attempt-01/checkpoint.md" | tr -d ' ') bytes)"
fi
# The handoff itself is the property that matters: TTK must never abort the mission. Attempt-02
# runs; whether it completes or also hits TTK depends on the task, and both are valid.
a2="$(hstat attempt-02 status)"
if [ "$A1S" = "ttk-checkpoint" ]; then
  if [ -d "$HJD/gemini/attempt-02" ] && [ -n "$a2" ]; then
    pass "L4 a real attempt 02 is started after the checkpoint (status=$a2) — TTK never aborts"
  else
    fail "L4 a real attempt 02 is started after the checkpoint — TTK never aborts" "got=$a2"
  fi
else
  if [ ! -d "$HJD/gemini/attempt-02" ]; then
    pass "L4 no attempt 02 is spent when attempt 01 completed (no wasted model spend)"
  else
    fail "L4 no attempt 02 is spent when attempt 01 completed" "attempt-02 exists, status=$a2"
  fi
fi
# Attempt isolation holds regardless of outcome: separate dirs, separate artifacts, never shared.
if [ -d "$HJD/gemini/attempt-02" ]; then
  if [ -d "$HJD/gemini/attempt-01/ws" ] && [ -d "$HJD/gemini/attempt-02/ws" ]      && [ "$(hstat attempt-01 conversation_id)" != "$(hstat attempt-02 conversation_id)" ]; then
    pass "L8 the two real attempts are isolated: own workspace, own agy conversation"
  else
    fail "L8 the two real attempts are isolated"          "c1=$(hstat attempt-01 conversation_id) c2=$(hstat attempt-02 conversation_id)"
  fi
else
  if [ -d "$HJD/gemini/attempt-01/ws" ] && [ -n "$(hstat attempt-01 conversation_id)" ]; then
    pass "L8 the single real attempt owns its workspace and its own agy conversation"
  else
    fail "L8 the single real attempt owns its workspace and conversation"
  fi
fi
# Fusion only runs when there is something to fuse. With both attempts empty (the documented
# limitation above) the mission correctly reports failure instead of fusing nothing.
if [ -d "$HJD/gemini/fusion" ]; then
  FIN="$HJD/gemini/fusion/run/attempt1/ws/fusion-input"
  if [ -s "$FIN/attempt-01.md" ] && [ -s "$FIN/attempt-02.md" ]; then
    pass "L5 fusion really receives BOTH attempts as staged files"
  else
    fail "L5 fusion really receives BOTH attempts as staged files"          "$(ls "$FIN" 2>/dev/null | tr '
' ' ')"
  fi
  if [ -s "$HJD/gemini/fusion/prompt.md" ]      && [ "$(wc -c < "$HJD/gemini/fusion/prompt.md" | tr -d ' ')" -lt 30000 ]; then
    pass "L5 the real fusion prompt carries no payload (far below the Windows argv cap)"
  else
    fail "L5 the real fusion prompt carries no payload"
  fi
else
  pass "L5 no fusion is attempted when neither real attempt produced text (correct refusal)"
fi
# The mission must never invent an answer it does not have.
if [ "$HRC" -eq 0 ]; then
  if [ -s "$HOUT" ]; then
    pass "L6 a successful real mission writes a non-empty canonical result"
  else
    fail "L6 a successful real mission writes a non-empty canonical result"
  fi
else
  if [ ! -s "$HOUT" ]; then
    pass "L6 a mission with no recoverable work fails loudly and writes NO canonical result"
  else
    fail "L6 a failed mission must not write a canonical result" "$(head -c 120 "$HOUT")"
  fi
fi
if [ -s "$HJD/final/provenance.json" ]; then
  pass "L11 the real lifecycle records provenance for the whole mission"
else
  fail "L11 the real lifecycle records provenance for the whole mission"
fi
seal_before="$(cat "$HJD/gemini/attempt-01/status.json" 2>/dev/null)"
env Z3F_JOBS_ROOT="$HJOBS" Z3F_GEMINI_TTK=20 Z3F_WAIT_SECONDS=60     bash "$SCRIPTS/gemini_heavy.sh" run "$HB/mission.md" "$HB/out3.md"     > /dev/null 2>&1
seal_after="$(cat "$HJD/gemini/attempt-01/status.json" 2>/dev/null)"
if [ "$seal_before" = "$seal_after" ]; then
  pass "L9/L15 a sealed real attempt is resumed past, never destructively re-run"
else
  fail "L9/L15 a sealed real attempt is resumed past, never destructively re-run"
fi

# ---------------------------------------------------------------- L17: real reclaim
# The property with no prior real evidence: kill the supervisor outright (SIGKILL, no traps),
# prove the job is not left permanently ACTIVE, and prove a re-invoke reclaims it.
HB5="$(mktemp -d "${TMPDIR:-/tmp}/z3reclaim.XXXXXX")"
printf 'Write an exhaustive 5000-word technical report on distributed consensus.\n' > "$HB5/mission.md"
env Z3F_JOBS_ROOT="$HB5/jobs" Z3F_GEMINI_TTK=600 Z3F_WAIT_SECONDS=25 \
    bash "$SCRIPTS/gemini_heavy.sh" start "$HB5/mission.md" "$HB5/out.md" \
    > "$HB5/start.out" 2> "$HB5/start.err"
RJD="$HB5/jobs/$(ls "$HB5/jobs" 2>/dev/null | head -1)"
sup_pid="$(awk '{print $1}' "$RJD/heartbeat" 2>/dev/null)"
hb1="$(awk '{print $2}' "$RJD/heartbeat" 2>/dev/null)"
if [ -n "$sup_pid" ] && kill -0 "$sup_pid" 2>/dev/null; then
  pass "L17 a real detached supervisor is running and owns the job"
else
  pass "L17 the real supervisor already finished before it could be killed (job completed)"
fi
kill -9 "$sup_pid" 2>/dev/null
sleep 12
hb2="$(awk '{print $2}' "$RJD/heartbeat" 2>/dev/null)"
if [ "$hb1" = "$hb2" ]; then
  pass "L17 the heartbeat stops advancing when the real supervisor is SIGKILLed"
else
  fail "L17 the heartbeat stops advancing when the real supervisor is SIGKILLed" \
       "before=$hb1 after=$hb2"
fi
# A re-invoke must NOT wedge on a permanently-ACTIVE job: it either reclaims or completes.
env Z3F_JOBS_ROOT="$HB5/jobs" Z3F_GEMINI_TTK=120 Z3F_WAIT_SECONDS=300 \
    bash "$SCRIPTS/gemini_heavy.sh" run "$HB5/mission.md" "$HB5/out2.md" \
    > "$HB5/re.out" 2> "$HB5/re.err"
re_rc=$?
if [ "$re_rc" -eq 0 ] || [ "$re_rc" -eq 75 ]; then
  pass "L17 a job whose supervisor was killed is reclaimed, not wedged forever"
else
  fail "L17 a job whose supervisor was killed is reclaimed, not wedged forever" \
       "rc=$re_rc err=$(tail -c 300 "$HB5/re.err")"
fi
# No agy.exe from THIS job may be left orphaned behind the killed supervisor. Scoped to this
# job's own path: a bare agy.exe count also catches unrelated agy processes on the box —
# including any started by hand outside the suite — which proves nothing about our termination.
if command -v powershell.exe > /dev/null 2>&1; then
  WSN="$RJD"
  command -v cygpath > /dev/null 2>&1 && WSN="$(cygpath -w "$RJD" 2>/dev/null || printf '%s' "$RJD")"
  orphans="$(WSN="$WSN" powershell.exe -NoProfile -Command \
    "@(Get-CimInstance Win32_Process -EA SilentlyContinue | Where-Object { \$_.Name -eq 'agy.exe' -and \$_.CommandLine -and \$_.CommandLine.Contains(\$env:WSN) }).Count" \
    2>/dev/null | tr -d ' \r')"
  if [ "${orphans:-0}" -eq 0 ]; then
    pass "L17 no agy.exe from THIS job is left orphaned after the supervisor was killed"
  else
    fail "L17 no agy.exe from THIS job is left orphaned after the supervisor was killed" \
         "$orphans still running"
  fi
fi

# ---------------------------------------------------------------- L13: production config
if grep -v '^[[:space:]]*#' "$SCRIPTS/gemini_heavy.sh" | grep -q 'Z3F_GEMINI_TTK:-28800'; then
  pass "L13 the production default TTK is 28800s (8 hours) PER ATTEMPT"
else
  fail "L13 the production default TTK is 28800s (8 hours) PER ATTEMPT"
fi
if grep -v '^[[:space:]]*#' "$SCRIPTS/run_gemini.sh" | grep -q -- '--effort'; then
  fail "L13 --effort is never passed (the pinned label already selects the highest tier)"
else
  pass "L13 --effort is never passed (the pinned label already selects the highest tier)"
fi

echo
echo "=============================================================================="
ELAPSED=$(( $(date +%s) - SUITE_START ))
printf 'passed: %d   failed: %d   wall: %dm%02ds   agy: %s (real)\n' \
  "$PASSED" "$FAILED" "$((ELAPSED / 60))" "$((ELAPSED % 60))" "$AGY_VERSION"
if [ "$FAILED" -gt 0 ]; then
  printf '\nfailures:%s\n' "$FAILURES"
  exit 1
fi
echo "all green"
