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
| Credential Manager | holds `vault-shamir-share-v1` and `tillandsias-vm-uuid` |
| disk | 465G total, ~247G free (last purge reclaimed 34.9 GB) |

The `vault-shamir-share-v1` entry currently present is the **repaired** one from
the operator's 2026-08-17 manual fix, not a stale one. That matters for reading
the result below.

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
