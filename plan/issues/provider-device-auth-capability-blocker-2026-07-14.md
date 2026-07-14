# Provider device-auth capability blocker - 2026-07-14

- affected packets: orders 303, 304, and 307
- host: Linux mutable
- discovery: delegated read-only source and installed-CLI audit
- status: aggregate packets blocked; Codex-only child ready as order 338

## Verified provider capabilities

| Provider | Installed CLI | Compliant device flow | Result |
|---|---|---|---|
| Codex | 0.144.4 | `codex login --device-auth` | available |
| Claude | 2.1.208 | none exposed by `claude auth login --help` | blocked |
| Antigravity | 1.1.0 | no auth/login subcommand | blocked |

The operator amendment requires a short code plus plain verification URI,
without browser launch, terminal hyperlinks, or paste-token fallback. Claude
and Antigravity therefore cannot be approximated with the current CLIs.

## Current implementation defects

- The tray launcher bypasses `ensure_provider_auth`; the CLI launcher calls it.
- Generic provider login selects a nonexistent `curl` image.
- `get_generic_login_token_script` is a hidden paste-token prompt even though
  the configuration says `OAuthDevice`.
- OAuth presence reads fields named after the provider, while writes use
  `access_token`.
- The forge image lacks the current `vault-cli.sh` helper used by the script.
- Launch injects API keys only; it neither restores nor harvests OAuth files
  from the ephemeral forge home.
- Claude, Codex, and Antigravity credential files disappear with `--rm`.

## Safe continuation

Order 338 implements the available Codex device-command and credential-schema
foundation without weakening the device-flow policy. Follow-on restore,
harvest, and tray parity slices must remain provider-specific. Orders 303 and
304 can be reshaped or resumed only when every named provider has a supported
device mechanism or the operator explicitly narrows their aggregate scope.

Order 307 remains blocked after its proxy fix because no supported
Antigravity/Gemini credential acquisition path can populate the credential
that launch currently expects.
