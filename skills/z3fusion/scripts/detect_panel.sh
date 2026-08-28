#!/usr/bin/env bash
# detect_panel.sh — figure out which panelist CLIs/APIs are reachable and recommend a z3Fusion panel.
#
# z3Fusion fans a prompt out to a panel of models in parallel, then the orchestrating Claude Code session
# (whichever model it is actually running as) judges. An in-session Claude panelist is always available
# via the Agent tool (in-process subagents), and the orchestrating session is always the judge — so
# neither needs a CLI check.
#
# This script does two things now:
#   1. (legacy, unchanged logic) Probes just the two original external panelist CLIs — GPT-5.6 Sol via
#      codex, Gemini 3.1 Pro via agy / Antigravity — and prints a final `SLUG=...` line the orchestrator
#      greps for. Same shape as always: 4 possible SLUG values (claude-claude, claude-gpt5.6, claude-gemini3.1pro, claude-gpt5.6-gemini3.1pro), same precedence,
#      so existing commands/*.md files that grep for SLUG= keep working unmodified.
#   2. (new) ALSO probes every other runner the generic dispatcher (run_panelist.sh) can reach — local
#      runtimes (ollama, LM Studio) and hosted OpenAI-compat providers gated on an API key env var — and
#      prints a "RUNNERS AVAILABLE:" table plus a composable "--models ...@runner,...@runner" example, so
#      a caller knows a z3Fusion panel is not limited to the 4 legacy slug presets.
#
# NOTE (unverified in this environment): the localhost reachability probes (ollama server, LM Studio
# server) are best-effort — curl is given a short --max-time so a dead/firewalled port fails fast
# instead of hanging this script. No external CLI/API in this table is actually installed/reachable in
# this environment, so none of this has been exercised end to end.

have() { command -v "$1" >/dev/null 2>&1; }

# _http_ok URL — true if curl can reach URL with a 2xx/3xx-ish response, within 2s. Never hangs the
# script waiting on a dead/firewalled local port. Treated as "not reachable" (not a hard error) if
# curl itself isn't installed.
_http_ok() {
  have curl || return 1
  curl -sf --max-time 2 "$1" >/dev/null 2>&1
}

# _env_set VAR_NAME — true if the named env var is set AND non-empty.
_env_set() {
  local name="$1"
  [ -n "${!name:-}" ]
}

# ---------------------------------------------------------------------------------------------
# 1. Legacy probe (unchanged): codex + agy -> one of the 4 original SLUG presets.
# ---------------------------------------------------------------------------------------------
codex_ok=false; agy_ok=false
have codex && codex_ok=true
have agy   && agy_ok=true

echo "panelist availability (an in-session Claude subagent is always a panelist; the orchestrating"
echo "session is always the judge, via Agent subagents):"
echo "  claude   : yes (Agent subagents — always available)"
printf "  gpt5.6   : %s (codex CLI)\n"      "$([ "$codex_ok" = true ] && echo yes || echo NO)"
printf "  gemini3.1pro : %s (agy CLI)\n"    "$([ "$agy_ok"   = true ] && echo yes || echo NO)"
echo

if   $codex_ok && $agy_ok; then slug="claude-gpt5.6-gemini3.1pro"
elif $agy_ok;              then slug="claude-gemini3.1pro"
elif $codex_ok;            then slug="claude-gpt5.6"
else                            slug="claude-claude"
fi

echo "recommended panel (legacy 4-preset system): $slug"
echo

# ---------------------------------------------------------------------------------------------
# 2. New probes: local runtimes + hosted OpenAI-compat providers reachable via run_panelist.sh.
# ---------------------------------------------------------------------------------------------
ollama_cli_ok=false; have ollama && ollama_cli_ok=true
ollama_server_ok=false; _http_ok "http://localhost:11434/api/tags" && ollama_server_ok=true
if $ollama_cli_ok || $ollama_server_ok; then ollama_ok=true; else ollama_ok=false; fi

lmstudio_ok=false; _http_ok "http://localhost:1234/v1/models" && lmstudio_ok=true

# name:env_var pairs for the built-in hosted OpenAI-compat providers (see providers.sh).
hosted_providers="
openrouter:OPENROUTER_API_KEY
ollama-cloud:OLLAMA_API_KEY
openai:OPENAI_API_KEY
groq:GROQ_API_KEY
together:TOGETHER_API_KEY
fireworks:FIREWORKS_API_KEY
deepseek:DEEPSEEK_API_KEY
mistral:MISTRAL_API_KEY
xai:XAI_API_KEY
google:GOOGLE_API_KEY
"

echo "RUNNERS AVAILABLE (via run_panelist.sh's \"model@runner\" slot syntax):"
printf "  %-12s %-4s  %s\n" "codex" "$([ "$codex_ok" = true ] && echo yes || echo NO)" \
  "$($codex_ok && echo "codex CLI on PATH" || echo "missing: codex CLI not found on PATH")"
printf "  %-12s %-4s  %s\n" "agy" "$([ "$agy_ok" = true ] && echo yes || echo NO)" \
  "$($agy_ok && echo "agy CLI on PATH" || echo "missing: agy CLI not found on PATH")"
printf "  %-12s %-4s  %s\n" "ollama" "$([ "$ollama_ok" = true ] && echo yes || echo NO)" \
  "$($ollama_ok && echo "ollama CLI and/or local server reachable" || echo "missing: no ollama CLI on PATH and no server at localhost:11434")"
printf "  %-12s %-4s  %s\n" "lmstudio" "$([ "$lmstudio_ok" = true ] && echo yes || echo NO)" \
  "$($lmstudio_ok && echo "LM Studio local server reachable" || echo "missing: no local server at localhost:1234")"

for pair in $hosted_providers; do
  name="${pair%%:*}"
  env_var="${pair#*:}"
  if _env_set "$env_var"; then
    printf "  %-12s %-4s  %s\n" "$name" "yes" "$env_var is set"
  else
    printf "  %-12s %-4s  %s\n" "$name" "NO" "missing: $env_var is not set"
  fi
done

printf "  %-12s %-4s  %s\n" "ollama-api" "$([ "$ollama_ok" = true ] && echo yes || echo NO)" \
  "REST spelling of ollama's OpenAI-compat endpoint (localhost:11434/v1) — same server as 'ollama' above"
echo

# A NO on the ollama-cloud row above means only that the REST transport has no key. It does NOT
# mean hosted Ollama models are out of reach: the local CLI signs in to Ollama Cloud itself, so a
# ":cloud"-tagged model runs through the keyless 'ollama' runner. Without this note the table
# reads as "hosted Ollama unavailable" when it is in fact one slot spelling away.
if [ "$ollama_ok" = true ]; then
  echo "note: hosted Ollama models do NOT require OLLAMA_API_KEY — a \":cloud\" tag routes to Ollama's"
  echo "      cloud through the signed-in local CLI, i.e. the keyless 'ollama' runner:"
  echo "        --models opus@claude,deepseek-v4-flash:0731-cloud@ollama"
  echo "      The 'ollama-cloud' runner above is the keyed REST transport for the same models."
  echo
fi

echo "custom panel example (any mix, not limited to the 4 legacy slugs):"
echo "  --models opus@claude,gpt-5.6-sol@codex,llama4@ollama,deepseek/deepseek-v4-pro@openrouter"
echo
echo "register more runners (custom HTTP providers or non-HTTP command templates) in:"
echo "  ~/.claude/z3fusion-runners.json   (see providers.sh's header comment for the exact shape)"
echo

# Legacy grep target — keep this line last and in this exact "SLUG=..." shape.
echo "SLUG=$slug"
