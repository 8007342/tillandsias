# Secrets & Trust Architecture

## Overview

Tillandsias manages secrets (GitHub tokens, SSH keys, git credentials) and build artifacts transparently. Users never see encryption mechanics, keyring prompts, or container mount configurations -- it "just works." You authenticate once, and every forge environment session has access to your credentials without re-authentication.

The trust architecture spans three domains:
1. **Credential secrets** -- user authentication tokens, SSH keys, git identity
2. **Build artifacts** -- container images, embedded scripts, Nix store outputs
3. **Runtime isolation** -- agent restrictions, mount permissions, container security

All three domains follow the same principle: **secure by default, transparent to users.** Phase 1 ships with practical security (restrictive permissions, signed binaries, content-addressed builds). Phase 2 adds encryption at rest and cryptographic verification.

---

## Secret Categories

| Category | Scope | Host Storage Path | Container Mount | Access |
|----------|-------|-------------------|-----------------|--------|
| GitHub auth | Shared (all projects) | `~/.cache/tillandsias/secrets/gh/` | `~/.config/gh/` | rw |
| Git identity | Shared | `~/.cache/tillandsias/secrets/git/` | `~/.gitconfig`, `~/.config/git/` | ro |
| SSH keys | Shared | `~/.cache/tillandsias/secrets/ssh/` | `~/.ssh/` | ro |
| Project tokens | Per-project | `<project>/.tillandsias/secrets/` | `<project>/.env` | rw |

**Shared** means the same credential is available in every forge environment. **Per-project** means the credential is only mounted into the forge for that specific project.

Default behavior is shared. Per-project overrides are configured in `.tillandsias/config.toml`:

```toml
[secrets]
git-identity = "per-project"
gh-auth = "per-project"
```

---

## Current Implementation (Phase 1)

### Plain directory mounts with restrictive permissions

Secrets are stored as plain files at `~/.cache/tillandsias/secrets/` with restrictive UNIX permissions:
- Directories: `0700` (owner only)
- Files: `0600` (owner only)

These directories are transparently mounted into containers at the paths where tools expect them. No configuration required from the user.

### Scripts embedded in signed binary

Build and setup scripts (`build-image.sh`, `ensure-builder.sh`, etc.) are embedded directly in the signed Tillandsias binary rather than existing as loose files on disk. This prevents tampering with the scripts that manage container creation, image building, and secrets mounting. An attacker cannot modify the scripts without invalidating the binary signature.

### Nix content-addressed store verification

All container images are built through Nix inside the `tillandsias-builder` toolbox. Nix provides content-addressed verification by design: every store path includes a cryptographic hash of its inputs. If any source file, dependency, or build instruction changes, the resulting hash changes. This means:

- Build outputs are reproducible -- the same inputs always produce the same hash
- Tampering is detectable -- any modification to a store path invalidates its hash
- Dependencies are locked -- `flake.lock` pins exact dependency versions with hashes

---

## Mount Strategy

Host paths are mapped to standard tool-expected paths inside containers:

```
Host: ~/.cache/tillandsias/secrets/
  |-- gh/           --> Container: ~/.config/gh/           (rw)
  |-- git/          --> Container: ~/.gitconfig + ~/.config/git/  (ro)
  |-- ssh/          --> Container: ~/.ssh/                  (ro)
  +-- per-project/  --> Container: <project>/.env           (rw)
```

**Mount flags:**

| Secret | Mount Mode | Rationale |
|--------|-----------|-----------|
| SSH keys | `:ro` | Forge should never modify SSH keys |
| GitHub auth | `:rw` | `gh auth refresh` needs write access to update tokens |
| Git config | `:ro` | Identity is set on host, forge reads it |
| Per-project secrets | `:rw` | Project may generate or rotate tokens |

All mounts use `--userns=keep-id` so file ownership maps correctly between host and container.

---

## Security Model

| Threat | Mitigation |
|--------|------------|
| Agent reads secrets | `/bash-private` patterns, `agent_blocked` skills prevent agent from reading credential files |
| Container escape | `--cap-drop=ALL`, `--security-opt=no-new-privileges`, rootless podman |
| Host reads secrets at rest | Phase 2: encrypted at rest via gocryptfs, key in system keyring |
| Cross-project secret leak | Per-project secrets mounted only into that project's forge |
| Token appears in AI context | Private auth flow -- credentials never enter the conversation |
| Backup exposure | Phase 2: encrypted blobs safe to back up; decryption requires keyring access |
| Stolen laptop | System keyring locked by OS login; Phase 2 encrypted secrets unreadable without session |
| Tampered build scripts | Phase 1: scripts embedded in signed binary, cannot be modified independently |
| Tampered container image | Phase 2: image hash verification; Phase 3: signed images |
| Tampered Nix store | Content-addressed verification -- any modification invalidates the hash |

**Trust zones:**

