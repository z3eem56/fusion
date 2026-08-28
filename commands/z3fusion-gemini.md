---
description: z3Fusion panel of an in-session Claude panelist + Gemini 3.1 Pro in parallel, judged by the orchestrating Claude Code session (claude-gemini3.1pro)
argument-hint: <your question>
---
Invoke the **z3fusion** skill on the task below, forcing the `claude-gemini3.1pro` legacy panel:
an in-session Claude panelist (Agent subagent) and Gemini 3.1 Pro (via `agy`) answer the SAME
prompt IN PARALLEL, each independently with web + bash and neither seeing the other's work → the
orchestrating Claude Code session judges both answers and writes the final answer grounded in the analysis.

The Gemini slot is **hard-pinned to `gemini-3.1-pro-high`** — the runner always passes an explicit
`--model` to `agy`, verifies from agy's own log which model it actually routed to, never falls back to
Flash, another Pro tier, or agy's configured default, and fails the panelist outright if that model is
unavailable or if agy routed elsewhere.

The Gemini panelist runs under the **`karpathy-engineering-v1`** engineering governance profile, injected
by `scripts/run_gemini.sh` from `references/gemini_governance.md`. Do not restate it here or in the panel
prompt — it is injected exactly once, at the runner. If `agy` fails transiently (a timeout), the runner
retries **once** automatically at double the timeout; deterministic failures are not retried.

Follow the skill's SKILL.md exactly (preflight → fan out in parallel → judge picking the track that fits the
task → grounded final deliverable → save provenance → present). For a research/analysis task present the
standard sections (Consensus / Contradictions / Partial coverage / Unique insights / Blind spots / Final
answer); for a code/artifact task run both candidates and merge them into one working result with a merge
rationale. Use exactly one in-session Claude panelist and one Gemini 3.1 Pro panelist — do NOT add a
GPT-5.6 Sol panelist or a second in-session Claude panelist. Pass the task verbatim to both; no "lenses".

If the `agy` CLI is missing or the Gemini panelist fails/times out, drop it, record a one-line degradation
note, and fall back to `claude-claude` (spawn a second independent in-session Claude panelist) so the judge
still sees two blind answers — never abort because one CLI failed.

**Attempts — this is a SYNCHRONOUS run by default.** Attempt 1 at `FUSION_TIMEOUT` (300s), one retry at
600s if, and only if, the failure was transient. That is the whole policy for an ordinary question. The
8-hour lifecycle is a *different, opt-in* mode and is **off unless asked for**: if the user wants a mission
that legitimately runs for hours (repo-wide analysis, iterative implementation), set `Z3F_GEMINI_HEAVY=1`
on the `run_gemini.sh` call and it delegates to `scripts/gemini_heavy.sh` — a detached job of up to 2
attempts × `Z3F_GEMINI_TTK` (default 28800s = 8h), with TTK checkpoint, handoff, and a fusion pass. Never
enable it for a normal question: it detaches, and `run` returns 75 ("still running, re-invoke to
re-attach") rather than an answer. Read SKILL.md's heavy section first, including the known limitation
that a TTK kill recovers no partial work on agy 1.1.9.

Always run `scripts/claude_relay.py normalize --file <relay> --agent-id <agentId> --agent-status completed
--out <canonical>` on the Claude panelist's `Agent` result before the judge sees it (SKILL.md Step 2). A
completed subagent can relay `Idle.`, a wake-up reply, or a sentinel wrapped in a `SECURITY WARNING:`
block plus an `agentId:`/`<usage>` trailer that makes it *look* like an answer — normalize strips the
harness envelope, classifies the actual answer, and recovers the completed task output when needed. A
recovered panelist is healthy and goes to the judge like any other; only a genuinely unrecoverable one is
dropped.

Present the result per SKILL.md Step 6: the deliverable, then a verbatim `RAW PANEL OUTPUTS` section from
`scripts/render_raw_panel.sh` showing what each panelist actually produced, then your `JUDGE / SYNTHESIS`
section. Do not paraphrase a panelist's answer in the raw section.

For a custom panel beyond this fixed 2-model preset — any mix of models, providers, or local runners — use
`/z3fusion --models <model@runner,...> :: <question>` instead.

Task: $ARGUMENTS
