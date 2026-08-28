#!/usr/bin/env bash
# gemini_heavy.sh — heavy/long-running Gemini execution lifecycle for z3Fusion.
#
#   gemini_heavy.sh run     <prompt_file> <output_file>   synchronous facade (start|re-attach|collect)
#   gemini_heavy.sh start   <prompt_file> <output_file>   launch detached, print the job id, return
#   gemini_heavy.sh status  [job_id]                      print a job's state.json (or list jobs)
#   gemini_heavy.sh collect <job_id> <output_file>        copy the canonical result to a caller path
#
# ---------------------------------------------------------------------------------------
# WHY THIS EXISTS
# ---------------------------------------------------------------------------------------
# A heavy Gemini mission — repository-wide analysis, frontend implementation, iterative
# coding/testing/debugging — legitimately runs for hours. Two things break under that load:
#
#   1. A long run is not a failed run. Hitting the time-to-kill boundary must be a CHECKPOINT
#      + HANDOFF, not delete-and-restart. Work already produced has to survive.
#   2. The caller cannot hold the process. Claude's Bash tool caps a foreground call at ~10
#      minutes; agy children outlive it. Previously the caller stopped waiting, the original
#      agy kept running, a second agy was launched, and both eventually wrote the SAME result
#      path. Attempt isolation plus job re-attach removes that failure mode by construction.
#
# ---------------------------------------------------------------------------------------
# LIFECYCLE
# ---------------------------------------------------------------------------------------
#   ATTEMPT-01 (up to TTK)
#      |-- completes ................ canonical = attempt-01, DONE. No attempt-02, no fusion.
#      |-- reaches TTK .............. capture checkpoint, seal, continue to ATTEMPT-02
#      `-- deterministic failure .... abort. A pin mismatch / auth rejection / stale transcript
#                                     cannot be fixed by burning another 8 hours.
#   ATTEMPT-02 (up to TTK, FRESH context, same mission)
#   FUSION      compares both attempts + real repository evidence -> canonical result
#
# Attempt-02 is deliberately a fresh Gemini execution rather than `agy --continue`: two
# independent reasoning paths over the same mission are worth more than one path resumed, and
# it matches z3Fusion's own independence-then-synthesis thesis. The attempts DO share whatever
# project state attempt-01 left on disk — that is expected and is evidence, not leakage.
# Attempt-02 never sees attempt-01's TEXT before producing its own; only fusion sees both.
#
# ---------------------------------------------------------------------------------------
# WHAT THIS SCRIPT DOES NOT REIMPLEMENT
# ---------------------------------------------------------------------------------------
# Every agy invocation — both attempts and the fusion pass — goes through run_gemini.sh. The
# model pin, the post-run routing verification, the karpathy-engineering-v1 governance
# injection, the layered json/text/transcript transport and the per-invocation provenance are
# therefore inherited unchanged, not duplicated. This script owns the LIFECYCLE only.
#
# ---------------------------------------------------------------------------------------
# REASONING EFFORT (verified against agy 1.1.8 on this machine)
# ---------------------------------------------------------------------------------------
# The highest supported reasoning effort for this model is expressed BY THE MODEL LABEL, not by
# `--effort`. Probed directly:
#   --model "Gemini 3.1 Pro (High)" --effort high
#       -> ERROR: --effort is not supported for model "Gemini 3.1 Pro (High)"
#   --model gemini-3.1-pro --effort high
#       -> exit 0, SUCCESS, and silently routed to "Gemini 3.6 Flash (High)"
# So `--effort` is the mechanism for labels that do NOT encode a tier; adding it here would
# either hard-fail the run or downgrade it to Flash. The existing pin already selects the
# highest tier. Provenance records reasoning_effort=high with that resolution noted.
#
# Config (env):
#   Z3F_GEMINI_TTK          seconds per attempt. DEFAULT 28800 (8 hours).
#   Z3F_GEMINI_TTK_GRACE    external backstop grace over TTK, seconds (default 300).
#   Z3F_GEMINI_MAX_ATTEMPTS default 2. Clamped 1..3.
#   Z3F_GEMINI_FUSION       1 (default) = run the fusion pass when 2 attempts produced output.
#   Z3F_GEMINI_PROJECT_DIR  repo whose git state is captured as fusion evidence (optional).
#   Z3F_JOBS_ROOT           default ~/.claude/z3fusion-runs/jobs
#   Z3F_WAIT_SECONDS        how long `run` waits before returning 75 (default 540).
#   Z3F_JOB_SUFFIX          disambiguates two jobs with an identical mission prompt.
#
# Exit codes for `run`/`collect`:
#   0 canonical result written | 75 still running, re-invoke to re-attach (NOT a failure)
#   1 failed | 124 every attempt hit TTK with nothing usable | 127 agy missing | 2 bad usage

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/_fusion_lib.sh"

# Runner-neutral spellings (Z3F_HEAVY_*) are accepted as aliases so a caller can set one
# attempt/TTK policy for a mission without hardcoding which runner serves it. The
# runner-specific Z3F_GEMINI_* spelling still WINS where both are set — it is the more
# specific instruction. This is naming only: the lifecycle below stays agy-only, because its
# termination proof enumerates `agy.exe` by name (see _snapshot_agy / _kill_recorded) and that
# proof is what makes the attempt-02 handoff safe.
# Fold the alias in FIRST, as a separate step, so each default below stays a single literal
# assignment. tests/run_tests.sh L13 asserts the production default by grepping for the exact
# string `Z3F_GEMINI_TTK:-28800`; nesting the alias inside that expansion would silently defeat
# the assertion that pins the 8-hour default, which is precisely the value most worth pinning.
: "${Z3F_GEMINI_TTK:=${Z3F_HEAVY_TTK:-}}"
: "${Z3F_GEMINI_TTK_GRACE:=${Z3F_HEAVY_TTK_GRACE:-}}"
: "${Z3F_GEMINI_MAX_ATTEMPTS:=${Z3F_HEAVY_MAX_ATTEMPTS:-}}"

TTK="${Z3F_GEMINI_TTK:-28800}"
TTK_GRACE="${Z3F_GEMINI_TTK_GRACE:-300}"
MAX_ATTEMPTS="${Z3F_GEMINI_MAX_ATTEMPTS:-2}"
case "$MAX_ATTEMPTS" in 1|2|3) ;; *) MAX_ATTEMPTS=2 ;; esac
DO_FUSION="${Z3F_GEMINI_FUSION:-1}"
JOBS_ROOT="${Z3F_JOBS_ROOT:-$HOME/.claude/z3fusion-runs/jobs}"
WAIT_SECONDS="${Z3F_WAIT_SECONDS:-540}"
HEARTBEAT_INTERVAL=15
HEARTBEAT_STALE=$((HEARTBEAT_INTERVAL * 3))

# _sha12 <file> — stable job identity from the mission prompt, so re-invoking with the same
# mission RE-ATTACHES instead of launching a duplicate execution.
_sha12() {
  "$FUSION_PY" - "$1" <<'PYEOF'
import hashlib, sys
h = hashlib.sha1(open(sys.argv[1], "rb").read()).hexdigest()
sys.stdout.write(h[:12])
PYEOF
}

