# Boogy Superpowers

Skills that teach coding agents to build [Boogy](https://boogy.ai)
services well — service design, data modeling, auth, transactions,
background jobs, mesh composition, MCP/REST surfaces, and the honest
list of what the platform doesn't do yet.

Works with Claude Code out of the box (no plugin needed), and with any
agent that can read markdown.

## Install (recommended): vendor into your project

From your project root:

```bash
boogy skills install        # via the boogy CLI
# or, without the CLI:
npx degit Boogy-ai/boogy-superpowers/skills .claude/skills/boogy
```

Claude Code auto-discovers `.claude/skills/`. Re-run `boogy skills update`
(or the same degit command) to refresh.

## Use as a plugin

The repo ships `.claude-plugin/plugin.json` (Claude Code) and
`gemini-extension.json` (Gemini CLI); marketplace listings will follow.

## Start here

`skills/using-boogy/SKILL.md` is the entry point — it routes every kind
of Boogy task to the right skill.

## License

MIT
