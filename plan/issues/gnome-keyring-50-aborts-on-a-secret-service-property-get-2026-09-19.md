# gnome-keyring 50.0 aborts on a Secret Service property GET — upstream bug, not our container usage

- filed: 2026-09-19
- hosts: lenovinha-silverblue (5 SIGABRTs), macuahuitl-fedora (1)
- trace: order:1265-8qr6
- status: fleet fix is AVOIDANCE (both probes removed). The defect is upstream's.

## It is not container misuse. That hypothesis is dead.

The working theory for most of a day was that a `busctl` call from inside the
`tillandsias-builder` toolbox reached the host's session bus and the daemon
could not resolve the caller across the namespace. **That is wrong**, and the
evidence against it was already on our own hosts before the research:

- the 21:14:55 crash on lenovinha came from a **host-side** run, outside any
  container;
- both hosts run **identical** gnome-keyring 50.0-1.fc44, glib2 2.88.3-1.fc44,
  gcr3 3.41.1-12.fc44, dbus-broker 37-8.fc44, kernel 7.2.5-200.fc44, both
  wayland/GNOME with PAM-unlocked collections.

## The actual root cause, confirmed upstream

Debian **#1147303**, *"daemon aborts on a Secret Service property GET when the
caller has no PKCS#11 client record"*, describes our crash exactly:

1. `gkd_secret_service_get_pkcs11_session()` returns NULL — the caller has no
   `ServiceClient` record;
2. `secret_objects_lookup_gck_object_for_path()` guards with
   `g_return_val_if_fail()` and returns FALSE **without setting a GError**;
3. the property getter therefore fails with `*error == NULL`;
4. GLib's `invoke_get_property_in_idle_cb()` asserts `error != NULL` and
   **aborts the process**.

Our journal prints steps 1, 2 and 4 verbatim, in that order, before the core
dump — including the `gkd_secret_service_get_pkcs11_session: assertion 'client'
failed` and `secret_objects_lookup_gck_object_for_path: assertion 'session'
failed` lines we had recorded but not explained.

Affected: gnome-keyring **50.0-1** with glib 2.88.2 through 2.89.4. We are on
50.0-1 + glib 2.88.3. Upstream GNOME issues **#190** (same shape on the
`OpenSession` → `aes_negotiate()` path, **with a patch**), **#194**, and **#195**
(same abort site, open since 2026-09-02). The fix is to set a real
`G_DBUS_ERROR_FAILED` instead of returning FALSE silently.

## Why it is intermittent, which we could not characterise

Clients are registered **lazily**, via a `G_PRIORITY_HIGH` idle. A property GET
or `OpenSession` dispatched *before* that registration lands finds no client
record and takes the fatal path. **It is a race**, which explains what looked
host-conditional: five aborts on one host and one on another, same daemon, same
script. Frequency tracks timing and concurrency, not namespace.

The wider pattern is well attested — the same abort is reported from
python-keyring's backend probe, Poetry's parallel installer, and any tool that
opens a Secret Service session per operation in a burst.

## Why `busctl get-property` is such a reliable trigger

It is a **bare property read**: it never calls `OpenSession`, so it never
establishes a `ServiceClient` record at all. It is precisely the caller shape
step 1 describes. Our guard made two such calls, one of them looping over two
collections.

## What we did, and what is still open

Removed both `Locked` reads on every namespace (1265-8qr6) and kept the
diagnosis as text. That is avoidance, and it is the right fleet-level action
because the abort costs the host its credential channel.

Still open, and worth a follow-up:

- **Anything else on the fleet that touches the Secret Service** is exposed to
  the same abort. `gh` itself uses libsecret; we have not audited what call
  shapes it makes, and the exoneration of gh in 1265-8qr6 was only about *this*
  backtrace, not about gh being safe in general.
- **The upstream fix is not in our version.** Watch for a gnome-keyring release
  carrying the #190 patch and the #195 fix; until then avoidance is the only
  control.
- **A locked collection after an abort is a consequence, not a cause.** D-Bus
  re-activates the daemon and the new instance has no unlocked collection, so
  every abort costs an operator unlock. That is the real fleet cost, and it is
  why this is P1 rather than cosmetic.

## Is the missing client record a broken state? No — an unrepresentable one

Worth stating precisely, because it determines whether we can supply what is
missing. The daemon **is** a PKCS#11 token; collections and items are objects in
it, and the Secret Service D-Bus layer is a front end over that. Each D-Bus
caller gets a `ServiceClient` record holding its own PKCS#11 session, which is
what carries caller identity and unlock state. With no record there is no
session, so the lookup has no handle with which to resolve
`/org/freedesktop/secrets/collection/login` into an object. Nothing is corrupt.
There is genuinely nothing to look the path up *with*.

