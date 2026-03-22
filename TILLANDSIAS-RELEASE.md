# TILLANDSIAS-RELEASE.md

**Release, Signing, Distribution, and Update Strategy (OpenSpec)**

---

# 1. Objective

Define a **low-friction, secure, transparent release pipeline** for Tillandsias that:

* Distributes binaries via GitHub
* Ensures integrity via signatures
* Enables seamless auto-updates
* Minimizes cost and operational overhead
* Scales toward reproducible, verifiable builds

---

# 2. Distribution Targets

## 2.1 Primary Artifacts

| Platform | Format                  | Rationale              |
| -------- | ----------------------- | ---------------------- |
| Linux    | AppImage                | Portable, zero install |
| macOS    | `.app` bundle (zip/dmg) | Native UX              |
| Windows  | `.exe` (portable)       | Minimal friction       |

---

## 2.2 Release Hosting

* Platform: GitHub Releases
* Versioning: Semantic (`v0.x.y`)
* Assets per release:

  * binaries
  * checksums
  * signatures

---

# 3. Signing Strategy

## 3.1 Primary Signing: Cosign (Sigstore)

Use Sigstore Cosign

### Key Properties

* **Free**
* No long-lived private keys required (keyless mode)
* Uses:

  * OIDC identity (GitHub Actions)
  * transparency log (Rekor)
* Verifiable publicly

---

## 3.2 How Cosign Works (Keyless Mode)

1. CI pipeline authenticates via GitHub OIDC
2. Cosign generates ephemeral signing key
3. Signature recorded in transparency log
4. Binary + signature uploaded

Verification:

```bash id="verify1"
cosign verify-blob \
  --certificate cert.pem \
  --signature app.sig \
  app.bin
```

---

## 3.3 Cost

| Component               | Cost                           |
| ----------------------- | ------------------------------ |
| Cosign                  | Free                           |
| Sigstore infrastructure | Free                           |
| GitHub Actions          | Free tier sufficient initially |

---

## 3.4 Alternative (Fallback)

Use minisign

* Static keypair
* Simple verification
* No transparency log

---

# 4. Platform-Specific Signing

## 4.1 macOS

### Apple Signing

Requires:

* Apple Developer Program ($99/year)

Benefits:

* No “unidentified developer” warnings
* Gatekeeper compliance
* Notarization support

### Recommendation

| Phase  | Strategy               |
| ------ | ---------------------- |
| MVP    | unsigned + user bypass |
| Growth | signed only            |
| Mature | signed + notarized     |

---

## 4.2 Windows

### Code Signing

* Certificate required ($100–$500/year)
* Improves SmartScreen reputation

### Recommendation

| Phase  | Strategy           |
| ------ | ------------------ |
| MVP    | unsigned           |
| Growth | basic signing      |
| Mature | EV cert (optional) |

---

## 4.3 Linux

* No centralized signing authority
* Rely on:

  * Cosign
  * checksums

---

# 5. Release Pipeline (CI/CD)

## 5.1 Trigger

* Git tag push (`v*`)

---

## 5.2 Steps

```text id="pipeline1"
1. Build binaries (Linux/macOS/Windows)
2. Package artifacts
3. Generate SHA256 checksums
4. Sign artifacts (Cosign)
5. Upload to GitHub Release
6. Publish release metadata
```

---

## 5.3 GitHub Actions Requirements

* Matrix builds
* OIDC enabled
* Secure dependency pinning

---

# 6. Update System

## 6.1 Requirements

* Silent check
* User-approved install
* Signature verification mandatory

---

## 6.2 Mechanism

Use Tauri updater:

* Source: GitHub Releases
* Download latest version
* Verify signature before install

---

## 6.3 Update Flow

```text id="update1"
App starts
  ↓
Check latest version
  ↓
Download artifact
  ↓
Verify signature (Cosign)
  ↓
Replace binary
  ↓
Restart
```

---

# 7. Trust Model

## 7.1 Guarantees

* Binary integrity (signature verified)
* Public transparency (Sigstore log)
* Source visibility (GitHub)

---

## 7.2 Threats Mitigated

* Tampered downloads
* Supply chain injection (partial)
* MITM attacks

---

## 7.3 Remaining Risks

* Compromised CI pipeline
* Malicious dependencies
* Social engineering

---

# 8. Reproducibility (Long-Term)

## 8.1 Goal

Enable users to:

> rebuild binaries and verify identical output

---

## 8.2 Approach

* Use Nix
* Define deterministic builds
* Publish build derivations

---

## 8.3 Outcome

* Trust shifts from:

  * “download binary”
    → “verify reproducible build”

---

# 9. Installer Strategy

## 9.1 Primary

* Direct download (GitHub)

---

## 9.2 Optional Script

```bash id="install1"
curl -sSL https://.../install.sh | sh
```

Script must:

* detect OS
* download correct binary
* verify signature
* install locally

---

## 9.3 Future Channels

| Platform | Channel           |
| -------- | ----------------- |
| macOS    | Homebrew          |
| Windows  | winget            |
| Linux    | AppImageHub / AUR |

---

# 10. Versioning Policy

* Semantic versioning
* Breaking changes explicit
* Backward compatibility where possible

---

# 11. Key Management

## Cosign (preferred)

* No persistent keys
* Identity = GitHub workflow

## Minisign (fallback)

* Store private key securely
* Publish public key in repo

---

# 12. UX Requirements

User should experience:

```text id="ux1"
Download → Run → Tray appears → Done
```

Updates:

* unobtrusive
* safe
* fast

No user interaction with:

* signatures
* verification steps

---

# 13. Minimal Viable Implementation

## Phase 1

* GitHub Releases
* Manual downloads
* SHA256 checksums

## Phase 2

* Cosign integration
* Automated CI builds

## Phase 3

* Auto-updater
* Silent verification

## Phase 4

* macOS notarization
* Windows signing

## Phase 5

* Reproducible builds (Nix)

---

# 14. Guiding Principles

* Security must be **automatic**
* Verification must be **invisible**
* Distribution must be **frictionless**
* Trust must be **verifiable**

---

# 15. Final Statement

Tillandsias distribution must reflect its core philosophy:

> ephemeral, portable, reproducible, and safe

Users should:

* trust the system
* not think about how

---

**Bootstrapping Directive**

Extend the existing project with:

* GitHub Actions pipeline
* Multi-platform build targets
* Cosign integration (keyless)
* Release automation
* Checksum generation

Design the system so that:

* every release is verifiable
* every update is safe
* every binary is reproducible (eventually)

---
