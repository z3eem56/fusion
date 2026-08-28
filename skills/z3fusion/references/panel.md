# The panel

z3Fusion's power comes from **independent answers, synthesized** — not from a clever prompt or assigned
personas. You dispatch the same question to several models at once, each works the problem cold with no
knowledge of the others, and a judge fuses their answers. Independent agreement is high-confidence;
independent disagreement is exactly the signal worth surfacing.

## No lenses, no personas

Do not assign panelists "roles" or "stances" (skeptic, optimizer, first-principles, etc.). That biases
*how* each one reasons artificially and corrupts the very independence that makes the panel work. Pass
every panelist the user's task **verbatim** and let each answer it straight.

The diversity is already there for free. Running the same prompt independently produces different
reasoning paths, different tool calls, and different source selections — even when it's the *same model
answering twice*. (Two independent runs of the same model, synthesized by the judge, beat a single run of
that model by a wide margin precisely because of this — and the effect compounds further once the
panelists are genuinely different models from different providers.) You don't manufacture diversity; you
harvest it from independence.

## Independence is the rule

Panelists must never see each other's work. Don't show one panelist another's answer, and don't let the
orchestrator pre-digest or summarize the task before handing it over. The judge is the only place the
answers meet. Cross-pollination before the judge defeats the entire mechanism.

## Panel composition per slug

z3Fusion panels are composable: any 1 to 8 panelists, drawn from any provider, in any combination, using the
slot syntax `model@runner` (a bare `model` with no `@` means an in-session Claude Agent-tool subagent —
`@claude` is the explicit spelling of the same thing). A panelist can be an in-session Claude subagent, a
model reached through a CLI (`codex` for OpenAI models, `agy` for Google models), a fully local model
(Ollama, LM Studio, or any other OpenAI-compatible local server), or any model listed on OpenRouter or
another OpenAI-compatible provider. Nothing about the mechanism — independence, no lenses, one judge —
depends on which models, how many, or which providers end up in the panel.

Four presets exist as convenience defaults, not as the boundary of what's possible:

- `claude-claude` — the **same prompt run twice** as two independent in-session Claude panelists (Agent
  subagents), then judged. Same model, two cold runs.
- `claude-gpt5.6` — an in-session Claude panelist and GPT-5.6 Sol (codex) answer **in parallel**, then judged.
- `claude-gemini3.1pro` — an in-session Claude panelist and Gemini 3.1 Pro (agy) answer **in parallel**,
  then judged.
- `claude-gpt5.6-gemini3.1pro` — an in-session Claude panelist, GPT-5.6 Sol, and Gemini 3.1 Pro answer in
  parallel, then judged.

These four are legacy presets, kept for convenience — not a ceiling. Any other composition is equally
valid: for example, a custom panel of `@claude` (in-session), `gpt-5.6-sol@codex`, and `llama4@ollama` mixes
a hosted frontier model with a fully local, zero-API-key model running on the user's own machine — useful
when part of the question shouldn't leave the box, or when a specific model outside the four presets is
the right fit.

In every case the orchestrating Claude Code session — whichever model is actually running that session —
is also the judge/synthesizer, kept separate from the panelists (the panelists are spawned or invoked; the
orchestrating session judges) so the synthesis reads the answers fresh rather than defending one it wrote
itself. The orchestrating session always judges and writes the final answer — the pipeline can't be
reversed, since panelist models can't call back out to spawn the orchestrator. This is a real, stated scope
boundary, not an oversight: the panel is freely composable (any 1 to 8 models, any provider) — the judge is
not; it is always, and only, whichever model is running the z3Fusion session.

## Prompt each panelist gets

Each panelist receives the user's task **verbatim**, plus a short instruction: *research with web search
and bash, then return a complete, self-contained answer; you are one of several independent experts and
will not see the others' work.* Nothing more — no lens, no framing that nudges the conclusion.
