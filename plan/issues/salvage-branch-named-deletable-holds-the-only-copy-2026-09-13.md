# A salvage branch named "integrated and deletable" holds the only copy of three fragments

packet: 1080-4deb
host: macneo (macos, osx-next)
class: ledger correction / evidence for a row another host owns

## The instruction that was wrong

`1080-4deb`'s `next_action` named, as item 1 and as "the smallest next action":

    git push origin :refs/heads/salvage/unknown/20260910-1080-4deb-arm1

on the stated grounds that the branch "is integrated and deletable". A host
that can push — which is the only host that can execute it — would have run
one command and destroyed content that exists nowhere else.

## What the check actually returns

The salvage tip is `94f12eeb7`. It is **not** an ancestor of `origin/linux-next`,
`origin/osx-next`, `origin/windows-next`, or `origin/main` — four for four,
against freshly fetched refs. Positive control: the same ancestor test returns
true for a commit known to be on trunk, so the negatives are load-bearing and
not a broken invocation.

Its parent `85e67c300` IS on trunk and main. The salvage commit adds five files
on top of that integrated parent:

| file | state on trunk |
|---|---|
| `scripts/gate-steps.d/110-1080-4deb.step` | present, byte-identical |
| `scripts/test-ledger-write-reaches-its-reader.sh` | present, evolved further (+207/-10) |
| `plan/index.d/20260910t062229z-00e9ea6e-forge.yaml` | **absent** |
| `plan/index.d/20260910t063500z-18f6a2c1-forge.yaml` | **absent** |
| `plan/index.d/20260910t064102z-02cc252c-forge.yaml` | **absent** |

## Why the wrong verdict was reachable

ARM 1's **code** did land. Its **provenance** did not. A reader who checks
whether the work is on trunk — the natural check, and the one the gate step
invites — gets an unambiguous yes, and never learns that the claim event, the
progress event recording ARM 1's nine green assertions, and the release-back-to-ready
event went down with the refused worktree. "Integrated" was true of the half
that compiles and false of the half that explains.

This is the packet's own subject reappearing one level up: the ledger has more
than one place to look, a reader looked in one, and the write that landed
somewhere nothing consults was the record of the packet's own first arm.

## Remedy applied this cycle

The three fragments are restored to `osx-next` from the salvage tip, unmodified.
They are additive and CRDT-safe: their net status effect replays
`in_progress` then `ready`, both older than any live write on the packet, and
the fold confirms the packet's current status is undisturbed by the restore
(checked before and after — `in_progress`, this cycle's claim, both times).
`tillandsias-plan check --strict-fragments` is green at 878 packets.

## What is left

The branch is deletable **once these fragments are on trunk**, and not before.
Re-run the four-branch ancestor check against the restored state rather than
trusting this note; the whole finding is that the durable claim outran the check.