_now() { date +%s; }
_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# _write_once <dest> — write stdin to <dest>, but REFUSE if <dest> already exists. This is the
# no-clobber primitive: a late attempt-01 that finally finishes cannot overwrite a sealed
# artifact, attempt-02's work, the fusion result, or the canonical output.
_write_once() {
  local dest="$1" tmp="$1.tmp.$$"
  cat > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  if [ -e "$dest" ]; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$dest" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# _json_get <file> <key> — read one top-level key out of a provenance/state document.
_json_get() {
  "$FUSION_PY" - "$1" "$2" <<'PYEOF' 2>/dev/null
import json, sys
try:
    v = json.load(open(sys.argv[1], encoding="utf-8-sig")).get(sys.argv[2])
except Exception:
    v = None
sys.stdout.write("" if v is None else str(v))
PYEOF
}

# _json_get2 <file> <key> <subkey> — the lifecycle record nests under "gemini_execution".
_json_get2() {
  "$FUSION_PY" - "$1" "$2" "$3" <<'PYEOF' 2>/dev/null
import json, sys
try:
    v = (json.load(open(sys.argv[1], encoding="utf-8-sig")).get(sys.argv[2]) or {}).get(sys.argv[3])
except Exception:
    v = None
sys.stdout.write("" if v is None else str(v))
PYEOF
}

_set_state() {
  STATE="$1" JOB="$job_dir" TTKV="$TTK" \
  "$FUSION_PY" - <<'PYEOF' 2>/dev/null
import json, os, time
p = os.path.join(os.environ["JOB"], "state.json")
try:
    doc = json.load(open(p, encoding="utf-8"))
except Exception:
    doc = {}
doc["state"] = os.environ["STATE"]
doc["ttk_seconds"] = int(os.environ["TTKV"])
doc["updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
tmp = p + ".tmp"
json.dump(doc, open(tmp, "w", encoding="utf-8"), indent=2)
os.replace(tmp, p)
PYEOF
}

# _liveness <job_dir> — prints ACTIVE | DEAD | STALE | UNKNOWN.
#
# A heartbeat file alone answers "was some file touched recently", not "is the owner of this
# mission still alive" — and those two diverge in BOTH dangerous directions: an orphaned ticker
# keeps a dead mission looking alive forever, and a failed timestamp lookup makes a live
# 8-hour mission look dead and get duplicated. So liveness correlates three signals: the owner
# pid recorded IN the heartbeat, whether that pid is actually alive, and how far the heartbeat
# has fallen behind.
#
# The timestamp is read from the file CONTENT, not from mtime: the previous `date -r` version
# failed open (a failing lookup yielded `age = now - 0`, i.e. "dead"), which is exactly the
# wrong direction for an 8-hour job.
#
# Anything ambiguous resolves to UNKNOWN and never to a confident answer, because a wrong DEAD
# duplicates the mission and a wrong ACTIVE wedges it permanently.
_liveness() {
  local hb="$1/heartbeat" owner ts now age
  [ -s "$hb" ] || { printf 'DEAD'; return; }
  owner="$(awk '{print $1}' "$hb" 2>/dev/null)"
  ts="$(awk '{print $2}' "$hb" 2>/dev/null)"
  case "$owner" in ''|*[!0-9]*) printf 'UNKNOWN'; return ;; esac
  case "$ts"    in ''|*[!0-9]*) printf 'UNKNOWN'; return ;; esac
  now="$(_now)"
  case "$now" in ''|*[!0-9]*) printf 'UNKNOWN'; return ;; esac
  age=$(( now - ts ))

  if kill -0 "$owner" 2>/dev/null; then
    # Pid alive AND the heartbeat is advancing => genuinely ours and running.
    [ "$age" -le "$HEARTBEAT_STALE" ] && { printf 'ACTIVE'; return; }
    # Pid alive but the heartbeat has FROZEN. Our ticker advances it every
    # HEARTBEAT_INTERVAL for as long as the owner lives, so a live pid attached to a dead
    # heartbeat is not our supervisor: either the pid was recycled by an unrelated process or
    # the ticker is wedged. Treating "pid alive" alone as ACTIVE created a permanent trap —
    # ACTIVE re-attaches, UNKNOWN refuses, only DEAD reclaims, so the mission returned 75
    # forever with no way out. STALE is that way out, and it needs a much longer grace than a
    # missed beat so a merely slow host is never reclaimed out from under a live run.
    if [ "$age" -gt $(( HEARTBEAT_STALE * 10 )) ]; then printf 'STALE'; return; fi
    printf 'UNKNOWN'; return
  fi

  # Owner gone AND the heartbeat stopped advancing => genuinely dead, safe to reclaim.
  if [ "$age" -gt "$HEARTBEAT_STALE" ]; then printf 'DEAD'; else printf 'UNKNOWN'; fi
}

# ======================================================================================
# ONE ATTEMPT
# ======================================================================================
# Runs run_gemini.sh with AGY_MAX_ATTEMPTS=1 (this script owns the attempt loop) against a
# PERSISTENT artifact dir, so the agy log and workspace survive for checkpoint recovery.
# Writes <adir>/status.json exactly once — that seal is what makes the attempt immutable.
_run_attempt() {
  local n="$1" adir="$2"
  mkdir -p "$adir"

  # RECLAIM SAFETY. If this attempt is already sealed, a previous supervisor finished it and
  # died later (reboot, sleep, killed shell). Re-running it would be destructive, not
  # idempotent: run_gemini.sh truncates its output_file on entry, so the checkpoint that
  # supervisor recovered would be erased before the new agy even starts — and the new seal
  # would then be refused, leaving provenance describing the OLD run. Resume past it instead.
  if [ -f "$adir/status.json" ]; then
    echo "[gemini_heavy] attempt $n already sealed — resuming past it, not re-running." >&2
    printf '%s' "$(_json_get "$adir/status.json" status)"
    return 0
  fi

  # Not sealed but the workspace already exists => a previous supervisor died PART WAY through
  # this attempt. run_gemini.sh's stale-transcript safety rests on each attempt getting a fresh
  # workspace, because agy keys a conversation to its workspace directory; reusing the dead
  # run's workspace would undermine that correlation. Move the remains aside instead of running
  # on top of them — the evidence is kept, the new execution starts clean.
  if [ -d "$adir/attempt1" ]; then
    mv "$adir/attempt1" "$adir/stale-exec-$(_now)" 2>/dev/null \
      && echo "[gemini_heavy] attempt $n had remains from an interrupted execution — set aside, starting clean." >&2
  fi
  local started ended rc status
  started="$(_now)"
  printf '%s' "$started" > "$adir/started_at.epoch"
  # Record the native agy identity concurrently with the (blocking) attempt, so termination can
  # later be proven against a concrete (pid, creation-time) pair rather than a command-line
  # match that can silently evaluate to "nothing here".
  _snapshot_agy "$adir" "$started"

  Z3F_ARTIFACT_DIR="$adir" \
  FUSION_TIMEOUT="$TTK" \
  AGY_MAX_ATTEMPTS=1 \
  Z3F_GEMINI_HEAVY=0 \
  bash "$SCRIPT_DIR/run_gemini.sh" "$job_dir/mission.md" "$adir/output.md" \
    > "$adir/runner.out" 2> "$adir/runner.err"
  rc=$?
  ended="$(_now)"

  # run_gemini.sh's own classifier already separates a transient timeout from a deterministic
  # failure; reuse that verdict instead of re-deriving it here.
  local inner_status
  inner_status="$(_json_get "$adir/output.md.provenance.json" attempt_1_status)"

  if [ "$rc" -eq 0 ]; then
    status="completed"
  elif [ "$rc" -eq 124 ] || [ "$inner_status" = "timeout" ]; then
    # A TTK — or a transient failure, which run_gemini.sh reports the same way — is a HANDOFF
    # BOUNDARY, and it stays one even when nothing could be recovered. Downgrading it to
    # "failed" because the transcript scraper came back empty would turn "checkpoint and hand
    # off" into "abort", losing attempt-02 on top of the lost work: the recovery miss and the
    # abort would compound instead of the second attempt covering for the first.
    status="ttk-checkpoint"
    # Confirm the process tree is dead BEFORE capturing evidence or handing off. A surviving
    # attempt-01 would keep editing the working tree that attempt-02 is about to use, and the
    # repository evidence fusion treats as authoritative would then describe BOTH attempts at
    # once — silently destroying attempt independence.
    if ! _kill_tree "$adir"; then
      status="terminate-unconfirmed"
    fi
    _capture_checkpoint "$adir" "$started"
    # Routing is ENFORCED here, not merely recorded. Partial work produced by a different model
    # must never reach fusion as this model's output — the checkpoint path has to hold the same
    # guarantee run_gemini.sh holds on the completed path.
    if [ "$(cat "$adir/pin_ok.txt" 2>/dev/null)" = "mismatch" ]; then
      echo "[gemini_heavy] attempt $n routed to \"$(cat "$adir/routed_label.txt" 2>/dev/null)\" — discarding its checkpoint rather than fusing another model's work." >&2
      status="failed"
      : > "$adir/output.md"
    fi
  elif [ "$rc" -eq 127 ]; then
    status="unavailable"
  else
    status="failed"
  fi

  STATUS="$status" RC="$rc" A="$adir" N="$n" S="$started" E="$ended" \
  CONV="$(_json_get "$adir/output.md.provenance.json" conversation_id)" \
  TRANSPORT="$(_json_get "$adir/output.md.provenance.json" output_transport)" \
  PIN="$(cat "$adir/pin_verified.txt" 2>/dev/null || _json_get "$adir/output.md.provenance.json" model_pin_verified)" \
  ROUTED="$(cat "$adir/routed_label.txt" 2>/dev/null || _json_get "$adir/output.md.provenance.json" routed_model_label)" \
  "$FUSION_PY" - <<'PYEOF' > "$adir/status.json.candidate"
import json, os, time
s, e = int(os.environ["S"]), int(os.environ["E"])
def iso(t): return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))
out = os.path.join(os.environ["A"], "output.md")
doc = {
    "attempt": int(os.environ["N"]),
    "status": os.environ["STATUS"],
    "exit_code": int(os.environ["RC"]),
    "started_at": iso(s), "ended_at": iso(e), "runtime_seconds": e - s,
    "conversation_id": os.environ["CONV"] or None,
    "output_transport": os.environ["TRANSPORT"] or None,
    "model_pin_verified": os.environ["PIN"].strip().lower() == "true",
    "routed_model_label": os.environ["ROUTED"] or None,
    "artifact": out,
    "chars": (os.path.getsize(out) if os.path.exists(out) else 0),
}
print(json.dumps(doc, indent=2))
PYEOF
  # Seal. If status.json already exists this attempt was already finalized — a late writer is
  # refused here rather than being allowed to rewrite history.
  _write_once "$adir/status.json" < "$adir/status.json.candidate"
  rm -f "$adir/status.json.candidate"
  printf '%s' "$status"
}