| Component | Trust Level |
|-----------|-------------|
| Tray App (signed binary) | Trusted -- manages keyring, mounts secrets, embeds scripts |
| Builder Toolbox | Trusted -- isolated Nix environment, reproducible builds |
| Forge Container | Untrusted -- has mounted secrets, but agent is restricted |
| User Code | Hostile -- no secret access beyond what the forge explicitly provides |

---

## Build Artifact Chain of Trust

The chain of trust ensures that every component from source to running container is verified.

### Phase 1: Embedded sources (current)

Build and setup scripts are embedded directly in the signed Tillandsias binary. This establishes a single trust anchor: the signed binary itself. The chain works as follows:

1. **Source scripts** (`build-image.sh`, `ensure-builder.sh`, etc.) are compiled into the binary at build time
2. **Binary is signed** -- the Tauri release process produces a signed application bundle
3. **At runtime**, the binary extracts its embedded scripts to a temporary directory, executes them, and cleans up
4. **No loose scripts on disk** to tamper with between runs

This means the user only needs to trust one artifact (the signed binary) rather than a collection of scripts.

### Phase 2: Image hash verification

After building a container image, Tillandsias records its content hash. On every container start, the image hash is verified against the recorded value:

1. `build-image.sh` produces a tarball via `nix build`
2. The tarball is loaded into podman (`podman load`)
3. The image digest (sha256) is recorded in `~/.cache/tillandsias/image-hashes.toml`
4. On container launch, `podman inspect --format '{{.Digest}}'` is compared against the recorded hash
5. If the hash does not match, the container launch is blocked and the user is notified

This detects image tampering, accidental corruption, and stale image references.

### Phase 3: Signed container images

Full image signing using `sigstore/cosign` or podman's native signing support:

1. After `nix build` produces the image tarball, it is signed with a project key
2. The signature is stored alongside the image (or in a transparency log)
3. On container launch, the signature is verified before the image is used
4. Public key is embedded in the signed Tillandsias binary (bootstrapping trust from the application signature)

This closes the loop: the signed binary trusts its embedded scripts, the scripts build verified images, and the images are cryptographically signed.

---

## Nix Store Protection

### Builder toolbox isolation

Container images are built inside a dedicated `tillandsias-builder` toolbox, separate from both the host system and the development toolbox (`tillandsias`). This provides:

- **Dependency isolation** -- Nix and its store (`/nix/store`) exist only inside the builder toolbox, not on the host or in development environments
- **Minimal attack surface** -- the builder toolbox contains only Nix and build dependencies, no development tools, user code, or credentials
- **Clean rebuilds** -- `scripts/ensure-builder.sh` can recreate the builder toolbox from scratch, and `build.sh --toolbox-reset` destroys and recreates it
- **No cross-contamination** -- the builder cannot access the development toolbox's state, and vice versa

The builder toolbox is created on demand by `scripts/ensure-builder.sh` and used exclusively by `scripts/build-image.sh`.

### Content-addressed verification

Nix's content-addressed store provides built-in integrity guarantees:

- Every store path (e.g., `/nix/store/abc123-package-1.0/`) includes a hash derived from all inputs (source, dependencies, build instructions)
- Changing any input produces a different hash, which means a different store path
- `flake.lock` pins every dependency to an exact revision and hash -- no implicit updates
- `nix build` verifies all fetched sources against their expected hashes before building
- The final image tarball's path includes a hash of the entire build graph

This means: if the `flake.nix`, `flake.lock`, or any source file is tampered with, the build either fails (hash mismatch on fetch) or produces a detectably different output (different store path).

### Phase 2: Encrypted Nix store at rest

When no build is in progress, the Nix store inside the builder toolbox contains the build cache and outputs. Phase 2 protects this at rest:

**Option A: gocryptfs overlay**
- The builder toolbox's `/nix/store` is backed by a gocryptfs-encrypted directory on the host
- Encryption key stored in the system keyring
- Unlocked when `build-image.sh` runs, locked when the build completes
- Transparent to Nix -- it sees a normal filesystem

**Option B: LUKS-encrypted loop device**
- A LUKS-encrypted loop file is mounted as `/nix/store` inside the builder toolbox
- Higher performance than gocryptfs for large stores (block-level encryption)
- Requires more setup but provides stronger guarantees

**Recommendation:** gocryptfs for consistency with the secrets filesystem encryption (same tooling, same keyring integration, same unlock/lock lifecycle). LUKS only if performance profiling shows gocryptfs is a bottleneck for large builds.

---

## Encrypted Secrets Filesystem (Phase 2)

### gocryptfs / LUKS options

Phase 2 replaces plain secret files with an encrypted filesystem at `~/.cache/tillandsias/secrets/`:

