## Context

Tillandsias manages GitHub credentials through the `gh` CLI running inside a forge container. The authentication flow (`gh-auth-login.sh`) saves an OAuth token to `~/.cache/tillandsias/secrets/gh/hosts.yml` on the host. This file is then bind-mounted read-only into every forge container at `/home/forge/.config/gh/`. The file format is YAML with the token stored as a plain string.

The secrets-architecture design document (Phase 1) acknowledged this as a temporary approach. Phase 2 calls for encrypted secret storage. Using the OS keyring is the simplest, most secure path to Phase 2 — it provides encryption at rest, session-scoped unlocking, and zero extra infrastructure.

## Goals / Non-Goals

**Goals:**
- Store the GitHub OAuth token in the OS native secret service
- Retrieve the token at container launch time and make it available via the existing `hosts.yml` mount mechanism
- Auto-migrate existing plain text tokens into the keyring on first run
- Gracefully fall back to plain text when keyring is unavailable
- Keep the existing container mount interface unchanged (containers still see `/home/forge/.config/gh/hosts.yml`)

**Non-Goals:**
- Encrypting git identity (`.gitconfig`) — name and email are not secrets
- Encrypting SSH keys — separate concern, handled by SSH agent forwarding in a future change
- Providing a GUI for secret management — this is invisible infrastructure
- Removing the `hosts.yml` file entirely — the `gh` CLI inside containers expects it

## Decisions

### D1: Use the `keyring` crate for cross-platform secret storage

**Choice**: Add `keyring = "3"` to `src-tauri/Cargo.toml`. The `keyring` crate provides a unified API across Linux (Secret Service / D-Bus), macOS (Keychain), and Windows (Credential Manager).

**Rationale**: This is the standard Rust approach. No C FFI, no build-time dependencies. The crate is actively maintained and widely used. Tauri's `stronghold` plugin is an alternative but adds ~2MB of dependencies and requires its own key management — overkill when the OS already provides a secret service.

### D2: Store one secret with key `github-oauth-token` under service `tillandsias`

**Choice**: A single keyring entry with service name `tillandsias` and key `github-oauth-token`. The stored value is the raw OAuth token string extracted from `hosts.yml`.

**Rationale**: The `gh` CLI stores one token per host (e.g., `github.com`). Tillandsias only supports `github.com` today. If multi-host support is added later, the key can be extended (e.g., `github-oauth-token:github.com`).

### D3: Write a temporary `hosts.yml` at container launch, not at app startup

**Choice**: The token is retrieved from the keyring and written to `~/.cache/tillandsias/secrets/gh/hosts.yml` just before `podman run` is invoked. The file is overwritten each time.

**Rationale**: This minimizes the window where the plain text file exists on disk. The file is needed because the `gh` CLI inside containers reads `~/.config/gh/hosts.yml` — there is no way to pass the token via environment variable to the `gh` CLI. Writing it per-launch ensures the latest token is always used and avoids stale credentials.

### D4: Graceful fallback when keyring is unavailable

**Choice**: If the keyring operation fails (no D-Bus session, headless environment, locked keyring), fall back to reading `hosts.yml` directly. Log a warning but do not fail.

**Rationale**: Tillandsias must work in environments without a desktop session (SSH, CI). The keyring is an enhancement, not a hard requirement.

### D5: Auto-migrate existing tokens on first run

**Choice**: At app startup, if `hosts.yml` exists and contains a token but the keyring entry is empty, store the token in the keyring automatically. No user interaction required.

**Rationale**: Existing users should not need to re-authenticate. Migration is silent and idempotent.

## Risks / Trade-offs

- **Keyring locked**: On some Linux distributions, GNOME Keyring may not be unlocked until the user enters their password. If Tillandsias starts before login (e.g., autostart), the keyring may be locked. Fallback to plain text handles this.
- **D-Bus not available**: In containers, WSL without systemd, or minimal environments, the Secret Service D-Bus API may not exist. The `keyring` crate returns an error; our fallback handles it.
- **Token format coupling**: We parse `hosts.yml` YAML to extract the `oauth_token` field. If the `gh` CLI changes its format, extraction breaks. This is low risk — the format has been stable since gh 2.0.
