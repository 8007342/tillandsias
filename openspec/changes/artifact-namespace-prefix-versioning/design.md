## Context

`methodology/versioning.yaml` (v0.5) defines the canonical CalVer format:
```
v<Major>.<Minor>.<YYMMDD>.<Build>+<CommitHash>
```
The leading `v` is a literal denoting "version". The version is monotonic, calendar-anchored, and reproducible via the LUB-on-merge resolution rule. The format has shipped well over a hundred releases and is load-bearing for `scripts/verify-version-monotonic.sh`, the CI release pipeline, and the `version-history.jsonl` audit log.

The Windows + macOS host-shell wave introduces two new artifacts that are not standalone — they are **host-side variants** of the same logical release. The macOS tray (`tillandsias-tray.app`) and the Windows tray (`tillandsias-tray.exe`) are version-locked to a specific Linux tillandsias:
- They speak the vsock control wire whose envelope schema is defined alongside the Linux headless (`spec:vsock-transport`).
- They materialize the in-VM rootfs from a recipe whose hash inputs include the Linux tillandsias version (`spec:vm-provisioning-lifecycle`, post-recipe-refinement).
- They run inside the same logical release window — a v0.2 tray cannot drive a v0.3 in-VM headless without protocol breakage.

Three release artifacts, one logical release. The version string needs to declare both the release identity and the host context.

## Goals / Non-Goals

**Goals:**
- Make the host context (Linux / macOS / Windows) legible at a glance from any embedded version string, log line, or release tag.
- Enforce — via CI, not convention — that the three variants of a given release share `Major.Minor.YYMMDD.Build`.
- Preserve full backward compatibility with the existing `v`-prefix and existing tag history.
- Keep the LUB-on-merge ordering rule operational: prefix is part of the artifact identity, NOT part of version comparison.

**Non-Goals:**
- Reorganizing the four positional components (`Major.Minor.YYMMDD.Build`) — they stay.
- Defining prefixes for non-host-shell artifacts (container images, sidecars, etc). Those keep `v` or remain unprefixed per current convention.
- Cross-host code sharing — that's settled by the `tillandsias-host-shell` crate and unrelated to versioning.
- Renaming, migrating, or rewriting existing `v`-prefixed tags. Historic immutability per `spec:versioning` invariant is unchanged.

## Decisions

### D1: Single-letter prefix replaces the leading `v`

`m0.2.260523.6+abcd123` rather than `vm0.2.260523.6+abcd123` or `v0.2.260523.6+m+abcd123`. The single letter is the entire prefix; `v` is itself a value of the same enum (canonical Linux).

**Why over alternatives:**
- `vm`/`vw`/`vv` (compound) — visually noisy, breaks the `[vV]\d` grep patterns shipped in `verify-version-monotonic.sh` and several editor extensions.
- Build-metadata suffix (e.g. `+macos`) — semver-style metadata is ignored by most version comparators including ours, so the host context wouldn't reliably round-trip through tag fetches.
- Separate registry namespace (e.g. ghcr.io/tillandsias-macos/) — solves the artifact storage question but not the human-readability question. Orthogonal; can still happen later.

### D2: Three letters now (`v`, `m`, `w`), open for extension

The vocabulary is closed (CI rejects unknown prefixes) but documented as extensible. Future host-shells (e.g. iPad sidecar, ChromeOS) would add their letter through a methodology refinement.

### D3: Parity is a release-time CI gate, not a build-time invariant

A developer building `tillandsias-macos-tray` locally on a non-tagged commit gets `m0.2.260524.dev+localhash` — no parity check; this is a developer build. Parity is enforced only by the `release-parity-check` CI job when all three artifacts have been uploaded to a tag.

**Why:** local dev velocity matters more than enforced cross-host coupling. The contract bites at release; until then artifacts can drift freely.

### D4: Version comparison ignores the prefix

`m0.2.260523.6 < m0.2.260523.7` and `v0.2.260523.6 < m0.2.260523.7` both hold under the existing comparator. Two artifacts with the same `Major.Minor.YYMMDD.Build` but different prefixes are **incomparable by version** but **equal as release-tuples**. The methodology yaml will name this explicitly: "comparison is on the four positional components; prefix denotes artifact namespace and is not ordered."

### D5: `version-history.jsonl` records the prefix in a separate field

```json
{ "version": "0.2.260523.6", "prefix": "m", "date": "...", ... }
```
Keeping prefix out of the `version` field preserves existing jq-based queries; new queries can filter on prefix.

## Risks / Trade-offs

- **[R1] Existing tooling that hardcodes a `v` prefix breaks.** → Mitigation: the methodology section explicitly lists `v` as the default and required-when-unspecified value. Scripts that emit `v$(cat VERSION)` continue to work. Only new prefix-aware tooling (the macOS/Windows build pipelines, the parity-check job) must be aware of the vocabulary.
- **[R2] Three release artifacts implies three CI build pipelines all green before release.** → Mitigation: the parity-check job is the single gate; individual host pipelines fail independently and can be retried without blocking the others. The gate only fires when all three uploaded artifacts exist on the tag.
- **[R3] Human confusion: "is `m` a typo for `v`?"** → Mitigation: methodology yaml example block puts all three side-by-side. Release notes always cite all three artifact names + their prefixed versions.
- **[R4] Some downstream consumer (homebrew formula, third-party packager) might version-compare `m...` against `v...` and get unexpected ordering.** → Mitigation: the parity contract means the four positional components match for the same release, so naive lexical sort still groups artifacts of the same release together. Document this explicitly.
- **[R5] The methodology refinement workflow is heavier than the change itself.** → Acknowledged. The refinement establishes the discipline; the build-script and CI changes are mechanical.

## Migration Plan

1. Land the methodology yaml edit + `bump-version.sh --prefix` flag + `verify-version-monotonic.sh` extension on `linux-next`. No behavior change for existing pipelines; default prefix `v` keeps the old shape.
2. macOS tray build pipeline (added in a parallel change) consumes `--prefix=m` from day one — its first release is `m0.2.YYMMDD.B`.
3. Windows tray build pipeline similarly consumes `--prefix=w`.
4. `release-parity-check` CI job is added with `if: github.event_name == 'release'` — runs only on tagged releases, no impact on push/PR builds.
5. Rollback: revert the methodology yaml + script edits; the parity-check job is independent and can be disabled by setting a workflow flag without reverting the rest.

## Open Questions

- Should the prefix vocabulary live in `methodology/versioning.yaml` alone or be duplicated into a machine-readable manifest under `methodology/manifests/` for non-yaml consumers? **Default:** yaml only; consumers parse it.
- Should `version-history.jsonl` continue to be a single append-only file, or split per prefix (`version-history-v.jsonl`, `version-history-m.jsonl`)? **Default:** single file with a `"prefix"` field; preserves existing queries.
- Should the parity-check job auto-create a GitHub release annotation when parity is verified? **Default:** out of scope; release notes already enumerate artifacts.
