# install-macos.sh post-install verify crashes: `DIAG_PIN: unbound variable` — 2026-06-22

**Filed:** 2026-06-22 (macOS curl-install e2e of v0.3.260622.4)
**Kind:** bug (installer UX)  **Status:** ready  **Owner:** install-UX / macOS
**Trace:** `spec:macos-tray-build-and-release`

## Symptom

`curl …/install-macos.sh | bash` installs `Tillandsias.app` correctly (download +
SHA256 verify + extract to /Applications all succeed), but the final
post-install verification step crashes:

```
  verifying installed binary via --diagnose --json
bash: line 188: DIAG_PIN<bytes>: unbound variable
```

The app is installed fine; only the cosmetic verify-print aborts (non-zero exit
from the piped installer).

## Root cause

`scripts/install-macos.sh` runs under `set -euo pipefail` (line 18). Line 188:

```bash
say "installed: version=$DIAG_VERSION pin=$DIAG_PIN…"
```

The `…` is a multibyte ellipsis (U+2026) abutting `$DIAG_PIN`. Bash's
unbraced `$DIAG_PIN…` lexes part of the multibyte char into the variable name →
an unset name → `unbound variable` under `set -u`. (DIAG_PIN is assigned on line
187, so the value isn't the issue — the name lexing is.)

## Fix

Brace the variable so the ellipsis can't bleed into the name:

```bash
say "installed: version=${DIAG_VERSION} pin=${DIAG_PIN}…"
```

Closure: `curl …/install-macos.sh | bash` exits 0 and prints the
`installed: version=… pin=…` line. Add an install-script shellcheck / a
curl-install smoke that asserts exit 0.
