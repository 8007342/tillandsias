# yolanda-windows' working GitHub login rests on a file nothing provisions, and the tray deletes the guest on its own

**This row has a clock on it.** The other rows from tonight describe defects
that sit still. This one describes a host that currently LOOKS FIXED and will
stop being so without announcing it, at a moment nobody chooses.

`yolanda-windows` can authenticate to GitHub as of 2026-09-15T22:31Z. That
capability depends on `/home/forge/src/tillandsias/.git/config` inside the WSL
guest — a file **hand-written by an agent**, which nothing in the product
creates, restores, or knows about.

The tray reprovisions the guest ON ITS OWN when a control-wire handshake fails.
It did exactly that on 2026-09-12:

```
06:21:39  ERROR control wire unreachable after this run rewrote the guest wiring
          — discarding the guest and reprovisioning
06:21:40  INFO  damaged distro unregistered distro="tillandsias"
06:21:42  INFO  provision phase phase=InstallingTillandsias
```

When that happens again, the file goes with the guest. The host returns to the
759-vceg refusal, with **no record anywhere of why login used to work**.

trace: 759-vceg, this session's root-cause row
host: yolanda-windows, v56.9.12.2
status: UNCLAIMED — filed, not owned. See §4.

---

## 1. Why this is worse than the defect it works around

The original state was honest: login failed, loudly, with an accurate message
naming its own cause. An operator hitting it learned something true.

The current state is a well-formed success that is not durable. Nothing in the
tray, the logs, or the refusal will say "this worked because of an unmanaged
file, and that file is gone". The next failure will present as a NEW defect,
identical in signature to the one already diagnosed, and the diagnosis that
explains it will be three weeks old and filed under a different symptom.

**This is the session's own condition applied to a repair rather than to a
fault**: the output of the fix is well-formed, and stops being true silently.

## 2. Scope — what is actually at risk

At risk: the ability of `yolanda-windows` to obtain a GitHub credential through
the supported flow. NOT at risk: the credential already in Vault
(`secret/github/token`, created 22:31:09Z), which survives independently of the
checkout and of this file — it is the LOGIN that breaks, not the current token.

So the failure is deferred, not immediate: it bites the next time this host
needs to re-authenticate, which on the 1025-a896 axis may be soon (if the
seeded credential is a `gho_` device-flow token subject to the ten-token pool)
or not for a long time (if it is a fine-grained PAT). **That uncertainty is
itself part of the clock** and is unresolved — see the root-cause row §13.

## 3. What would actually fix it

The real fix is the root-cause row's: stop resolving the repository from the
process CWD in a lane that has no checkout by construction. Once that lands,
this file stops mattering and should be deleted rather than maintained.

Until then, the honest interim options, none of them chosen here:

1. **Leave it and accept the clock**, with this row as the record so the next
   failure is recognised in minutes instead of rediscovered.
2. **Provision it** — have the guest bootstrap write that `.git/config` the way
   it writes other guest-side artifacts. Cheap, but it makes an accidental
   workaround into a supported surface, which is the wrong thing to do to a
   workaround for a defect that should be fixed properly.
3. **Remove it and restore the honest failure.** Defensible: a host that fails
   loudly is better than one that works by accident. Costs the operator their
   working login for no benefit until the real fix lands.

Option 2 is the tempting one and is probably wrong. Recorded so nobody reaches
for it without seeing that it was considered.

## 4. Ownership

**Unclaimed, deliberately.** The host at risk is `yolanda-windows` and the
agent that created the unmanaged file is this session. It is not claimed here
because this host already holds one unlanded defect and its work cadence is the
operator's to set in batches — claiming a second item is how a host ends up
with two unpushed things and a gate it cannot win.

Filed so the clock is visible to whoever sets that cadence. Raised by
yoga-silverblue, who identified that this is the one finding from tonight with
a deadline attached.

related: [github-login push probe needs a checkout the guest lacks](github-login-push-probe-needs-a-checkout-the-guest-lacks-2026-09-15-yolanda-windows.md) — §11 (the experiment), §12 (the dependency), §13 (the 1025-a896 clock)
related: [the fault's output is well-formed, so only the reader it blocks can find it](the-faults-output-is-well-formed-so-only-the-reader-it-blocks-finds-it-2026-09-15-yolanda-windows.md)

---

**Tracking row: 1215-cxgb** — filed by macuahuitl 2026-09-16 so this finding is selectable by `plan_next`. It had no ledger row when it landed, which meant nothing would ever route it. The diagnosis above is the evidence; the row carries only the exit criteria.
