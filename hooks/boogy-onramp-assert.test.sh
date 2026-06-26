#!/usr/bin/env sh
# Tests for boogy-onramp-assert.sh: matcher + once-per-session.
# Uses the UserPromptSubmit hook schema field name "user_prompt".
set -eu
HOOK="$(dirname "$0")/boogy-onramp-assert.sh"
TMPDIR="$(mktemp -d)"
export TMPDIR
fail=0

# 1. Non-Boogy prompt -> no output.
out="$(printf '{"user_prompt":"build me a todo app","session_id":"s1"}' | sh "$HOOK")"
[ -z "$out" ] || { echo "FAIL: non-boogy prompt produced output: $out"; fail=1; }

# 2. Boogy prompt -> injects plain text (contains contract phrase) on first hit.
out="$(printf '{"user_prompt":"build X on boogy","session_id":"s2"}' | sh "$HOOK")"
printf '%s' "$out" | grep -q "do not work around it" || { echo "FAIL: boogy prompt did not inject"; fail=1; }

# 3. Same session again -> silent (once per session).
out="$(printf '{"user_prompt":"another boogy thing","session_id":"s2"}' | sh "$HOOK")"
[ -z "$out" ] || { echo "FAIL: second boogy prompt in session re-injected: $out"; fail=1; }

# 4. Different session -> injects again.
out="$(printf '{"user_prompt":"boogy please","session_id":"s3"}' | sh "$HOOK")"
printf '%s' "$out" | grep -q "INVOKE them" || { echo "FAIL: new session did not inject"; fail=1; }

[ "$fail" -eq 0 ] && echo "boogy-onramp-assert: OK" || { echo "boogy-onramp-assert: FAILED"; exit 1; }
