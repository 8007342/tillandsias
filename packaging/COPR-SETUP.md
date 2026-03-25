# COPR Repository Setup

How the Tillandsias RPM reaches Fedora users via
[COPR](https://copr.fedorainfracloud.org).

## Architecture

COPR uses the **Custom source method**. Instead of building Rust from source
(which would require the entire Tauri/WebKit toolchain), the custom script
(`copr-custom-script.sh`) downloads the pre-built RPM from GitHub Releases and
repackages it.

```
GitHub Release (RPM artifact)
        │
        ▼
copr-custom-script.sh   ← downloads RPM, writes versioned .spec
        │
        ▼
COPR build system        ← extracts RPM, produces repo metadata
        │
        ▼
dnf install tillandsias  ← user installs from COPR repo
```

## One-time setup

1. Log in to <https://copr.fedorainfracloud.org> with your Fedora account.
2. Create a new project named `tillandsias`.
3. Under **Settings**:
   - Architectures: `x86_64`
   - Chroots: `fedora-rawhide-x86_64`, `fedora-43-x86_64`, `fedora-42-x86_64`
4. Under **Packages**, add a package named `tillandsias`:
   - Source type: **Custom**
   - Script: paste or upload `packaging/copr-custom-script.sh`
   - Builddeps: `cpio`
5. Under **Settings > Integrations**, copy the webhook URL.
6. In the GitHub repo **Settings > Webhooks**, add the COPR webhook URL:
   - Events: **Releases** only
   - Content type: `application/json`

## Trigger flow

1. A new GitHub Release is published (e.g., `v0.2.0.1`).
2. GitHub sends a release webhook to COPR.
3. COPR runs `copr-custom-script.sh`, which downloads the RPM from GitHub.
4. COPR builds the package (extract + repackage) and updates the repo.
5. Users get the update on their next `dnf update`.

## User install

```bash
sudo dnf copr enable 8007342/tillandsias
sudo dnf install tillandsias
```

## User update

```bash
sudo dnf update tillandsias
```

Or automatically via `dnf-automatic`.

## Manual rebuild

```bash
# Trigger a rebuild from the CLI (requires copr-cli + Fedora account)
copr-cli build-package 8007342/tillandsias --name tillandsias
```

## Files

| File | Purpose |
|------|---------|
| `tillandsias.spec` | RPM spec that extracts the pre-built RPM from GitHub |
| `copr-custom-script.sh` | COPR Custom source script — downloads RPM + writes versioned spec |
