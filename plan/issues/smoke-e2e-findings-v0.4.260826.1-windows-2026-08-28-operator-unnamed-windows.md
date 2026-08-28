# Windows manual operator smoke — v0.4.260826.1 — after-the-fact record

## Run 2026-08-28, UTC window not captured — **PASS (operator-reported)** (tag v0.4.260826.1, commit 341ab0010, channel not captured)

This is an after-the-fact record of a manual test the operator reported
verbally on 2026-08-28. No transcript, log, screenshot, or structured
checklist was captured; this file was written 2026-08-28T19:54:36Z from the
verbal report alone. It exists so the release ledger holds SOME record of this
pass rather than nothing — it is deliberately the weakest grade of PASS in
this queue, and it supersedes nothing.

- **Host:** unknown — the operator did not name the machine, and no OS/WSL
  versions were captured. `operator-unnamed-windows` in the filename is a
  placeholder, not a hostname. If the host is later identified, supersede this
  file with a proper leg rather than editing this one.
- **Tag:** the operator said the *latest published release*; the README
  release ledger (README.md:77+, newest row) puts that at **v0.4.260826.1**
  (**STABLE**, promoted 2026-08-26, tag pinned at commit `341ab0010`), so that
  is the tag this record names.
- **Install path:** not captured — unknown whether the default stable path
  (`irm .../releases/latest/download/install-windows.ps1 | iex`), a pinned
  URL, or a pre-existing install was used. Channel therefore also unknown.

## Result

| check | result |
| --- | --- |
| release works on a Windows machine (the operator's own bar) | PASS — operator-reported, verbal, 2026-08-28 |
| stable-channel resolution | NOT CHECKED — no data captured |
| SHA-256 verification | NOT CHECKED — no data captured |
| install exit code | NOT CHECKED — no data captured |
| version after install | NOT CHECKED — no data captured |
| post-condition health / guest health | NOT CHECKED — no data captured |
| destructive reset + cold provision | NOT CHECKED — unknown whether attempted |
| GitHub login | NOT CHECKED — unknown whether attempted (untested in the 2026-08-26 legs too) |

## Ledger claims

Sorting the v0.4.260826.1 ledger row's claims (README.md:77+, newest row)
against what this run can actually support:

### EXERCISED (to verbal strength only)

- "the published artifacts install … on three platforms" — the Windows slice,
  corroborated only as "worked" with zero captured detail. This neither
  re-proves nor strengthens the instrumented 2026-08-26 yolanda legs
  (`smoke-e2e-findings-v0.4.260826.1-windows-2026-08-26-yolanda.md` and the
  `-stable-` sibling), which remain the authoritative Windows evidence for
  this tag.

### NOT APPLICABLE

- 635-bhkb (macOS tray reports workspace VERSION) and 663-acdw (macOS
  github-login expect ordering) — macOS-only claims.
- 900-z3kv, the Linux credential-cold gap — Linux-only.

### NOT CHECKED (no per-check data captured)

- Everything else in the row, including: SHA256SUMS match and cosign signing
  coverage; 804-ckst (guest-wipe clears the host vault identity); 894-scxy
  (credential-guard verdicts); 620-duta (portable tray without the VC++
  redist); 647-i98k (`--diagnose` CONVERGING); 731-m58f/vaqx/pc5r (cloud
  submenu); 648-jv69 (Retry control); and the Windows GitHub login gap, which
  the promotion itself names untested — this run does not change that.

## What this run does NOT cover

1. **No structured checklist was run** — or none was captured, which for the
   ledger is the same thing: no per-check results, no logs, no hashes, no exit
   codes. Every individual ledger claim stays exactly as strong or as weak as
   the 2026-08-26 evidence left it.
2. Host identity, OS/WSL versions, UTC window, channel, and install path are
   all unrecorded.
3. No falsifiers were pre-registered; a verbal "worked" cannot fail a specific
   criterion. This record must never be cited as evidence for any individual
   claim above — only as "an operator ran the release on a real Windows
   machine on 2026-08-28 and reported it worked".
