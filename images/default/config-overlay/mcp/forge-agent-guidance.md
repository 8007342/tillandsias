<!-- @trace order:1724-kcj4 — forge-wide guidance for every coding agent in a Tillandsias forge.
     ONE source, linked by agent-profile.sh (link_forge_agent_guidance) as each harness's
     USER-level instructions: ~/.claude/CLAUDE.md, ~/.codex/AGENTS.md, ~/.gemini/GEMINI.md and
     ~/.config/opencode/AGENTS.md. A project's own CLAUDE.md / AGENTS.md still loads on top. -->

# Working in a Tillandsias forge

These notes apply to every project in this forge. Your project's own instructions come first wherever they disagree.

## Stopping a process

To stop a process, find it with `pgrep`, then kill it by its PID, skipping your own shell (`$$`).

```bash
pgrep -af vite        # list the candidates with their command lines
kill 4242             # stop the one you mean, by PID
```

Don't use `pkill -f` or `killall -r`. Your command runs as `bash -c "<your command>"`, so the pattern you pass is also in your own shell's command line, and the kill ends your own shell along with the target (exit status 144). In Claude, the forge's command check refuses both.

## Generating images

`image.generate` starts on the smallest model. When a bigger one fits this computer, the result carries `bigger_tier_offer` with an `ask` sentence. Show the user that sentence exactly as written. Only if they say yes, call `image.generate` again with the same prompt, the offered `tier` and its `consent_token`. A token works once. Never ask for a bigger tier on your own: without a token you get `consent_required` and nothing runs.