# _capture_checkpoint <adir> <started_epoch> — TTK is a checkpoint boundary, not a delete.
# run_gemini.sh truncates output.md when it fails, so the answer is rebuilt here from agy's own
# on-disk transcript for THAT attempt's conversation. The transcript accumulates model turns
# DURING the run (verified live: 5 completed PLANNER_RESPONSE turns while agy was still
# executing), so a run killed at 8 hours still yields everything it had finished saying.
_capture_checkpoint() {
  local adir="$1" started="$2"
  local ws="$adir/attempt1/ws" conv
  conv="$(_json_get "$adir/output.md.provenance.json" conversation_id)"

  # Clear the routing verdicts FIRST, before any early return. These files must never be
  # sticky: leaving a previous execution's "verified" answer in place would let a reclaimed
  # attempt vouch for routing this execution never proved. The workspace-missing path is
  # exactly when a stale verdict is most likely to survive, so it has to be cleared before the
  # guard rather than after it.
  rm -f "$adir/routed_label.txt" "$adir/pin_verified.txt" "$adir/pin_ok.txt"

  [ -d "$ws" ] || return 0

  local native="$ws"
  have cygpath && native="$(cygpath -w "$ws" 2>/dev/null || printf '%s' "$ws")"
  local args=( --workspace "$native" --since "$started" )
  [ -n "$conv" ] && args+=( --conversation-id "$conv" )

  "$FUSION_PY" "$SCRIPT_DIR/agy_transcript.py" "${args[@]}" \
    > "$adir/checkpoint.md" 2> "$adir/checkpoint.err"

  # A timed-out attempt never reaches run_gemini.sh's post-run routing check, so a checkpoint
  # would otherwise carry work whose model was never verified. The agy log for that attempt is
  # preserved here, so the same guarantee is recoverable after the fact: read the routed label
  # back and compare it to the label the runner pinned. Partial work still has to prove which
  # model produced it.
  local lg routed=""
  for lg in "$adir"/attempt1/agy.*.log; do
    [ -s "$lg" ] || continue
    routed="$(grep -o 'Propagating selected model override to backend: label="[^"]*"' "$lg" 2>/dev/null \
              | sed 's/.*label="//; s/"$//' | sort -u | paste -sd'|' -)"
    [ -n "$routed" ] && break
  done
  if [ -n "$routed" ]; then
    printf '%s' "$routed" > "$adir/routed_label.txt"
    local expected
    expected="$(_json_get "$adir/output.md.provenance.json" agy_model_arg)"
    # THREE states, matching run_gemini.sh's _verify_routing (0 verified / 1 mismatch /
    # 2 unverifiable). Collapsing "unverifiable" into "mismatch" was destructive: when the
    # expected label could not be read back — missing or unreadable provenance — a checkpoint
    # with a perfectly correct routed label was discarded and its output truncated. Absence of
    # evidence is not evidence of a wrong model.
    if [ -z "$expected" ]; then
      printf 'unverifiable' > "$adir/pin_ok.txt"
    elif [ "$routed" = "$expected" ]; then
      printf 'true'  > "$adir/pin_verified.txt"; printf 'ok'       > "$adir/pin_ok.txt"
    else
      printf 'false' > "$adir/pin_verified.txt"; printf 'mismatch' > "$adir/pin_ok.txt"
    fi
  fi

  if [ -s "$adir/checkpoint.md" ]; then
    {
      echo "_[TTK CHECKPOINT — this attempt reached its ${TTK}s time-to-kill boundary. What"
      echo "follows is every model turn it completed before the boundary, recovered from agy's"
      echo "own transcript. It is partial work, preserved deliberately, not a finished answer.]_"
      echo
      cat "$adir/checkpoint.md"
    } > "$adir/output.md"
  fi
  _capture_repo_evidence "$adir"
}

# _kill_tree <adir> <started_epoch> — confirm this attempt's native process tree is dead before
# the next attempt is allowed to touch the same tree.
#
# MEASURED TOPOLOGY (this box, Git Bash + agy 1.1.8), not assumed:
#   bash --(fork)--> perl --(exec)--> agy.exe
# `_run_with_timeout` uses `exec`, so the perl child BECOMES agy.exe: the MSYS-visible pid and
# the native process are the same process, and MSYS translates TERM/KILL into TerminateProcess.
# Verified directly — `_run_with_timeout 20 agy <long prompt>` returned 124 and left zero
# agy.exe running. So the wrapper-dies-child-survives case does NOT occur for agy.exe itself.
#
# What TerminateProcess does NOT do is kill a process's OWN descendants, and agy runs tools with
# --dangerously-skip-permissions. Those grandchildren are the real exposure, and they are what
# this sweep removes.
#
# OWNERSHIP: only processes whose command line contains THIS attempt's unique workspace path are
# eligible. That path is a fresh mktemp-derived directory unique to this attempt, so a
# concurrent z3Fusion mission's agy can never match. Killing by name alone would be unsafe.
_kill_tree() {
  local adir="$1"
  # Secondary net first — may legitimately find nothing, which proves nothing either way.
  _kill_matching "$adir/attempt1/ws" "$adir/termination-bypath.json" || true
  # The actual proof: every process this attempt recorded must be confirmed gone.
  _kill_recorded "$adir" "$adir/termination.json"
}

# _sweep_job_orphans <job_dir> — kill anything still running that belongs to THIS job, whatever
# stage spawned it.
#
# This exists because of a measured fact: a real agy.exe SURVIVES its supervisor being killed
# (verified — the supervisor was SIGKILLed and agy.exe was still running with its parent gone).
# `_kill_tree` only runs at the TTK boundary, so a supervisor that died any other way left its
# agy alive with nothing to reap it. A reclaiming supervisor would then start an attempt while
# the previous run's orphan was still editing the same workspace — silently fusing two
# executions' edits and destroying attempt independence, which is the exact corruption the
# termination stage exists to prevent. Every supervisor now sweeps its own job before doing
# anything else. Matching on the job directory covers every attempt AND the fusion workspace.
_sweep_job_orphans() {
  local jd="$1" rc=0 a
  # Reap by RECORDED IDENTITY for every stage that ever launched agy under this job. An attempt
  # that was already sealed still gets swept: its process can outlive the seal.
  for a in "$jd"/gemini/attempt-0*/ "$jd"/gemini/fusion/run/; do
    [ -d "$a" ] || continue
    # No identity-file guard: _kill_recorded enumerates at kill time, so a stage whose snapshot
    # never landed is still swept rather than skipped.
    _kill_recorded "${a%/}" "${a%/}/reclaim-termination.json" || rc=1
  done
  # Best-effort net for anything the identity records missed.
  local match="$jd"
  have cygpath && match="$(cygpath -w "$jd" 2>/dev/null || printf '%s' "$jd")"
  _kill_matching_path "$match" "$jd/reclaim-sweep.json" || true
  return $rc
}

# _kill_matching <posix_path> <out_json> — convert then delegate.
_kill_matching() {
  local p="$1"
  have cygpath && p="$(cygpath -w "$1" 2>/dev/null || printf '%s' "$1")"
  [ -n "$p" ] || return 0
  _kill_matching_path "$p" "$2"
}

# _snapshot_agy <adir> <started_epoch> — record the NATIVE identity of the agy process(es) this
# attempt started, so termination can later be proven against a concrete identity.
#
# Why identity and not command-line matching: Win32_Process.CommandLine came back EMPTY for a
# live agy.exe during a real reclaim test. The sweep filtered on `$_.CommandLine -and ...`, so
# an unreadable command line silently meant "not mine" — the sweep reported `owned_found: 0`
# and `confirmed_dead: true` while the orphan was demonstrably still running. Ownership has to
# rest on something that cannot silently evaluate to "no": a recorded (pid, creation-time) pair.
# Creation time is what makes it safe against pid reuse.
#
# Runs in the background because the attempt call itself blocks.
_snapshot_agy() {
  local adir="$1" started="$2"
  ( sleep 8
    ADIR="$adir" ST="$started" AGYNAME=agy.exe powershell.exe -NoProfile -Command '
$since = (Get-Date "1970-01-01Z").ToUniversalTime().AddSeconds([double]$env:ST)
$procs = @(Get-CimInstance Win32_Process -EA SilentlyContinue |
           Where-Object { $_.Name -eq $env:AGYNAME -and $_.CreationDate -ge $since } |
           ForEach-Object { [ordered]@{ pid = $_.ProcessId; created = $_.CreationDate.ToString("o") } })
@{ recorded = $procs; count = $procs.Count } | ConvertTo-Json -Depth 4 |
  Set-Content -Encoding utf8 (Join-Path $env:ADIR "agy_identity.json")
' >/dev/null 2>&1 ) &
}

# _kill_recorded <adir> <out_json> — kill exactly the processes this attempt recorded, and prove
# each one is gone by pid AND creation time. Returns 1 unless every recorded process is
# confirmed gone; an unreadable or missing identity file yields UNKNOWN, never "confirmed".
_kill_recorded() {
  local adir="$1" out="$2" st
  st="$(cat "$adir/started_at.epoch" 2>/dev/null)"
  case "$st" in ''|*[!0-9]*) st=0 ;; esac

  # The target set is built AT KILL TIME by positive enumeration (every agy.exe created at or
  # after this attempt started), unioned with whatever the background snapshot managed to
  # record. Depending on the snapshot alone was a race: a fast attempt finishes before the
  # snapshot lands, and "no identity file" was then indistinguishable from "nothing to kill",
  # which wrongly marked healthy handoffs terminate-unconfirmed.
  # `confirmed_dead` is true ONLY when enumeration succeeded AND every target is verified gone.
  # If enumeration itself throws, the answer is null (UNKNOWN) — never a confident "dead".
  IDF="$adir/agy_identity.json" OUT="$out" ST="$st" AGYNAME=agy.exe powershell.exe -NoProfile -Command '
$ErrorActionPreference = "Stop"
try {
  $since = (Get-Date "1970-01-01Z").ToUniversalTime().AddSeconds([double]$env:ST)
  $targets = @{}
  foreach ($p in @(Get-CimInstance Win32_Process |
                   Where-Object { $_.Name -eq $env:AGYNAME -and $_.CreationDate -ge $since })) {
    $targets[[string]$p.ProcessId] = $p.CreationDate.ToString("o")
  }
  if (Test-Path $env:IDF) {
    $doc = Get-Content -Raw $env:IDF | ConvertFrom-Json
    foreach ($r in @($doc.recorded)) { if ($r) { $targets[[string]$r.pid] = [string]$r.created } }
  }
  $killed = @(); $survivors = @()
  foreach ($procId in $targets.Keys) {
    # taskkill writes ERROR: The process ... not found. on stderr when the target has ALREADY
    # exited. At a TTK boundary that is the normal case: the runner own timeout backstop has
    # already killed agy by the time we sweep. Under PowerShell 5.1 a native command stderr
    # merged with 2>&1 becomes ErrorRecords, and with $ErrorActionPreference = Stop that THROWS
    # — so an already-dead process fell into the catch below as confirmed_dead = null, which
    # fails closed and aborts the mission. Every real TTK checkpoint died here. Swallow it:
    # taskkill complaint is not evidence either way. The Get-CimInstance check below is what
    # establishes death, and no such process is the strongest possible proof of it.
    try { & taskkill.exe /PID $procId /T /F 2> $null | Out-Null } catch { }
    Start-Sleep -Milliseconds 400
    $still = Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -EA SilentlyContinue
    # Same pid with a DIFFERENT creation time is an unrelated process that reused the pid, not
    # a survivor, and must not be reported as one.
    if ($still -and $still.CreationDate.ToString("o") -eq $targets[$procId]) {
      $survivors += @{ pid = $procId }
    } else { $killed += @{ pid = $procId } }
  }
  @{ requested = $true; enumerated = $true; targets = $targets.Count; killed = $killed
     survivors = $survivors; confirmed_dead = ($survivors.Count -eq 0) } |
    ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 $env:OUT
} catch {
  @{ requested = $true; enumerated = $false; confirmed_dead = $null; error = "$_" } |
    ConvertTo-Json -Depth 3 | Set-Content -Encoding utf8 $env:OUT
}
' >/dev/null 2>&1
  [ -s "$out" ] || printf '{"requested":true,"enumerated":false,"confirmed_dead":null,"error":"powershell sweep failed or unavailable"}\n' > "$out"
  local c; c="$(_json_get "$out" confirmed_dead)"
  case "$c" in True|true) return 0 ;; *) return 1 ;; esac
}

