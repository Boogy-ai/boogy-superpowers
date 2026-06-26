#!/usr/bin/env sh
# Assert-only UserPromptSubmit hook for the Boogy onramp.
# On a prompt that mentions Boogy, inject the setup contract ONCE per session
# as plain stdout text (the reliable UserPromptSubmit context-injection mechanism).
# Never runs a state-changing command — assert only.
# Input: hook JSON on stdin (fields: user_prompt, session_id). Output: plain text, or nothing.
set -eu

input="$(cat)"

# Extract user_prompt + session id without assuming jq is present (best-effort grep).
# Field name per the UserPromptSubmit hook schema is "user_prompt".
prompt="$(printf '%s' "$input" | sed -n 's/.*"user_prompt"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 | tr 'A-Z' 'a-z')"
session_id="$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
[ -n "$session_id" ] || session_id="nosession"

# Only act on Boogy-intent prompts.
case "$prompt" in
  *boogy*) : ;;
  *) exit 0 ;;
esac

# Once per session: a marker keyed by session id.
marker_dir="${TMPDIR:-/tmp}/boogy-onramp"
marker="$marker_dir/$session_id"
[ -e "$marker" ] && exit 0
mkdir -p "$marker_dir" 2>/dev/null || true
: > "$marker" 2>/dev/null || true

# Inject the contract as plain text. (No commands are run; this is context only.)
printf '%s\n' "Boogy work detected. Before doing anything: (1) the Boogy skills are installed via this plugin — INVOKE them, do not summarize or distill them into your own words; (2) authenticate the user now via the \`login\` MCP tool (show the URL + one-time code, then poll \`login_status\`); (3) work strictly from the skills — start by invoking \`boogy-onramp\`, then \`using-boogy\`; (4) deploy needs the CLI (\`boogy deploy\`); (5) if you get stuck, STOP and ask the user — do not work around it."
