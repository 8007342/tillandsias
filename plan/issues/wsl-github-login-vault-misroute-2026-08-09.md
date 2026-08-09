# wsl-github-login-vault-misroute — login lanes misclassify WSL guests and crash the launch terminal

Filed 2026-08-09 from the Esmeralda N100 field host. Deliverable for packet
620-9xpg. Reported live by the operator: GitHub Login from the tray "crashed
big time", and copying the error text crashed the adjacent terminal too
(escape-sequence garbage).

trace: order 312 (non-elevated transport), packet 114 / vsock-vault-bootstrap-e2e
(the vault:8200-vs-8201 TLS-hang precedent this extends to CLI lanes),
crates/tillandsias-headless/src/vault_bootstrap.rs, crates/tillandsias-windows-tray/src/{wsl_lifecycle.rs,notify_icon.rs}

## Root causes (all live-verified on this host)

1. **`is_running_in_vm()` never fires in WSL guests.** Its three signals are
   delivered in-VM credentials (service process only), `TILLANDSIAS_HOST_KIND`
   (unset in login shells), and hostname `tillandsias-vm` — but WSL distros
   inherit the WINDOWS hostname (here `Esmeralda`). A bare
   `tillandsias-headless --github-login` shell therefore classifies as a
   native Linux host and probes vault at `https://127.0.0.1:8201` — the
   host-port-forward with the KNOWN WSL2/netavark TLS-hang that packet 114
   already routed the service around. Evidence (dummy-token run, no env):
   `ensure tillandsias-git-login: tillandsias-vault not satisfied: vault
   podman health is healthy but vault API probe failed: … 127.0.0.1:8201 …
   operation timed out`, after a multi-minute silent wait (vault resource
   lock serialization + 8 bounded 10s probes).
2. **The tray's login terminal argv goes through `wt.exe`'s re-parser.** The
   inline `bash -lc '<script with quotes/${}/&&/()>'` must survive both
   std::process MSVC quoting and Windows Terminal's own re-parse; the window
   died instantly and its error text carried terminal-hostile escapes (the
   operator's copy attempt took a neighboring terminal down with it).

Control evidence: with `TILLANDSIAS_VAULT_API_BASE_URL=https://vault:8200`
exported, the SAME dummy-token flow completes end-to-end in seconds and fails
exactly at GitHub validation: `error validating token: HTTP 401: Bad
credentials (https://api.github.com/)` — proving the vault write path, the
enclave URL, and the validation gate are all sound.

## Fixes (implemented this session, windows-next)

- `vault_bootstrap::is_running_in_vm()` gains a provisioning-owned marker
  check: `/etc/tillandsias/in-vm`, written by `inject_bootstrap_logic` (and
  therefore deployed by adopt-path reconciliation). Every in-guest lane now
  classifies correctly with no env dependency.
- `inject_bootstrap_logic` writes `/usr/local/lib/tillandsias/github-login.sh`:
  exports HOME/XDG_RUNTIME_DIR/vault URL, runs the login with all output
  tee'd to `/root/.cache/tillandsias/github-login-last.log`, and on failure
  names the log path and holds the window 10s. The tray's GithubLogin intent
  launches that bare path (no shell metacharacters through wt.exe).
- (Already present, verified:) the vault client bounds every probe at 10s —
  the observed 20-minute wedge was two concurrent diagnostic logins
  serialized on the vault resource lock, not an unbounded probe.

## Second field crash + third root cause (2026-08-09, after the wrapper landed)

The operator's retry with the wrapper-launching tray STILL died instantly:
`/bin/bash: -c: line 1: unexpected EOF while looking for matching '"'`
(exit 2). tray.log proved the launched argv was the metacharacter-free
`["/usr/local/lib/tillandsias/github-login.sh"]` — isolating the ONLY quoted
token left on the wt command line: the window title
`"Tillandsias — GitHub Login"` (spaces + em-dash force std::process quoting;
wt.exe's re-parser bleeds a dangling quote into the trailing args, which
wsl.exe joins into ONE `bash -c` string). Fix: `wt_safe_title` sanitizes
titles to single unquoted ASCII tokens at the wt argv boundary (raw display
titles unchanged); tests pin that no sanitized title ever needs quoting.
windows-next commit 2ae0e470 (pushed as cace9cd1 after merging linux-next
938459cb). Positive control after fix: relaunched tray reaches wire Ready on
attempt 1. Note the crash also validated the detachment work: the failing
terminal took down nothing else this time, and the error was plain
copyable text.

## Exit criteria

- [x] Dummy-token flow reaches GitHub validation and fails 401 in seconds
      (2026-08-09, evidence above).
- [ ] Real-token login succeeds on this host (operator retry pending).
- [ ] Tray-menu GitHub Login opens the wrapper, works, and leaves a readable
      `github-login-last.log` in the guest.
- [ ] Follow-up: known limitation — same-VERSION wiring changes do not
      redeploy through reconciliation (version string is the contract);
      dev hosts force it by removing the guest binary. Consider a wiring
      content hash alongside the version.
- [ ] Follow-up: tray icon appears in the taskbar overflow but not in
      Windows Settings > Taskbar > Other system tray icons (app-identity
      registration); watch after the next version bump.

## Evidence / handoff

- Branch: code on windows-next; this note + fragment on linux-next.
- Owned files: crates/tillandsias-headless/src/vault_bootstrap.rs,
  crates/tillandsias-windows-tray/src/wsl_lifecycle.rs.
- Next action: operator real-token retry via the documented with-token
  command or the rebuilt tray menu; append the outcome here, then the
  completed-status fragment.