# _kill_matching_path <native_path_fragment> <out_json> — best-effort secondary sweep by command
# line. Kept as a NET for stragglers the identity record missed, never as the proof itself: an
# empty/unreadable CommandLine makes a process invisible here, so "found nothing" from this
# function means nothing at all.
_kill_matching_path() {
  local ws_native="$1" out="$2"
  [ -n "$ws_native" ] || return 0

  WSN="$ws_native" OUT="$out" powershell.exe -NoProfile -Command '
$ws = $env:WSN; $out = $env:OUT
$killed = @(); $failed = @()
# Match on the workspace path in the command line: mission-scoped, never name-based.
$owned = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
         Where-Object { $_.CommandLine -and $_.CommandLine.Contains($ws) }
foreach ($p in $owned) {
  $rec = [ordered]@{ pid = $p.ProcessId; name = $p.Name; created = "$($p.CreationDate)" }
  # /T takes the whole tree, /F forces. Kill the tree, then VERIFY rather than trust the exit.
  # Same 2>&1 hazard as the identity sweep: an already-exited pid must not become an error.
  try { & taskkill.exe /PID $p.ProcessId /T /F 2> $null | Out-Null } catch { }
  Start-Sleep -Milliseconds 400
  $still = Get-CimInstance Win32_Process -Filter "ProcessId=$($p.ProcessId)" -ErrorAction SilentlyContinue
  # PID reuse guard: same pid but a different creation time is a DIFFERENT process, not a survivor.
  if ($still -and "$($still.CreationDate)" -eq $rec.created) { $failed += $rec } else { $killed += $rec }
}
$survivors = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
               Where-Object { $_.CommandLine -and $_.CommandLine.Contains($ws) })
