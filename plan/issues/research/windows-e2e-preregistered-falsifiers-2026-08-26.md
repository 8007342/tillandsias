# Pre-registered falsifiers — Windows curl-install e2e, next daily

- **Host:** yolanda (Windows 11, WSL2), `windows-next`
- **Written:** 2026-08-26, **before the tag exists** and before any e2e run
- **Why committed rather than messaged:** a pre-registration that lives only in
  a transcript is indistinguishable from a rationalisation written afterwards
  (yoga, `9fbe0e935`). Third leg after macbook and yoga.

## Pre-state, recorded honestly

| fact | value |
| --- | --- |
| installed tray | `tillandsias-tray 0.4.260817.1 (0bba6525f)` |
| provenance | the published v0.4.260817.1 daily — a real release |
| distro `tillandsias` | STOPPED, will be unregistered by the reset |
| distro `tillandsias-build` | RUNNING — **must survive**; it is the Linux-artifact lane, not the product guest |
| Credential Manager | holds **all three**: `vault-shamir-share-v1`, `vault-root-token-v1`, `tillandsias-vm-uuid` |
| disk | 465G total, ~247G free (last purge reclaimed 34.9 GB) |

The `vault-shamir-share-v1` entry currently present is the **repaired** one from
the operator's 2026-08-17 manual fix, not a stale one. That matters for reading
the result below.

### PRE-RESET HASHES — recorded 2026-08-26T01:52Z, before the tag existed

Read via `CredReadW` (P/Invoke), SHA-256 of the raw blob. **Hashes only — the
share is an unseal secret and its plaintext is never printed or logged.**

| target | bytes | sha256 |
| --- | --- | --- |
| `vault-shamir-share-v1` | 44 | `76e3de20ef39f67a78397ac74eb84fa8a23b6ec68e66bab42ac8b163795b6575` |
| `vault-root-token-v1` | 28 | `2e30cdd09c4cfe245a543fed6c86fc6c8963d22bcbbde2f557aae9e47a8adcf2` |
| `tillandsias-vm-uuid` | 36 | `4193d5277645f8a97ac56b4053b29c0429d81b2efbd1911efdccb75dfc5a5f86` |

This is the irreversible-if-missed step: once the reset runs, the pre-reset
value cannot be recovered. Falsifier 3 is unfalsifiable without it.

`tillandsias-vm-uuid`'s hash is recorded for the opposite reason to the other
two — it must be **UNCHANGED** afterwards. Part A preserves it deliberately, and
a changed UUID means the reset rotated the installation identity, which is its
own defect regardless of what GitHub login does.

### A PRE-STATE FACT I REPORTED WRONG, corrected here

Earlier tonight I told the coordinator this host held only
`vault-shamir-share-v1` and `tillandsias-vm-uuid`. **That was wrong — all three
have been present the whole time.** The cause was my own filter, not a state
change: I ran `cmdkey /list | grep -i "tillandsias\|vault-shamir"`, and
`vault-root-token-v1` matches neither pattern. A grep that cannot match the
thing it is looking for returns a clean, confident, wrong answer.

Recorded rather than quietly fixed because it is the same shape as the four
findings that died tonight — an artifact read as evidence of a measurement that
never happened — and because it was very nearly load-bearing: a run that only
watched the share would have missed the root token being cleared or preserved,
and Part A clears **both**.

## THE HAZARD SPECIFIC TO THIS LANE — my own fix is under test

803-49re means a stale `vault-shamir-share-v1` surviving the reset will break
GitHub login on the fresh guest. Part A (`a8cd8cc32`) is supposed to prevent
exactly that, and **I wrote it.** So this e2e is not an independent test of the
release; it is partly a test of my own change, run by me, on the host where I
measured the original defect.

**The way I could get this wrong in my own favour:** treat a passing GitHub
login as evidence the release is healthy, when it would equally be evidence that
*only my fix* is working — or, worse, that the credential simply happened to
still be valid because this host's guest was never actually wiped hard enough to
invalidate it. A pass that I cannot attribute is not a pass.

**Mitigation, decided in advance:** before the reset I will record the current
`vault-shamir-share-v1` blob's hash, and after the reset I will record whether
the entry is absent (Part A cleared it) or present-and-different (the handover
re-populated it from the fresh guest). I will report **which of those happened**
alongside the login result. If I cannot tell, the login result does not count as
coverage for 803-49re.

## Falsifiers — stated before the run

The run **FAILS**, and I will report it as failed, if any of these hold:

1. **`tillandsias-build` is gone or broken after the reset.** The runbook says
   `--terminate` not `--shutdown` (802-bajv) precisely to avoid this. If my
   Linux-artifact lane is collateral damage, the runbook is wrong regardless of
   what the product did.
2. **GitHub login fails on the fresh guest** with the 803-49re signature —
   `cipher: message authentication failed` in
   `/root/.cache/tillandsias/github-login-last.log`. This is the primary thing
   under test and a failure here means Part A did not do its job.
3. **`vault-shamir-share-v1` is still present AND byte-identical** to the
   pre-reset value. That is Part A failing silently — login might still work by
   luck if the share happens to match, and it would be the misleading pass this
   document exists to prevent.
4. **The installed version does not match the new tag** at `--version` or in
   `--diagnose --json`. Both surfaces already read `WORKSPACE_VERSION` on
   Windows (635-bhkb's windows half landed long ago), so there is no excuse for
   a `0.1.0` here.
5. **`--diagnose` exits non-zero, or reports `podman_ready=false`** on the first
   poll after `Ready`.
6. **The run takes a health reading before its last mutating step.** Per the
   2026-08-10 rule: a post-condition belongs after the last MUTATING step, not
   the last interesting one. If I launch the tray after the last `--diagnose`,
   that diagnose is stale and the run is unfinished.

## What would make me DISTRUST a pass

- Any step where I substitute a command because the documented one is missing,
  without saying so. (`/usr/bin/time` was absent on this lane tonight; assume
  more of that.)
- A `--diagnose` green taken while the model re-pull is still running. The
  weights live inside the VHDX and `--unregister` deletes them (806-a4tu), so
  every Windows run of this smoke is cold **by construction** — ~447 MB re-pull
  measured 2026-08-17. A fast green is suspicious, not good.
- Anything I only observed once. Three of my four numbers tonight needed
  correcting after n=1.

## What this run CANNOT establish, stated up front

- It cannot clear 803-49re. Part B (the reconcile half, `890-y72v`) is unwritten,
  so a host that already holds a stale credential is untested by anything I do
  here — Part A only covers hosts that wipe *after* the fix.
- It cannot speak to gate performance. The 38.6x bridge finding (`895-bkrn`) is
  about `/mnt/c`; the e2e exercises the installed product, not the build lane.
