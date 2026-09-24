#!/usr/bin/env sh
# Tests for boogy-onramp-bootstrap.sh: the SessionStart bootstrap hook.
#
# The property under test is that the hook is SELF-EXTINGUISHING — it speaks
# only while the CLAUDE.md directive is absent, and it must never fail a
# session. Every case therefore asserts the exit status as well as the output.
#
# Hermetic: HOME is redirected into a temp tree and every case passes an
# explicit `cwd`, so nothing here reads the developer's own CLAUDE.md.
set -eu
HOOK="$(cd "$(dirname "$0")" && pwd)/boogy-onramp-bootstrap.sh"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
HOME="$ROOT/home"
export HOME
mkdir -p "$HOME/.claude"
fail=0

MARKER='<!-- boogy-superpowers-directive -->'

# Run the hook with a given cwd; capture stdout and status separately.
run() {
  set +e
  out="$(printf '{"session_id":"s1","hook_event_name":"SessionStart","source":"startup","cwd":"%s"}' "$1" | sh "$HOOK")"
  rc=$?
  set -e
}

expect_silent() { # label
  [ "$rc" -eq 0 ] || { echo "FAIL: $1 exited $rc, expected 0"; fail=1; }
  [ -z "$out" ] || { echo "FAIL: $1 should be silent, got: $out"; fail=1; }
}

expect_speaks() { # label
  [ "$rc" -eq 0 ] || { echo "FAIL: $1 exited $rc, expected 0"; fail=1; }
  [ -n "$out" ] || { echo "FAIL: $1 emitted nothing, expected the bootstrap line"; fail=1; }
}

# 1. Directive present (explicit marker) -> silent, exit 0.
#    This is the common case for anyone already set up, and it must cost nothing.
mkdir -p "$ROOT/has-marker"
printf '# Project\n\n%s\n## Boogy\n\nblah\n' "$MARKER" > "$ROOT/has-marker/CLAUDE.md"
run "$ROOT/has-marker"
expect_silent "directive present (marker)"

# 2. Directive present as the pre-marker wording only -> still silent. Someone
#    who pasted the block before the marker existed must not be re-prompted.
mkdir -p "$ROOT/has-legacy"
printf '## Boogy\n\nAll Boogy work goes through the `boogy-superpowers` skills.\n' \
  > "$ROOT/has-legacy/CLAUDE.md"
run "$ROOT/has-legacy"
expect_silent "directive present (pre-marker wording)"

# 3. Directive absent -> emits, exit 0.
mkdir -p "$ROOT/absent"
printf '# Some unrelated project\n\nNothing to do with anything.\n' > "$ROOT/absent/CLAUDE.md"
run "$ROOT/absent"
expect_speaks "directive absent"

# 4. No CLAUDE.md at all -> emits, exit 0 (a brand-new project is the case the
#    hook exists for: there is no manifest and no CLAUDE.md yet).
mkdir -p "$ROOT/bare"
run "$ROOT/bare"
expect_speaks "no CLAUDE.md at all"

# 5. A bare `## Boogy` heading is NOT the probe. A project may legitimately have
#    a section by that name about something else; if the hook went quiet on it,
#    it would go quiet in exactly the project that needs it. This is the case
#    that justifies carrying an explicit marker in the block.
mkdir -p "$ROOT/decoy"
printf '# Notes\n\n## Boogy\n\nWe evaluated it and chose something else.\n' \
  > "$ROOT/decoy/CLAUDE.md"
run "$ROOT/decoy"
expect_speaks "bare '## Boogy' heading is not the directive"

# 6. Directive in an ANCESTOR directory -> silent. A session started in a
#    subdirectory still has the project root's CLAUDE.md in context.
mkdir -p "$ROOT/ancestor/sub/deeper"
printf '%s\n' "$MARKER" > "$ROOT/ancestor/CLAUDE.md"
run "$ROOT/ancestor/sub/deeper"
expect_silent "directive in an ancestor directory"

# 7. Directive in the user's global memory file -> silent. This is the path
#    offered to someone who builds on Boogy across projects.
mkdir -p "$ROOT/global-only"
printf '%s\n' "$MARKER" > "$HOME/.claude/CLAUDE.md"
run "$ROOT/global-only"
expect_silent "directive in \$HOME/.claude/CLAUDE.md"
rm -f "$HOME/.claude/CLAUDE.md"

# 8. Directive in .claude/CLAUDE.md beside the project -> silent.
mkdir -p "$ROOT/dotclaude/.claude"
printf '%s\n' "$MARKER" > "$ROOT/dotclaude/.claude/CLAUDE.md"
run "$ROOT/dotclaude"
expect_silent "directive in .claude/CLAUDE.md"

# 9. The emitted line carries the three things that make it actionable AND
#    self-extinguishing: the entry-point skill, the persistence instruction,
#    and the escape clause for an unrelated project. Without the last one this
#    hook is noise in every non-Boogy session it fires in.
run "$ROOT/bare"
printf '%s' "$out" | grep -q 'using-boogy' \
  || { echo "FAIL: emitted line does not name the entry-point skill"; fail=1; }
