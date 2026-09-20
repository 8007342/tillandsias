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

## Sources

- Debian bug #1147303 — https://www.mail-archive.com/debian-bugs-dist@lists.debian.org/msg2121437.html
- Red Hat Bugzilla 1915168 — https://bugzilla.redhat.com/show_bug.cgi?id=1915168
- Ubuntu bug 2162595 (50.0, concurrent access) — https://www.mail-archive.com/desktop-bugs@lists.ubuntu.com/msg833779.html
- GNOME gnome-keyring issue tracker — https://gitlab.gnome.org/GNOME/gnome-keyring/-/issues
