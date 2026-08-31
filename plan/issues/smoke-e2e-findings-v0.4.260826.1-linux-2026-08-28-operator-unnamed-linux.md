# Linux manual operator smoke — v0.4.260826.1 — after-the-fact record

## Run 2026-08-28, UTC window not captured — **PASS (operator-reported)** (tag v0.4.260826.1, commit 341ab0010, channel not captured)

This is an after-the-fact record of a manual test the operator reported
verbally on 2026-08-28. No transcript, log, screenshot, or structured
checklist was captured; this file was written 2026-08-28T19:54:36Z from the
verbal report alone. It exists so the release ledger holds SOME record of this
pass rather than nothing — it is deliberately the weakest grade of PASS in
this queue, and it supersedes nothing.

- **Host:** unknown — the operator did not name the machine, and no distro or
  podman versions were captured. `operator-unnamed-linux` in the filename is a
  placeholder, not a hostname. If the host is later identified, supersede this
  file with a proper leg rather than editing this one.
- **Tag:** the operator said the *latest published release*; the README
  release ledger (README.md:77+, newest row) puts that at **v0.4.260826.1**
  (**STABLE**, promoted 2026-08-26, tag pinned at commit `341ab0010`), so that
  is the tag this record names.
- **Install path:** not captured — unknown whether a fresh curl-install, an
  existing `~/.local/bin/tillandsias`, or something else. Channel therefore
  also unknown.

## Result

| check | result |
| --- | --- |
| release works on a Linux machine (the operator's own bar) | PASS — operator-reported, verbal, 2026-08-28 |
| release sustains real use | PASS (operator-reported) — the operator used this install to diagnose current progress, i.e. the release ran well enough to serve as a working tool, not merely to launch |
| channel resolution | NOT CHECKED — no data captured |
| SHA-256 / version assertion | NOT CHECKED — no data captured |
| install exit code | NOT CHECKED — no data captured |
| destructive reset + empty-store assertion | NOT CHECKED — unknown whether attempted |
| cold init | NOT CHECKED — unknown whether attempted |
| forge lane / in-forge MCP experts / egress assertion | NOT CHECKED — unknown whether attempted |

## Ledger claims

Sorting the v0.4.260826.1 ledger row's claims (README.md:77+, newest row)
against what this run can actually support:

### EXERCISED (to verbal strength only)

- "the published artifacts install … on three platforms" — the Linux slice,
  corroborated as "worked" plus one genuinely additional fact: the install was
  **used for real diagnostic work**, which the unattended 2026-08-26 legs
  (yoga, lenovinha) could not claim. Still uninstrumented: no captured detail
  supports any narrower claim. The instrumented 2026-08-26 Linux legs
  (`smoke-e2e-findings-v0.4.260826.1-linux-2026-08-26-yoga.md`,
  `…-lenovinha.md`) remain the authoritative Linux evidence for this tag.

### NOT APPLICABLE

- 635-bhkb (macOS tray reports workspace VERSION) and 663-acdw (macOS
  github-login expect ordering) — macOS-only claims.
- 804-ckst (Windows guest-wipe clears the host vault identity), 620-duta
  (portable tray without the VC++ redist), and the Windows GitHub-login gap —
  Windows-only claims.

### NOT CHECKED (no per-check data captured)

- Everything else in the row, including: SHA256SUMS match and cosign signing
  coverage; 894-scxy (credential-guard verdicts); 647-i98k (`--diagnose`
  CONVERGING); 731-m58f/vaqx/pc5r (cloud submenu); 648-jv69 (Retry control);
  749-8iw4 (vault audit records off the doomed layer); and 900-z3kv — this
  run says nothing about whether Linux resets are credential-cold, since it
  is unknown whether a reset was even performed. That gap stays exactly where
  the 2026-08-26 legs left it.

## What this run does NOT cover

1. **No structured checklist was run** — or none was captured, which for the
   ledger is the same thing: no per-check results, no logs, no hashes, no exit
   codes. Every individual ledger claim stays exactly as strong or as weak as
   the 2026-08-26 evidence left it.
2. Host identity, distro, UTC window, channel, and install path are all
   unrecorded.
3. No falsifiers were pre-registered; a verbal "worked" cannot fail a specific
   criterion. This record must never be cited as evidence for any individual
   claim above — only as "an operator ran the release on a real Linux machine
   on 2026-08-28, reported it worked, and used it to diagnose current
   progress".
