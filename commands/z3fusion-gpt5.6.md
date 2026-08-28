---
description: z3Fusion panel of an in-session Claude panelist + GPT-5.6 Sol in parallel, judged by the orchestrating Claude Code session (claude-gpt5.6)
argument-hint: <your question>
---
Invoke the **z3fusion** skill on the task below, forcing the `claude-gpt5.6` legacy panel
(the codex slot is hard-pinned to model slug **`gpt-5.6-sol`** — the bare `gpt-5.6` is rejected by
codex on a ChatGPT account and silently drops this panelist):
an in-session Claude panelist (Agent subagent) and GPT-5.6 Sol (via `codex exec`) answer the SAME prompt IN
PARALLEL, each independently with web + bash and neither seeing the other's work → the orchestrating Claude
Code session judges both answers and writes the final answer grounded in the analysis.

Follow the skill's SKILL.md exactly (fan out in parallel → judge → grounded final answer) and present the
standard sections (Consensus / Contradictions / Partial coverage / Unique insights / Blind spots / Final
answer). Use exactly one in-session Claude panelist and one GPT-5.6 Sol panelist — do not add a Gemini panelist
or a second in-session Claude panelist. Pass the task verbatim to both; no "lenses". If the `codex` CLI is
not installed, stop and say so rather than silently downgrading to the claude-claude panel.

For a custom panel beyond this fixed 2-model preset — any mix of models, providers, or local runners — use
`/z3fusion --models <model@runner,...> :: <question>` instead.

Task: $ARGUMENTS
