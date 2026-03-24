## Context

OpenCode supports user-defined slash command skills via markdown files with YAML frontmatter. Skills placed in the `skills/command/` directory within the OpenCode configuration become available as `/skill-name` commands. The `agent_blocked: true` frontmatter flag prevents the AI agent from invoking the skill, restricting it to human use only.

The forge container currently launches OpenCode as the foreground process. Users who need a shell must exit OpenCode or use a separate terminal. This friction discourages shell usage and makes secret-handling workflows (like `gh auth login`) awkward or insecure.

## Goals / Non-Goals

**Goals:**
- Let users open a bash shell from within OpenCode via `/bash`
- Let users run commands privately (invisible to AI) via `/bash-private`
- Block agent invocation of both skills to prevent arbitrary command execution
- Keep implementation minimal — markdown skill definitions only, no Rust code

**Non-Goals:**
- Implementing a terminal emulator within OpenCode
- Persisting private session history or output
- Modifying the entrypoint or Containerfile
- Creating skills for specific tools (e.g., `/git`, `/npm`) — those can come later

## Decisions

### D1: Skill file location

**Choice:** `images/default/skills/command/` directory, co-located with the container image definition.

Skills are part of the forge image and should live alongside the Containerfile and entrypoint. OpenCode discovers skills from its configured skills directory. The entrypoint or image build will need to place these files where OpenCode expects them.

### D2: Agent-blocked for both skills

**Choice:** Both `/bash` and `/bash-private` use `agent_blocked: true`.

`/bash` could theoretically be agent-accessible (the agent already has tool access to run commands), but allowing it would bypass OpenCode's tool sandbox. Blocking agent access for both skills is the conservative and correct choice. The agent has its own sandboxed bash tool; it does not need an unsandboxed escape hatch.

### D3: Private session isolation

**Choice:** `/bash-private` runs in a subshell with terminal clearing before and after.

The private session clears the terminal before starting, runs bash in a subshell, and clears again on exit. The AI agent sees only a "Private command completed." message. This is a UX-level isolation — it relies on OpenCode respecting the `agent_blocked` flag and not capturing terminal output during private sessions. It is not cryptographic isolation, but it is sufficient for the threat model (preventing accidental secret leakage into AI context).

### D4: One-shot command support

**Choice:** Both skills accept optional arguments to run a single command instead of opening an interactive session.

`/bash ls -la` runs `ls -la` and shows output. `/bash-private gh auth status` runs the command privately. This matches user expectations from terminal workflows and avoids the overhead of entering and exiting an interactive session for simple commands.