$doc = [ordered]@{
  requested       = $true
  owned_found     = $owned.Count
  killed          = $killed
  kill_failed     = $failed
  survivors_after = $survivors.Count
  confirmed_dead  = ($survivors.Count -eq 0)
}
$doc | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 $out
' >/dev/null 2>&1

  # PowerShell absent or the sweep itself failed: say so rather than implying a clean handoff.
  if [ ! -s "$out" ]; then
    printf '{"requested":true,"confirmed_dead":null,"error":"termination sweep unavailable (powershell.exe missing or failed)"}\n' \
      > "$out"
  fi
  local confirmed
  confirmed="$(_json_get "$out" confirmed_dead)"
  if [ "$confirmed" = "True" ] || [ "$confirmed" = "true" ]; then
    return 0
  fi
  echo "[gemini_heavy] WARNING: could not confirm process-tree death ($(head -c 200 "$out"))" >&2
  return 1
}

# _capture_repo_evidence <dir> — what actually changed on disk. Text answers are claims; the
# repository is evidence, and fusion is told to prefer the latter.
_capture_repo_evidence() {
  local dir="$1" proj="${Z3F_GEMINI_PROJECT_DIR:-}"
  [ -n "$proj" ] && [ -d "$proj" ] || return 0
  {
    echo "### git status (short)"
    git -C "$proj" status --short 2>/dev/null | head -100
    echo
    echo "### git diff --stat"
    git -C "$proj" diff --stat 2>/dev/null | tail -60
  } > "$dir/repo_evidence.md" 2>/dev/null
}

# ======================================================================================
# FUSION
# ======================================================================================
# A third pinned, routing-verified, governed Gemini call. This is NOT the z3Fusion panel judge
# — it produces the Gemini SLOT's single canonical answer, which then goes to the orchestrating
# Claude session as one panelist among several. The panel judge is unchanged.
_run_fusion() {
  local fdir="$job_dir/gemini/fusion"
  mkdir -p "$fdir"

  # RECLAIM SAFETY — the same guard the attempts have, which fusion was missing. If a
  # supervisor died AFTER fusion succeeded but BEFORE the canonical write, a reclaiming
  # supervisor would re-enter here, run_gemini.sh would truncate output.md on entry, and a good
  # sixteen-hour fusion result would be destroyed by a retry that might then fail. Worse, the
  # `_write_once` seal below would refuse the new status doc, so provenance would describe the
  # OLD run while the NEW bytes shipped. A sealed fusion is resumed past, never re-run.
  if [ -f "$fdir/status.json" ] && [ -s "$fdir/output.md" ]; then
    echo "[gemini_heavy] fusion already sealed with output — resuming past it, not re-running." >&2
    return 0
  fi
  cp "$job_dir/gemini/attempt-01/output.md" "$fdir/input-attempt-01.md" 2>/dev/null
  cp "$job_dir/gemini/attempt-02/output.md" "$fdir/input-attempt-02.md" 2>/dev/null

  local s1 s2
  s1="$(_json_get "$job_dir/gemini/attempt-01/status.json" status)"
  s2="$(_json_get "$job_dir/gemini/attempt-02/status.json" status)"

  {
    cat <<EOF
# ATTEMPT OUTPUT FUSION

You previously worked on the mission below TWICE, independently — two separate executions, each
reasoning from scratch. Both transcripts are given to you now. Produce the single strongest
final answer to the mission.

Attempt 01 finished with status: $s1
Attempt 02 finished with status: $s2

Rules for this fusion pass:

- Do NOT prefer attempt 02 merely because it ran later. Do NOT discard attempt 01 merely
  because it reached its time boundary. Judge them on merit.
- A "ttk-checkpoint" attempt is PARTIAL WORK THAT WAS PRESERVED ON PURPOSE. If it contains the
  better architecture, the better implementation or a finding the other attempt missed, use it.
  Partial does not mean worthless.
- Identify explicitly: consensus, disagreements, what each attempt actually completed, the
  stronger implementation choices, missing pieces, complementary discoveries, conflicting edits
  or conclusions, tests performed, tests still missing.
- Where the attempts conflict, prefer the one supported by the repository evidence below over
  the one that merely asserts it. A claim is not a result.
- The expected outcome is usually a COMBINATION: one attempt's implementation plus the other's
  fixes and verification — not a winner-takes-all pick.
- Output the final answer to the mission itself, not a report about the two attempts. Put a
  short "Fusion notes" section at the end recording what you took from each and why.

## YOUR INPUTS ARE FILES, NOT TEXT IN THIS PROMPT

Read them with your own file tools from the working directory before answering:

    fusion-input/manifest.json         index: every artifact, its size and its sha256
    fusion-input/mission.md            the original mission
    fusion-input/attempt-01.md         attempt 01's full output (status above)
    fusion-input/attempt-02.md         attempt 02's full output (status above)
    fusion-input/repo-evidence.md      actual on-disk repository state, authoritative

Read every file listed in the manifest. If a file's byte size does not match the manifest,
say so explicitly in your answer rather than proceeding as if the evidence were complete.
EOF
  } > "$fdir/prompt.md"

  # -----------------------------------------------------------------------------------
  # FILE-BACKED TRANSPORT (why the payload is not in the prompt)
  # -----------------------------------------------------------------------------------
  # agy takes its prompt as ONE argv element and Windows caps a command line at 32767 bytes.
  # Probed directly on agy 1.1.8: there is NO stdin prompt path — `--print` with no value
  # ignores stdin and answers a generic greeting, and `--print -` sends the literal "-". So the
  # payload cannot be piped in. Two multi-hour attempt outputs would blow the argv cap as a
  # matter of course, and a fusion stage must not die after sixteen hours of work because of a
  # command-line limit.
  # Instead the payload is written as FILES into the workspace agy is about to run in, and the
  # prompt — a few hundred bytes — tells agy to read them with its own file tools. run_gemini.sh
  # does `mkdir -p` on this workspace, so pre-populating it is safe and nothing is truncated.
  local ws="$fdir/run/attempt1/ws/fusion-input"
  mkdir -p "$ws"

  # Repository evidence source: attempt-02's if present, else attempt-01's.
  local eviden="$job_dir/gemini/attempt-02/repo_evidence.md"
  [ -s "$eviden" ] || eviden="$job_dir/gemini/attempt-01/repo_evidence.md"
  [ -s "$eviden" ] || { eviden="$fdir/no-evidence.md"
    echo "_(no repository evidence captured — Z3F_GEMINI_PROJECT_DIR was not set)_" > "$eviden"; }

  # STAGE AND VERIFY ACROSS THE TRUST BOUNDARY.
  # Hashing only the staged copies made the manifest agree with itself by construction: a failed
  # copy produced an empty destination, the manifest faithfully recorded `bytes: 0`, and the
  # model was told the evidence was complete. Integrity has to compare the AUTHORITATIVE SOURCE
  # against what actually landed, so staging failure is detectable rather than self-consistent.
  S1="$s1" S2="$s2" JOB="$job_id" WS="$ws" \
  SRC_MISSION="$job_dir/mission.md" SRC_A1="$fdir/input-attempt-01.md" \
  SRC_A2="$fdir/input-attempt-02.md" SRC_EV="$eviden" \
  "$FUSION_PY" - <<'PYEOF' > "$ws/manifest.json"
import hashlib, json, os, shutil, sys, time

ws = os.environ["WS"]
pairs = [("mission.md", os.environ["SRC_MISSION"]),
         ("attempt-01.md", os.environ["SRC_A1"]),
         ("attempt-02.md", os.environ["SRC_A2"]),
         ("repo-evidence.md", os.environ["SRC_EV"])]

def digest(path):
    h = hashlib.sha256()
    n = 0
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk); n += len(chunk)
    return n, h.hexdigest()

