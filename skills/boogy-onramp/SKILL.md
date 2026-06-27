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
   skills, the `login` MCP tool (step 2), and the gate are not active yet.
2. **Authenticate the user now.** Call the `login` tool (from the bundled Boogy
   MCP server); show the human the URL + one-time code; poll `login_status`
   until it returns a token. (No CLI needed just to authenticate. CLI path:
   `boogy login`.) Do this early — only the human can do the browser step.
3. **Work strictly from the installed skills — start by invoking `using-boogy`**
   (the router; it sends every Boogy task to the right skill). Never build from
   memory, from the platform API, or from a summary.
4. **Deploy needs the CLI** (`boogy deploy`) or the `/v1` API — the MCP cannot
   deploy. Install it once: `cargo install --locked --git https://github.com/Boogy-ai/boogy-sdk boogy-cli`.
5. **If you get stuck, STOP — do not work around it.** If a step is blocked
   (login won't complete, a tool is missing, you lack a permission), do not skip
   it, do not improvise an alternative, do not build without it. Tell the user
   exactly what is blocking you and the choice or action you need, then wait.

Now invoke `using-boogy` and proceed.
