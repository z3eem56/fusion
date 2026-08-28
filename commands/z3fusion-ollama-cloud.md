---
description: z3Fusion panel of an in-session Claude panelist + an Ollama Cloud model (default glm-5.3-flash:cloud) in parallel, judged by the orchestrating Claude Code session
argument-hint: "[--model <ollama-cloud-model> | --model ? | --list] [<your question>]"
---
Invoke the **z3fusion** skill on the task below with a two-slot panel: one in-session Claude panelist
(Agent subagent) and one **Ollama Cloud** panelist answer the SAME prompt IN PARALLEL, neither seeing the
other's work → the orchestrating Claude Code session judges both and writes the final answer grounded in
the analysis.

**Parse `$ARGUMENTS` first, before doing anything else:**

Check these in order; the first match wins.

- If it starts with `--list`, or with `--model ?`, run the model picker below **before** dispatching
  anything. Whatever follows is the task. If nothing follows, show the list and stop — no panel runs.
- Otherwise, if it starts with `--model` followed by a value, that value is the model and everything after
  it is the task. Example: `--model kimi-k3:cloud Explain X` → model = `kimi-k3:cloud`, task = `Explain X`.
- Otherwise the whole of `$ARGUMENTS` is the task and the model is the default
  **`glm-5.3-flash:cloud`**.

## Choosing the Ollama Cloud model

The default is silent — it never prompts. Choice is opt-in, two ways:

1. **Name it:** `--model <tag>` is passed through verbatim (see the pass-through rule below).
2. **Pick it:** `--model ?` or `--list` — enumerate what this machine already knows about with
   `ollama list | awk 'NR>1 && $1 ~ /cloud/ {print $1}'` and present it as a **numbered list of tags**,
   the default marked as such, and let the user reply with one. Do not reach for `AskUserQuestion` here:
   it takes at most 4 options and this list is normally longer. It fits only once the choice is already
   narrowed to three or fewer. Use the answer as the model for this run only; nothing is written back as
   a new default.
   Match on `cloud` anywhere in the tag, not on a trailing `:cloud` — hosted tags also come in the
   `<model>:<variant>-cloud` shape (`deepseek-v4-flash:0731-cloud`, `gemma4:31b-cloud`), and a
   `:cloud`-only filter silently drops them.

Two things the picker must state, because both are easy to get wrong:

- `ollama list` shows only the cloud tags **already registered on this machine** — it is not the Ollama
  Cloud catalog, and it will be missing models that exist. Any other tag can still be used: `ollama show
  <tag>` resolves a Cloud model that has never been pulled here, and a successful `show` means the tag is
  usable in a panel.
- **A cloud model needs its explicit cloud tag.** `glm-5.3-flash:cloud` resolves; bare `glm-5.3-flash`
  becomes `glm-5.3-flash:latest` and 404s (`Error: model 'glm-5.3-flash:latest' not found`). Most are
  `:cloud`, some are `:<variant>-cloud`. Do not auto-append anything — model names are not rewritten
  (below) — but do say which tag to use when a user's bare name fails.

## Transport — use the signed-in CLI, not the keyed REST endpoint

Ollama Cloud is reachable two different ways, and they have different prerequisites. **Default to the
first.**

| Slot spelling | Path | Needs | Verified on this machine |
| --- | --- | --- | --- |
| `<model>@ollama` | local `ollama` CLI, already signed in to Ollama Cloud | nothing | ✅ `glm-5.3-flash:cloud` returned a real answer, exit 0 (also verified: `kimi-k3:cloud`) |
| `<model>@ollama-cloud` | REST `https://ollama.com/v1` | `OLLAMA_API_KEY` | ❌ key not set — exits 127 |

A `:cloud`-tagged model is served by Ollama's cloud even when invoked through the local CLI, so the
`@ollama` slot gets the hosted model **without any API key**. Dispatch that, in the same turn as the
Claude subagent so both run concurrently:

```bash
bash <skill_dir>/scripts/run_panelist.sh ollama "<MODEL>" <prompt_file> <output_file>
```

Only use `run_panelist.sh ollama-cloud "<MODEL>" …` if the user explicitly asks for the REST transport or
the CLI path is unavailable — and check `OLLAMA_API_KEY` is set before you do, because without it that
path exits 127 immediately.

This command deliberately uses the composable slot mechanism rather than a dedicated legacy slug. Do not
invent a fifth slug for it; the panel is exactly `<in-session Claude subagent>, <MODEL>@ollama`.

**Attempt policy (inherited, not restated in the prompt):** attempt 1 at `FUSION_TIMEOUT` (300s), one
retry at 600s if — and only if — the failure was transient. A model that does not exist, an auth
rejection, or a missing CLI never retries. Exit 127 = ollama unreachable; 124 = timed out; 1 = other
failure or empty answer. A `:cloud` model is a large hosted model behind a local CLI call: if the task is
heavy, raise the budget (`FUSION_TIMEOUT=600`) rather than accepting a timeout — but note 600s is the
harness ceiling for a single Bash call.

**Model names are passed through verbatim and are not rewritten.** If the provider rejects one as unknown,
report its own error rather than guessing at a corrected slug. `ollama list` shows what is already pulled
locally; `ollama show <model>` resolves a tag that is not yet pulled.

**Degradation:** if the Ollama panelist fails or times out, drop it, record a one-line degradation note,
and fall back to `claude-claude` (spawn a second independent in-session Claude panelist) so the judge still
sees two blind answers. Never abort because one runner failed, and never present a one-panelist run as if
it were a fusion result.

Follow the skill's SKILL.md exactly (preflight → fan out in parallel → judge picking the track that fits
the task → grounded final deliverable → save provenance → present). For a research/analysis task present
the standard sections (Consensus / Contradictions / Partial coverage / Unique insights / Blind spots /
Final answer); for a code/artifact task run both candidates and merge them into one working result with a
merge rationale. Pass the task verbatim to both panelists; no "lenses". Use exactly one in-session Claude
panelist and one Ollama panelist — do not add a GPT-5.6 Sol or Gemini panelist.

Always run `scripts/claude_relay.py normalize --file <relay> --agent-id <agentId> --agent-status completed
--out <canonical>` on the Claude panelist's `Agent` result before judging (SKILL.md Step 2) — a completed
subagent can relay `Idle.` or a sentinel wrapped in a `SECURITY WARNING:` block plus an `agentId:`/`<usage>`
trailer that makes it *look* like an answer. Normalize strips the harness envelope and recovers the real
output; a recovered panelist is healthy and goes to the judge like any other.

Present per SKILL.md Step 6: the deliverable, then a verbatim `RAW PANEL OUTPUTS` section from
`scripts/render_raw_panel.sh`, then your `JUDGE / SYNTHESIS` section. Do not paraphrase a panelist's
answer in the raw section. Note that the thinking-capable cloud models — `glm-5.3-flash:cloud` and
`kimi-k3:cloud` among them — emit a `Thinking... / ...done thinking.` preamble before their answer; that is
the model's own output and stays verbatim in the raw section, and the judge reads past it.

For a panel beyond this two-slot preset — more slots, other providers, a mix of local and hosted — use
`/z3fusion --models <model@runner,...> :: <question>` instead. Remember that `model@ollama` with a plain
tag (e.g. `llama4`) stays entirely on this machine, while a `:cloud` tag reaches Ollama's servers through
the same runner.

Raw input (parse per the rules above before treating any of it as the task): $ARGUMENTS
