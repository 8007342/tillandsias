# Security investigation — GitHub token at rest after `--github-login` (cross-host) — 2026-06-22

**Filed:** 2026-06-22 (operator-directed, from macOS interactive `--github-login` finalize)
**Kind:** research / security investigation
**Status:** ready (Linux + Windows workers)
**Owner hosts:** `linux_mutable` / `linux_immutable` (native + forge), `windows` (WSL2)
**Trace:** `spec:gh-auth-script`, `spec:tillandsias-vault`, `spec:secret-rotation`,
`spec:podman-secrets-integration`

## Concern (operator)

After `tillandsias --github-login`, the GitHub PAT must exist **only** in Vault
(encrypted at rest). We must verify no **unencrypted** copy of the token is left
lying around on **Linux native**, the **Linux forge**, or **WSL2** containers /
filesystems. "We don't like secrets unencrypted at rest."

## What the shared flow does (crates/tillandsias-headless/src/main.rs `run_github_login`)

- Runs `gh auth login --hostname github.com --with-token` **inside a git-service
  container** started `--detach --rm` (`main.rs:3974-3997`), token piped via
  `GH_LOGIN_TOKEN_SCRIPT` (`main.rs:3872-3916`); `LoginContainerCleanup`
  (`main.rs:3962`) removes the container.
- Writes the token to Vault (vault-cli, `--secret` approle lease).
- The container is ephemeral (`--rm`), so the gh credential file
  (`~/.config/gh/hosts.yml` inside the container) should be destroyed on exit.

This is the *intended* design; the audit is to **verify it actually holds** on
each backend — `--rm` timing, storage drivers, volumes, and WSL2 differ.

## Audit checklist (file evidence per host)

1. **gh credential file**: after a successful login, assert no
   `**/.config/gh/hosts.yml` (or `gh` token) exists on the host, in any podman
   volume, or in the container storage overlay (`podman` graphroot). On WSL2,
   check the distro filesystem + `\\wsl$`.
2. **Container removal**: confirm the `tillandsias-gh-login-*` container is gone
   (`podman ps -a`), and its overlay upperdir under the graphroot is deleted
   (no lingering token in `overlay/*/diff`).
3. **podman secrets / build cache / layers**: ensure the token wasn't baked into
   an image layer or left in `podman secret` (the approle lease secret is for
   Vault auth, not the PAT — verify the PAT itself is not a podman secret at
   rest).
4. **journald / logs**: grep `journalctl` + tillandsias logs for the token value
   (should never appear; `read -rs` + `run_command_silent` should prevent it).
5. **Vault is the only persistent copy**: confirm `vault-cli read
   secret/github/token` returns it and that it is encrypted at rest in the Vault
   storage backend (sealed file store).
6. **Crash path**: if login fails mid-way (e.g. bad token, network), confirm the
   `--rm` container + `LoginContainerCleanup` still remove all unencrypted
   traces (no orphaned container holding the token).

## Closure (verifiable)

A litmus / scripted check per backend that runs a login with a disposable test
token, then asserts items 1–4 + 6 find **zero** unencrypted occurrences of the
token on disk / in volumes / in logs, and item 5 confirms the Vault copy. Wire
it into the e2e or a security-gate litmus so a regression fails loud.

## Notes

- Surfaced while finalizing the macOS `--github-login` (drives this SAME shared
  guest flow over the control wire). macOS uses the identical container path, so
  a fix/verification here covers all hosts. See
  [[optimization-macos-vz-idiomatic-exec-layer-2026-06-21]].
- If any backend leaves the token at rest, file the remediation as a child
  packet (e.g. explicit shred of the gh config before container removal, or a
  tmpfs-backed container HOME).
