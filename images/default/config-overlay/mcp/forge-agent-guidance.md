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

`image.generate` runs the biggest model already on this computer unless you name a `tier`; any tier up to what the computer can run may be named directly. The only thing it asks about is downloading a model's files the first time: the result is `consent_required` (or carries `bigger_tier_offer`) with an `ask` sentence naming the one-time download in GB and minutes. Show the user that sentence exactly as written. Only if they say yes, call `image.generate` again with the same prompt, that `tier` and its `consent_token`. A token works once; the yes holds for this computer, so that tier never asks again. Never start a download on your own: without a token you get `consent_required` and nothing runs.

## Host tools: which one starts what

One MCP server, registered as `host-browser`, carries every host-side tool. The names are grouped by what they do, and the server's `initialize` reply (or `tillandsias.index {}`) lists them:

- `preview.*` — this project's local web preview at `www.<project>.localhost`. `preview.publish` STARTS a sibling web container; `preview.status`, `preview.reload`, `preview.stop`, `preview.logs` act on it. For a framework dev server, run it inside the forge instead.
- `toolchain.*` — `toolchain.prepare` STARTS a one-time build of a shared toolchain image (flutter); the `flutter` command calls it for you.
- `image.*` — `image.generate` generates images locally (stable-diffusion.cpp; starts the engine on the host GPU queue on first use).
- `studio.*` — the headless ComfyUI pipeline: `studio.run_workflow` and `studio.key_footage` queue GPU work in the project's studio container (it must be running: call `studio.start {}` first, no relaunch; `studio.status {}` says whether it is up). `studio.start` returns a `window_url`: `browser.open {url: window_url, dev: true}` opens the SAME studio in a window the operator can use with you; `studio.validate_family`, `studio.finish_pixels`, `studio.contact_sheet` start nothing.
- `browser.*` — `browser.open` STARTS a browser window on the host (the forge has no browser binary); the rest drive it.
- `cloudflare.*` — read-only views of the operator's Cloudflare account; call `cloudflare.scope_probe` first.
- `webstudio.*` — the visual co-edit studios (GrapesJS, Decap, Tina, Puck); `webstudio.open` starts nothing from the lane today and names the operator command.

The flat names `publish_local`, `service_status`, `service_stop`, `service_reload`, `service_logs`, `toolchain_prepare`, `studio_options`, `studio_open`, `studio_changes`, `studio_publish_request` still work for one release as deprecated aliases; prefer the namespaced names.
