---
description: Open a bash shell in the project directory
agent_blocked: true
---

# /bash

Open an interactive bash shell in the project directory.

## Usage

- `/bash` — opens a new bash shell in the current project directory
- `/bash <command>` — runs a command in bash and shows the output

## Behavior

When run with no arguments, this opens a new interactive bash session. The user can run any commands they need. Type `exit` to return to OpenCode.

When run with arguments, the command is executed and output is displayed.

## Security

This skill is **blocked for agent use**. Only the human user can invoke it. This prevents AI agents from running arbitrary commands outside the normal tool sandbox.

## Implementation

For no arguments:
```bash
exec bash
```

For with arguments:
```bash
bash -c "<arguments>"
```