arts, failures = {}, []
for name, src in pairs:
    dst = os.path.join(ws, name)
    if not os.path.exists(src):
        # An absent source is a real state (no attempt-02 yet), recorded as such — not silently
        # turned into an empty file that looks like successfully staged evidence.
        arts[name] = {"staged": False, "reason": "source does not exist", "source": src}
        open(dst, "w", encoding="utf-8").close()
        continue
    sbytes, ssha = digest(src)
    shutil.copyfile(src, dst)
    dbytes, dsha = digest(dst)
    ok = (sbytes == dbytes and ssha == dsha)
    arts[name] = {"staged": ok, "source": src, "source_bytes": sbytes, "source_sha256": ssha,
                  "staged_path": dst, "staged_bytes": dbytes, "staged_sha256": dsha}
    if not ok:
        failures.append(name)

print(json.dumps({
    "run_id": os.environ["JOB"], "stage": "fusion",
    "attempt_01_status": os.environ["S1"], "attempt_02_status": os.environ["S2"],
    "transport": "file-backed (workspace); prompt carries no payload",
    "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "artifacts": arts,
    "total_staged_bytes": sum(a.get("staged_bytes", 0) for a in arts.values()),
    "staging_failures": failures,
    "evidence_complete": not failures,
}, indent=2))
sys.exit(1 if failures else 0)
PYEOF
  local stage_rc=$?
  cp "$ws/manifest.json" "$fdir/manifest.json" 2>/dev/null
  if [ "$stage_rc" -ne 0 ]; then
    echo "[gemini_heavy] fusion input staging FAILED integrity check (source != staged). Refusing to tell fusion the evidence is complete. See $fdir/manifest.json" >&2
    return 1
  fi

  # The prompt must stay far below the argv cap now that it carries no payload. If this ever
  # trips, the transport regressed and it should fail loudly rather than be truncated by the OS.
  local pbytes
  pbytes="$(wc -c < "$fdir/prompt.md" | tr -d ' ')"
  if [ "${pbytes:-0}" -gt 30000 ]; then
    echo "[gemini_heavy] fusion prompt is ${pbytes} bytes — the payload should be file-backed; refusing to risk argv truncation." >&2
    return 1
  fi

  Z3F_ARTIFACT_DIR="$fdir/run" \
  FUSION_TIMEOUT="$TTK" \
  AGY_MAX_ATTEMPTS=1 \
  Z3F_GEMINI_HEAVY=0 \
  bash "$SCRIPT_DIR/run_gemini.sh" "$fdir/prompt.md" "$fdir/output.md" \
    > "$fdir/runner.out" 2> "$fdir/runner.err"
  local rc=$?
  FRC="$rc" FD="$fdir" "$FUSION_PY" - <<'PYEOF' > "$fdir/status.json.candidate"
import json, os, time
fd = os.environ["FD"]; out = os.path.join(fd, "output.md")
print(json.dumps({
    "stage": "fusion", "performed": True, "attempt_count": 2,
    "exit_code": int(os.environ["FRC"]),
    "status": "completed" if int(os.environ["FRC"]) == 0 else "failed",
    "output_artifact": out,
    "chars": (os.path.getsize(out) if os.path.exists(out) else 0),
    "completed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
}, indent=2))
PYEOF
  _write_once "$fdir/status.json" < "$fdir/status.json.candidate"
  rm -f "$fdir/status.json.candidate"
  return $rc
}

