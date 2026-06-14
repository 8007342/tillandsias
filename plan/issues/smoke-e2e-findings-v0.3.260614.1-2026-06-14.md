# Smoke E2E findings — release `v0.3.260614.1` — 2026-06-14

- Discovered by: `/smoke-curl-install-and-test-e2e` (Windows-equivalent variant)
- Release under test: `v0.3.260614.1` (published 2026-06-14T00:54:01Z), binary
  `tillandsias-tray 0.3.260614.1 (3395626c)`.
- Host: Windows (Yolanda, Win11 26200), branch `windows-next`.
- Runner note: the canonical skill targets a **Linux** runtime host (curl
  `install.sh` → `podman system reset` → `tillandsias --init` → `--opencode`
  forge lane). This host has no native podman and **no WSL distro installed**,
  so by operator decision the smoke was run as the **Windows equivalent**:
  download + verify + unzip the published `tillandsias-tray-...-windows-x64.zip`,
  then drive the headless `--diagnose` / `--provision-once` / `--status-once`
  surfaces. The `--opencode` forge lane is not available on Windows, so Steps 4+
  of the canonical runbook are out of scope here.

## Result: HALTED at provisioning (clean-room rootfs fetch 404)

The smoke could not reach Vault init / GitHub-login E2E: `--provision-once`
fails at the very first step (Fedora rootfs download) with HTTP 404. The host is
left clean (no partial WSL distro registered — the download fails before import).

### Evidence trail (`target/smoke-e2e/`)

- `01-verify.log` — published zip SHA256 verified **OK** against `SHA256SUMS-windows`.
- `tillandsias-tray.exe --version` → `0.3.260614.1 (3395626c)` (matches the tag).
- `03-diagnose-before.json` — clean-room baseline, exit 2 (degraded):
  `distro_registered:false`, `distro_running:false`, `wsl_version:"2.7.3.0"`,
  `release_tag:"fedora-44"`, `manifest_pin_x86_64_tar_xz:"a28cabe7c9df"`,
  `wire.reachable:false` ("no running WSL utility VM").
- `04-provision-once.err`:
  `RESULT: FAILED — GET https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-44-1.7.x86_64.tar.xz -> HTTP 404 Not Found`
  (exit code **1** = failed).
- `05-status-after.json` — exit 1, `reachable:false` (no VM came up, as expected).

### What actually exists on the Fedora mirror (verified with curl)

| URL | HTTP |
|---|---|
| `…/images/Fedora-Cloud-Base-Generic-44-1.7.x86_64.tar.xz` (manifest pins this) | **404** |
| `…/images/Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2` | 200 |
| `…/images/Fedora-Cloud-Base-GCE-44-1.7.x86_64.tar.gz` | 200 |
| `…/images/Fedora-Cloud-Base-WSL-44-1.7.x86_64.tar.xz` | 404 |
| `…/releases/44/WSL/` | 404 (no WSL tree; only `Cloud/` + `Container/`) |

Root cause: the Fedora **build (`44-1.7`)** and variant (**Generic**) are right,
but **Fedora does not publish a Generic `.tar.xz` rootfs for x86_64** — only
`.qcow2` (Generic), `.tar.gz` (GCE), and `.vhdfixed.xz` (Azure). There is no
official Fedora-44 WSL image either. The recipe manifest pins a **non-existent
artifact**, so every clean Windows (and macOS, same template) provision 404s.

---

### Work Packet: smoke-finding/fedora-rootfs-artifact-url-404

