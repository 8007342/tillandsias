## 1. Methodology refinement

- [ ] 1.1 Edit `methodology/versioning.yaml`: add `artifact_namespace_prefix` section per `design.md` D1–D4 (closed vocabulary `v|m|w`, examples for all three, comparison semantics statement).
- [ ] 1.2 Edit `methodology/versioning.yaml`: extend `artifacts_and_tracing.embedding` block to note that host-shell binaries embed the prefix in their platform-native version metadata (`Info.plist` `CFBundleShortVersionString` for macOS; `FileVersion` resource for Windows).
- [ ] 1.3 Edit `methodology/versioning.yaml`: extend `metadata_tracking.format` example JSONL to include a `"prefix"` field, and add a `metadata_tracking.prefix_default` note that absence implies `v`.
- [ ] 1.4 Add a `@trace spec:versioning` annotation to the new section.

## 2. Version utility scripts

- [ ] 2.1 Edit `scripts/bump-version.sh`: add `--prefix=<v|m|w>` flag parsing (default `v`); reject any other value with a usage diagnostic.
- [ ] 2.2 Edit `scripts/bump-version.sh`: when emitting the version string for `stdout` / file writes other than `VERSION`, prepend the resolved prefix. Confirm `VERSION` file content stays prefix-less (four positional components + commit hash only).
- [ ] 2.3 Edit `scripts/verify-version-monotonic.sh`: accept `v`, `m`, `w` as leading character; reject any other with the documented error.
- [ ] 2.4 Add unit test `scripts/tests/bump-version-prefix.bats` covering: default `v`, explicit `m`, explicit `w`, invalid `q`. Run via existing bats harness.

## 3. Release parity verification

- [ ] 3.1 Create `scripts/verify-release-parity.sh <tag>`. Fetches artifacts from the GitHub release for `<tag>` (via `gh release download`), extracts each artifact's embedded version, compares the four positional components, exits non-zero if they diverge.
- [ ] 3.2 Add `scripts/tests/verify-release-parity.bats` with three cases: all-match passes; build-component drift fails; single-variant release passes vacuously.
- [ ] 3.3 Add a new job `release-parity-check` to `.github/workflows/release.yml`: runs after the macOS and Windows tray build jobs (`needs: [build-linux, build-macos-tray, build-windows-tray]`), invokes `verify-release-parity.sh ${{ github.ref_name }}`, marks the release as blocked on failure.

## 4. version-history.jsonl format extension

- [ ] 4.1 Update the script that appends to `version-history.jsonl` (in `scripts/bump-version.sh` per task 2.2) to include `"prefix": "<resolved>"` in every new entry.
- [ ] 4.2 Add a migration note to `methodology/versioning.yaml.metadata_tracking` documenting that historical entries without `"prefix"` default to `"v"`; no rewrite of the existing log is performed.
- [ ] 4.3 Add a smoke test that creates a fresh `version-history.jsonl`, appends entries with each prefix, and verifies `jq` queries on `version` still return the four-positional component strings.

## 5. Spec sync

- [ ] 5.1 Run `/opsx:sync` (or `openspec specs sync --change artifact-namespace-prefix-versioning`) to merge the delta into `openspec/specs/versioning/spec.md`.
- [ ] 5.2 Add cross-reference notes in `openspec/specs/macos-native-tray/spec.md` and `openspec/specs/windows-native-tray/spec.md` pointing at the new versioning requirements.
- [ ] 5.3 Regenerate `openspec/specs/versioning/TRACES.md`.

## 6. Verify

- [ ] 6.1 Run `openspec validate artifact-namespace-prefix-versioning` — expect "valid".
- [ ] 6.2 Run the bats test suite locally — all green.
- [ ] 6.3 Run `scripts/verify-version-monotonic.sh` against three fabricated tags (`v0.2.260523.6`, `m0.2.260523.6`, `w0.2.260523.6`) — all three pass.
- [ ] 6.4 Dry-run `scripts/verify-release-parity.sh` against a recent test tag — exits zero.

## 7. Archive

- [ ] 7.1 Once implementation is verified end-to-end, run `/opsx:archive artifact-namespace-prefix-versioning`.
- [ ] 7.2 Bump `Change` counter in `VERSION` per archive protocol.