# ======================================================================================
# SUPERVISOR — runs detached; the caller's wait window has no bearing on it
# ======================================================================================
_supervise() {
  job_dir="$1"
  job_id="$(basename "$job_dir")"
  # The heartbeat records WHO owns it and WHEN, and the ticker polls its owner and exits the
  # moment the owner is gone. Without that self-termination a killed supervisor leaves a ticker
  # advancing the heartbeat forever, and the mission reads ACTIVE permanently with no path to
  # reclaim — the exact opposite of what a heartbeat is for.
  #
  # `ticker` is deliberately NOT `local`: the EXIT trap runs at top level, where a
  # function-local is out of scope. Under `set -u` that made the trap itself abort with
  # `ticker: unbound variable`, so the cleanup never ran and orphaned the very process it was
  # meant to kill. Two independent mechanisms now have to fail before an orphan survives.
  local owner=$$
  ( while kill -0 "$owner" 2>/dev/null; do
      printf '%s %s\n' "$owner" "$(date +%s)" > "$job_dir/heartbeat"
      sleep "$HEARTBEAT_INTERVAL"
    done ) &
  ticker=$!
  # Release ownership on the way out so a finished/crashed supervisor does not hold the lock.
  trap 'kill "$ticker" 2>/dev/null; rm -rf "$job_dir/owner.lock" 2>/dev/null' EXIT

  # Reap anything this job left running before touching a single artifact. On a first start
  # this finds nothing; on a RECLAIM it is what stops a previous run's orphaned agy.exe — which
  # really does outlive its supervisor — from editing the same workspace as the attempt that is
  # about to begin.
  _sweep_job_orphans "$job_dir" \
    || echo "[gemini_heavy] WARNING: reclaim sweep could not confirm the job is free of orphans; see $job_dir/reclaim-sweep.json" >&2

  _set_state "attempt-01"
  local st1 st2="not-run" canonical="" source=""
  st1="$(_run_attempt 1 "$job_dir/gemini/attempt-01")"
  echo "[gemini_heavy] attempt-01 -> $st1" >&2

  if [ "$st1" = "completed" ]; then
    canonical="$job_dir/gemini/attempt-01/output.md"; source="attempt-01"
  elif [ "$st1" = "terminate-unconfirmed" ]; then
    # Refuse the handoff. Starting attempt-02 while attempt-01 may still be editing the same
    # working tree is exactly the corruption this stage exists to prevent, and a corrupted
    # 16-hour result is worse than an honest stop. Whatever attempt-01 produced is kept.
    echo "[gemini_heavy] attempt-01 process tree could not be confirmed dead — refusing to start attempt-02 against a tree that may still be being edited." >&2
    [ -s "$job_dir/gemini/attempt-01/output.md" ] && {
      canonical="$job_dir/gemini/attempt-01/output.md"; source="attempt-01-checkpoint"; }
  elif [ "$st1" = "ttk-checkpoint" ] && [ "$MAX_ATTEMPTS" -ge 2 ]; then
    _set_state "attempt-02"
    st2="$(_run_attempt 2 "$job_dir/gemini/attempt-02")"
    echo "[gemini_heavy] attempt-02 -> $st2" >&2
    if [ "$DO_FUSION" = "1" ] && [ -s "$job_dir/gemini/attempt-02/output.md" ] \
       && [ -s "$job_dir/gemini/attempt-01/output.md" ]; then
      _set_state "fusion"
      if _run_fusion && [ -s "$job_dir/gemini/fusion/output.md" ]; then
        canonical="$job_dir/gemini/fusion/output.md"; source="fusion"
      fi
    fi
    # Fusion is an enhancement, never a single point of failure: if it cannot run or fails,
    # fall back to the best attempt output rather than losing both attempts' work.
    if [ -z "$canonical" ]; then
      if [ -s "$job_dir/gemini/attempt-02/output.md" ]; then
        canonical="$job_dir/gemini/attempt-02/output.md"; source="attempt-02"
      elif [ -s "$job_dir/gemini/attempt-01/output.md" ]; then
        canonical="$job_dir/gemini/attempt-01/output.md"; source="attempt-01-checkpoint"
      fi
    fi
  else
    # Deterministic failure (pin mismatch, auth, stale transcript, bad usage) or nothing
    # recoverable: a second 8-hour attempt cannot change the outcome, so do not spend it.
    [ -s "$job_dir/gemini/attempt-01/output.md" ] && {
      canonical="$job_dir/gemini/attempt-01/output.md"; source="attempt-01"; }
  fi

  mkdir -p "$job_dir/final"
  if [ -n "$canonical" ] && [ -s "$canonical" ]; then
    # _write_once refuses when an earlier supervisor already wrote the canonical answer. That
    # refusal is fine — but it must not be mistaken for a successful write, so success is
    # decided by what is actually on disk afterwards rather than by having called the writer.
    _write_once "$job_dir/final/output.md" < "$canonical" \
      || echo "[gemini_heavy] canonical output already existed (earlier supervisor) — keeping it." >&2
    if [ -s "$job_dir/final/output.md" ]; then
      _finalize_provenance "$st1" "$st2" "$source" "success"
      _set_state "done"
    else
      echo "[gemini_heavy] canonical output could not be written — failing rather than reporting a result that is not there." >&2
      _finalize_provenance "$st1" "$st2" "none" "failed"
      _set_state "failed"
    fi
  else
    _finalize_provenance "$st1" "$st2" "none" "failed"
    _set_state "failed"
  fi
  kill "$ticker" 2>/dev/null
  : > "$job_dir/heartbeat"
}

_finalize_provenance() {
  ST1="$1" ST2="$2" SRC="$3" FINAL="$4" JOB="$job_dir" TTKV="$TTK" \
  "$FUSION_PY" - <<'PYEOF' > "$job_dir/final/provenance.json.candidate"
import json, os, time
job = os.environ["JOB"]
def load(p):
    try: return json.load(open(p, encoding="utf-8"))
    except Exception: return None
a1 = load(os.path.join(job, "gemini", "attempt-01", "status.json"))
a2 = load(os.path.join(job, "gemini", "attempt-02", "status.json"))
fu = load(os.path.join(job, "gemini", "fusion", "status.json"))
p1 = load(os.path.join(job, "gemini", "attempt-01", "output.md.provenance.json")) or {}
# Describe the ANSWER THAT SHIPPED, not always attempt-01. Reporting attempt-01's routing and
# pin verdict for text produced by fusion or attempt-02 would claim a verification that never
# happened for the delivered content.
src = os.environ["SRC"]
_stage = {"fusion": ("gemini", "fusion"), "attempt-02": ("gemini", "attempt-02")}.get(
    src, ("gemini", "attempt-01"))
pc = load(os.path.join(job, *_stage, "output.md.provenance.json")) or {}
_status_doc = {"fusion": a2, "attempt-02": a2}.get(src, a1) or {}
# A timed-out stage has no routing in the runner's own provenance; the checkpoint stage
# recovers it from that attempt's preserved agy log, so fall back to the status doc.
_routed = pc.get("routed_model_label") or _status_doc.get("routed_model_label")
_pinned = pc.get("model_pin_verified")
if _pinned is None:
    _pinned = _status_doc.get("model_pin_verified")
doc = {"gemini_execution": {
    "model": pc.get("model") or p1.get("model") or "gemini-3.1-pro-high",
    "routed_model": _routed,
    "model_pin_verified": _pinned,
    "provenance_describes": src,
    "reasoning_effort": "high",
    "reasoning_effort_resolution":
        "encoded in the model label 'Gemini 3.1 Pro (High)'; agy 1.1.8 rejects --effort for "
        "this model, and --model gemini-3.1-pro --effort high silently routes to Flash",
    "governance_profile": pc.get("governance_profile") or p1.get("governance_profile"),
    "ttk_seconds_per_attempt": int(os.environ["TTKV"]),
    "attempt_01": a1, "attempt_02": a2,
    "fusion": fu or {"performed": False},
    "canonical_source": os.environ["SRC"],
    "final_status": os.environ["FINAL"],
    "completed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
}}
print(json.dumps(doc, indent=2))
PYEOF
  _write_once "$job_dir/final/provenance.json" < "$job_dir/final/provenance.json.candidate"
  rm -f "$job_dir/final/provenance.json.candidate"
}

# ======================================================================================
# ENTRY POINTS
# ======================================================================================
_prepare_job() {
  local prompt="$1"
  [ -s "$prompt" ] || { echo "[gemini_heavy] prompt file missing or empty: $prompt" >&2; exit 2; }
  job_id="z3f-gem-$(_sha12 "$prompt")${Z3F_JOB_SUFFIX:+-$Z3F_JOB_SUFFIX}"
  job_dir="$JOBS_ROOT/$job_id"
  mkdir -p "$job_dir/gemini"
  [ -f "$job_dir/mission.md" ] || cp "$prompt" "$job_dir/mission.md"
  [ -f "$job_dir/state.json" ] || printf '{"job_id":"%s","state":"new","created_at":"%s"}\n' \
    "$job_id" "$(_iso)" > "$job_dir/state.json"
}