- id: `smoke-finding/fedora-rootfs-artifact-url-404`
- owner_host: linux            # canonical fix is in images/vm/manifest.toml (recipe scope); blocks windows+macos
- capability_tags: [recipe, vm-layer, fedora, podman, release, wsl]
- status: done
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.3.260614.1`
- severity: high — blocks ALL clean-room Windows/macOS provisioning (and HEAD: the
  current `images/vm/manifest.toml` still pins the same dead URL, so a re-cut
  release reproduces it).
- evidence:
  - `target/smoke-e2e/04-provision-once.err:1` — `… Fedora-Cloud-Base-Generic-44-1.7.x86_64.tar.xz -> HTTP 404 Not Found`
  - `images/vm/manifest.toml` `[output].artifact_url_template` = `…Fedora-Cloud-Base-Generic-44-1.7.{arch}.{format}` with `expected_rootfs_sha."x86_64.tar.xz"` pinned — artifact does not exist on the mirror.
  - curl matrix above: only `…Generic-44-1.7.x86_64.qcow2` (200) and `…GCE-44-1.7.x86_64.tar.gz` (200) are real rootfs/disk artifacts.
- repro:
  - `tillandsias-tray.exe --provision-once`  (Windows), or any clean-room init on macOS that resolves the same `artifact_url_template`.
  - `curl -sSL -o /dev/null -w '%{http_code}' https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-44-1.7.x86_64.tar.xz` → 404.
- next_action: >
    Repoint `images/vm/manifest.toml` `artifact_url_template` + `expected_rootfs_sha`
    to a real, WSL-importable Fedora-44 rootfs and re-pin SHAs. Three candidates,
    pick per the recipe design:
    (1) **Materialize from the pinned container base** — the manifest already pins
    `registry.fedoraproject.org/fedora:44` digests in `[[base]]`; export its rootfs
    to a tar (the Linux `materialize` / buildah-export path) and host/pin that as
    the per-arch artifact. Most aligned with vm-recipe-provisioning; produces a
    clean WSL rootfs. (2) **GCE tar.gz** (`Fedora-Cloud-Base-GCE-44-1.7.x86_64.tar.gz`,
    confirmed 200) — a real rootfs tarball; requires the fetch/import path to accept
    `.tar.gz` (gzip, not xz) and re-pin the SHA; carries google-compute-engine agents.
    (3) **Generic qcow2** — needs a qcow2→rootfs conversion step before `wsl --import`
    (heavier). Whichever is chosen, update the `{format}` token + per-format SHA keys
    and re-verify `--provision-once` reaches Ready on a clean Windows box.
- cross_host_impact: >
    macOS vz provisioning resolves the same `artifact_url_template`; this 404 blocks
    the macOS clean-room init too. A single manifest fix covers both once a real
    artifact + import path is chosen.
- events:
  - type: discovered
    ts: "2026-06-14T02:25:31Z"
    agent_id: "windows-yolanda-claude-20260614T004000Z"
    host: windows
  - type: claim
    ts: "2026-06-14T02:30:29Z"
    agent_id: "linux-macuahuitl-codex-20260614T023029Z"
    host: linux
    lease_id: "a78bab78943e"
    expires_at: "2026-06-14T06:30:29Z"
  - type: completed
    ts: "2026-06-14T02:43:55Z"
    agent_id: "linux-macuahuitl-codex-20260614T023029Z"
    host: linux
    lease_id: "a78bab78943e"
    implementation_commits:
      - "bf6b0d03"
    evidence:
      - "Fedora x86_64 OCI archive resolved through redirects to HTTP 200 and matched SHA-256 75200f5752a74a21a616ca9a75e25beb594e2e117a0195c54f87c0b3e3974d1b."
      - "Fedora archive manifest contains one application/vnd.oci.image.layer.v1.tar+gzip layer; the Windows path now preserves that layer tar's Unix metadata."
      - "Fedora aarch64 Generic qcow2 URL resolved through redirects to HTTP 200."
      - "cargo test -p tillandsias-vm-layer --features recipe,materialize,download: 56 passed, 2 ignored."
      - "cargo test -p tillandsias-windows-tray: 3 passed."
      - "./build.sh --check: passed."
      - "./build.sh --test: passed."
      - "Windows GNU cross-check reached native dependency compilation but could not complete because this Linux host lacks the MinGW C headers/toolchain."

---

## Linux canonical smoke: HALTED at Vault launch

The published Linux installer and checksum verification passed, the full
Podman reset left an empty store, and all application images built successfully
from scratch. Init then failed before Vault initialization because the image was
built only under its content-addressed tag while the runtime launched `:latest`.
The forge continuous-enhancement step was not run because init was unhealthy.

### Work Packet: smoke-finding/vault-digest-image-missing-latest-alias

- id: `smoke-finding/vault-digest-image-missing-latest-alias`
- owner_host: linux
- capability_tags: [rust, podman, vault, testing, release]
- status: done
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.3.260614.1`
- evidence:
  - `target/smoke-e2e/03-init.log:3994` — Vault commits
    `localhost/tillandsias-vault:sha256-256304745261e6a7ab1aa7bcb94d132e592c0a1c0112096a9ae5d6558ccc6f38`.
  - `target/smoke-e2e/03-init.log:4010` — runtime tries to pull
    `localhost/tillandsias-vault:latest`.
  - `target/smoke-e2e/03-init.log:4014` — localhost registry connection is
    refused because no local `:latest` image exists.
  - `target/smoke-e2e/03-init.log:4015` — init exits with
    `podman run vault failed: exit status: 125`.
  - `target/smoke-e2e/03-images-after-failure.txt` — Vault has only the
    content-addressed tag; other built images have digest, version, and latest
    aliases.
