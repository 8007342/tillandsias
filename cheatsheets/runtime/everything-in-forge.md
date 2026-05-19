---
tags: [forge, runtime, podman, agents, contract]
languages: [bash, rust]
since: 2026-05-19
last_verified: 2026-05-19
sources:
  - https://docs.podman.io/en/stable/
  - https://github.com/containers/podman/docs
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---

# Everything Runs in the Forge

@trace spec:forge-as-only-runtime

**Use when**: Adding a new agent type, auditing a launch path, reasoning
about a mount, debugging "but it works on my host" complaints.

## The Contract

Every coding agent, every maintenance shell, and every runtime utility
executes inside the project's forge container. There is no host-side
execution surface for developer-facing tooling. The host only does three
things: it operates the Tillandsias tray/headless orchestrator, it spawns
the user's default terminal emulator as a TTY window for an interactive
`podman run -it`, and it manages podman itself. Everything else — Claude,
Codex, OpenCode, OpenCode Web, and the maintenance `bash` — lives in one
image and is reached through one launcher seam.

## Forge-Resident Binaries

Baked into `tillandsias-forge:latest` (`images/default/Containerfile`):

| Binary     | Source                                            | Entrypoint                                          | Launch mode                |
|------------|---------------------------------------------------|-----------------------------------------------------|----------------------------|
| `claude`   | `npm i -g @anthropic-ai/claude-code` (line 29)    | `/usr/local/bin/entrypoint-forge-claude.sh`         | `ForgeAgentMode::Claude`   |
| `codex`    | baked agent CLI                                   | `/usr/local/bin/entrypoint-forge-codex.sh`          | `ForgeAgentMode::Codex`    |
| `opencode` | `npm i -g opencode-ai@latest` (line 29)           | `/usr/local/bin/entrypoint-forge-opencode.sh`       | `ForgeAgentMode::OpenCode` |
| `opencode serve` | same package, web mode                      | `/usr/local/bin/entrypoint-forge-opencode-web.sh`   | `run_opencode_web_mode`    |
| `bash`     | Fedora minimal base                               | `/usr/local/bin/entrypoint-terminal.sh`             | `ForgeAgentMode::Maintenance` |

Verify from outside the forge:

```bash
podman run --rm --entrypoint /bin/sh tillandsias-forge:latest \
    -c 'command -v claude codex opencode bash'
# expect 4 absolute paths
```

## Adding a New Agent — PR Checklist

1. **Bake it in the image.** Edit `images/default/Containerfile`. If it ships
   as a Node package, extend the `npm install -g` line. Otherwise add a new
   `RUN` that installs the binary into `/usr/local/bin` and a `COPY` for the
   entrypoint script.
2. **Add an entrypoint.** Drop `entrypoint-forge-<agent>.sh` next to the
   existing ones. Source `lib-common.sh`, populate hot paths, set up the CA,
   `cd` to the project, banner, then `exec <agent> "$@"`.
3. **Wire it into Rust.** Add a variant to `ForgeAgentMode` in
   `crates/tillandsias-headless/src/main.rs`, return the entrypoint path
   and slug from the relevant `match` arms, and surface a tray menu entry.
4. **Do NOT install on the host.** No `Command::new("<agent>")` in
   `crates/tillandsias-headless/src/` or `crates/tillandsias-podman/src/`.
   The agent is reached *only* through `launch_forge_agent` (or
   `run_opencode_web_mode` if it serves over HTTP).
5. **Extend the litmus.** Add the new binary name to the
   `command -v` check in
   `openspec/litmus-tests/litmus-forge-as-only-runtime.yaml` so future
   image regressions fail loudly.
6. **Update this cheatsheet.** Add a row to the table above and a note in
   the spec's `Sources of Truth` block.

## The Four Mount Categories

A forge `ContainerSpec` may bind-mount sources from **exactly these four**
categories. Anything else is a spec violation.

| Category        | Source                                         | Mount point                       | Discipline               |
|-----------------|------------------------------------------------|-----------------------------------|--------------------------|
| Project workspace | the user-selected project root              | `/home/forge/src/<project>`       | RW, the only durable mount |
| CA certs        | `ensure_enclave_for_project(...)` certs dir    | `/etc/pki/tls/certs/tillandsias`  | RO, ephemeral per launch |
| `tmpfs`         | declared via `--tmpfs`                         | e.g. `/tmp`, `/run/user/1000`     | RW, dies with container  |
| `mktemp -d`     | fresh host tempdir per launch                  | control sockets, short-lived state | RW, removed on exit     |

### Do NOT mount

- `$HOME` (any path under it other than the project workspace)
- `~/.config/`, `~/.cache/`, `~/.ssh/`, `~/.gitconfig`
- The host's `~/.config/tillandsias/` directory
- The host keyring / Secret Service socket
- Host `/var/run/docker.sock` or `/run/podman/podman.sock`
- Anything that hands the forge ambient credentials

A forge that needs a credential gets it via an ephemeral podman secret
through the git-service container (see
`runtime/dedicated-service-account-podman.md`). The forge itself stays
fully offline and credential-free.

## The Host Terminal Seam

The tray's interactive launch path looks like this:

```text
tray (Rust)
  └── detect_host_terminal()   ← only host-side process
        └── foot / gnome-terminal / alacritty / kitty / xterm / …
              └── podman run -it tillandsias-forge:<ver> <entrypoint>
                    └── entrypoint-forge-<agent>.sh
                          └── exec <agent>
```

- `detect_host_terminal` returns the argv prefix for the user's terminal.
- `build_forge_agent_run_argv` returns the podman argv suffix (image,
  entrypoint, mounts).
- The terminal's sole job is to provide a TTY window. It MUST NOT carry
  application logic, environment overrides, or per-distro behavior.
- The terminal is the **only** host-side child the tray spawns on the
  interactive path. No editor, no LSP, no agent CLI.

OpenCode Web is the one exception in shape — it uses
`run_opencode_web_mode` rather than `launch_forge_agent` because it is
served over HTTP rather than presented in a TTY — but it follows the same
contract: the agent runs inside the forge, the host only opens a browser
window.

## Pointers

- Spec: `openspec/specs/forge-as-only-runtime/spec.md`
- Launcher (interactive TTY): `crates/tillandsias-headless/src/main.rs` →
  `launch_forge_agent`, `build_forge_agent_run_argv`,
  `detect_host_terminal`
- Launcher (web): `crates/tillandsias-headless/src/main.rs` →
  `run_opencode_web_mode`
- Image: `images/default/Containerfile` (line 29 bakes the agent set)
- Idiomatic podman layer: `crates/tillandsias-podman/src/client.rs`,
  `crates/tillandsias-podman/src/container_spec.rs`
- Sibling cheatsheets: `runtime/forge-container.md` (overall forge model),
  `runtime/podman-control-plane.md` (one-throat-to-choke framing),
  `runtime/podman-idiomatic-patterns.md` (the boundary this contract
  narrows to interactive agents).