cmd_start() {
  _prepare_job "$1"
  local state; state="$(_json_get "$job_dir/state.json" state)"
  if [ "$state" = "done" ] || [ "$state" = "failed" ]; then
    echo "$job_id"; return 0
  fi
  # ATOMIC OWNERSHIP. `mkdir` either creates the directory or fails, indivisibly, on every
  # filesystem — so exactly one of N simultaneous callers can win. The previous
  # check-liveness-then-launch sequence was a read followed by a write with a wide gap between
  # them (a Python process spawn), which is not an ownership protocol at all: two callers with
  # the same mission hash could both observe "free" and both launch a supervisor.
  if ! mkdir "$job_dir/owner.lock" 2>/dev/null; then
    local live; live="$(_liveness "$job_dir")"
    case "$live" in
      ACTIVE)
        # Re-attaching is the whole point: this is what stops a caller that gave up waiting
        # from launching a SECOND multi-hour agy run against the same mission.
        echo "[gemini_heavy] job $job_id is already running (owner alive) — re-attaching, not launching a duplicate." >&2
        echo "$job_id"; return 0 ;;
      DEAD|STALE)
        # Reclaim only on POSITIVE evidence the previous owner is gone — never merely because
        # the lock looks old. An 8-hour workload makes age-based assumptions actively unsafe.
        echo "[gemini_heavy] previous owner of $job_id is confirmed dead — reclaiming." >&2
        rm -rf "$job_dir/owner.lock"
        if ! mkdir "$job_dir/owner.lock" 2>/dev/null; then
          echo "[gemini_heavy] another caller reclaimed $job_id first — deferring to it." >&2
          echo "$job_id"; return 0
        fi ;;
      *)
        # UNKNOWN: refuse to guess. Duplicating a live 8-hour mission is worse than waiting.
        echo "[gemini_heavy] ownership of $job_id is UNKNOWN (owner pid or heartbeat unreadable) — refusing to launch a possible duplicate. Inspect $job_dir/heartbeat." >&2
        echo "$job_id"; return 0 ;;
    esac
  fi

  # Claim the heartbeat with OUR OWN identity the instant the lock is won, before the spawns.
  # Otherwise the gap between acquiring the lock and the supervisor's first heartbeat spans a
  # `nohup bash` spawn AND a Python spawn, and any caller arriving inside it reads the PREVIOUS
  # dead owner's pid, concludes DEAD, deletes the winner's lock and launches a duplicate. That
  # window is hit by the ordinary re-attach pattern (caller gets 75 at WAIT_SECONDS and
  # re-invokes), so it is routine, not exotic.
  printf '%s %s\n' "$$" "$(_now)" > "$job_dir/heartbeat"

  nohup bash "$SCRIPT_DIR/gemini_heavy.sh" _supervise "$job_dir" \
    >> "$job_dir/supervisor.log" 2>&1 &
  local sup=$!
  disown 2>/dev/null || true
  # Seed the heartbeat with the supervisor's identity immediately, so a concurrent caller sees
  # ACTIVE rather than an empty heartbeat during the window before the ticker's first write.
  printf '%s %s\n' "$sup" "$(_now)" > "$job_dir/heartbeat"
  OWNER="$sup" HOST="$(hostname 2>/dev/null || echo unknown)" JD="$job_dir" MID="$job_id" \
    "$FUSION_PY" - <<'PYEOF' > "$job_dir/owner.lock/owner.json" 2>/dev/null
import json, os, time
print(json.dumps({
    "supervisor_pid": int(os.environ["OWNER"]),
    "mission_id": os.environ["MID"],
    "run_id": os.environ.get("Z3F_RUN_ID", ""),
    "hostname": os.environ["HOST"],
    "cwd": os.getcwd(),
    "acquired_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
}, indent=2))
PYEOF
  echo "$job_id"
}

cmd_collect() {
  local jid="$1" out="$2" jd="$JOBS_ROOT/$1"
  [ -d "$jd" ] || { echo "[gemini_heavy] no such job: $jid" >&2; return 2; }
  local state; state="$(_json_get "$jd/state.json" state)"
  case "$state" in
    done)
      mkdir -p "$(dirname "$out")"
      # Collection is verified, not assumed. The previous version ran an unchecked `cp` under
      # `set -uo pipefail` (no `-e`) and then printed "ok" and returned 0 regardless — a second,
      # independent way to hand the orchestrator an empty canonical result while reporting
      # success. Delivery is now proven by comparing the destination against the source.
      if [ ! -s "$jd/final/output.md" ]; then
        echo "[gemini_heavy] job $jid is 'done' but its canonical artifact is missing or empty: $jd/final/output.md" >&2
        return 1
      fi
      if ! cp "$jd/final/output.md" "$out" 2>/dev/null; then
        echo "[gemini_heavy] failed to copy the canonical result to $out" >&2
        return 1
      fi
      local src_b dst_b
      src_b="$(wc -c < "$jd/final/output.md" | tr -d ' ')"
      dst_b="$(wc -c < "$out" 2>/dev/null | tr -d ' ')"
      if [ -z "$dst_b" ] || [ "$src_b" != "$dst_b" ]; then
        echo "[gemini_heavy] canonical result did not land intact ($src_b bytes -> ${dst_b:-0}); refusing to report success." >&2
        return 1
      fi
      cp "$jd/final/provenance.json" "$out.provenance.json" 2>/dev/null
      echo "[gemini_heavy] ok -> $out (job $jid, source $(_json_get2 "$jd/final/provenance.json" gemini_execution canonical_source))"
      return 0 ;;
    failed)
      echo "[gemini_heavy] job $jid failed; see $jd/supervisor.log" >&2
      cp "$jd/final/provenance.json" "$out.provenance.json" 2>/dev/null
      return 1 ;;
    *)
      echo "[gemini_heavy] job $jid still running (state=$state). Artifacts: $jd" >&2
      return 75 ;;
  esac
}

# _require_windows_caps — the TTK handoff cannot prove a process tree is dead without native
# process enumeration. Detect that dependency UP FRONT. Discovering it at the TTK boundary
# instead means attempt-02 and fusion are silently lost hours into a mission while the job
# still finishes "successfully" on attempt-01's checkpoint — success reported for a run that
# lost two thirds of its lifecycle.
_require_windows_caps() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *) return 0 ;;   # non-Windows host: the process-tree sweep does not apply
  esac
  if ! command -v powershell.exe >/dev/null 2>&1; then
    echo "[gemini_heavy] powershell.exe is required to prove attempt process-tree death before the attempt-02 handoff, and it is not on PATH. Refusing to start a multi-hour mission whose TTK handoff cannot be made safe." >&2
    return 1
  fi
  if ! powershell.exe -NoProfile -Command 'exit 0' >/dev/null 2>&1; then
    echo "[gemini_heavy] powershell.exe is present but not executable here; the TTK handoff could not prove process death. Refusing to start." >&2
    return 1
  fi
  return 0
}

cmd_run() {
  local prompt="$1" out="$2"
  have agy || { echo "[gemini_heavy] agy CLI not installed — skip this panelist." >&2; exit 127; }
  _require_windows_caps || exit 2
  local jid; jid="$(cmd_start "$prompt")" || exit $?
  local waited=0
  while [ "$waited" -lt "$WAIT_SECONDS" ]; do
    local st; st="$(_json_get "$JOBS_ROOT/$jid/state.json" state)"
    case "$st" in
      done|failed) break ;;
    esac
    # Only a POSITIVE dead verdict stops the wait. UNKNOWN keeps waiting, because abandoning a
    # possibly-live 8-hour mission is the more expensive mistake.
    if [ "$(_liveness "$JOBS_ROOT/$jid")" = "DEAD" ] && [ "$waited" -gt "$HEARTBEAT_STALE" ]; then
      echo "[gemini_heavy] supervisor for $jid is confirmed dead — stopping the wait." >&2
      break
    fi
    sleep 5
    waited=$((waited + 5))
  done
  cmd_collect "$jid" "$out"
}

case "${1:-}" in
  run)       shift; cmd_run "${1:?usage: gemini_heavy.sh run <prompt_file> <output_file>}" "${2:?need output_file}" ;;
  start)     shift; _prepare_job "${1:?need prompt_file}"; cmd_start "$1" ;;
  collect)   shift; cmd_collect "${1:?need job_id}" "${2:?need output_file}" ;;
  status)    shift
             if [ -n "${1:-}" ]; then cat "$JOBS_ROOT/$1/state.json" 2>/dev/null || { echo "no such job: $1" >&2; exit 2; }
             else ls -1 "$JOBS_ROOT" 2>/dev/null; fi ;;
  _supervise) shift; _supervise "${1:?need job_dir}" ;;
  *) echo "usage: gemini_heavy.sh {run|start|status|collect} ..." >&2; exit 2 ;;
esac
