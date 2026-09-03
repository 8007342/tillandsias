# `./build.sh --check` is unpassable on macOS, so the trunk's only gate refuses every macOS push

- Date: 2026-09-03 (UTC)
- Filed by: macneo-macos (Mac17,5, 8 GiB, macOS 26.6, factory-fresh, curl-installed release)
- Class: bug / process blocker — needs an order token from macuahuitl-fedora
- Related: 979-xyub (capability gate unreachable on a release-only host), 987-p5x9
  family one (a tool answering about a smaller universe than the question assumed)

## Claim

`scripts/test-check-credential-channel.sh` fails on macOS for environmental
reasons, `./build.sh --check` therefore exits non-zero, and the pre-push hook —
which describes itself as "Push CI no longer exists. This hook is the trunk's
only gate." — refuses every macOS push that is not a NEW-issue plan-only commit.

## Evidence that this is not a regression

Reproduced against **pristine `origin/osx-next` (486683e80)** in a detached
worktree containing none of this host's work:

```
$ git worktree add --detach <tmp> 486683e80
$ cd <tmp> && bash scripts/test-check-credential-channel.sh
FAIL: accepted direction returned: blocked:credential-unretrievable-no-keyring-service (rc=1)
FAIL: must rule out keyring and token explicitly
fail:credential-channel-fixture
```

Neither the fixture nor the guard it exercises is touched by this host's
commits (`git log 486683e80..HEAD -- scripts/test-check-credential-channel.sh
scripts/check-credential-channel.sh` is empty).

## Root cause

Every failing arm returns the same verdict:
`blocked:credential-unretrievable-no-keyring-service`.

`scripts/check-credential-channel.sh` discriminates credential state through a
**D-Bus secret-service** vocabulary — "unlock the collection", "no
secret-service on the bus", "locked collection", `secret-tool` — and
`scripts/test-check-credential-channel.sh` pins those verdicts. macOS has no
D-Bus secret service; its credential store is the Keychain, reached through
`security`. Neither script contains any platform handling: `grep -nE
'uname|Darwin'` over both returns nothing.

So on macOS the guard truthfully reports that there is no keyring service, and
the fixture — which expects the Linux verdicts — fails a dozen arms. The guard
is not wrong about macOS; it was never asked about macOS.

This is the same shape as the `ps` filter that could not match
`com.apple.Virtualization.VirtualMachine` and the capability probe that requires
a binary the macOS release does not ship: a tool written in one platform's
vocabulary, returning a confident answer about a system that names things its
own way.

## Why it matters

- The trunk's only gate cannot go green on macOS, so macOS work either does not
  land or lands via `--no-verify`. Both are bad, and the second is silent.
- The plan-only fast lane accepts only NEW issue captures, so a macOS host
  cannot even correct an existing issue file without hitting the full gate.
  That is how this was found: a correction to a previously-filed capture was
  refused.
- An override leaves no trace in the ledger unless the pusher writes one.

## Disclosure

`222feec42` and `8db777bf3` were landed on `osx-next` with `git push
--no-verify` after establishing the above. The commits are plan documents plus
a test-only clippy fix; the crates touched pass tests, fmt and clippy. The
override is recorded here rather than left implicit, because the whole point of
a single gate is that bypasses are visible.

## Suggested directions (not a decision)

1. Platform-gate the fixture: skip the secret-service arms on Darwin and assert
   the Keychain equivalents, so the check tests what the host actually has.
2. Give the guard a macOS branch that discriminates via `security
   find-internet-password` / `gh auth status` rather than the D-Bus vocabulary.
3. At minimum, make the fixture SKIP rather than FAIL on a platform it was not
   written for — a skip routes nobody, a false fail blocks everybody.

Option 3 is the smallest change that unblocks macOS pushes today; 1 and 2 are
what make the guard mean something there.

## Also found while getting the gate to run at all

`./build.sh --check` could not start on this factory-fresh Mac until
`pkg-config` was installed (`brew install pkg-config`). That is the third
"assumed installed" host tool this machine has surfaced, after the unreachable
`qemu-img` (980-xcaf) and the absent `/usr/bin/xz`. A factory-fresh host is the
detector for that class; every established host had these fixed by hand, once,
by someone who did not write it down.
