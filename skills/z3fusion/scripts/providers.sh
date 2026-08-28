#!/usr/bin/env bash
# providers.sh — resolves a runner name to an OpenAI-chat-completions-compatible HTTP
# endpoint, for run_openai_compat.sh. Sourced (not executed), same convention as
# _fusion_lib.sh:
#
#   source "$SCRIPT_DIR/providers.sh"
#   if provider_lookup "$runner"; then
#     ...use $PROVIDER_BASE_URL / $PROVIDER_API_KEY_ENV / $PROVIDER_EXTRA_JSON...
#   fi
#
# provider_lookup <runner_name>
#   Sets three globals (always reset at the top of the call, even on a miss):
#     PROVIDER_BASE_URL     - e.g. https://openrouter.ai/api/v1
#     PROVIDER_API_KEY_ENV  - name of the env var holding the bearer token, or "" for a
#                              local no-auth server (send no Authorization header at all)
#     PROVIDER_EXTRA_JSON   - raw JSON object string to shallow-merge into the request body,
#                              or "" if none (see run_openai_compat.sh for how it's used)
#   Returns 0 if the runner name is recognized (built-in table or a user override/addition
#   from ~/.claude/z3fusion-runners.json), 1 if not recognized.
#
#   NOTE: provider_lookup ONLY ever inspects the top-level "providers" object of
#   z3fusion-runners.json (see shape below). It deliberately does NOT look at "custom" —
#   those are non-HTTP shell-command templates, and run_panelist.sh checks that table
#   itself, directly, only after provider_lookup here has already returned 1. Matching a
#   "custom" entry from inside provider_lookup would make the caller try to POST to it as
#   if it were an HTTP endpoint, which is wrong.
#
# ---------------------------------------------------------------------------------------
# ~/.claude/z3fusion-runners.json (optional, user-editable; this comment block is the only
# spec for its shape — there is no separate schema doc):
#
#   {
#     "providers": {
#       "<runner-name>": {
#         "baseUrl": "https://example.com/v1",
#         "apiKeyEnv": "SOME_API_KEY",      // omit or "" => no auth header (local no-key server)
#         "extraJson": { "...": "..." }      // optional, shallow-merged into the request body
#                                             // (see run_openai_compat.sh's EXPERIMENTAL note)
#       }
#     },
#     "custom": {
#       "<runner-name>": {
#         "template": "some-cli --model {model} --in {prompt_file} --out {output_file}"
#       }
#     }
#   }
#
# User entries in "providers" override built-ins of the same name (e.g. you can point
# "openrouter" at a proxy, or override just the apiKeyEnv). "custom" entries are plain
# shell command-line templates for non-HTTP runners (arbitrary local CLIs); the three
# literal placeholders {model}, {prompt_file}, {output_file} are substituted by the caller
# (run_panelist.sh) with plain string replacement — no eval of user input beyond running
# the templated command line itself. NOTE: quote the placeholders in your template (e.g.
# `--in "{prompt_file}"`) — substitution is textual, so unquoted paths containing spaces
# (common on Windows) split into multiple arguments.
# ---------------------------------------------------------------------------------------
#
# NOTE (bash 3.2 compat): the built-in table below is deliberately a `case` statement, not
# an associative array (`declare -A` is bash-4+ only, and stock /bin/bash on macOS is still
# 3.2 — see the identical note in run_codex.sh).

# Prefer the rebranded config; fall back to the pre-rebrand filename so existing setups keep working.
if [ -z "${FUSION_RUNNERS_JSON:-}" ]; then
  if [ -f "$HOME/.claude/z3fusion-runners.json" ] || [ ! -f "$HOME/.claude/fusion-runners.json" ]; then
    FUSION_RUNNERS_JSON="$HOME/.claude/z3fusion-runners.json"
  else
    FUSION_RUNNERS_JSON="$HOME/.claude/fusion-runners.json"
  fi
fi

# Python fallback (same as _fusion_lib.sh, duplicated because this file is sourced standalone):
# Windows installs often expose only `python`, not `python3`.
FUSION_PY="${FUSION_PY:-$(command -v python3 || command -v python || echo python3)}"

