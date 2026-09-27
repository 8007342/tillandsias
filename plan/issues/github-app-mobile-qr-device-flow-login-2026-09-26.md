# GitHub App mobile QR device-flow login (1381-za6b)

- Date: 2026-09-26
- Reporter: operator (@8007342)
- Order: 1381-za6b
- Status: filed
- Deliverable: `crates/tillandsias-headless/src/main.rs`
- Cross-ref:
  - 777-kyjp (`github-login-device-flow-only`: remove token-paste prompts entirely; device login becomes only GitHub auth flow)
  - 648-e5pf (`github-login-asks-for-a-token-it-does-not-need-2026-08-10.md`)
  - 1025-a896 (`gh-auth-token-invalidation-investigation-2026-09-04.md`: multi-host OAuth 10-token eviction cascade)
  - `github-login-device-flow-dangling-enter-prompt-2026-08-16.md`

## Problem & Context

Currently, `tillandsias --github-login` (and the tray's GitHub Login action) presents a token-paste prompt (`main.rs` `GH_LOGIN_TOKEN_SCRIPT`) asking the operator to generate a fine-grained Personal Access Token and paste it into the terminal.

This has several compounding defects:
1. **Manual friction**: Operators must manually open a browser, create a PAT with specific permissions, copy it, and paste it into a raw or cooked terminal prompt.
2. **Multi-host eviction risk (1025-a896)**: Using GitHub CLI's OAuth app previously led to a 10-token per-account cap across the fleet, repeatedly revoking sibling hosts.
3. **Local browser dependency**: Relying on local browser redirects or manual copying on headless/remote hosts creates unnecessary failure modes.

## Operator Directive

The operator has created a dedicated GitHub App:
- Owner: `@8007342`
- App ID: `5081125`
- Client ID: `Iv23liddVkg9ME6OB1K1`
- Device Flow: Enabled

The requested flow:
When a user launches Tillandsias or clicks GitHub Login with missing/expired credentials:
1. The terminal displays a high-contrast QR code rendered via Unicode block characters (`▀` / `▄`), encoding the device verification URL with the pre-filled one-time code (`https://github.com/login/device?user_code=...`).
2. The user scans the QR code with their cellphone.
3. The user completes authentication and 2FA (FaceID, Passkey, GitHub Mobile push) on their mobile device without opening any local desktop browser.
4. Tillandsias polls the authorization endpoint in the background, writes the resulting token to Vault at `secret/github/token` (`token` field) from within the ephemeral container, and cleanly closes the login terminal without dangling prompts.

## Architecture & Security Discipline

1. **Host-Side Secret Isolation**: Per `spec:gh-auth-script` and `spec:tillandsias-vault`, host memory never holds the token. The public `client_id`, `device_code`, and `user_code` are unprivileged. `tillandsias-headless` initiates the device authorization and renders the QR code. The ephemeral container polls `/login/oauth/access_token` and streams the token directly to Vault via `vault-cli.sh write-stdin secret/github/token token`.
2. **Zero Image Rebuilds**: The `tillandsias-git` container already contains `curl`, `jq`, and `vault-cli.sh`.
3. **Pure Rust QR Generation**: `tillandsias-headless` uses the pure-Rust `qrcode` crate (default-features = false) with ANSI contrast wrapping (`\x1b[47m\x1b[30m`), rendering reliably on dark, light, or transparent terminal themes.
4. **Automatic Identity**: On successful auth, git `user.name` and `user.email` are resolved directly from `https://api.github.com/user`, eliminating manual prompt steps.
