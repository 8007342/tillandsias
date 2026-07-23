# P1: saved-file runs of install-windows.ps1 SILENTLY SKIP download+extract — BOM-less UTF-8 em-dashes parse as CP-1252 smart quotes under PS 5.1

- Date: 2026-07-22
- Host: windows (windows-next), found during the order-455 smoke of v0.3.260722.1
- Class: bug (P1, release artifact integrity / installer)
- discovered_by: windows-bullo-fable5-20260722 (Set-PSDebug -Trace 1 on the
  published installer — the decisive evidence)
- Related: `smoke-finding/windows-installer-version-verify-transient-failure`
  (plan/issues/smoke-e2e-findings-v0.3.260719.1-2026-07-18-windows.md) — SAME
  ROOT CAUSE, that packet's "transient" framing is superseded by this doc.

## The failure (reproduced, deterministic)

Running the PUBLISHED installer from a SAVED FILE (`& install-windows.ps1`
after downloading it — the smoke-skill flow, the documented -Purge flow, and
any download-then-review corporate flow) under Windows PowerShell 5.1:

- The console shows `Fetching SHA256SUMS-windows...` then jumps straight to
  `Start Menu shortcut: ...` — the Asset/Downloading/SHA-256/Extracting steps
  NEVER RUN (`Set-PSDebug -Trace 1`: execution transfers from the
  Invoke-WebRequest statement directly to New-Shortcut, ~48 statements
  swallowed).
- Verification then fails (`--version` exit 1 — there is no exe) and the
  installer Dies with the MISLEADING "binary is broken".

## Root cause

The script ships as BOM-less UTF-8 and contains em-dashes (U+2014) INSIDE
string literals (e.g. `Die "Could not download ... — check network or
version."`). PS 5.1 reads BOM-less files as ANSI (CP-1252): the em-dash
bytes decode to `â€"` whose final byte is a CP-1252 RIGHT DOUBLE QUOTATION
MARK — and PowerShell treats Unicode smart quotes as legal QUOTE
CHARACTERS. The injected quote terminates the string early and re-pairs
with later mojibake quotes, so the file PARSES SUCCESSFULLY into a
DIFFERENT PROGRAM whose string literals swallow the download+extract
section. No parse error, no runtime error — silent structural corruption.

Why it was missed: the primary documented flow `irm ... | iex` DECODES the
HTTP body to a proper .NET string (charset/BOM detection) before parsing —
correct program, no symptom. Only saved-file execution breaks. The repo even
had a litmus step for this exact trap ("no em-dash in the preflight block")
— scoped too narrowly.

## Retro-diagnosis of the 2026-07-19 "transient" verify failure

The v0.3.260719.1 smoke's install "failed once then passed on retry" and was
filed as a transient first-exec flake. Wrong: NO installer run ever
extracted the exe on this host. The "successful retry" verified an exe this
agent had manually copied into the install dir during diagnosis minutes
earlier. The disappearing-directory confusion was the backup-rename dance
across failed attempts. That packet's next_action (verify retry + stderr
capture) remains nice-to-have but is NOT the fix.

## Fix (landed this cycle, windows-next)

1. `scripts/install-windows.ps1` transliterated to PURE ASCII (677
   non-ASCII chars -> 0: em-dash -> `--`, box-drawing -> `-`, ellipsis ->
   `...`). Sibling release-shipped scripts (diagnose-windows.ps1,
   tray-diagnose.ps1) and windows build scripts ASCII-fied too. All five
   parse clean under PS 5.1.
2. `litmus:installer-wsl-preflight-shape`: the narrow em-dash step replaced
   with a WHOLE-FILE pure-ASCII gate on the installer + a siblings gate.
3. The v0.3.260722.1 smoke proceeded with a BOM-corrected copy of the
   published installer (workaround documented in the smoke report); the
   published artifact itself is fixed at the next release cut.

## Exit criteria

- saved-file `& install-windows.ps1` on PS 5.1 downloads, extracts, and
  verifies identically to `irm | iex` (proven by the BOM-less fixed file)
- litmus fails on ANY non-ASCII byte reintroduced into the installer or
  shipped sibling scripts
- (optional hardening, linux lane welcome) release workflow adds a
  PS 5.1 `ParseFile` + pure-ASCII assertion on every shipped .ps1
