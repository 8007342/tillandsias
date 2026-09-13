# Fleet restart drill — yoga findings

Per-host file (coordinator folds these; the main
`fleet-restart-2026-09-12.md` has one writer). FLAT name deliberately: a
`.d/` subdirectory matches the pre-push lane's `*/*` arm and takes the FULL
gate on every note — only `research/`, `exploration/`, `enhancement/` and
`optimization/` buy a subdirectory the plan-only lane.

## 2026-09-13 — yoga

- **A green run on a path that cannot reach the condition is a pass that
  asserts nothing.** The sanctioned Windows gate exports `CARGO_TARGET_DIR` to
  an ext4 dir holding Linux artefacts only, so `resolve_target_binary` never
  sees two runnable candidates and the ordering cannot matter there. A green
  sanctioned gate is therefore SILENT about the 1140-d6ni fix. The hermetic
  fixture arm is the only artefact in the tree that can go red on a revert.
  Generalises past this packet: before quoting a green as coverage, ask whether
  that path can reach the condition at all.

- **Name the path/variable the code actually reads before theorising about how
  hosts differ.** Four environment-asymmetry stories died on one measurement
  each in one night: a mirrored ruby layout (host had ruby in both contexts), a
  930-line "stale skill copy" (`git show HEAD:` on an untracked path returns 0
  bytes), "which side of the WSL boundary runs the step" (it was
  `CARGO_TARGET_DIR`), and an `ok:`-on-skip report (the quoted line was a
  fixture's own assertion text, not production output). Three of the four were
  mine. `resolve_target_binary` reads a DIRECTORY; naming that first would have
  replaced every one of those stories.

- **A mutation test whose mutation did not apply reports a PASS.** Twice in one
  night a `sed`/`perl` pattern missed (indentation had changed) and the fixture
  came back green against an unmutated file — which reads exactly like a fixture
  with teeth. Now a step: print the diff and REFUSE if it is empty before
  believing any mutation result.

- **`./build.sh --check` short-circuits on its freshness stamp.** A re-run on an
  unchanged tree prints `ok:gate-fresh` and exits in seconds without running a
  gate, so a stray-process check taken across such a run finds nothing — a true
  observation about a gate that never started. Any reproduction that depends on
  a gate having run must pass `TILLANDSIAS_FORCE_CHECK=1`.

- **Editing a tracked file while a gate is running refuses the land**
  (`violation:gate-wrote-tracked-files:1`, 1063-363b). The guard is aimed at the
  gate writing into the checkout; a human editing mid-run is the same
  observable. Cost one gate. The checkout lock exists for the multi-agent case;
  this is the single-agent version of the same discipline.

- **Choose a `gate-steps.d/NNN-*.step` prefix AFTER the integrate.** The landing
  script pulls sibling hosts' steps in, so a slot free when the file was written
  can be taken by gate time. Cost one gate.

- **One-command configuration discriminator for any Windows gate result**
  (esme): `grep -c 'Re-execing inside' <gatelog>` — `1` sanctioned, `0`
  hand-launched. The two configurations produced opposite verdicts from the
  same tree, so a Windows gate result reported without it is underdetermined.