So it is not a broken state, and not quite a missing required one either. It is
a **legitimate state the code declines to represent**. `g_return_val_if_fail()`
is GLib's assertion for *programmer error* — "this cannot happen; if it did, the
caller has a bug." The daemon uses it for a condition an untrusted D-Bus peer
can produce at will. That is the defect: a remote-reachable state classified as
impossible, so the FALSE path never learned to set a `GError`, while GLib one
layer up asserts that a failed getter set one. Two components each locally
reasonable; the seam aborts.

## The client-side workaround exists, and we declined it

A caller obtains a record by calling `OpenSession` first — which is exactly what
libsecret does and what `busctl get-property` never does. So "supply the missing
state" concretely means *use a real Secret Service client* (`secret-tool`, or
libsecret) rather than a bare property read. That is the correct shape for any
probe we might want later, and it is recorded here so nobody re-derives it.

It is a workaround and not a fix, for two reasons:

- **It does not close the race.** Registration lands on a `G_PRIORITY_HIGH`
  idle. A client that calls `OpenSession` and *awaits the reply* is safe, but
  the python-keyring and Poetry reports are from real libsecret clients — they
  hit it when a second call overtakes registration. A polite caller narrows the
  window; it does not eliminate it.
- **It leaves the abort armed for every other process on the host.** Our own
  discipline protects nothing that we do not write.

We took avoidance instead. Restoring a probe via libsecret would buy back a
capability we decided we do not need, at the cost of re-entering a race. Do not
do it unless something later actually requires the check.

## Pinning to a pre-bug version: analysed, declined

Asked directly whether rpm-ostree could pin us below the bug. It can, and the
analysis is recorded because the obvious target is the wrong one.

**gnome-keyring is a dead end as a pin target.** The missing `GError` is
long-standing and was harmless for years; what changed is that **glib 2.88.2
made a getter failing with `error == NULL` fatal**. That is why Debian scopes
the report as *gnome-keyring 50.0-1 with glib 2.88.2–2.89.4* rather than to a
keyring version. Downgrading gnome-keyring lands on code carrying the same
defect.

**So the pin target is glib2**, and a pre-bug build does exist and was verified
available on 2026-09-19: `glib2-2.88.0-1.fc44` in the F44 GA repo, below the
2.88.2 floor. The mechanism is `rpm-ostree override replace --from repo=fedora
glib2 <subpackages>`, which works on base-image packages, not only layered ones.

Declined on three grounds:

- **Blast radius.** 293 of 1722 installed packages link `libglib-2.0` directly.
  This is the bottom of the GNOME stack, on a deployment whose same-day update
  moved 35 packages built against 2.88.3. Version skew there does not announce
  itself.
- **An override is sticky and silent.** It survives every `rpm-ostree upgrade`
  and rebase until `override reset`, freezing glib *security* updates too, with
  nothing to remind anyone it is there.
- **It buys less than it appears to.** The probe is already gone, so we no
  longer generate this abort. A pin would only cover third-party callers — real
  but unmeasured — at a large permanent cost against an unquantified risk.

**Recommended instead, and cheap — NOT YET APPLIED.** `ostree admin pin` on the
currently booted known-good deployment, so a rollback target cannot be
garbage-collected. Reversible, no ongoing cost, and it guards against a *future*
update making this worse. It needs operator sudo and could not be applied from
an agent session on 2026-09-19:

```
ostree admin status        # the * marks the booted deployment
sudo ostree admin pin 1    # index 1 = booted 44.20260918.0 at time of filing
```

Check the index before running it — a staged update shifts the numbering, and
on 2026-09-19 index 0 was the staged 44.20260919.0, not the booted one.

## Disposition: it gets fixed upstream, and we wait

The real fix is a few lines in gnome-keyring — set a `GError` on that path
instead of asserting — and it is already written for the sibling call site in
GNOME **#190**. We are not going to carry a patched build, downgrade the base of
the desktop, or re-enter the race with a politer client. **We avoid the call,
we watch for the release, and we hope upstream is not slow.** That is the whole
plan, stated plainly so that nobody mistakes the silence for an oversight.

The decision criterion if this needs revisiting: the probe was removed at
`3b1de6a32`. **If aborts recur with no `Locked` read in the tree**, a
third-party caller is involved, the residual risk becomes measured, and the
glib2 pin turns into a defensible trade. If they stop, the pin was never needed.
Honest gap in that reasoning: not all six recorded aborts are attributable to
our probe — the 21:14:55 one was host-side and outside our call path — so at
least one may have another origin. That argues for watching, not for pinning.

## Sources

- Debian bug #1147303 — https://www.mail-archive.com/debian-bugs-dist@lists.debian.org/msg2121437.html
- Red Hat Bugzilla 1915168 — https://bugzilla.redhat.com/show_bug.cgi?id=1915168
- Ubuntu bug 2162595 (50.0, concurrent access) — https://www.mail-archive.com/desktop-bugs@lists.ubuntu.com/msg833779.html
- GNOME gnome-keyring issue tracker — https://gitlab.gnome.org/GNOME/gnome-keyring/-/issues
