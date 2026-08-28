---
name: z3fusion
description: >-
  Answer a hard question by fanning it out to a PANEL of models running in parallel — each answering
  independently with web search and bash, none seeing the others' work — then having the orchestrating
  Claude Code session judge every response into a structured analysis (consensus, contradictions, partial
  coverage, unique insights, blind spots) and write a final answer grounded in it. The panel is fully
  composable: 1-8 slots, each an independent "model@runner" pairing from ANY provider — in-session Claude
  Agent-tool subagents, the GPT family via the codex CLI, the Gemini family via the agy/Antigravity CLI,
  fully local Ollama models, a local LM Studio / vLLM / any OpenAI-compatible server, or literally any
  OpenRouter-listed model from any provider (Anthropic, OpenAI, Google, DeepSeek, Meta/Llama, Mistral,
  xAI/Grok, Qwen, and more) via an OPENROUTER_API_KEY. Four legacy slugs remain as zero-config presets
  (claude-claude, claude-gpt5.6, claude-gemini3.1pro, claude-gpt5.6-gemini3.1pro) but they are convenience
  defaults, not the ceiling — pass a custom "--models" panel string of comma-separated model@runner slots
  instead. The orchestrating Claude Code session (whichever model it is actually running as) always judges
  and writes the final answer — the pipeline can't be reversed, because external panelist CLIs/APIs have no
  way to call back into this session. Runs on local CLI subscriptions or fully local models with no metered
  API required for the legacy presets, and can also reach metered provider APIs when configured. Saves a
  timestamped provenance .md per run, and answers in French by default. Use this whenever the user asks to
  "run it through z3Fusion", says /z3fusion, wants a multi-model / panel / ensemble answer, wants a question
  cross-checked across models, or wants a higher-confidence answer with consensus and blind spots surfaced —
  even if they don't say "fusion". General-purpose: any topic (research, law, strategy, technical,
  personal). Best for high-stakes research, design calls, and debugging where being confidently wrong is
  expensive.
---

# z3Fusion

z3Fusion turns one prompt into a panel. The question goes to several models **at the same time**, each
answering independently — with web search and bash, and with no knowledge of the others. Then the
orchestrating Claude Code session (this very session — whichever model it is actually running as: Opus,
Sonnet, Haiku, Fable, whatever the user selected via `/model`) reads every answer, extracts the structure of
the panel's reasoning (what they agree on, where they conflict, what only one saw, what they all missed),
and writes a final answer grounded in that analysis.

The whole mechanism is **independence, then synthesis**. The diversity that makes a panel beat a single
model is harvested, not manufactured: running the same prompt independently yields different reasoning
paths, tool calls, and sources. So there are **no assigned "lenses" or personas** — every panelist gets the
user's task **verbatim** and answers it straight. (See `references/panel.md`.)

**One hard rule, stated plainly as a scope boundary: the panel is freely composable across any model or
provider, but the judge and final synthesizer is always the orchestrating Claude Code session itself — the
pipeline can't be reversed.** External panelist CLIs and APIs (codex, agy, a local Ollama model, an
OpenRouter-listed model, any OpenAI-compatible server) have no way to call back into this session to spawn
more subagents, judge the panel, or write the final synthesis — only the orchestrator can do that, because
that capability lives in this session, not in a shelled-out CLI or an HTTP response. This is a real
limitation, not an implementation detail to gloss over: compose the panel however rich you like, across
however many providers you like, but the judge slot is never one of the panelists and is never itself
swappable to an external model.

