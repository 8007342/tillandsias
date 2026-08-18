## Cycle 2026-08-18T03:36Z (cont.) — seven Step 1 attempts, seven distinct real causes, six fixed; priority (3) complete

**Result: the substrate was never destroyed, and that was correct every time.
Step 1 failed seven times and no two failures shared a cause. Six are fixed or
explained; the seventh is filed. Priority (3) — the operator's expert
architecture — is now fully closed.**

### The seven attempts

| # | Failed at | Cause | Disposition |
| - | --------- | ----- | ----------- |
| 1 | pre-build ×5 + container-bases | 4× my `capabilities.txt` mis-sort, 1× my perf regression, 1× the fork's `:latest` in a mock argument | fixed (816-kq2z) |
| 2 | post-build forge lane | credential, FULL mode — a correct refusal | 809-w2xy, operator |
| 3 | post-build forge lane | credential, SMOKE mode — wrong; smoke pushes nothing | fixed (818-cgpn) |
| 4 | runtime residual | stale EMPTY `/dev/shm/tillandsias-experts` | cleared; not recreated |
| 5 | pre-build | load starvation: a 0s fixture starved past 30s | flake (820-c8q8) |
| 6 | pre-build lib tests | the sibling's 551 registered an engine with no graded corpus | fixed (551 follow-on) |
| 7 | post-build forge lane | smoke ran 252 in-forge litmus, got 1/252, honestly refused | filed (822-4vwa) |

Attempt 4 is the one that matters most: **post-build passed 11/11**, forge lane
included. That is the first green post-build phase on this host in this
campaign, and it is the live evidence 818-cgpn was held open for.

### What I got wrong, and how it was caught

- **I asserted a green I had not checked.** The 812-d45t closure says "Crate
  tests 176 pass" — that was the LIB suite; the BIN suite was red on a
  mis-sorted `capabilities.txt` line. Four litmus tests end with "the crate's
  own unit pins are GREEN", so one line produced four failures pointing away
  from the cause. **No gate runs that test directly.**
- **The mirror image of it, from a sibling**: `1e8ab97c1` says "green and
  falsifiable" while `cargo test --workspace --lib` was red. `--check` does not
  run lib tests; `--ci-full` does. So `--check` was green on that exact tree.
  Two hosts, one night, the same habit: reading *a* green line as *the* result.
- **I misattributed twice.** I called attempt 5's timeout a possible regression
  (it was load); I let a grep for `MO-SMOKE:` match the litmus's own
  *expected_behavior* text and briefly concluded a failing run had passed. Both
  corrected against authoritative signals (`echo $?` files, `FORGE_EXIT`).
- **The notifications lied about exit codes on every single background build** —
  "exit code 0" while the recorded `echo $?` said 1, eight times out of eight.
  Reading the wrapper's status as the producer's would have wiped the image
  store on a failed gate.

### Priority (3) — complete

801-a2by closed on measurements taken **deliberately before** the reset would
erase them: `tillandsias-spec-index-tillandsias`, 578 MB, three
fingerprint-keyed corpora, 58,156 chunks (19,435 in the 803-su4n code corpus).
The warm-hit claim is recorded as a **bound**, not a stopwatch: the whole forge
lane took 131s against the packet's own ~12min cold build. g9nn, kqme and
su4n were already closed. **All four done.**

### For the operator

- **809-w2xy** — still the root blocker and only you can clear it. The FULL
  forge lane is correctly blocked because it would push. 818-cgpn now lets the
  SMOKE lane survive it, proven live.
- **808-zrzz** — wants a recorded decision. Tonight is the evidence: the forge
  lane blocked the destruction gate in 3 of 7 attempts, it is
  non-deterministic (822-4vwa), and the build/install half — the thing the stop
  rule actually protects — was green in essentially all of them. **I did not
  override the stop rule on my own authority.** I could have: `tillandsias
  --version` and the path probe both returned rc=0, so "no valid local build
  was installed" was false every time. But the rule says stop, and deviating
  from a safety rule by private judgment at midnight is the failure mode, not
  the fix. One line from you re-authorizes it.
- **801-x1nx**, **814-iyu7** — still need your calls.
- **820-c8q8**, **822-4vwa**, **819-s92y**, **815-gdjk** — filed tonight, ready.

### Not done

§2/§3 of the e2e (the destruction and re-provision — still unreached); 406's
runtime half; 802-2536; 767-qrbv. `--install` bumped VERSION on every attempt
(702-eusw) and was reverted each time.