**gocryptfs (recommended):**
- Userspace FUSE -- no root required
- Per-file encryption -- plays well with backups, sync, and git
- Cross-platform potential (Linux/macOS via gocryptfs, Windows via cppcryptfs)
- Smaller attack surface than full block device encryption
- Initialization: `gocryptfs -init ~/.cache/tillandsias/secrets-encrypted/`
- Mount: `gocryptfs ~/.cache/tillandsias/secrets-encrypted/ ~/.cache/tillandsias/secrets/`

**LUKS (alternative):**
- Block-level encryption via loop device
- Better performance for large secret stores
- Requires root for initial setup (loop device creation)
- Linux only (macOS would need a different approach)

**Decision:** gocryptfs is the default. LUKS is available as a user-configurable option in `~/.config/tillandsias/config.toml` for users who prefer block-level encryption.

### System keyring integration

The encryption passphrase is stored in the OS system keyring so users never type it:

| Platform | Keyring Backend | API |
|----------|----------------|-----|
| Linux (GNOME) | GNOME Keyring / Secret Service | `libsecret` / D-Bus |
| Linux (KDE) | KWallet | D-Bus |
| macOS | macOS Keychain | Security framework |
| Windows | Windows Credential Manager | `wincred` |

**Key lifecycle:**
1. On first run, Tillandsias generates a random 256-bit encryption key
2. The key is stored in the system keyring under the service name `tillandsias-secrets`
3. On subsequent runs, the key is retrieved from the keyring automatically
4. If the keyring is locked (e.g., after reboot before first login), the OS prompts for the user's login password -- this is the only user-visible prompt
5. **Fallback:** if no system keyring is available, Tillandsias prompts for a passphrase once per session and holds it in memory

### Auto-unlock / auto-lock lifecycle

The encrypted secrets filesystem follows the container lifecycle:

```
First container start  ──>  Unlock secrets filesystem
                            (retrieve key from keyring)
                                │
                                v
                         Secrets available at
                         ~/.cache/tillandsias/secrets/
                                │
        ┌───────────────────────┤
        │                       │
  Container A running     Container B running
        │                       │
        └───────────────────────┤
                                │
Last container stop    ──>  Lock secrets filesystem
                            (unmount gocryptfs/LUKS)
                                │
                                v
                         Only encrypted blobs at
                         ~/.cache/tillandsias/secrets-encrypted/
```

**Rules:**
- **Unlock** happens on the first container start of the session (tray app retrieves key from keyring, mounts the decrypted view)
- **Lock** happens when the last running container stops (tray app unmounts the decrypted view)
- **Reference counting:** the tray app tracks how many containers are using the secrets mount; the filesystem stays unlocked as long as the count is > 0
- **Crash safety:** if the tray app crashes or is killed, the gocryptfs mount persists until the next reboot (kernel cleans up FUSE mounts) or until the user manually unmounts
- **Idle timeout:** configurable in `~/.config/tillandsias/config.toml` -- optionally lock after N minutes of no container activity, even if the tray app is still running

```toml
# ~/.config/tillandsias/config.toml
[secrets]
encryption = "gocryptfs"       # or "luks" or "none" (Phase 1 behavior)
idle-lock-minutes = 30          # 0 = lock only when last container stops
```

---

## Implementation Phases

### Phase 1 (current): Plain directory mounts + embedded scripts

| Component | Status |
|-----------|--------|
| `~/.cache/tillandsias/secrets/` directory structure | Created on first run |
| Plain files with `0600`/`0700` permissions | Active |
| Volume mounts into containers via podman | Active |
| Agent blocked from reading credential paths | Active |
| Build scripts embedded in signed binary | Active |
| Nix content-addressed store verification | Active (builder toolbox) |
| Builder toolbox isolation | Active |

**Scope boundary:** No encryption, no keyring integration, no image signing. Security relies on UNIX permissions, binary signing, and Nix's content-addressed store.

### Phase 2: Encryption at rest + image verification

| Component | Scope |
|-----------|-------|
| gocryptfs-encrypted secrets directory | `~/.cache/tillandsias/secrets-encrypted/` |
| System keyring integration | Store/retrieve encryption key |
| Auto-unlock on first container start | Tray app manages mount lifecycle |
| Auto-lock on last container stop | Reference-counted unmount |
| Encrypted Nix store at rest | gocryptfs overlay on builder toolbox `/nix/store` |
| Image hash verification on launch | `image-hashes.toml` + `podman inspect` check |
| Idle-lock timeout | Configurable in config.toml |

**Scope boundary:** No image signing, no multi-device sync, no secret rotation automation.

### Phase 3: Signed images + advanced isolation

| Component | Scope |
|-----------|-------|
| Signed container images | cosign or podman native signing |
| Per-project secret directories | `.tillandsias/config.toml` overrides |
| Deploy key management | Generate, store, mount per-project SSH keys |
| Secret rotation reminders | Token expiry detection and notification |
| Multi-identity support | Work/personal git identity switching |

**Scope boundary:** Full chain of trust from signed binary through signed images to encrypted secrets. This is the target architecture.
