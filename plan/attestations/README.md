# Cross-host verification attestations

<!-- @trace spec:methodology-accountability -->
<!-- # freshness: auditor=linux-macuahuitl-fable5-20260825t195813z date=2026-08-25 verdict=updated scope=created with order 738-3pft; format agreed between the windows writer proposal (2026-08-14) and the macOS reply's constraints 1 and 3 -->

A host-native verification result that only its author can see is not evidence.
This directory is where a verification **crosses the host boundary**.

## Why this exists

On 2026-08-14 the linux host reported
`stale:windows-sources-never-verified:4` and quoted it to the operator as "the
largest unverified surface in this release", **holding a release on it** — while
the Windows host had run `cargo test -p tillandsias-windows-tray --bins`
natively, 89 passed, twice, once against the exact merge candidate, and stamped
both times. The stamp lived under `$GIT_DIR`, so it could not cross a host
boundary. A statement about the reader's **visibility** was read as a statement
about the **sources**.

Order 738-3pft. Sharpened from the windows host's 736-28m7.

## The format

One file per scope **and** host — `<scope>-sources.<host>.json` — so two hosts
never write the same path and git has nothing to merge. Same reason
`plan/index.d/` fragments are per-host.

```json
{
  "scope": "windows-only",
  "host": "windows",
  "attested_at": "2026-08-25T20:31:00Z",
  "commit": "9138147b...",
  "command": "cargo test -p tillandsias-windows-tray --bins",
  "result": "test result: ok. 89 passed; 0 failed; 7 ignored",
  "sources": {
    "crates/tillandsias-windows-tray/src/notify_icon.rs": "<git blob sha>"
  },
  "known_red": []
}
```

### Staleness keys on source content, never on the commit

This is the one design decision that matters, and it came from the writer side.
Keyed on the commit, an attestation would go stale on the very next commit — and
here the next commit is almost always a plan fragment. It would read `stale`
within minutes of being written, permanently, and we would have rebuilt
736-28m7 with extra steps: a verdict that says something about the sources while
actually reporting something else.

`commit` is **provenance only**. The reader recomputes every hash from its own
checkout, which is what makes this file evidence rather than a promise: you are
not believing someone's "89 passed", you are checking that the bytes they ran
against are the bytes you have.

Hashes are `git hash-object -- <path>` — **filtered**, never `--no-filters`.
With `* text=auto eol=lf` in `.gitattributes`, a CRLF Windows worktree and an LF
Linux checkout agree. Raw-byte hashing would make every cross-platform
comparison fail silently.

### `scope` is a field, not part of the token

The verdict grammar is shared across platforms so the macOS writer (739-6r6n)
reuses this vocabulary instead of minting a second one:

```
ok:sources-verified:<scope>:<n>          all n sources match the evidence
stale:sources-drifted:<scope>:<n>:<f>    n moved since the evidence, first is f
missing:sources-no-attestation:<scope>   THIS REPOSITORY holds no attestation
skip:no-sources:<scope>                  nothing to check
ok:sources-attested:<scope>:<n>          the writer wrote the tracked file
```

`missing:` is deliberately **not** spelled `never-verified`. Absence of an
attestation is a statement about this repository, not about whether anyone ever
ran the tests — and `stale:` now means one thing only: the sources moved.

## Writing one (one command)

```bash
cargo test -p tillandsias-windows-tray --bins 2>&1 \
  | scripts/check-windows-only-sources-verified.sh attest --from -
```

`--from -` reads the transcript from stdin, so no temp file is needed. The same
evidence gate as `stamp` applies: a transcript with no test results is refused,
and any `FAILED` test not named in `scripts/windows-only-known-red.txt` is
refused by name. A stamp with no transcript is an assertion, not a verification.

Add `--host <label>` when the auto-detected label is wrong — a Windows agent
running under WSL bash detects as `linux`.

Then commit the file. It is tracked on purpose.

## Reading one

`scripts/check-windows-only-sources-verified.sh check` prefers a tracked
attestation and falls back to the host-local `$GIT_DIR` stamp, so nothing that
depended on the local lane changed behaviour. `./build.sh --check` carries the
verdict on every Linux cycle.
