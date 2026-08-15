# The Windows tray's embedded guest binary goes stale on any VERSION move

Filed 2026-08-13 (windows host, meta-orchestration cycle 7). Captured, not
fixed — it is not this cycle's packet, and the fix has a release-path shape that
deserves its own decision.

## What is red

`cargo test -p tillandsias-windows-tray` on this host:

```
test wsl_lifecycle::tests::embedded_guest_headless_matches_workspace_version ... FAILED
  embedded x86_64 guest headless does not contain workspace version 0.4.260812.1
  — stale staged binary; re-run scripts/build-guest-binaries.sh then
    scripts/build-windows-tray.ps1
```

85 passed, 1 failed, and the failure reproduces with this cycle's diff stashed,
so it is pre-existing and unrelated to order 648-772y.

## Why it is interesting rather than routine

The test is correct and its message is exactly right. What makes it worth a
packet is the *coupling* it exposes, which is the same family as the packet this
cycle drained:

- `crates/tillandsias-windows-tray/src/assets/tillandsias-headless-*` is a
  committed binary that carries a version string.
- `WORKSPACE_VERSION` moves whenever the build counter moves — which is every
  local build (`methodology/versioning.yaml`), and it moved twice on this host
  in the last 24 hours (0.4.260812.2 reverted to 0.4.260812.1 per the operator's
  ruling that a platform host does not own the release).
- Nothing rebuilds the asset when that happens, so the crate's own test suite
  goes red on a tree nobody touched.

A red that appears without a code change trains agents to read red as noise.
That is the same mechanism as the `rg`-missing litmus failure filed in
`research-windows-methodology-accountability-litmus-red-2026-08-13.md`, and it
is worth counting them together: this host currently has two standing reds that
are about the environment rather than the code.

## The connection to 648-772y

648-772y is about a tray injecting guest wiring whose version does not match the
guest's. This is the build-time half of the same coupling: the tray's *embedded*
guest binary and the tray's *own* version can disagree before it ships anything.
A tray built from a tree in this state would inject a guest binary whose version
string does not match `WORKSPACE_VERSION`, and `reconcile_adopted_guest` compares
exactly those two values — so it would re-inject on every single launch, forever,
each one reporting version skew to the operator.

That is a plausible amplifier for the incident 648-772y was filed from, and it
should be checked before assuming the shipped artifacts are clean.

## Not decided here

Whether the asset should be committed at all is the real question, and it has a
release-path answer (see order 710-w9kc, which removed a committed ELF sidecar in
favour of a staged build artifact plus a signed release asset — the same shape).
Deciding it from a host that cannot run the full release path would be guessing
at the blast radius.
