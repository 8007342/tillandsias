# Fleet restart 2026-09-12 — esme's drill notes

Per the coordination convention: hosts write their own flat file here and the
coordinator folds them into `plan/issues/fleet-restart-2026-09-12.md` on the
coordination pass. Flat, not `.d/` — the pre-push plan-only lane accepts
`plan/issues/*.md` and, one level down, only `research/`, `exploration/`,
`enhancement/`, `optimization/`; anything else takes the full gate (verified in
`scripts/hooks/pre-push-local-gate.sh`, the `*/*` arm).

- **The sanctioned gate on the floor tier is 2598 s, and the 6.75x I reported
  decomposes** (esme, confirming yoga's `resolve_target_binary` reorder at
  c91650cec). `./build.sh --check` launched from Git Bash so
  `with-wsl2-builder` re-execs — verified, not assumed, with
  `grep -c 'Re-execing inside' <gatelog>` = **1** against **0** on the earlier
  run — passed `CHECK_RC=0` in **2598 s (43m18s)**. The tier step's verdict
  verbatim:

      [build] Checking cheatsheet tier declarations...
      check-cheatsheet-tiers: 228 cheatsheets validated
        by tier: bundled=154, distro-packaged=0, pull-on-demand=74, unset=0

  228 is exactly yolanda's count on the same check.

  **THIRD CORRECTION TO MY OWN NUMBER, and this one partly restores what I
  disowned.** I first reported 4050 s as a floor-tier cost, then retracted that
  as "drvfs versus ext4, not two tiers". Both were wrong. The ratio factors
  cleanly:

      unsanctioned (drvfs target dir)   4050 s
      sanctioned   (ext4 target dir)    2598 s   -> configuration factor 1.56x
      yolanda, sanctioned              ~600 s    -> host factor          4.33x
      1.56 x 4.33 = 6.75, the observed ratio

  So bypassing the wrapper cost 1.56x, and the remaining **4.33x is a genuine
  host difference** between esme and yolanda on the same sanctioned path. My
  retraction over-corrected: I threw out a real tier signal along with the
  configuration error. The honest figure for "what a gate costs on the floor
  tier" is **2598 s**, and it is still roughly four times the capable Windows
  host. yolanda's ~600 s is their own approximation ("expect ~10 minutes"), so
  the host factor is good to about one significant figure and deserves a
  measured number from that side before anyone leans on it.

- **Confirming yoga's reorder did not require the gate at all.** The sanctioned
  path cannot reach the defect — `with-wsl2-builder` exports
  `CARGO_TARGET_DIR` to an ext4 dir holding Linux artefacts only, so
  `resolve_target_binary` never sees two runnable candidates and a green gate
  is silent about the ordering. The direct test, on the mixed drvfs directory
  that produced the false refusal and with both artefacts still present, took
  seconds:

      resolve_target_binary tillandsias-policy debug <root>
        -> target/debug/tillandsias-policy          (the ELF; previously the .exe)
      bash scripts/check-cheatsheet-tiers.sh
        -> OK: all tier checks passed.               (previously: ERROR, directory not found)

  Claimed on the verdict text rather than an exit code: the `PIPESTATUS`
  capture came back empty through nested `wsl.exe` quoting, which is the same
  trap recorded above, so the rc is not vouched for.

- **`grep -c 'Re-execing inside' <gatelog>` is the one-command discriminator**
  between the sanctioned and hand-launched configurations — 1 and 0
  respectively. Anyone reporting a Windows gate result should be able to say
  which configuration produced it; the two produce opposite verdicts from the
  same tree. This is a better artefact than either host's transcript.

- **A green run on a path that cannot reach the condition is a pass that
  asserts nothing** (yoga's framing, adopted). So the hermetic fixture that can
  go red on a revert — yoga's case 6, two runnable stubs in one directory with
  the ELF required to win — is the load-bearing artefact, and a production
  transcript that depends on one host's accidental configuration is the weaker
  one, because nobody else can reproduce it.
