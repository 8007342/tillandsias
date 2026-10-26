## Why

Cloud minutes are metered, finite and paid by the operator. Today any agent
that reaches a host tool, a host script or the git mirror can spend them:
pushing to an integration branch starts GitHub Actions, `gh workflow run`
dispatches a release, and the Cloudflare deploy tool being specified in order
1853-qr4h will create Workers and connect repositories. Nothing between the
agent and the bill asks the human. Operator direction 2026-10-25: every action
that costs cloud minutes needs an approval the operating system verified, given
outside the forge, which an agent can never give itself.

The same direction asks for two related surfaces that share the dialog work:
a fully informed window before large first-use downloads, and a startup and
shutdown splash so the operator stops clicking the tray icon while it starts.

## What Changes

- A host **approval broker** (in the tray process) that turns a request for a
  cost-bearing action into a signed approval statement after an OS-verified
  user check. It lives outside the forge; the forge can only ask.
- A **gate table** of cost-bearing actions, starting with: triggering GitHub
  Actions or workflows, merges and pull requests into integration branches,
  creating remote workers, and creating or refreshing any Cloudflare resource.
  Gated in `handle_mcp_jsonrpc`, in host scripts that dispatch workflows, and in
  the git-mirror `pre-receive` hook.
- **Per-host enrolled approval keys**, hardware-backed and unlocked by the
  platform's lightest native check: a Secure Enclave key behind Touch ID on
  macOS, a Windows Hello (TPM) key credential on Windows, and a FIDO2 security
  key (YubiKey, `ed25519-sk`) on Linux, with a polkit-verified, honestly
  labelled software fallback where no hardware exists.
- An **approval record**: an SSH signature (`SSHSIG`, namespace
  `tillandsias-approval@v1`) over a canonical statement, stored as a git note
  on `refs/notes/tillandsias/approvals` and pushed atomically with the ref it
  approves; merge commits made by host tools also carry a plain
  `Approved-by:` trailer. The pre-receive hook verifies it with
  `ssh-keygen -Y verify` against the mirror's allowed-signers file.
- A **Mācron approval dialog**: a small, calm window showing Mācron doing the
  action in a workshop among tillandsias, with curated sentences saying what
  happens and what it costs.
- A **first-use download window** (later gate) with a storage bar and
  Tillandsias' share, driven by the download manifest specified in PR #650's
  change `forge-storage-single-root-and-disk-discipline`.
- A **lifecycle splash**, never always-on-top, whose Mācron animation advances
  only on tray lifecycle events, so a stuck step visibly stalls.

## Capabilities

### New Capabilities
- `approval-gate`: which actions are cost-bearing, where they are gated, and
  the rule that no agent can approve itself.
- `approval-attestation`: per-OS verification mechanisms and the enrolled
  per-host approval key.
- `approval-record`: the signed statement, its git note and trailer, and what
  the mirror `pre-receive` hook verifies.
- `approval-dialog`: the Mācron approval window and the curated sentence rules.
- `lifecycle-splash`: the event-driven startup and shutdown splash.
- `first-use-download-consent`: the informed large-download window and the disk
  bar.

### Modified Capabilities
<!-- None: the git-mirror and MCP changes are additive and specified in the new
capabilities above so existing requirements stay untouched. -->

## Impact

- `crates/tillandsias-headless`: new approval broker module; `handle_mcp_jsonrpc`
  consults the gate table before dispatching cost-bearing tools; the tray's
  lifecycle stages (`TrayStatusStage`) feed the splash.
- `crates/tillandsias-macos-tray`: Secure Enclave signer, LocalAuthentication,
  AppKit dialog and splash windows.
- `crates/tillandsias-windows-tray`: `KeyCredentialManager` signer, dialog and
  splash windows.
- `images/git/pre-receive-hook.sh`: verifies approval notes for integration and
  default branch updates, reading branch names from the branch-discipline seed.
- Host scripts that call `gh workflow run` gain an approval request step.
- Art: Mācron poses follow the canon in the macron.dev repository
  (`assets/Tlatoāni + Mācron cannon guidelines.md`).
- Related: order 1853-qr4h (Cloudflare deploy tool), PR #650 (download
  manifest and disk discipline).
