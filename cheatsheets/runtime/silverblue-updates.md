---
tags: [silverblue, rpm-ostree, akmods, nvidia, fleet, operations]
languages: []
since: 2026-09-13
last_verified: 2026-09-13
sources:
  - internal
authority: internal
status: draft
tier: bundled
---

# Silverblue updates: "ready, requires restart" that never applies

## The symptom

GNOME Software or `rpm-ostree upgrade --check` reports an update is **ready and
requires a restart**. The restart happens. Nothing changes. Repeat.

Checked afterwards, **nothing was ever staged**:

- no `/run/ostree/staged-deployment`
- no `ostree-finalize-staged` entries in the journal
- `rpm-ostree status` shows the same booted deployment as before

This is not a stale kmod, not a stuck apply, and not a corrupt deployment. The
failure happens **before** staging, which is exactly why a restart cannot fix it
and why the check keeps saying "ready".

## The cause

`akmods` — which the NVIDIA stack drags in — carries a rich dependency:

    (kernel-devel-matched if kernel-core)

`kernel-core` is present from the OSTree base, so the `if` **fires**. Every
`kernel-devel-matched` in the repo is then refused, because each one requires a
`kernel-core` the base already provides and no repo `kernel-core` can be layered
on an image that ships its own.

So when the base image bumps the kernel **before** the updates repo publishes
`kernel-devel-matched` for that exact kernel, depsolve fails. `--check` does not
depsolve, which is why it keeps answering "ready" about an update this host
cannot apply.

**It is transient by construction.** It clears when the repo catches up.

## Reading it yourself (read-only)

    journalctl -u rpm-ostreed --no-pager | grep -A3 'failed: Could not depsolve'

The line to look for, and the one that names the cause:

    Txn Upgrade ... failed: Could not depsolve transaction; 4 problems detected
     Problem 1: package akmod-nvidia-... requires akmods, but none of the
      providers can be installed
      - package akmods-...-noarch requires (kernel-devel-matched if kernel-core),
        but none of the providers can be installed

Or run the probe, which reports `skew:` / `ok:no-skew` / `could-not-run:` and
changes nothing:

    scripts/probe-silverblue-update-skew.sh

## The three remedies — the operator's choice, not an agent's

An agent reports this condition. It does not resolve it: every remedy changes
what is installed on someone's workstation.

1. **Wait.** The repo publishes `kernel-devel-matched` for the base's kernel and
   the update applies normally. Correct whenever the host is not needed on the
   new kernel today.
2. **Temporarily unlayer the NVIDIA stack**, update, re-layer. Fastest, and it
   costs the GPU driver until re-layered.
3. **Pin** the current deployment, if the host must not move at all while this
   resolves.

## Scope, measured

| host | layered | result |
|---|---|---|
| lenovinha | `akmod-nvidia akmods …` | 14 depsolve failures in ~2h, nothing staged |
| yoga | `google-chrome-stable rocm` | applied `44.20260913.0` cleanly, booted 7.2.5 |

Two Silverblue hosts **disagreeing** is what localises this: the variable is
`akmods`, not GPU drivers generally and not Silverblue. A host layering `rocm`
is unaffected.

Order 1165-g6wx. Root-caused read-only by lenovinha; scope confirmed on yoga.
