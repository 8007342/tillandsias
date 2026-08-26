# Pre-registered falsifiers for the Linux curl-install e2e leg

- **Classification:** `exploration/`
- **Host:** yoga (Silverblue, `linux_immutable`) — the Linux leg of the three-platform promote gate
- **Written:** 2026-08-26T01:29Z, **BEFORE the tag exists.** That is the whole point: a falsifier chosen after seeing the result is not a falsifier.
- **Mirrors:** macbook's pre-registration for the macOS leg, at macuahuitl's suggestion.

## Why this file exists rather than a message

Tonight produced seven self-retractions and at least two claims that lived only
in transcripts until someone went looking. A pre-registration that is not
committed before the event is indistinguishable from a rationalisation after
it. This is timestamped in git ahead of the tag so the ordering is checkable.

## The failure this whole evening started from

A Linux host deferred its e2e because "v0.4.260817.1 has 2026-08-17 PASS
findings" — those findings were **Windows-only**. Two platforms reached zero
coverage and nobody noticed. So: this leg's report names the exact tag, states
the platform, and inherits nothing.

## Measured pre-state, so the post-state is comparable

```
2026-08-26T01:29:31Z
podman: Images 1 (2.182GB) / Containers 1 (918.6MB) / Local Volumes 1
  container: tillandsias-builder  (fedora-toolbox:44, Up 5 hours)
  image:     registry.fedoraproject.org/fedora-toolbox:44  3a39a7ef141d
  volume:    tillandsias-spec-index-tillandsias
graphroot depth-2 entries: 33
installed binary: Tillandsias v0.4.260823.1
latest published release: v0.4.260810.1
```

**Note the pre-state is already anomalous and it is recorded, not smoothed:**
the installed binary is `v0.4.260823.1`, which exists as **no published
release**. Its provenance is an unrecorded local `./build.sh --install`. It is
not evidence of anything and is not counted as coverage.

## The six falsifiers

Each names the way a Linux PASS could be untrustworthy, and the check that
rules it out. A leg that cannot run one of these reports it as unruled-out
rather than omitting it.

1. **A `--version` assertion that cannot fail.** Asserting the binary "reports a
   version" passes on the pre-existing `v0.4.260823.1` and proves no install
   happened. RULED OUT BY: recording the pre-install version above, then
   asserting `tillandsias --version` equals the **exact new tag string**. A
   no-op install is then visible as an unchanged version.

2. **Destruction that removed nothing.** `podman system reset --force` on an
   already-empty store succeeds silently and looks identical to a real reset.
   RULED OUT BY: the non-zero pre-state above, plus `podman system df` after,
   which must show 0 images / 0 containers. **If the pre-state is empty when
   the reset runs, the idempotence claim is unproven and I say so rather than
   reporting a green reset.**

3. **`--init` exiting 0 without provisioning.** RULED OUT BY: requiring positive
   post-conditions that did not exist pre-reset — named images present, the
   forge container creatable — not merely `rc=0`.

4. **A health check that predates the last mutating step.** Earned 2026-08-10: a
   sibling reported 4/4 PASS on a `--diagnose` taken at 04:32:20, then ran one
   more mutating step that wedged the host at 04:33:27. RULED OUT BY: re-running
   `--diagnose` after the LAST mutating step, whatever that turns out to be, and
   treating any earlier health reading as stale.

5. **A `curl | bash` install that half-failed.** A pipe reports the LAST
   command's status, so a failed download can present as success. This exact
   class bit me tonight: I read `$?` after a pipeline, got `tail`'s status, and
   published it as the gate's exit code. RULED OUT BY: capturing
   `${PIPESTATUS[@]}` for every stage, and asserting the installer's own status
   rather than the pipeline's.

6. **A guest/tray version skew that no longer warns.** RULED OUT BY: recording
   both versions post-install and asserting the skew warning fires when they
   differ — a silent skew is the 531-shape (truthful state, wrong artifact).

## Reporting rules, also pre-registered

- **Raw outputs, not verdicts.** Commands and their actual output; the reader
  derives the verdict.
- **No retry-for-green.** An unexplained red is reported as a red. Re-running to
  get a better result destroys the evidence — `target/convergence/check-logs/`
  is overwritten by the next run, which is how a real intermittent failure
  survived two cycles being called "unexplained".
- **The toolbox cost is stated, not hidden.** The reset destroys
  `tillandsias-builder`, so this host cannot gate or push for ~2.5 min
  afterwards (measured: image pull 11.5s, `toolbox create` 0.1s, first forced
  `--check` 131.9s). A slow first `--check` after the reset is that, not a hang.
- **Skips are reported as skips.** Per 888-miiy, a capability gap is a loud
  named skip, never a silent green. If this host cannot exercise something, the
  report says which and why.
