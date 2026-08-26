# Windows/WSL2 curl-install e2e — v0.4.260826.1

## Run 2026-08-26T02:55Z→03:12Z — **PASS** (tag v0.4.260826.1, commit 341ab0010)

- **Host:** yolanda — Windows 11 26200.9168, WSL 2.7.12.0, AMD Ryzen AI 7 350, 8c/16t, 15.2 GiB
- **Channel:** `daily` — `scripts/resolve-smoke-release.sh daily` → `channel:daily tag:v0.4.260826.1`
- **Sibling heads:** main `341ab0010`, linux-next `f8a7ff0c2`, windows-next `c3b849e8e`, osx-next `171239dcf`
- **Falsifiers pre-registered before the tag existed:** `plan/issues/research/windows-e2e-preregistered-falsifiers-2026-08-26.md`, committed `4f8845ce9`. **None fired.**

## Result per step

| step | result | evidence |
| --- | --- | --- |
| 1 curl-install (pinned daily) | PASS | sha256 `62cfcea5…` verified by installer; `INSTALL_RESULT_RC=0` |
| version assertion | PASS | `tillandsias-tray 0.4.260826.1 (341ab0010)` |
| 2 destructive reset | PASS | `DESTRUCTION_GATE=PASS`, `CACHE_PURGE=PASS` |
| build-lane separation | PASS | `BUILD_LANE_SURVIVED=PASS` |
| 3 fresh init from pristine | PASS | `[provision] RESULT: VM Ready — control wire up ✓`, rc=0, 95 s |
| post-condition health | PASS | `Status: HEALTHY (exit 0)`, `Guest health: healthy` |
| guest vault | PASS | `tillandsias-vault Up (healthy)`, `tillandsias-proxy Up (healthy)` |

`--diagnose --json`: `version=0.4.260826.1`, `guest_version=0.4.260826.1`,
`build_commit=341ab0010`, `exit_code=0`, `distro_running=True`.
**Both version surfaces agree with the tag** — 635-bhkb's windows half means these
read `WORKSPACE_VERSION`, so no `0.1.0` was possible here.

Init log scanned for every failure signature the runbook names — `Error:`, panic,
`cipher: message authentication failed`, connection-refused, SIGSEGV,
short-name-mode, TLS, build failure: **all zero.** One benign notice
(`Failed to preset unit: systemd-tmpfiles-clear.service does not exist`), a
Fedora container artifact, not a failure.

## 803-49re Part A — VERIFIED, and attributed deliberately

**The attribution problem, and how it was avoided.** The runbook's reset clears the
two credentials *manually* (804-ckst). Running only that would have tested the
runbook, not the fix. So Part A's **own call site** was exercised first —
`tillandsias-tray.exe --reset-guest` — and the credential store read immediately
after, before the runbook's step could touch anything.

| credential | T0 pre-install | T1 post-install | **T2 after `--reset-guest`** |
| --- | --- | --- | --- |
| `vault-shamir-share-v1` | `76e3de20…` | identical | **ABSENT** |
| `vault-root-token-v1` | `2e30cdd0…` | identical | **ABSENT** |
| `tillandsias-vm-uuid` | `4193d527…` | identical | **`4193d527…` — byte-identical** |

Product output at T2: `[reset-guest] cleared host-side vault credentials:
vault-shamir-share-v1, vault-root-token-v1 (installation UUID preserved)` — and
the credential store was read independently to confirm it, because the log line
is the claim and the store is the fact.

Pre-registered branch taken: **absent (Part A cleared it)**. The FAILURE branch —
*still present and byte-identical* — did not occur. `tillandsias-vm-uuid` unchanged,
so the installation identity was not rotated.

Guest side after fresh init: **zero** `generate-root` aborts, no
`cipher: message authentication failed` anywhere, vault healthy. The 803-49re
spin (18 aborts in ten minutes on 2026-08-17) does not reproduce.

## WHAT THIS RUN DOES **NOT** COVER — read before treating it as 803-49re coverage

1. **GitHub login was never exercised.** It needs interactive device-flow auth,
   which an unattended run cannot perform. `github-login-last.log` is ABSENT in
   the guest — no attempt was made. Falsifier 2 is therefore **untested, not
   passed.** The sign-in state resolved correctly to `signed-out` on an empty
   credential store, which is the right behaviour but is not a login test.
2. **803-49re is NOT cleared by this run.** Part B — the reconcile half, where a
   delivered share that fails to authenticate must lose to the guest's own unseal
   secret — is unwritten (`890-y72v`, linux lane). A host that *already* holds a
   stale credential is untested by anything here; Part A only helps hosts that
   wipe after the fix.
3. **This host's starting condition was healthier than a typical user's** — the
   repaired entry from the operator's 2026-08-17 manual fix. So this tests Part A's
   *clearing* behaviour, not its recovery-from-broken behaviour.
4. **A credential transition was observed but not hashed.** Between T2 (absent) and
   the runbook's clear, the fresh guest's handover had repopulated both entries —
   the runbook step reported clearing them rather than finding them absent. The
   intermediate values were not captured, so *regenerated-and-different* is inferred
   from absent→present, not proven byte-wise. The originals are provably gone; that
   the replacements differ is an inference.

## Findings

**No product defects found.** Two process defects, both mine:

- **My own evidence pipeline truncated a log.** `--reset-guest` was captured with
  `| tee "$LOG" | head -30`; `head` exiting SIGPIPE'd `tee`, so the file stops at 75
  lines with no RESULT line. This is the exact failure the meta-orchestration skill
  documents ("if you pipe the gate through `tail -N`… you will cut that block off").
  The result was recoverable from other surfaces, but the primary evidence file is
  incomplete. Every subsequent capture used redirection, never a truncating pipe.
- **A summary describing shell commands was passed through a shell.** An earlier
  ledger event contained backticks inside a double-quoted string; bash executed them
  and substituted empty output. Caught by reading back what was written rather than
  trusting the tool's `appended` confirmation.

## Raw evidence

`C:\Users\bullo\e2e-20260826\` — `00-prestate-creds.txt`, `00-prestate-distros.txt`,
`01-postinstall-creds.txt`, `02a-reset-guest.log` (truncated, see above),
`02b-postreset-creds.txt`, `02c-destructive-reset.log`, `02d-cleanroom-creds.txt`,
`03-init.log`, `04-posthandover-creds.txt`, `05-diagnose.txt`, `05-diagnose.json`,
`06-guest-vault-state.txt`. Install log: `target/smoke-e2e/01-install-windows.log`.
