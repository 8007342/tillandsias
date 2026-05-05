# Claude Code

@trace spec:agent-source-of-truth

**Version baseline**: Claude Code v0.2+ (baked at /opt/agents/claude)  
**Use when**: Running Claude Code inside the forge, understanding its CLI, passing model flags, reading task output

## Provenance

- https://claude.ai/code — Claude Code documentation
- https://github.com/anthropic-ai/claude-code — Source repository
- https://docs.anthropic.com/claude/reference/getting-started-with-the-api — Claude models and API
- **Last updated:** 2026-04-27

## Quick reference

| Command | Purpose |
|---------|---------|
| `claude help` | Show all subcommands |
| `claude read <path>` | Read a file (batch mode, non-interactive) |
| `claude /analyze <prompt>` | Analyze code/files (slash command in REPL) |
| `claude /loop <interval> <prompt>` | Run prompt on repeat (e.g., every 5 minutes) |
| `claude /bash <command>` | Execute bash command (trusted, inline) |
| `--model claude-opus` | Use Opus model (slowest, most capable) |
| `--model claude-sonnet` | Use Sonnet model (balanced) |
| `--model claude-haiku` | Use Haiku model (fastest, forge default) |

## Common patterns

**Interactive analysis from the CLI:**
```bash
claude /analyze "explain the error in this stack trace"
# Claude reads context (working dir, git state) and responds
```

**Batch file read (non-interactive):**
```bash
claude read src/main.rs  # Returns file contents
# Useful in scripts: `claude read file.rs | grep -A5 "fn main"`
```

**Running with a specific model:**
```bash
# Default (Haiku, fast, suitable for forge work)
claude /bash "cargo build"

# Switch to Sonnet for complex reasoning
CLAUDE_MODEL=claude-sonnet claude /analyze "refactor this module"
```

**Looping a task (polling, monitoring):**
```bash
# Check build status every 30 seconds until it passes
claude /loop 30s /bash "cargo build --workspace"
```

**Slash command discovery:**
```bash
# List all available skills/commands inside REPL
/help
/skills
/memory
```

## Common pitfalls

❌ **Assuming Opus is the default**: The forge uses Haiku by default (fast, constrained tokens). Opus is slow inside containers. → Use `--model claude-sonnet` for complex reasoning without adding much latency.

❌ **Running large file reads without context**: `claude read huge-codebase/src/` might timeout. → Use `find` + filtering: `find . -name '*.rs' -type f | head -20 | xargs -I {} claude read {}`.

❌ **Forgetting to git-add before analysis**: Claude sees only committed files (or working tree if staged). → `git add .` before running `/analyze`.

❌ **Using `/loop` for long-running tasks without output**: The loop runs your prompt repeatedly. → Use `/bash "cargo build"` directly; `/loop` is for polling short checks (build finished? test passed?).

❌ **Forgetting to set TILLANDSIAS_CHEATSHEETS**: Claude's system prompt doesn't know where the cheatsheets are unless the env var is set. → The forge entrypoint sets this; but if you're in a nested shell, echo `$TILLANDSIAS_CHEATSHEETS` to verify.

## See also

- `agents/openspec.md` — OpenSpec workflow for structured changes
- `agents/opencode.md` — OpenCode CLI for web/visual development
