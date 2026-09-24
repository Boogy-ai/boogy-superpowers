#!/usr/bin/env sh
# Assert-only SessionStart hook for the Boogy onramp — the bootstrap half.
#
# Why this exists: the sibling UserPromptSubmit hook only fires on a prompt that
# literally says "boogy", so "build me a service that syncs my YouTube likes"
# fires nothing, and the standing CLAUDE.md directive that would cover that
# prompt never gets written — the directive is only ever written by an agent
# that already invoked a Boogy skill, which is the exact failure it exists to
# fix. This hook closes that loop and then gets out of the way.
#
# SELF-EXTINGUISHING: it prints one line only while the directive is ABSENT.
# Once the directive exists in any CLAUDE.md on the path, this hook is silent
# forever, in every project, at no cost beyond a few file reads.
#
# Never runs a state-changing command — it reads files and prints, nothing else.
# In particular it does NOT write CLAUDE.md: writing is the agent's job, and the
# agent announces it to the human.
#
# Never fails a session: unreadable files, an absent HOME, a weird CLAUDE.md and
# malformed stdin all exit 0 quietly.
#
# Input: hook JSON on stdin (SessionStart; `cwd` is used when present).
# Output: one line of plain text, or nothing.
set -eu

input="$(cat 2>/dev/null)" || input=""

# Extract cwd without assuming jq is present (best-effort sed, same style as the
# sibling hook). Fall back to the process's own working directory.
cwd="$(printf '%s' "$input" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
[ -n "$cwd" ] && [ -d "$cwd" ] || cwd="${PWD:-.}"

# The probe. Two patterns, both fixed strings:
#  - MARKER is the explicit, unambiguous one and is carried by the directive
#    block in `boogy-onramp` step 5 and in the README. A bare `## Boogy` heading
#    would NOT be safe to probe on: a Boogy project's CLAUDE.md may well have a
#    `## Boogy` section about something else entirely, and this hook would then
#    go silent in exactly the project that needs it.
#  - LEGACY catches a directive pasted before the marker existed, so anyone
#    already set up does not get re-prompted.
MARKER='<!-- boogy-superpowers-directive -->'
LEGACY='All Boogy work goes through the'

has_directive() {
  [ -f "$1" ] && [ -r "$1" ] || return 1
  grep -F -q -e "$MARKER" -e "$LEGACY" "$1" 2>/dev/null
}

# Walk up from cwd: a session started in a subdirectory (or a worktree) must
# still see the project root's CLAUDE.md. Bounded, and never follows anything
# but the parent chain.
dir="$cwd"
depth=0
while [ "$depth" -lt 64 ]; do
  has_directive "$dir/CLAUDE.md" && exit 0
  has_directive "$dir/CLAUDE.local.md" && exit 0
  has_directive "$dir/.claude/CLAUDE.md" && exit 0
  [ "$dir" = "/" ] && break
  parent="${dir%/*}"
  [ -n "$parent" ] || parent="/"
  [ "$parent" = "$dir" ] && break
  dir="$parent"
  depth=$((depth + 1))
done

# The user's global memory file — where someone who builds on Boogy across
# projects is told to put the directive.
if [ -n "${HOME:-}" ]; then
  has_directive "$HOME/.claude/CLAUDE.md" && exit 0
fi

# Absent. Say it once, conditionally, and say how to make it stop.
printf '%s\n' "The \`boogy-superpowers\` skills are installed in this session. If any of this work touches Boogy (boogy.ai), invoke them with the Skill tool starting at \`using-boogy\` — never work from memory of them — and persist the standing directive into \`CLAUDE.md\` as \`boogy-onramp\` step 5 describes, which also stops this line appearing again. If the work is unrelated to Boogy, ignore this line."
