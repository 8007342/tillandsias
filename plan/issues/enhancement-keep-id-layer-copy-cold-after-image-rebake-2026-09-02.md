# enhancement: a cold ID-mapped layer copy after an image rebake makes every `--userns=keep-id` fixture time out (2026-09-02)

Class: `enhancement/` (precondition gating; 956-llei family). Found on
macuahuitl during the stable-release gate of 2026-09-02 (`./build.sh
--ci-full` on 038075b1a), operator asleep.

## What happened

The full pre-build litmus reported four timeouts, every one a forge-runtime
fixture that runs the forge image with `--userns=keep-id`:

- `litmus:forge-standard-gitconfig-path` (30s budget)
- `litmus:forge-gitconfig-bidirectional-quarantine` (60s)
- `litmus:forge-runtime-ca-trust` (60s)
- `litmus:forge-config-trust-cross-platform-parity` (300s)

The new kill-time adjudicator (956-llei) read each one as **NOT contended**
(`cpu.pressure some-stall` 0% over the whole budget): the host was idle; the
step was genuinely waiting. Run under a cap by hand, the fixture's own output
names the wait:

```
Error: creating container storage: creating an ID-mapped copy of layer
"a948647c…": signal: terminated
```

Rootless podman materialises a per-user-namespace COPY of every layer the
first time an image is run with `--userns=keep-id`. The forge image is 3.1 GB;
the copy takes minutes. Every image on this host was rebaked today at
v56.9.1.2 after a tag prune (post-restart checklist, 2026-09-02), so the copies
the previous day's green ci-full had relied on no longer existed. The fixtures
are correct and fast once the copy exists (`scripts/test-forge-standard-
gitconfig-path.sh` exits 0 in seconds — the esmeraldinha audit measured the
same fixture at "zero seconds when run alone" and attributed the in-suite
timeout to contention, which was the instrument of that day; today's
adjudicator says otherwise, and the storage error is the direct reading).

Warmed once by hand — `podman run --rm --userns=keep-id
localhost/tillandsias-forge:v56.9.1.2 true` — and the four run inside budget.

## Why it matters

- Any host that rebakes images (every `--init` after a version change, every
  post-restart checklist run) has this cold state, and the first full litmus
  after it reads as four product failures. Yesterday's release ci-full was
  green because the copies happened to exist.
- The budgets encode "the container starts in seconds", which is true only
  after the first keep-id run per image version.

## Disposition

Two rungs, not claimed here (the release cut is the cycle's story):

1. **Warm at bake time.** The image ensure path (`ensure_image_exists`, and
   `tillandsias --init`) should perform one `--userns=keep-id` no-op run per
   freshly built image so the ID-mapped copy is part of "the image exists",
   not part of the first test that needs it. Cost is paid once, at the moment
   the operator already expects a long step.
2. **Fixtures name the precondition.** A keep-id fixture whose container
   creation exceeds ~10s should say `skip:keep-id-copy-cold:<image>` (or fail
   with that reason) instead of a bare timeout — the budget is then a claim
   about the product, not about podman's storage state (the RED-names-its-
   instrument rule).

Owner: linux lane; candidate epic convergence-velocity-milestone. Related:
811-28eh (the same "read the storage/cgroup, not the symptom" method),
956-llei (precondition gating holes).