**Design reference.** This skill's shape is a local implementation of [OpenRouter's Fusion Router](https://openrouter.ai/docs/guides/routing/routers/fusion-router): its `analysis_models` array (1-8
models, any provider, run in parallel with web tools) judged/synthesized by one outer `model` is exactly
what Step 2 (fan-out) and Step 3 (judge) do here — the difference is this skill dispatches every panelist
itself, locally, over CLI/API calls, instead of delegating that fan-out to OpenRouter's server-side plugin.
That means z3Fusion works **with or without an OpenRouter account**: the legacy presets and any local/CLI
runner need no OpenRouter key at all. When `OPENROUTER_API_KEY` *is* set, it additionally unlocks the
`<model>@openrouter` runner so any panel slot can point at literally any OpenRouter-listed model as a plain
per-model HTTP call — this is the robust, verified path, and it is what makes "any provider" real without
depending on OpenRouter's own multi-model plugin behavior. Separately, `providers.sh` also exposes an
EXPERIMENTAL `extra_json` passthrough (see Step 2's `openrouter` bullet) for advanced users who want to
attach OpenRouter's own native fusion plugin as a nested meta-panelist inside a single panel slot — that
path is opt-in, unverified against real provider responses in this environment, and clearly labeled
experimental; it is not needed for, and does not replace, the plain per-model path above.

Throughout, `<skill_dir>` is the directory containing this SKILL.md (when installed:
`~/.claude/skills/z3fusion`). Write the user's question **verbatim** to `/tmp/z3fusion_question.txt` first —
several steps reuse it.

## Step 0 — Pick the panel

```bash
bash <skill_dir>/scripts/detect_panel.sh
```

It probes every runner this machine can currently reach — not just `codex`/`agy` but also a local Ollama
CLI/server, a local LM Studio server, and whichever provider API keys are set in the environment (e.g.
`OPENROUTER_API_KEY`, `OPENAI_API_KEY`, `GROQ_API_KEY`, and the rest of the table in `providers.sh`) — and
prints a `SLUG=` line recommending the richest of the 4 legacy presets, plus a `RUNNERS AVAILABLE:` table
so you can see everything else that is composable beyond those 4 presets.

| Slug | Panel | Requires |
| --- | --- | --- |
| `claude-claude` | the same prompt run twice as 2 independent in-session Claude panelists | nothing — always available |
| `claude-gpt5.6` | in-session Claude + GPT-5.6 Sol (pinned `gpt-5.6-sol`) in parallel | `codex` CLI |
| `claude-gemini3.1pro` | in-session Claude + Gemini 3.1 Pro (pinned `gemini-3.1-pro-high`) in parallel | `agy` CLI |
| `claude-gpt5.6-gemini3.1pro` | in-session Claude + GPT-5.6 Sol (pinned `gpt-5.6-sol`) + Gemini 3.1 Pro (pinned `gemini-3.1-pro-high`) in parallel | `codex` + `agy` CLIs |

**The codex slot's model half is a runtime slug, not a marketing name.** The `claude-gpt5.6*` presets
pass **`gpt-5.6-sol`** to `run_panelist.sh codex`, never the bare `gpt-5.6`. Observed on this machine
(codex-cli 0.144.1, ChatGPT-account auth, no `OPENAI_API_KEY`): `--model gpt-5.6` is rejected by the API
with `400 The 'gpt-5.6' model is not supported when using Codex with a ChatGPT account`, which the attempt
policy correctly classifies as deterministic — so the panelist is dropped on attempt 1 and the whole panel
silently degrades to 2 models. `--model gpt-5.6-sol` is accepted. This is an observed fact about this
account/auth/CLI version, not a spec: if codex is ever re-authed with an API key, or `codex` changes its
slugs, re-check with `grep '^model' ~/.codex/config.toml` — that value is the slug this install accepts.
Passing an **empty** model half also works and defers to exactly that configured default.

Beyond these 4 presets, compose an ad hoc panel with `--models` — a comma-separated list of `model@runner`
slots, one per panelist. A bare model name with no `@` always means an in-session Claude Agent-tool
subagent (`opus` and `opus@claude` mean the same thing); every other slot's `runner` half selects how that
panelist is invoked (see Step 2). A few concrete examples, mixing local and cloud:

- `--models opus@claude,gpt-5.6-sol@codex,gemini-3.1-pro@agy` — the legacy 3-model panel, spelled out
  explicitly instead of via a slug.
- `--models opus@claude,llama4@ollama,deepseek/deepseek-v4-pro@openrouter` — one in-session Claude
  panelist, one fully local Ollama model (no API key), one OpenRouter-routed frontier model.
- `--models qwen3.6@ollama,llama-4-maverick@openrouter,gpt-5.6-sol@codex,gemini-3.1-pro@agy,claude@claude` — a
  5-slot panel spanning a local model, OpenRouter, codex, agy, and in-session Claude in one call.

If the user named a slug (or used a pinned `/z3fusion-*` command) or passed `--models`, honor it — but if a
required CLI/server/key for a given slot is missing, say so, drop that panelist, and fall back to the
next-richest option (Step 2's graceful-degradation rules) rather than failing outright. Otherwise use the
detector's recommendation. Register additional local/remote runners for `--models` to use in
`~/.claude/z3fusion-runners.json` (see `scripts/providers.sh` for its exact shape).

## Step 1 — Preflight (informational, never a gate)

```bash
bash <skill_dir>/scripts/preflight.sh <SLUG> /tmp/z3fusion_question.txt
```

Show its output to the user (rough token/call estimate + Codex cap reminder), then proceed. It never
blocks. Each panelist is bounded by a per-panelist timeout (`FUSION_TIMEOUT`, default 300s) baked into the
runners; raise it for heavy deep-research questions (`FUSION_TIMEOUT=600 bash <skill_dir>/scripts/...`).

### Attempt policy — every runner, one rule

A panelist is not dropped on its first stumble. Every runner makes up to **`FUSION_MAX_ATTEMPTS`**
attempts (default **2**, clamped 1–3), where attempt *n* runs at `FUSION_TIMEOUT × FUSION_RETRY_FACTOR^(n-1)`
(default factor **2**: 300s, then 600s). Two rules keep that safe:

- **Only transient failures retry.** A timeout (124), a 429/502/503, a connection reset, a service-
  unavailable — those a second attempt can fix. A missing CLI (127), bad usage (2), an auth rejection, an
  unknown model, or a quota cap **never** retries: trying again cannot change the answer, and the
  orchestrator needs the degradation note promptly. The deny-list is checked first, so "auth failed after
  timeout" classifies as deterministic.
- **The budget escalates.** The most common transient failure is "not enough time", and a retry at the
  same budget fails identically.

| Runner | Attempt loop | Owned by |
| --- | --- | --- |
| `codex` | 2 × (300s → 600s), fresh throwaway workdir per attempt | `run_codex.sh` |
| `ollama` | 2 × (300s → 600s) | `_drive_attempts` in `_fusion_lib.sh` |
| any OpenAI-compatible provider (`openrouter`, `ollama-cloud`, `openai`, …) | 2 × (300s → 600s) | `_drive_attempts` |
| `agy` (Gemini) | 2 × (300s → 600s) | `run_gemini.sh`'s own driver (`AGY_MAX_ATTEMPTS`) — predates and supersedes the shared policy for this runner only |
| in-session Claude subagent | n/a — the Agent tool has no timeout to escalate | the harness |

Set `FUSION_MAX_ATTEMPTS=1` to restore strict one-shot behavior (that path runs in-process, with no
subprocess and no retry, exactly as before this policy existed).

> **The ceiling is the harness, not this policy.** Claude's Bash tool caps a foreground call at 600s. A
> *synchronous* panelist therefore cannot usefully be given a multi-hour budget no matter what
> `FUSION_TIMEOUT` says — the tool call dies before the runner can report, and the work is lost rather
> than degraded. Multi-hour missions need the **detached** supervisor below, which is precisely why that
> exists and why it is not simply a larger timeout.

## Step 2 — Fan out, in parallel and blind

Read `references/panel.md`. Build each panelist's prompt as the user's task **verbatim** plus the short
instruction to research with web + bash and return a complete, self-contained answer as one of several
independent experts who won't see the others' work. Do **not** assign lenses; do **not** pre-digest the
task. (Answer in the user's question language.)

Launch **all panelists in a single turn** so they run concurrently:

- **In-session Claude panelist(s)** (any slot with no `@`, or explicitly `@claude`) → the `Agent` tool,
  `subagent_type: general-purpose` (web + bash built in). For `claude-claude`, spawn **two** independent
  Claude subagents with the *same* prompt — two cold runs. For every other panel, spawn **one** Claude
  subagent per `@claude` slot alongside the other panelists. Spawn them in the same message so they run at
  once. When each returns, write its answer to a temp file for provenance: `/tmp/z3fusion_opusA.md` (and
  `/tmp/z3fusion_opusB.md` for a second Claude run, etc.).

  **Normalize the relay before trusting it — a completed Claude panelist can return a sentinel, and
  the harness can dress that sentinel up as an answer.** An `Agent` call can come back
  `status: completed`, with real token spend and real tool use, while the text relayed to you is just
  `Idle.` (observed cause: a `SubagentStop` hook re-waking an already-finished subagent until its last
  message degenerates; the Agent tool returns that last message). Worse, the harness wraps that relay in
  its own bookkeeping — a `SECURITY WARNING:` block, the `agentId: … (use SendMessage …)` trailer, a
  `<usage>` element — all glued onto the **same line**, which makes a 700-char blob that *looks* like an
  answer and is not. The real answer is **not lost** — it is in the subagent's own transcript. Never
  treat this as an empty panelist.

  **Always run this once per Claude panelist, before the judge sees anything:**

  ```bash
  # Write the Agent tool's relayed text to a file first, then normalize it. This single call
  # strips harness wrappers, classifies the ANSWER (not the envelope), recovers the completed
  # task output when the answer is degenerate, and writes the CANONICAL panel result.
  python <skill_dir>/scripts/claude_relay.py normalize \
    --file "$fusion_run_dir/opusA_relay.md" \
    --agent-id <agentId from the Agent result> --agent-status completed \
    --out "$fusion_run_dir/opusA_out.md"
  # exit 0 -> opusA_out.md holds a validated answer (normal, or recovered)
  # exit 1 -> no usable answer exists; only now fail this panelist
  ```

  Wrappers are stripped structurally and anchored to the shapes the harness actually emits, so an answer
  that merely *discusses* a security warning, an agent or a tool is never touched. After stripping, the
  answer is suspicious when it is empty, whitespace-only, `Idle.` / `No action.` or another bare status
  sentinel, a wake-up reply ("No new input received…"), harness metadata only, or implausibly short.
  Recovery is keyed on the `agentId` the Agent tool reported — never a reconstructed path — and refuses
  to read anything unless the agent actually completed, so a still-running agent is never scraped for
  partial output.

  `normalize` writes `<out>.provenance.json` with `relay_wrapper_detected`, `relay_wrapper_type`,
  `relay_classification` (`normal`/`suspicious`), `relay_anomaly`, and `result_transport`
  (`normal` or `recovered-task-output`). When wrappers were stripped from an otherwise healthy relay, the
  untouched original is kept at `<out>.raw` — nothing is discarded silently. A panelist recovered this way
  is **healthy** and goes to the judge normally.

  (`classify` and `recover` remain available as separate steps for inspection; `normalize` is the one to
  use in the pipeline, because it cannot be half-followed.)

  Fail the Claude panelist **only** when the agent errored, timed out, or `normalize` exits non-zero (no
  completed output exists, or nothing in it passes validation). A sentinel alone is never sufficient
  grounds to drop the panelist — normalization and recovery run first.
- **Every other panelist slot** (`codex`, `agy`, `ollama`, `openrouter`, `lmstudio`, or any custom runner
  registered in `~/.claude/z3fusion-runners.json`) → write its prompt to a temp file, then call the generic
  dispatcher:
  ```bash
  fusion_run_dir="$(mktemp -d "${TMPDIR:-/tmp}/z3fusion-panel.XXXXXX")"
  bash <skill_dir>/scripts/run_panelist.sh <runner> <model> "$fusion_run_dir/<runner>_prompt.md" "$fusion_run_dir/<runner>_out.md" [effort]
  ```
  Allocate one unique `fusion_run_dir` per z3Fusion invocation and put every prompt/output file for that
  invocation under it. Never use fixed paths like `/tmp/z3fusion_codex_prompt.txt` or
  `/tmp/z3fusion_codex_out.md`; multiple Claude Code sessions can run z3Fusion concurrently, and fixed names let
  one run read another run's prompt or answer.

  `run_panelist.sh` is the single entry point every non-Claude panelist goes through; it dispatches to the
  right underlying runner for you:
  - `codex` runner (GPT family, or whichever model the slot names, e.g. `gpt-5.6-sol@codex`) → copies the
    current repo/workdir to a throwaway directory, then launches `codex exec` with full local access
    against that copy. This preserves the live checkout while letting the codex panelist use the same local
    tools and keychain-backed credentials as a trusted terminal Codex run. `-o` makes codex write only its
    final answer to the output file; read it once it finishes. The slot's model half is passed through to
    codex's own `--model` flag when non-empty, so you can point this runner at a different GPT-family model
    without changing anything else about the call.
  - `agy` runner (Gemini family, or whichever model the slot names) → calls `agy --print` with an
    **explicit `--model`, always**. The slot's model half is exported as `AGY_MODEL`; the runner normalizes
    a logical name to the exact runtime id `agy models` reports, so `gemini-3.1-pro@agy` (and the
    `claude-gemini3.1pro` preset) resolve to **`gemini-3.1-pro-high`**. agy's own configured default is
    never used, and no other Gemini tier is ever substituted: if the pinned model is not listed by
    `agy models`, the panelist fails with `required model unavailable: <model>` instead of running
    something else. Output uses a layered transport — `--output-format json` (native, preferred), then
    plain `--output-format text` if the structured output is unusable, then agy's own on-disk transcript as
    a Windows compatibility fallback for the historical empty-stdout behavior (agy bug #76, fixed in
    1.1.8). Each attempt runs in its own fresh workspace so the fallback can only ever read *that*
    attempt's conversation, and a transcript older than the attempt is rejected rather than accepted as the
    answer. `exit 0` with empty output is not success, and a non-zero exit is never masked by the
    fallback.

    The runner also applies a **bounded automatic retry**: if attempt 1 fails for a *transient* reason
    (a timeout, or an empty result that came with timeout evidence), it retries **once** at double the
    timeout in a completely fresh attempt directory and workspace — you no longer re-run it by hand at a
    larger `FUSION_TIMEOUT`. Deterministic failures are **never** retried, because a second attempt
    cannot change them: a routed-model mismatch, an unavailable pinned model, an authentication/quota
    rejection, a rejected stale transcript, or any error with no transient evidence. Two attempts
    maximum.

    Every Gemini prompt is prefixed with the **Gemini engineering governance** block (profile
    `karpathy-engineering-v1`, defined in `references/gemini_governance.md`) — see "Gemini governance"
    below. The runner writes `<output_file>.provenance.json` (`model`, `model_pin_verified`,
    `routed_model_label`, `exit_code`, `output_transport`, `conversation_id`, `attempts`,
    `attempt_1_status`, `attempt_1_exit_code`, `retry_reason`, `attempt_2_status`, `final_status`,
    `governance_profile`, `governance_injected`) and echoes the same one-liner on stdout.
  - `ollama` runner (any locally-pulled model, zero API key) → prefers the `ollama` CLI, piping the prompt
    on stdin and stripping ANSI/control bytes from the captured output; falls back to the local
    `http://localhost:11434/api/chat` REST endpoint if the CLI is absent or produced empty output.
  - any other runner name (`openrouter`, `lmstudio`, `openai`, `groq`, `together`, `fireworks`, `deepseek`,
    `mistral`, `xai`, `google`, or a custom entry from `~/.claude/z3fusion-runners.json`) → a generic
    OpenAI-chat-completions-compatible HTTP call, using that provider's base URL and (if required) API key
    from `providers.sh`. This is what makes "any OpenRouter-listed model" real: point a slot at
    `<model>@openrouter` (e.g. `deepseek/deepseek-v4-pro@openrouter`, `meta-llama/llama-4-maverick@openrouter`,
    `x-ai/grok-4@openrouter`) with `OPENROUTER_API_KEY` set, and it is a plain per-model HTTP call — this is
    the robust, verified path for "any provider" and needs nothing beyond a standard chat-completions body.
    `providers.sh` also carries an EXPERIMENTAL `extra_json` field (empty by default) that gets merged
    verbatim into that slot's request body; its intended, opt-in use is attaching OpenRouter's own native
    fusion plugin as a nested meta-panelist inside a single `openrouter` slot (see the Design reference
    note above and `providers.sh` itself for the exact merge point) — treat this as unverified/best-effort
    only, the plain per-model path above is what to reach for by default.

  Exit codes are uniform across every runner `run_panelist.sh` dispatches to, not just codex/agy: `127` =
  the runner's CLI/API/server is not available, or the runner name is unrecognized — drop that panelist;
  `124` = timed out (`FUSION_TIMEOUT`) — drop that panelist; any other non-zero exit = drop that panelist
  and note the panel downgraded; `0` = success (output file written, non-empty). This is the same
  exit-code-based graceful-degradation contract that previously applied only to codex/agy — it now applies
  identically to every runner, built-in or custom.

Keep panelists isolated: never paste one panelist's output into another's prompt. The orchestrating session
(you) is the judge and must stay separate from the panelists — for `claude-claude`, or any custom panel with
multiple `@claude` slots, every Claude panelist is a spawned subagent, not you, so your synthesis reads all
answers fresh.

**Graceful degradation.** If a panelist exits non-zero, remove it, record a one-line degradation note (e.g.
`gemini dropped: agy empty -> claude-gpt5.6`, or `llama4@ollama dropped: ollama unreachable (127)`), and
continue with what's left. For the legacy presets, the fallback order is:
`claude-gpt5.6-gemini3.1pro` → `claude-gpt5.6` → ultimate `claude-claude` (two independent in-session Claude
runs, zero external CLI). For `claude-gemini3.1pro`, dropping Gemini falls back to `claude-claude` (spawn a
second independent Claude panelist) so the judge still sees two blind answers. For a custom `--models`
panel, the same rule applies generically: drop any failed slot, note the degradation, and continue with
whatever panelists remain. A degraded run still completes; never abort because one runner failed.

**Heavy Gemini execution (hours, not minutes).** For a mission that legitimately runs for hours —
repository-wide analysis, frontend implementation, iterative coding/testing/debugging — set
`Z3F_GEMINI_HEAVY=1`. It is **off by default** (`Z3F_GEMINI_HEAVY:-0`), so nothing below happens unless
you ask for it: a plain `/z3fusion-gemini` run is the synchronous path with the 2-attempt policy above,
not an 8-hour mission. `run_gemini.sh` then delegates to `scripts/gemini_heavy.sh`, which runs an attempt
lifecycle instead of one synchronous call:

```
ATTEMPT-01 (up to TTK, default 8h)
   ├── completes ............ canonical = attempt-01. No attempt-02, no fusion. (fast path)
   ├── reaches TTK .......... checkpoint + seal → ATTEMPT-02 (fresh context, same mission) → FUSION
   └── deterministic failure  abort. A pin mismatch or auth rejection cannot be fixed by
                              spending another 8 hours.
```

> **Scope — heavy mode is `agy`-only, deliberately.** There is no `codex_heavy.sh` or generic detached
> supervisor. The lifecycle above is not portable as written: its attempt-02 handoff is only safe because
> attempt-01's process tree is *proven* dead first, and that proof enumerates `agy.exe` by name
> (`_snapshot_agy`, `_kill_recorded`) on the back of a measured fact — a real `agy.exe` survives its
> supervisor being SIGKILLed. The equivalent topology for `codex` under
> `--dangerously-bypass-approvals-and-sandbox`, or for a local Ollama server, has not been measured. Porting
> the supervisor without that measurement would risk two attempts editing the same working tree at once,
> which is the exact corruption this file exists to prevent. Every other runner gets the synchronous
> 2-attempt policy in Step 1 and nothing more. Generic `Z3F_HEAVY_TTK` / `Z3F_HEAVY_MAX_ATTEMPTS` spellings
> are accepted as aliases (the `Z3F_GEMINI_*` names still win) so a future supervisor can share the
> vocabulary — but today they configure the Gemini path only.

**TTK is a handoff boundary, not a mission abort.** When an attempt hits its time-to-kill it is sealed
with status `ttk-checkpoint`, its process tree is terminated, and the mission proceeds to a fresh
attempt. Reaching TTK is never itself a failure. Whatever the attempt did manage to write is preserved
as its output and fused in on merit; a checkpoint still proves which model produced it, because the
routed label is read back from the attempt's preserved agy log (a timed-out attempt never reaches the
runner's own post-run routing check).

> **Known limitation — a TTK kill recovers no partial work on agy 1.1.9.**
> agy flushes model turns to its transcript **only at completion**, not incrementally. Measured
> directly: 112s into a real generation the conversation's transcript still held only `USER_INPUT` and
> `CONVERSATION_HISTORY`, and a short run's `PLANNER_RESPONSE` appeared only *after* the process
> exited. `--output-format stream-json` does not help — over 181s of real generation it emitted
> `init` / `step_update` / `result` state events and **zero answer prose**; the text exists only in the
> terminal `result` event, which never arrives if the process is killed.
>
> So an attempt killed at TTK has nothing on disk to recover, and its checkpoint is legitimately empty.
> The checkpoint machinery is correct and will preserve partial work on any backend that flushes
> incrementally, but on agy 1.1.9 the practical consequence is that **an 8-hour attempt that reaches
> TTK yields nothing**, and the mission's value rests entirely on an attempt completing within TTK.
> An earlier version of this document claimed the opposite ("accumulates model turns during a run,
> verified live"); that claim was wrong — it was read from a previous conversation's transcript.

**Attempts are isolated.** Each writes only inside its own artifact directory
(`~/.claude/z3fusion-runs/jobs/<job-id>/gemini/attempt-0N/`), is sealed by a `status.json` written exactly
once, and never shares a live output file. The canonical result is produced only by the fusion stage. A
late-finishing attempt-01 therefore cannot overwrite attempt-02, the fusion output, or the canonical
answer.

**Long runs survive the caller.** The lifecycle runs under a detached supervisor with a heartbeat file, so
it is not bounded by the ~10 minute limit on a foreground tool call. `run` waits up to `Z3F_WAIT_SECONDS`
(default 540) and then exits **75** — meaning *still running, re-invoke to re-attach*, not failure.
Re-invoking the same mission re-attaches to the same job (the job id is a hash of the mission prompt)
rather than launching a second execution. "The caller stopped waiting" and "Gemini stopped running" are
different states and are tracked separately.

Fusion is a third pinned, routing-verified, governed Gemini call. It is **not** the panel judge — it
produces the Gemini *slot's* single answer, which then goes to the orchestrating Claude session as one
panelist among several. The panel judge is unchanged.

**Gemini governance (profile `karpathy-engineering-v1`).** Gemini panelists run under a durable
behavioral profile: think before coding, simplicity first, surgical changes, goal-driven execution,
evidence over confidence, panel independence, no silent requirement drift, verify before claiming
success. It is defined **once**, in `references/gemini_governance.md`, and injected **once**, by
`scripts/run_gemini.sh`, which is the single point every Gemini execution path passes through
(`/z3fusion-gemini`, the Gemini slot of `/z3fusion-3`, and any `<model>@agy` slot of `/z3fusion --models`
all reach agy via `run_panelist.sh` → `run_gemini.sh`). Do not paste the block into a command file or a
panel prompt — a prompt that already carries the profile marker is passed through untouched, so the block
appears exactly once either way.

The block is a **preamble**: the user's task follows it and stays authoritative about *what* to produce;
the governance only constrains *how* the panelist works. It explicitly tells the panelist to resolve minor
ambiguity by stating an assumption and continuing, so it never turns uncertainty into a refusal. It
applies to Gemini only — Claude and Codex panelists are untouched. Each Gemini run records
`governance_profile` and `governance_injected` in its provenance. If the governance file is missing the
runner **fails closed** (exit 2) rather than running an ungoverned panelist.

## Step 3 — Judge (pick the track that fits the task)

Once every panelist has returned, read `references/judge_rubric.md` and **classify the deliverable first**,
because code and prose merge completely differently:

- **Artifact task** (code, script, config, Minecraft mod/datapack, schema — the user wants a buildable
  thing) → **Track A: run both, then merge**. You are integrating two *implementations* into one working
  program, not writing a report. **Run each candidate with bash first** to see what actually works and what
  breaks in each, decide what to keep based on observed behavior (not on which looks better), graft the
  parts that worked onto the stronger base, then **run the merged result and fix until it passes**. The
  panel's value here is that two independent attempts expose each other's bugs — running both is how you
  find which one is actually right, so the merge ends up **more correct than either input**. (If it truly
  can't be executed here — needs the live game or an unavailable toolchain — fall back to seam-reasoning
  and mark it unverified.)
- **Research / analysis task** (the user wants understanding or a recommendation) → **Track B: structured
  synthesis** — the five sections: **Consensus**, **Contradictions**, **Partial coverage**, **Unique
  insights**, **Blind spots**. Don't average or smooth over conflict; independent agreement is your
  highest-confidence signal, honest disagreement is the most useful thing the panel produces. Write this
  analysis to `/tmp/z3fusion_analysis.md` for the provenance record.

Either way: attribute decisions to each panelist (by model / run), and weight a panelist that actually ran
the code or read a primary source over one reasoning from memory. If a panelist failed or was dropped, the
judge treats it as **absent** — never as silent agreement.

## Step 4 — Final deliverable

- **Track A (code/artifact):** emit the complete, merged artifact — every file, ready to run as-is, not a
  diff or "take A's X and B's Y." Per `judge_rubric.md`, you got here by **running both candidates** and
  keeping what worked, and you **run the merged result and fix it until it passes** before presenting.
  Follow with a tight merge rationale: what each candidate did when run, what you took from each, and what
  you verified.
- **Track B (research):** write the answer grounded in the structured analysis — lead with high-confidence
  consensus, fold in unique insights, flag what stays uncertain. It must follow *from* the synthesis, not
  be one panelist's answer lightly edited. Write it to `/tmp/z3fusion_final.md` for the provenance record.

## Step 5 — Save provenance

Save the run to an internal provenance file under `~/.claude/z3fusion-runs/` (raw panelist answers + the
analysis + the final answer, timestamped, for auditing):

```bash
FUSION_PANEL_NOTE="<degradation note, or empty>" \
FUSION_ESTIMATE="<the preflight one-liner, optional>" \
bash <skill_dir>/scripts/save_run.sh <SLUG> /tmp/z3fusion_question.txt /tmp/z3fusion_analysis.md /tmp/z3fusion_final.md \
  "opus-A=/tmp/z3fusion_opusA.md" "gpt5.6=$fusion_run_dir/codex_out.md" "gemini=$fusion_run_dir/gemini_out.md"
```

(`save_run.sh` substitutes a placeholder for any answer file that is missing or empty, so a degraded panel
still produces a complete record.) Runners that wrote a `<answer_file>.provenance.json` — the `agy` runner
always, a Claude panelist whenever its relay had to be recovered — record how that answer actually reached
you; fold those fields into the run note so the record says which model really answered and over which
transport. The fields are: `model` / `requested_model` / `model_pin_verified` / `routed_model_label` /
`runtime_backend` / `exit_code` / `output_transport` (`json`, `stdout-text`,
`windows-transcript-fallback`) / `attempts` / `attempt_1_status` / `attempt_1_exit_code` /
`retry_reason` / `attempt_2_status` / `final_status` / `governance_profile` / `governance_injected` for
`agy`, and `result_transport` (`normal` or `recovered-task-output`) / `relay_classification` /
`relay_anomaly` / `relay_wrapper_detected` / `relay_wrapper_type` for a Claude panelist. If a Gemini
panelist needed its automatic retry, or a Claude relay had a harness wrapper stripped or had to be
recovered, put that in the degradation note — those are facts about the run, not implementation details.
For a custom `--models` panel, pass one `label=path` pair per panelist
actually launched — label each with its `model@runner` slot (e.g. `llama4@ollama=$fusion_run_dir/ollama_out.md`)
instead of the legacy `opus-A`/`gpt5.6`/`gemini` labels above.

## Step 6 — Present

Lead with the **final deliverable** — the merged working artifact (Track A) or the grounded answer
(Track B). Then, **before** the analysis, show what each panelist actually said, by running:

```bash
bash <skill_dir>/scripts/render_raw_panel.sh \
  "opus-A=$fusion_run_dir/opusA_out.md" "gemini=$fusion_run_dir/gemini_out.md"
```

Paste its output **verbatim**. It prints a delimited `RAW PANEL OUTPUTS` section: per panelist, the model
identity, backend, whether the model pin was verified and which transport the answer arrived on (read from
the runner's own provenance, never from claims made in the answer text), followed by that panelist's
canonical answer. Then write your own `JUDGE / SYNTHESIS` heading and put the analysis under it, so the
three layers stay visibly distinct:

```
==================================================
RAW PANEL OUTPUTS          <- verbatim, from render_raw_panel.sh
==================================================
...
==================================================
END RAW PANEL OUTPUTS
==================================================

==================================================
JUDGE / SYNTHESIS          <- your analysis and final answer
==================================================
```

Why this is mandatory: a result that only *summarizes* a panelist is unauditable — the operator cannot
tell a real disagreement from a judge's paraphrase, and a panelist that was factually wrong looks the same
as one that was right. **Do not paraphrase raw panel answers in that section.** It reads the canonical
result file, so a recovered Claude panelist shows its recovered answer and never the sentinel it replaced.
An answer past the preview budget is shown truncated **explicitly**, naming the character count and the
on-disk artifact that still holds it in full — never silently shortened. Never include a panelist's hidden
reasoning or scratch state; only the answer it actually returned.

Finish with the rest of the audit trail: for code, what each candidate did when run + the merge rationale
+ what you verified; for research, the five-section analysis. Name the panel slug (or the composed
`--models` list) you ran and which panelists participated. If the panel downgraded because a
CLI/server/key was missing, say so and how to enable the fuller panel (install the missing CLI, start the
local server, or set the missing API key). Disclose run anomalies too — a Gemini retry, a stripped harness
wrapper, a recovered relay.

## Cost & latency note

A panel costs roughly N× a single answer in tokens and runs as slow as its slowest panelist. That's the
deliberate trade: you spend more to stop being confidently wrong where that's expensive. For quick or
low-stakes questions, a single direct answer is the right call — don't reach for z3Fusion when one model
would obviously do.
