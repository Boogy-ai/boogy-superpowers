#!/usr/bin/env sh
# Assert-only UserPromptSubmit hook for the Boogy onramp.
# On a prompt that mentions Boogy, inject the setup contract ONCE per session
# as plain stdout text (the reliable UserPromptSubmit context-injection mechanism).
# Runs no command on the user's behalf and touches nothing in their project.
# It does write ONE thing: an empty marker file under TMPDIR, which is what
# makes the injection once-per-session rather than once-per-prompt. Saying
# "never writes" here would be false, and the write is load-bearing.
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
printf '%s\n' "Boogy work detected. Before doing anything: (1) the Boogy skills are installed via this plugin — INVOKE them, do not summarize or distill them into your own words; (2) authenticate the user now with \`boogy login\` (install the CLI first if it is missing: \`cargo install --locked --git https://github.com/Boogy-ai/boogy-sdk boogy-cli\`; it prints a URL + one-time code for the human to confirm and saves the token itself; never ask for the token or print it); (3) work strictly from the skills — start by invoking \`boogy-onramp\`, then \`using-boogy\`; (4) persist it — offer to add a short directive to the project's CLAUDE.md so later sessions invoke the skills without a hook (\`boogy-onramp\` step 5 has the exact text; ask the human before writing it); (5) repeat that instruction in EVERY subagent dispatch — a subagent inherits no hook and no conversation; (6) deploy with the same CLI (\`boogy deploy\`); (7) if you get stuck, STOP and ask the user — do not work around it."
