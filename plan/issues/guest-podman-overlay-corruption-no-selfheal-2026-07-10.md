# Guest podman overlay corruption → permanent image-build 125, no self-heal (2026-07-10)

- class: bug (robustness) — captured by macOS overnight cycle 3/8 via the
  TILLANDSIAS_PTY_DEBUG tee + `--exec-guest` idiomatic probe (no ssh/root)
- observed on: osx-next VM after cycles 1-2 (destructive provision + several
  attach attempts, at least one of which reaped an in-VM build per order 270)
- promoted: plan/index.yaml order 281 (renumbered from 278 — uniqueness gate caught a collision with forge-harness-icap-proxy) (linux-owned; guest image-build path)

## Symptom (verbatim, PTY debug tee)

A `--github-login` attach reached the containerized gh flow, which tried to
build the git image and died:

```
Error: Image command failed (status Some(125), retry Permanent):
  podman build -t localhost/tillandsias-git:v0.3.260710.6 ... -f .../images/git/Containerfile ...
stderr: Error: creating build container: creating container: creating
  read-write layer with ID "f143...": Stat /var/lib/containers/storage/
  overlay/88b4.../diff: no such file or directory
PtyClose code=1
```

`--exec-guest` probe confirms only `tillandsias-vault` built; git/proxy/
inference/forge are absent; 21 overlay dirs present but the git build's
expected parent `diff` is gone.

## Why this matters

The overlay store references a layer whose `diff` directory no longer exists
— a classic interrupted/killed-build artifact. `retry Permanent` means the
build never recovers: **every** subsequent login/attach fails because the git
image (needed for the gh flow) can never build. The operator sees repeated
failures with no path forward short of a full destructive re-provision.

## Likely cause + relationship to order 270

Order 270 established that a first-use attach reaps the in-VM image build
when the PTY closes. A killed `podman build` is precisely how an overlay ends
up referencing a missing `diff`. So order 270's fix (build survives PTY loss)
REDUCES the rate of this corruption, but does not REPAIR an already-corrupt
store — hence a distinct packet.

## Proposed reduction (order 278)

Before failing a build `Permanent` on a "no such file or directory" /
corrupt-overlay error, the guest image-build path should self-heal once:
detect the corrupt-storage signature, `podman system reset --force` (or a
scoped prune of the broken layer), and retry the build a single time. Pin
with a unit test on the error-classification + one-shot-recovery decision
(the destructive reset itself can be behind a trait seam so the test doesn't
need a real podman). Guard against reset loops (recover at most once per
build invocation).

## Housekeeping note

The osx-next VM is left in this corrupt state after cycle 3 (a destructive
re-provision already ran in cycle 1; not repeating it every cycle). A
`--provision` re-run or the next destructive e2e gate clears it. Operator: if
you relaunch the tray and see login/attach fail on a git-image build, that is
this finding — re-provision to clear until order 278 lands.
