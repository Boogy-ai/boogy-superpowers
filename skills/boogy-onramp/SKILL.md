---
name: boogy-onramp
description: Use when a user asks to build, deploy, or do anything on Boogy — BEFORE writing code, calling the platform API, or any other action. Establishes the required setup contract.
---

# Boogy onramp — do this before anything else

You are about to do Boogy work. Follow this contract IN ORDER before writing
code, calling the API, or improvising. Do NOT summarize, paraphrase, or
"distill" the skills into your own words — INVOKE them.

1. **The skills are already installed** (this plugin bundles them). Do not
   re-install and do not build from a summary — you will invoke them. If the
   plugin was just installed this session, tell the human to run
   **`/reload-plugins`** first (or restart Claude Code) — otherwise the bundled
   skills, the Boogy MCP and the gate are not active yet.
2. **Authenticate the user now, with the CLI.** Install it once if `boogy` is
   missing: `cargo install --locked --git https://github.com/Boogy-ai/boogy-sdk boogy-cli`.
   Then run `boogy login`: it prints a URL + one-time code and waits; show the
   human both, and they open the URL, confirm the code matches, and sign in.
   The CLI saves the token to its credentials file and every later `boogy`
   command uses it — the token never passes through you, so never ask for it
   or print it. (In Claude Code the human can also run it themselves by typing
   `! boogy login`.) Do this early — only the human can do the browser step.
   **A first-time user picks a handle in that browser step, and you NEVER pick
   it for them.** It is their account's username, not the name of the app you
   are building — chosen once, hard to change, and the account every service
   they ever deploy belongs to (each service gets its own address; the handle
   is not part of it). Let them choose it in the flow; if you are ever
   collecting one yourself, ask explicitly and wait for their answer. Full rule
   (and what to tell them while they choose): `using-boogy`, "Choosing a
   handle".
3. **Work strictly from the installed skills — start by invoking `using-boogy`**
   (the router; it sends every Boogy task to the right skill). Never build from
   memory, from the platform API, or from a summary.
4. **Deploy with the same CLI** (`boogy deploy`) or the `/v1` API — the MCP
   cannot deploy.
5. **Make it stick — offer to persist the directive.** A hook fires on a
   keyword and once per session; a line in `CLAUDE.md` is in context always, in
   every session and after any compaction. **Ask the human before writing it**:
   say in one or two lines what the block does and where it goes, and append it
   to the project's `CLAUDE.md` (creating the file if absent) only once they
   agree. If they decline, change nothing and do not ask again this session. If
   `CLAUDE.md` already carries such a directive, say so and change nothing. If
   the human builds on Boogy across projects, offer their global
   `~/.claude/CLAUDE.md` as the alternative.

   Copy the block **verbatim, comment line included**. That first line is a
   marker, not decoration: the session-start hook probes for it to decide
   whether the directive is already in place, and goes silent for good once it
   finds it. Drop the marker and the hook keeps asking for a directive that is
   already there.

   ```markdown
   <!-- boogy-directive -->
   ## Boogy

   **Whenever you build or change a Boogy module** (a service you deploy on
   Boogy: its manifest, its code, its deploy), **invoke** the
   Boogy skills with the Skill tool, every time, before the work;
   never summarize, paraphrase, or work from memory of them. Entry point:
   `using-boogy`, which routes to the rest. Work that builds or changes no
   module does not invoke them.

   Repeat this instruction in **every subagent dispatch that builds or changes
   a module**. A subagent inherits no hook and no conversation; unless you tell
   it, it builds from guesswork.

   Skills not installed? Install the plugin from its GitHub repo —
   `claude plugin marketplace add Boogy-ai/boogy-superpowers`, then
   `claude plugin install boogy@boogy`, then ask the human to run
   `/reload-plugins` — or vendor them with
   `npx degit Boogy-ai/boogy-superpowers/skills .claude/skills`. Flat, one
   level: a wrapper directory makes every skill silently undiscoverable.
   ```

6. **If you get stuck, STOP — do not work around it.** If a step is blocked
   (`boogy login` won't complete, a tool is missing, you lack a permission), do not skip
   it, do not improvise an alternative, do not build without it. Tell the user
   exactly what is blocking you and the choice or action you need, then wait.

Now invoke `using-boogy` and proceed.