- repro:
  - `podman system reset --force && tillandsias --debug --init`
- next_action: >
    Make Vault consume the same canonical image decision and alias path as the
    other init-built images: either launch the exact content-addressed tag
    returned by the build or create the version and latest aliases before
    launch. Add a clean-store regression test that proves Vault launch never
    attempts a registry pull after a successful local build.
- events:
  - type: discovered
    ts: "2026-06-14T03:46:47Z"
    agent_id: "linux-macuahuitl-codex-20260614T033837Z"
    host: linux
  - type: claim
    ts: "2026-06-14T05:57:48Z"
    agent_id: "linux-macuahuitl-codex-20260614T055748Z"
    host: linux
    lease_id: "f5d0682267ce"
    expires_at: "2026-06-14T09:57:48Z"
  - type: completed
    ts: "2026-06-14T06:01:50Z"
    agent_id: "linux-macuahuitl-codex-20260614T055748Z"
    host: linux
    lease_id: "f5d0682267ce"
    implementation_commits:
      - "11f0ba1d"
    evidence:
      - "Vault bootstrap now carries the successful build's canonical `sha256-*` tag directly into `podman run`; the mutable `:latest` launch dependency is removed."
      - "`vault_launch_requires_the_content_addressed_image_tag` passes with default features and rejects `:latest` plus malformed digest tags."
      - "All four focused `vault_bootstrap::tests` pass with the Vault feature."
      - "`cargo fmt --all -- --check` passes."
      - "`./build.sh --check` passes."
      - "Strict feature-minimal clippy remains red on ten pre-existing dead-code/collapsible-if warnings outside this patch."

---

## PASS / clean observations (no packet — recorded so the release is on the convergence ledger)

- Published artifact integrity: `tillandsias-tray-...-windows-x64.zip` SHA256
  **verified OK**; unzip yields `tillandsias-tray.exe` + `install-windows.ps1` +
  `diagnose-windows.ps1` + `tray-diagnose.ps1`.
- `--version` reports the exact release tag + build commit (`0.3.260614.1 (3395626c)`).
- `--diagnose --json` / `--status-once --json` surfaces are healthy and their
  **exit-code contracts are correct** (diagnose 2=degraded pre-provision;
  status-once 1=unreachable with an actionable `error` string pointing at
  `--provision-once`).
- Clean-room hygiene: the failed provision left **no** partial WSL distro
  registered (download fails before `wsl --import`), so retry is idempotent.
- Linux installer integrity: public `install.sh` verified the release checksum,
  installed `Tillandsias v0.3.260614.1`, and found Podman 5.8.2.
- Linux clean-store build: proxy, git, inference, router, Chromium core,
  Chromium framework, forge base, forge, web, and Vault images all built
  successfully before the Vault alias mismatch halted init.
- Runner note (not a product bug): the GUI-subsystem binary's stdout is **not**
  captured by git-bash `>` redirection, but the **documented** `cmd /c "... > out.json 2>nul"`
  / PowerShell `Start-Process -RedirectStandardOutput` path captures it fine
  (2936 bytes). Future smoke-runners on Windows should use the documented form,
  not a git-bash pipe/redirect.
