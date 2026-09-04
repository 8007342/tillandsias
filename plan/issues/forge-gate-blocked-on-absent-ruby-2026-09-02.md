# Every forge is gate-blocked: `./build.sh --check` reds on an absent `ruby` it cannot install

Filed 2026-09-02 by `pirria-tillandsias-forge` (N150 / 4 cores / CachyOS /
native podman, `TILLANDSIAS_HOST_KIND=forge`, v56.9.2.1, checkout seeded from
`linux-next` 2acb4f9ca). Found by being blocked by it.

## Symptom

`./build.sh --check` fails, reproducibly, at the last check it runs:

```
[build] Checking the plan archiver preserves the ready set (831-ezea)...
Running in check mode...
tillandsias: 'ruby' is not installed.
Install it in userspace with: brew install ruby
[build] the plan archiver would CHANGE THE READY SET, orphan events, or leave
        archived rows unanswerable — do not sweep
```

The message is a false statement about the ledger. The archiver did not
determine that the ready set would change; it never ran. `ruby` is absent, the
wrapper exited, and the caller reported the failure as a ledger verdict.

## Mechanism, read rather than inferred

- `scripts/archive-plan-packets.rb` opens with a `#!/usr/bin/env ruby` shebang.
- `scripts/archive-plan-packets.sh` documents the dependency explicitly in its
  `_ruby()` header comment: "this script has a HARD ruby dependency".
- The forge image ships no `ruby`. `which ruby` resolves to
  `/home/forge/.local/share/tillandsias/brew-shims/ruby` — the autoinstall
  shim, not an interpreter. `/home/linuxbrew/.linuxbrew/Cellar` does not
  exist; the tree is 31M of bootstrap with zero formulae.
- `brew install ruby` cannot supply it either. It fails on attestation:
  "attestation verification is REQUIRED and may be the cause — that is by
  design." So the documented remedy the message prints does not work here.

## Why this matters beyond one host

`core.hooksPath` aside, this is a property of the forge IMAGE, not of pirria.
Any forge that needs to push anything outside the plan-only allowlist
(`plan/index.d/`, `plan/loop_status.d/`, `plan/issues/`,
`plan/mo-full-attestations.d/`) must first pass the pre-push gate, and the gate
cannot pass. **The plan-only lane is therefore the only push path a forge has**,
which is a much stronger constraint than it is documented to be.

`tillandsias-plan append-event` writes the folded `plan/index.yaml` directly
rather than a fragment, so an events-only cycle does not qualify for the
plan-only lane by construction. A forge that records measurements on packets —
which is what a scout forge is for — lands outside the lane on its first
`append-event` and then cannot push at all.

## Two failures, not one

1. **The dependency.** A gate every host runs depends on an interpreter the
   forge image does not ship and cannot obtain. Either ship `ruby` in the forge
   image, or give the archiver check a no-ruby path.
2. **The classification.** Absent infrastructure is being reported as a ledger
   defect. The pair's protocol on 959-fpc5 already rules that a shim exit-127
   pre-classifies INFRA-ABSENCE; this call site does not honour it. A check
   that cannot run must say `unavailable:` and not render a verdict about data
   it never read — the same principle `check-capability-row` applies two checks
   earlier, where it prints `unavailable:forge-identity-ephemeral` rather than
   inventing a row.

(2) is the more dangerous half. (1) makes a forge slow; (2) makes a green
ledger look red, and a reader who trusts the message would go looking for
ledger damage that does not exist.

## Adjacent, filed separately

- `core.hooksPath` blinding `scripts/test-pre-push-empty-ref-list.sh` in every
  forge — fixed this cycle, recorded on 863-iicc.
- The brew autoinstall shim re-entering itself without a depth bound (3663 live
  processes, 89.4% of the 4096 pid ceiling) — recorded on 959-fpc5 and
  960-tpop. That is the same `brew install ruby` invocation as this one, seen
  from the pids side.

## Not verified

No fix is attempted here. Whether the archiver check has a viable no-ruby path,
and whether shipping `ruby` in the forge image is cheaper than removing the
dependency, are both open and belong to whoever owns 831-ezea's archiver.
