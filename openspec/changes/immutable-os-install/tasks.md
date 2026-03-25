## 1. Detection

- [x] 1.1 In `scripts/install.sh`, after architecture detection and before the Linux package manager block, add an `IS_IMMUTABLE=false` default
- [x] 1.2 Add detection: if `/run/ostree-booted` exists OR `rpm-ostree` is in PATH, set `IS_IMMUTABLE=true`
- [x] 1.3 When `IS_IMMUTABLE=true`, print: "Immutable OS detected (Silverblue/Kinoite/uBlue) — installing to userspace"

## 2. Routing

- [x] 2.1 In the Linux install block, add an early check: if `IS_IMMUTABLE=true`, skip directly to the AppImage download (set `INSTALLED=false` path, bypass all deb/rpm/COPR/rpm-ostree logic)
- [x] 2.2 Ensure the AppImage fallback message is adjusted to not say "Falling back" when IS_IMMUTABLE is true — it's the intended path, not a fallback

## 3. Verification

- [x] 3.1 Run `bash -n scripts/install.sh` — no syntax errors
- [ ] 3.2 Manually verify: on a non-immutable system the deb/rpm path is still attempted as before