provider_lookup() {
  local name="${1:-}"
  PROVIDER_BASE_URL=""
  PROVIDER_API_KEY_ENV=""
  PROVIDER_EXTRA_JSON=""

  if [ -z "$name" ]; then
    return 1
  fi

  local found=1   # 1 = not recognized yet; flips to 0 the moment anything matches

  # --- Built-in table -------------------------------------------------------------------
  local builtin_base="" builtin_key=""
  case "$name" in
    openrouter) builtin_base="https://openrouter.ai/api/v1";                builtin_key="OPENROUTER_API_KEY" ;;
    lmstudio)   builtin_base="http://localhost:1234/v1";                    builtin_key="" ;;
    ollama-api) builtin_base="http://localhost:11434/v1";                   builtin_key="" ;;
    # Ollama CLOUD — hosted, OpenAI-compatible, and unlike ollama-api it REQUIRES a key.
    # Distinct from the `ollama` runner (local CLI/REST) and from ollama-api (local server):
    # `model@ollama` stays on this machine, `model@ollama-cloud` leaves it.
    ollama-cloud) builtin_base="https://ollama.com/v1";                     builtin_key="OLLAMA_API_KEY" ;;
    openai)     builtin_base="https://api.openai.com/v1";                  builtin_key="OPENAI_API_KEY" ;;
    groq)       builtin_base="https://api.groq.com/openai/v1";             builtin_key="GROQ_API_KEY" ;;
    together)   builtin_base="https://api.together.xyz/v1";                builtin_key="TOGETHER_API_KEY" ;;
    fireworks)  builtin_base="https://api.fireworks.ai/inference/v1";      builtin_key="FIREWORKS_API_KEY" ;;
    deepseek)   builtin_base="https://api.deepseek.com/v1";                builtin_key="DEEPSEEK_API_KEY" ;;
    mistral)    builtin_base="https://api.mistral.ai/v1";                  builtin_key="MISTRAL_API_KEY" ;;
    xai)        builtin_base="https://api.x.ai/v1";                       builtin_key="XAI_API_KEY" ;;
    google)     builtin_base="https://generativelanguage.googleapis.com/v1beta/openai"; builtin_key="GOOGLE_API_KEY" ;;
    *) ;;
  esac

  if [ -n "$builtin_base" ]; then
    PROVIDER_BASE_URL="$builtin_base"
    PROVIDER_API_KEY_ENV="$builtin_key"
    PROVIDER_EXTRA_JSON=""
    found=0
  fi

  # --- User overrides/additions from ~/.claude/z3fusion-runners.json ("providers" only) ----
  if [ -f "$FUSION_RUNNERS_JSON" ]; then
    local user_out
    user_out="$(NAME="$name" JSON_FILE="$FUSION_RUNNERS_JSON" "$FUSION_PY" - <<'PYEOF'
import json
import os
import sys

name = os.environ["NAME"]
json_file = os.environ["JSON_FILE"]

try:
    with open(json_file, "r", encoding="utf-8", errors="replace") as f:
        data = json.load(f)
except Exception:
    sys.exit(1)

if not isinstance(data, dict):
    sys.exit(1)

providers = data.get("providers")
if not isinstance(providers, dict):
    sys.exit(1)

entry = providers.get(name)
if not isinstance(entry, dict):
    sys.exit(1)

base_url = entry.get("baseUrl") or ""
if not base_url:
    sys.exit(1)

api_key_env = entry.get("apiKeyEnv") or ""

extra = entry.get("extraJson")
extra_str = ""
if extra is not None:
    try:
        # Compact (default, no indent) so this stays a single line with no embedded raw
        # newlines — json.dumps escapes any newline that shows up inside a string value
        # as the two-character sequence \n, so this is safe to pass back one-line-per-field.
        extra_str = json.dumps(extra)
    except Exception:
        extra_str = ""

sys.stdout.write(base_url + "\n")
sys.stdout.write(api_key_env + "\n")
sys.stdout.write(extra_str + "\n")
PYEOF
)"
    local py_status=$?
    if [ "$py_status" -eq 0 ] && [ -n "$user_out" ]; then
      PROVIDER_BASE_URL="$(printf '%s\n' "$user_out" | sed -n '1p')"
      PROVIDER_API_KEY_ENV="$(printf '%s\n' "$user_out" | sed -n '2p')"
      PROVIDER_EXTRA_JSON="$(printf '%s\n' "$user_out" | sed -n '3p')"
      found=0
    fi
  fi

  return "$found"
}