printf '%s' "$out" | grep -q 'CLAUDE.md' \
  || { echo "FAIL: emitted line does not tell the agent to persist the directive"; fail=1; }
printf '%s' "$out" | grep -q 'unrelated to Boogy' \
  || { echo "FAIL: emitted line has no escape clause for an unrelated project"; fail=1; }
# It must be ONE line: this fires in every session of every project.
[ "$(printf '%s' "$out" | wc -l)" -eq 0 ] \
  || { echo "FAIL: emitted output is more than one line"; fail=1; }

# 10. Degrade gracefully, never fail a session.
set +e
out="$(printf 'not json at all' | HOME="$HOME" sh "$HOOK" 2>/dev/null)"; rc=$?
set -e
[ "$rc" -eq 0 ] || { echo "FAIL: malformed stdin exited $rc, expected 0"; fail=1; }

set +e
out="$(printf '' | sh "$HOOK" 2>/dev/null)"; rc=$?
set -e
[ "$rc" -eq 0 ] || { echo "FAIL: empty stdin exited $rc, expected 0"; fail=1; }

set +e
out="$(printf '{"cwd":"%s"}' "$ROOT/absent" | env -u HOME sh "$HOOK" 2>/dev/null)"; rc=$?
set -e
[ "$rc" -eq 0 ] || { echo "FAIL: unset HOME exited $rc, expected 0"; fail=1; }

set +e
out="$(printf '{"cwd":"%s/no-such-dir"}' "$ROOT" | sh "$HOOK" 2>/dev/null)"; rc=$?
set -e
[ "$rc" -eq 0 ] || { echo "FAIL: nonexistent cwd exited $rc, expected 0"; fail=1; }

# 11. Unreadable CLAUDE.md -> treated as absent, exit 0, never an error.
#     Two guards make this true and either alone is sufficient — the `-r` test
#     keeps grep away from the file, and grep's own stderr is discarded — so
#     removing just one of them leaves this case green. That redundancy is
#     deliberate; the assertion is on the behaviour, and removing BOTH is what
#     it catches. (Skipped when running as root, which can read anything.)
if [ "$(id -u)" -ne 0 ]; then
  mkdir -p "$ROOT/unreadable"
  printf '%s\n' "$MARKER" > "$ROOT/unreadable/CLAUDE.md"
  chmod 000 "$ROOT/unreadable/CLAUDE.md"
  run "$ROOT/unreadable"
  expect_speaks "unreadable CLAUDE.md"
  # ...and quietly: a permission-denied line on stderr would surface to the
  # human as a hook error even though the hook itself behaved correctly.
  set +e
  err="$(printf '{"cwd":"%s"}' "$ROOT/unreadable" | sh "$HOOK" 2>&1 >/dev/null)"
  set -e
  [ -z "$err" ] || { echo "FAIL: unreadable CLAUDE.md wrote to stderr: $err"; fail=1; }
  chmod 644 "$ROOT/unreadable/CLAUDE.md"
fi

# 12. Assert-only: the script must contain no state-changing command. It reads
#     files and prints. The sibling assert hook writes a session marker; this
#     one writes nothing at all, and that is a property worth pinning.
grep -Eq '(^|[^a-zA-Z_-])(mkdir|rm|mv|cp|touch|chmod|git|curl|wget|tee)([^a-zA-Z_-]|$)' "$HOOK" \
  && { echo "FAIL: hook contains a state-changing command"; fail=1; }
#     ...and no output redirection except discarding stderr, so it cannot create
#     or truncate a file even by accident.
sed 's|2>/dev/null||g' "$HOOK" | grep -Eq '(^|[[:space:]])[0-9]?>>?' \
  && { echo "FAIL: hook contains an output redirection other than 2>/dev/null"; fail=1; }

# 13. Every shipped copy of the directive block carries the marker this hook
#     probes for. The block exists in more than one place and they drift
#     silently: if one copy loses the marker, an agent that pastes THAT copy
#     leaves the hook asking forever for a directive that is already written.
#     Nothing else in the package would catch that.
PKG="$(cd "$(dirname "$0")/.." && pwd)"
if [ -d "$PKG/skills" ]; then
  for f in "$PKG/skills/boogy-onramp/SKILL.md" "$PKG/README.md"; do
    if [ -f "$f" ]; then
      grep -Fq "$MARKER" "$f" \
        || { echo "FAIL: $f does not carry the directive marker"; fail=1; }
    else
      echo "FAIL: expected a copy of the directive block at $f"; fail=1
    fi
  done
  # GEMINI.md carries no copy of its own — it defers to the skill, which is how
  # it stays in agreement. Pin that it still points at the step that holds it.
  if [ -f "$PKG/GEMINI.md" ]; then
    grep -q 'boogy-onramp/SKILL.md` step 5' "$PKG/GEMINI.md" \
      || { echo "FAIL: GEMINI.md no longer defers to boogy-onramp step 5"; fail=1; }
  fi
fi

[ "$fail" -eq 0 ] && echo "boogy-onramp-bootstrap: OK" || { echo "boogy-onramp-bootstrap: FAILED"; exit 1; }
