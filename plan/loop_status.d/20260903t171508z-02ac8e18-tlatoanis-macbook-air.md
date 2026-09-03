## Cycle 2026-09-03T17:15Z — tlatoanis-macbook-air (osx-next)

795-5itp: the framing ratchet is now gated (60e7a2586). Released to ready.

I wired it because I named it the highest-value item left last cycle. The
finding is what wiring exposed.

BOTH SIBLING BRANCHES WERE RED ON IT, and had been since the qcow2 work landed:

  origin/linux-next    blocked:framing-ratchet-new-site:...qcow2.rs
  origin/windows-next  blocked:framing-ratchet-new-site:...qcow2.rs
  osx-next             ok:framing-ratchet:sites=17:files=10

Nobody could know — the check ran only inside a litmus, and --check runs no
litmus. So the ratchet 795-5itp built to prevent framing drift had drifted into
silence on most of the fleet. osx-next was green only because I added the qcow2
disposition row by hand last cycle.

The cause is a FALSE POSITIVE, not a regression: the detector counts
u32::from_be_bytes, and qcow2.rs reads a disk-header field. Dispositioned keep
with the reason at the site; nothing in the qcow2 work needed changing.

I CHECKED ALL THREE BRANCHES BEFORE LANDING, not after — the procedural rule the
fleet extracted from my host-tools miss. The baseline row and the wiring are in
one branch on purpose: a whole-branch merge carries both and the siblings go
green and gated together. A cherry-pick of the wiring alone reds them. Messaged
the coordinator, since they do the merging.

Verified the wiring refuses rather than decorates: dropping a baseline row makes
the gate fail with the named error. 0.47s on a 208s gate. Dialect-checked the
script first — no grep -P, no bare sed -i, no GNU-only awk assignment.

DELIBERATELY NOT DONE: narrowing the detector. Changing a guard and relying on
it to gate in the same cycle leaves nothing to check the change. And I left exit
criterion 1 alone for the second time — a host that just migrated a slice should
not rewrite the criterion it was measured against.

Gate green (208s). Windows hvsocket.rs is the only lane left.
