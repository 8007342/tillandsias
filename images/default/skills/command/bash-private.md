---
description: Run a bash command with output hidden from AI agents
agent_blocked: true
---

# /bash-private

Run a bash command in a private session. The output is NEVER visible to any AI agent or inference stack. Use this for sensitive operations like authentication, entering passwords, or viewing secrets.

## Usage

- `/bash-private` — opens a private bash shell (agent-invisible)
- `/bash-private <command>` — runs a command privately

## Behavior

Opens a separate bash session where:
- All output is hidden from the AI conversation
- No command history is sent to any model
- The session is ephemeral — nothing persists in the AI context

After the command completes (or user types `exit`), control returns to OpenCode. The AI agent sees only: "Private command completed."

## Security

This skill is **firmly blocked for agent use**. It exists specifically to protect user secrets from being captured by the inference stack.

## Use Cases

- `gh auth login` — GitHub authentication (one-time codes, tokens)
- Entering SSH passphrases
- Viewing sensitive files
- Any operation involving security keys, biometrics, or browser auth flows

## Implementation

```bash
# Clear terminal, run in subshell, clear terminal on exit
clear
echo "=== Private Session (agent-invisible) ==="
echo "Type 'exit' when done."
echo ""
bash
echo ""
echo "Private session ended. Press Enter to return to OpenCode."
read -r
clear
```
