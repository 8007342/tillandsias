# `guest_wiring` reports "skipped-version-match" while holding the PREVIOUS install's version, so one run's diagnose contradicts itself

**Filed:** 2026-09-12 · **Kind:** bug (false reporting) · **Capability tags:** windows, tray, diagnose, provisioning
**Host:** ESMERALDINHA (N100/16GB, Windows 11, WSL 2.7.13.0)
**Severity:** not a wire defect — see the withdrawal below. A reporting defect on its own merits.

trace: `tillandsias-tray.exe --diagnose --json` (`guest_wiring` and `guest_version` fields)
       plan/issues/smoke-e2e-findings-v56.9.12.1-2026-09-12.md (the runs this came from)

## Claim

In a single `--diagnose --json` output, two fields disagree about which guest
is installed:

```
guest_version   : 56.9.5.1
guest_wiring    : { tray_version:          56.9.5.1,
                    guest_version_before:  56.9.12.1,      <-- the PREVIOUS install
                    outcome:               "skipped-version-match" }
```

`guest_version_before` carries a version that was replaced by an earlier
teardown and re-provision. The wiring step then reports that it **skipped
because the versions matched** — a match asserted against a value the run
itself contradicts four fields later.

## Measured

Observed on this host across two runs of the same rig:

| run | tray | diagnose `guest_version` | `guest_version_before` | outcome |
|---|---|---|---|---|
| v56.9.12.1 (FAIL) | 56.9.12.1 | null | 56.9.12.1 | skipped-version-match |
| v56.9.5.1 (PASS) | 56.9.5.1 | **56.9.5.1** | **56.9.12.1** | skipped-version-match |

The second row is the clear one: the distro had been unregistered and
re-provisioned from a wiped disk between the two runs, so 56.9.12.1 was not
present anywhere by then.

Note the first row is not evidence of the same thing — `guest_version` is null
there because the wire never came up, so there was nothing to read. Only the
passing run shows the contradiction cleanly. Stating this because the two rows
look like one pattern and only one of them is.

## WITHDRAWN as a wire lead — and why that is worth recording

I first raised this as a possible cause of 1084-x8ya's `noise: input error`,
reasoning that a guest left un-rewired across an upgrade would put a
version-bound PSK on one side and not the other. **That reasoning was wrong and
the lead is dead.** It is recorded here rather than deleted so the next reader
does not re-derive it:

- The root cause of the handshake failure is `release_root_secret()` hashing the
  running binary's own file (`current_exe` self-hash, found by macbookair,
  confirmed on yolanda). The tray and the headless binary are different files,
  so their digests can never be equal — the PSK mismatch needs no stale guest to
  explain it.
- My guest was not stale in any case. The published asset digest for
  `tillandsias-headless-x86_64-unknown-linux-musl` at v56.9.12.1 is
  `sha256:3d27e306…`, which is exactly the digest measured on the failing hosts.
  Byte-identical to what CI published.

So `skipped-version-match` skipped a re-wire that did not need doing, and the
wire failed for an unrelated reason. **The skip caused nothing.** What remains
is that the field is untrustworthy, and a decision is being made on it.

## Why it still deserves fixing

The outcome string asserts a fact ("the versions match") derived from a value
the same run shows to be stale. Any future defect whose diagnosis passes
through this field will be diagnosed against a lie, and a skip decided on a
stale read is a real skip even when today it happens to be harmless. It is also
exactly the kind of thing that gets rediscovered as a mystery in three weeks if
it lives only in a chat log.

## Exit criteria

- "`guest_version_before` reflects the guest actually present when the wiring step runs; pre-fix result: FAILS (reports 56.9.12.1 on a guest provisioned from a wiped disk that never held it)"
- "`outcome: skipped-version-match` is emitted only when the compared versions are both current reads; pre-fix result: FAILS (skip asserted against a stale value)"
- "the two fields cannot disagree within one diagnose output; pre-fix result: FAILS (guest_version 56.9.5.1 against guest_version_before 56.9.12.1 in one run)"
- "NEGATIVE CONTROL: a genuine version match still skips the re-wire — the fix is to make the read current, not to remove the optimisation"
